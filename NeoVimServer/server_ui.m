/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

@import Foundation;

#import "Logging.h"
#import "server_globals.h"
#import "NeoVimServer.h"
#import "NeoVimUiBridgeProtocol.h"
#import "NeoVimBuffer.h"
#import "NeoVimWindow.h"
#import "NeoVimTab.h"
#import "CocoaCategories.h"
#import "DataWrapper.h"

// FileInfo and Boolean are #defined by Carbon and NeoVim: Since we don't need the Carbon versions of them, we rename
// them.
#define FileInfo CarbonFileInfo
#define Boolean CarbonBoolean

#import <nvim/vim.h>
#import <nvim/api/vim.h>
#import <nvim/ui.h>
#import <nvim/ui_bridge.h>
#import <nvim/ex_getln.h>
#import <nvim/fileio.h>
#import <nvim/undo.h>
#import <nvim/api/window.h>


#define pun_type(t, x) (*((t *) (&(x))))

typedef struct {
    UIBridgeData *bridge;
    Loop *loop;

    bool stop;
} ServerUiData;

// We declare nvim_main because it's not declared in any header files of neovim
extern int nvim_main(int argc, char **argv);

static unsigned int _default_foreground = qDefaultForeground;
static unsigned int _default_background = qDefaultBackground;
static unsigned int _default_special = qDefaultSpecial;

// The thread in which neovim's main runs
static uv_thread_t _nvim_thread;

// Condition variable used by the XPC's init to wait till our custom UI initialization is finished inside neovim
static bool _is_ui_launched = false;
static uv_mutex_t _mutex;
static uv_cond_t _condition;

static ServerUiData *_server_ui_data;

static NSString *_marked_text = nil;

static int _marked_row = 0;
static int _marked_column = 0;

// for 하 -> hanja popup, Cocoa first inserts 하, then sets marked text, cf docs/notes-on-cocoa-text-input.md
static int _marked_delta = 0;

static int _put_row = -1;
static int _put_column = -1;

static NSString *_backspace = nil;

#pragma mark Helper functions
static inline int screen_cursor_row() {
  return curwin->w_winrow + curwin->w_wrow;
}

static inline int screen_cursor_column() {
  return curwin->w_wincol + curwin->w_wcol;
}

static inline String vim_string_from(NSString *str) {
  return (String) { .data = (char *) str.cstr, .size = str.clength };
}

static bool has_dirty_docs() {
  FOR_ALL_BUFFERS(buffer) {
    if (buffer->b_p_bl == 0) {
      continue;
    }

    if (bufIsChanged(buffer)) {
      return true;
    }
  }

  return false;
}

static void insert_marked_text(NSString *markedText) {
  _marked_text = [markedText retain]; // release when the final text is input in -vimInput

  nvim_input(vim_string_from(markedText));
}

static void delete_marked_text() {
  NSUInteger length = [_marked_text lengthOfBytesUsingEncoding:NSUTF32StringEncoding] / 4;

  [_marked_text release];
  _marked_text = nil;

  for (int i = 0; i < length; i++) {
    nvim_input(vim_string_from(_backspace));
  }
}

static void run_neovim(void *arg __unused) {
  char *argv[1];
  argv[0] = "nvim";

  nvim_main(1, argv);
}

static void set_ui_size(UIBridgeData *bridge, int width, int height) {
  bridge->ui->width = width;
  bridge->ui->height = height;
  bridge->bridge.width = width;
  bridge->bridge.height = height;
}

static void server_ui_scheduler(Event event, void *d) {
  UI *ui = d;
  ServerUiData *data = ui->data;
  loop_schedule(data->loop, event);
}

static void server_ui_main(UIBridgeData *bridge, UI *ui) {
  Loop loop;
  loop_init(&loop, NULL);

  _server_ui_data = xcalloc(1, sizeof(ServerUiData));
  ui->data = _server_ui_data;
  _server_ui_data->bridge = bridge;
  _server_ui_data->loop = &loop;

  set_ui_size(bridge, 30, 15);

  _server_ui_data->stop = false;
  CONTINUE(bridge);

  uv_mutex_lock(&_mutex);
  _is_ui_launched = true;
  uv_cond_signal(&_condition);
  uv_mutex_unlock(&_mutex);

  while (!_server_ui_data->stop) {
    loop_poll_events(&loop, -1);
  }

  ui_bridge_stopped(bridge);
  loop_close(&loop, false);

  xfree(_server_ui_data);
  xfree(ui);
}

#pragma mark NeoVim's UI callbacks

static void server_ui_resize(UI *ui __unused, int width, int height) {
  int values[] = {width, height};
  NSData *data = [[NSData alloc] initWithBytes:values length:(2 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdResize data:data];
  [data release];
}

static void server_ui_clear(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdClear];
}

static void server_ui_eol_clear(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdEolClear];
}

static void server_ui_cursor_goto(UI *ui __unused, int row, int col) {
  _put_row = row;
  _put_column = col;

  int values[] = {
    row, col,
    screen_cursor_row(), screen_cursor_column(),
    (int) curwin->w_cursor.lnum, curwin->w_cursor.col + 1
  };

  DLOG("%d:%d - %d:%d - %d:%d", values[0], values[1], values[2], values[3], values[4], values[5]);

  NSData *data = [[NSData alloc] initWithBytes:values length:(6 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetPosition data:data];
  [data release];
}

static void server_ui_update_menu(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetMenu];
}

static void server_ui_busy_start(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdBusyStart];
}

static void server_ui_busy_stop(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdBusyStop];
}

static void server_ui_mouse_on(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdMouseOn];
}

static void server_ui_mouse_off(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdMouseOff];
}

static void server_ui_mode_info_set(UI *ui __unused, bool enabled __unused, Array cursor_styles __unused) {
  // yet noop
}

static void server_ui_mode_change(UI *ui __unused, int mode) {
  int value = mode;
  NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdModeChange data:data];
  [data release];
}

static void server_ui_set_scroll_region(UI *ui __unused, int top, int bot, int left, int right) {
  int values[] = {top, bot, left, right};
  NSData *data = [[NSData alloc] initWithBytes:values length:(4 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetScrollRegion data:data];
  [data release];
}

static void server_ui_scroll(UI *ui __unused, int count) {
  int value = count;
  NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdScroll data:data];
  [data release];
}

static void server_ui_highlight_set(UI *ui __unused, HlAttrs attrs) {
  FontTrait trait = FontTraitNone;
  if (attrs.italic) {
    trait |= FontTraitItalic;
  }
  if (attrs.bold) {
    trait |= FontTraitBold;
  }
  if (attrs.underline) {
    trait |= FontTraitUnderline;
  }
  if (attrs.undercurl) {
    trait |= FontTraitUndercurl;
  }
  CellAttributes cellAttrs;
  cellAttrs.fontTrait = trait;

  unsigned int fg = attrs.foreground == -1 ? _default_foreground : pun_type(unsigned int, attrs.foreground);
  unsigned int bg = attrs.background == -1 ? _default_background : pun_type(unsigned int, attrs.background);

  cellAttrs.foreground = attrs.reverse ? bg : fg;
  cellAttrs.background = attrs.reverse ? fg : bg;
  cellAttrs.special = attrs.special == -1 ? _default_special : pun_type(unsigned int, attrs.special);

  NSData *data = [[NSData alloc] initWithBytes:&cellAttrs length:sizeof(CellAttributes)];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetHighlightAttributes data:data];
  [data release];
}

static void server_ui_put(UI *ui __unused, uint8_t *str, size_t len) {
  NSString *string = [[NSString alloc] initWithBytes:str length:len encoding:NSUTF8StringEncoding];
  int cursor[] = {screen_cursor_row(), screen_cursor_column()};

  NSMutableData *data = [[NSMutableData alloc]
    initWithCapacity:2 * sizeof(int) + [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
  [data appendBytes:cursor length:2 * sizeof(int)];
  [data appendData:[string dataUsingEncoding:NSUTF8StringEncoding]];

  if (_marked_text != nil && _marked_row == _put_row && _marked_column == _put_column) {
    DLOG("putting marked text: '%s'", string.cstr);
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdPutMarked data:data];
  } else if (_marked_text != nil && len == 0 && _marked_row == _put_row && _marked_column == _put_column - 1) {
    DLOG("putting marked text cuz zero");
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdPutMarked data:data];
  } else {
    DLOG("putting non-marked text: '%s'", string.cstr);
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdPut data:data];
  }

  _put_column += 1;

  [data release];
  [string release];
}

static void server_ui_bell(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdBell];
}

static void server_ui_visual_bell(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdVisualBell];
}

static void server_ui_flush(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdFlush];
}

static void server_ui_update_fg(UI *ui __unused, int fg) {
  int value[1];

  if (fg == -1) {
    value[0] = _default_foreground;
    NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetForeground data:data];
    [data release];

    return;
  }

  _default_foreground = pun_type(unsigned int, fg);

  value[0] = fg;
  NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetForeground data:data];
  [data release];
}

static void server_ui_update_bg(UI *ui __unused, int bg) {
  int value[1];

  if (bg == -1) {
    value[0] = _default_background;
    NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetBackground data:data];
    [data release];

    return;
  }

  _default_background = pun_type(unsigned int, bg);
  value[0] = bg;
  NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetBackground data:data];
  [data release];
}

static void server_ui_update_sp(UI *ui __unused, int sp) {
  int value[2];

  if (sp == -1) {
    value[0] = _default_special;
    NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetSpecial data:data];
    [data release];

    return;
  }

  _default_special = pun_type(unsigned int, sp);
  value[0] = sp;
  NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(int))];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetSpecial data:data];
  [data release];
}

static void server_ui_set_title(UI *ui __unused, char *title) {
  if (title == NULL) {
    return;
  }

  NSString *string = [[NSString alloc] initWithCString:title encoding:NSUTF8StringEncoding];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetTitle data:[string dataUsingEncoding:NSUTF8StringEncoding]];
  [string release];
}

static void server_ui_set_icon(UI *ui __unused, char *icon) {
  if (icon == NULL) {
    return;
  }

  NSString *string = [[NSString alloc] initWithCString:icon encoding:NSUTF8StringEncoding];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetIcon data:[string dataUsingEncoding:NSUTF8StringEncoding]];
  [string release];
}

static void server_ui_stop(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdStop];

  ServerUiData *data = (ServerUiData *) ui->data;
  data->stop = true;
}

#pragma mark Public
// called by neovim

void custom_ui_start(void) {
  UI *ui = xcalloc(1, sizeof(UI));

  ui->rgb = true;
  ui->stop = server_ui_stop;
  ui->resize = server_ui_resize;
  ui->clear = server_ui_clear;
  ui->eol_clear = server_ui_eol_clear;
  ui->cursor_goto = server_ui_cursor_goto;
  ui->update_menu = server_ui_update_menu;
  ui->busy_start = server_ui_busy_start;
  ui->busy_stop = server_ui_busy_stop;
  ui->mouse_on = server_ui_mouse_on;
  ui->mouse_off = server_ui_mouse_off;
  ui->mode_info_set = server_ui_mode_info_set;
  ui->mode_change = server_ui_mode_change;
  ui->set_scroll_region = server_ui_set_scroll_region;
  ui->scroll = server_ui_scroll;
  ui->highlight_set = server_ui_highlight_set;
  ui->put = server_ui_put;
  ui->bell = server_ui_bell;
  ui->visual_bell = server_ui_visual_bell;
  ui->update_fg = server_ui_update_fg;
  ui->update_bg = server_ui_update_bg;
  ui->update_sp = server_ui_update_sp;
  ui->flush = server_ui_flush;
  ui->suspend = NULL;
  ui->set_title = server_ui_set_title;
  ui->set_icon = server_ui_set_icon;

  ui_bridge_attach(ui, server_ui_main, server_ui_scheduler);
}

void custom_ui_autocmds_groups(
    event_T event, char_u *fname, char_u *fname_io, int group, bool force, buf_T *buf, exarg_T *eap
) {
  // We don't need these events in the UI (yet) and they slow down scrolling: Enable them, if necessary, only after
  // optimizing the scrolling.
  if (event == EVENT_CURSORMOVED || event == EVENT_CURSORMOVEDI) {
    return;
  }

  @autoreleasepool {
    DLOG("got event %d for file %s in group %d.", event, fname, group);

//    if (event == EVENT_TEXTCHANGED
//      || event == EVENT_TEXTCHANGEDI
//      || event == EVENT_BUFWRITEPOST
//      || event == EVENT_BUFLEAVE)
//    {
//      send_dirty_status();
//    }

    NSUInteger eventCode = event;

    NSMutableData *data;
    if (buf == NULL) {
      data = [[NSMutableData alloc] initWithBytes:&eventCode length:sizeof(NSUInteger)];
    } else {
      NSInteger bufHandle = buf->handle;

      data = [[NSMutableData alloc] initWithCapacity:(sizeof(NSUInteger) + sizeof(NSInteger))];
      [data appendBytes:&eventCode length:sizeof(NSUInteger)];
      [data appendBytes:&bufHandle length:sizeof(NSInteger)];
    }

    [_neovim_server sendMessageWithId:NeoVimServerMsgIdAutoCommandEvent data:data];

    [data release];
  }
}

#pragma mark Other help functions
void start_neovim() {
  // set $VIMRUNTIME to ${RESOURCE_PATH_OF_XPC_BUNDLE}/runtime
  NSString *bundlePath = [NSBundle bundleForClass:[NeoVimServer class]].bundlePath;
  NSString *resourcesPath = [bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Resources"];
  NSString *runtimePath = [resourcesPath stringByAppendingPathComponent:@"runtime"];
  setenv("VIMRUNTIME", runtimePath.fileSystemRepresentation, true);

  // Set $LANG to en_US.UTF-8 such that the copied text to the system clipboard is not garbled.
  setenv("LANG", "en_US.UTF-8", true);

  uv_mutex_init(&_mutex);
  uv_cond_init(&_condition);

  uv_thread_create(&_nvim_thread, run_neovim, NULL);
  DLOG("NeoVim started");

  // continue only after our UI main code for neovim has been fully initialized
  uv_mutex_lock(&_mutex);
  while (!_is_ui_launched) {
    uv_cond_wait(&_condition, &_mutex);
  }
  uv_mutex_unlock(&_mutex);

  uv_cond_destroy(&_condition);
  uv_mutex_destroy(&_mutex);

  _backspace = [[NSString alloc] initWithString:@"<BS>"];

  bool value = msg_didany > 0;
  NSData *data = [[NSData alloc] initWithBytes:&value length:sizeof(bool)];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdNeoVimReady data:data];
  [data release];
}

void quit_neovim() {
  DLOG("NeoVimServer exiting...");
  CFRunLoopStop(_mainRunLoop);
}

#pragma mark Functions for neovim's main loop

typedef NSData *(^work_block)(NSData *);

static void work_and_write_data_sync(void **argv, work_block block) {
  @autoreleasepool {
    NSCondition *outputCondition = argv[1];
    [outputCondition lock];

    NSData *data = argv[0];
    DataWrapper *wrapper = argv[2];
    wrapper.data = block(data);
    wrapper.dataReady = YES;
    [data release]; // retained in local_server_callback

    [outputCondition signal];
    [outputCondition unlock];
  }
}

//static void work_async(void **argv, work_block block) {
//  @autoreleasepool {
//    NSData *data = argv[0];
//    block(data);
//    [data release]; // retained in local_server_callback
//  }
//}

static NSString *escaped_filename(NSString *filename) {
  const char *file_system_rep = filename.fileSystemRepresentation;

  char *escaped_filename = vim_strsave_fnameescape(file_system_rep, 0);
  NSString *result = [NSString stringWithCString:(const char *) escaped_filename encoding:NSUTF8StringEncoding];
  xfree(escaped_filename);

  return result;
}

static NeoVimBuffer *buffer_for(buf_T *buf) {
  // To be sure...
  if (buf == NULL) {
    return nil;
  }

  if (buf->b_p_bl == 0) {
    return nil;
  }

  NSString *fileName = nil;
  if (buf->b_ffname != NULL) {
    fileName = [NSString stringWithCString:(const char *) buf->b_ffname encoding:NSUTF8StringEncoding];
  }

  bool current = curbuf == buf;

  NeoVimBuffer *buffer = [[NeoVimBuffer alloc] initWithHandle:buf->handle
                                                unescapedPath:fileName
                                                        dirty:(bool) buf->b_changed
                                                     readOnly:(bool) buf->b_p_ro
                                                      current:current];

  return [buffer autorelease];
}

void neovim_select_window(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    int handle = ((int *) data.bytes)[0];

    FOR_ALL_TAB_WINDOWS(tab, win) {
        if (win->handle == handle) {
          Error err = ERROR_INIT;
          nvim_set_current_win(win->handle, &err);

          if (ERROR_SET(&err)) {
            WLOG("Error selecting window with handle %d: %s", win->handle, err.msg);
            return nil;
          }

          // nvim_set_current_win() does not seem to trigger a redraw.
          ui_schedule_refresh();

          return nil;
        }
      }

    return nil;
  });
}

void neovim_tabs(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSMutableArray *tabs = [[NSMutableArray new] autorelease];
    FOR_ALL_TABS(t) {
      NSMutableArray *windows = [NSMutableArray new];

      FOR_ALL_WINDOWS_IN_TAB(win, t) {
        NeoVimBuffer *buffer = buffer_for(win->w_buffer);
        if (buffer == nil) {
          continue;
        }

        NeoVimWindow *window = [[NeoVimWindow alloc] initWithHandle:win->handle buffer:buffer];
        [windows addObject:window];
        [window release];
      }

      NeoVimTab *tab = [[NeoVimTab alloc] initWithHandle:t->handle windows:windows];
      [windows release];

      [tabs addObject:tab];
      [tab release];
    }

    DLOG("tabs: %s", tabs.description.cstr);
    return [NSKeyedArchiver archivedDataWithRootObject:tabs];
  });
}

void neovim_buffers(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSMutableArray *buffers = [[NSMutableArray new] autorelease];
    FOR_ALL_BUFFERS(buf) {
      NeoVimBuffer *buffer = buffer_for(buf);
      if (buffer == nil) {
        continue;
      }

      [buffers addObject:buffer];
    }

    DLOG("buffers: %s", buffers.description.cstr);
    return [NSKeyedArchiver archivedDataWithRootObject:buffers];
  });
}

void neovim_vim_command_output(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSString *input = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    Error err = ERROR_INIT;
    String commandOutput = nvim_command_output(vim_string_from(input), &err);
    char_u *output = (char_u *) commandOutput.data;

    // FIXME: handle err.set == true
    NSString *result = nil;
    if (output == NULL) {
      WLOG("vim command output is null");
    } else if (ERROR_SET(&err)) {
      WLOG("vim command output for '%s' was not successful: %s", input.cstr, err.msg);
    } else {
      result = [[NSString alloc] initWithCString:(const char *) output encoding:NSUTF8StringEncoding];
    }

    NSData *resultData = result == nil ? nil : [NSKeyedArchiver archivedDataWithRootObject:result];

    [result release];
    [input release];

    return resultData;
  });
}

void neovim_set_bool_option(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    bool *optionValues = (bool *) data.bytes;
    bool optionValue = optionValues[0];

    const char *string = (const char *)(optionValues + 1);
    NSString *optionName = [[NSString alloc] initWithCString:string encoding:NSUTF8StringEncoding];

    Error err = ERROR_INIT;

    Object object = OBJECT_INIT;
    object.type = kObjectTypeBoolean;
    object.data.boolean = optionValue;

    DLOG("%s to set: %d", optionName.cstr, optionValue);

    nvim_set_option(vim_string_from(optionName), object, &err);

    if (ERROR_SET(&err)) {
      WLOG("Error setting the option '%s' to %d: %s", optionName.cstr, optionValue, err.msg);
    }

    [optionName release];

    return nil;
  });
}

void neovim_get_bool_option(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSString *option = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    bool result = false;

    Error err = ERROR_INIT;
    Object resultObj = nvim_get_option(vim_string_from(option), &err);

    if (ERROR_SET(&err)) {
      WLOG("Error getting the boolean option '%s': %s", option.cstr, err.msg);
    }

    if (resultObj.type == kObjectTypeBoolean) {
      result = resultObj.data.boolean;
    } else {
      WLOG("Error got no boolean value, but %d, for option '%s': %s", resultObj.type, option.cstr, err.msg);
    }

    [option release];

    return [NSKeyedArchiver archivedDataWithRootObject:@(result)];
  });
}

void neovim_escaped_filenames(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSArray *fileNames = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    NSMutableArray *result = [NSMutableArray new];

    [fileNames enumerateObjectsUsingBlock:^(NSString* fileName, NSUInteger idx, BOOL *stop) {
      [result addObject:escaped_filename(fileName)];
    }];

    return [NSKeyedArchiver archivedDataWithRootObject:result];
  });
}

void neovim_has_dirty_docs(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    return [NSKeyedArchiver archivedDataWithRootObject:@(has_dirty_docs())];
  });
}

void neovim_resize(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    const int *values = data.bytes;
    int width = values[0];
    int height = values[1];

    set_ui_size(_server_ui_data->bridge, width, height);
    ui_refresh();

    return nil;
  });
}

void neovim_vim_command(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSString *input = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    Error err = ERROR_INIT;
    nvim_command(vim_string_from(input), &err);

    if (ERROR_SET(&err)) {
      WLOG("ERROR while executing command %s: %s", input.cstr, err.msg);
    }

    [input release];

    return nil;
  });
}

void neovim_vim_input(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSString *input = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];

    if (_marked_text == nil) {
      nvim_input(vim_string_from(input));
      return nil;
    }

    // Handle cases like ㅎ -> arrow key: The previously marked text is the same as the finalized text which should
    // inserted. Neovim's drawing code is optimized such that it does not call put in this case again, thus, we have
    // to manually unmark the cells in the main app.
    if ([_marked_text isEqualToString:input]) {
      DLOG("unmarking text: '%s'\t now at %d:%d", input.cstr, _put_row, _put_column);
      const char *str = _marked_text.cstr;
      size_t cellCount = mb_string2cells((const char_u *) str);

      for (int i = 1; i <= cellCount; i++) {
        DLOG("unmarking at %d:%d", _put_row, _put_column - i);
        int values[] = {_put_row, MAX(_put_column - i, 0)};

        NSData *unmarkData = [[NSData alloc] initWithBytes:values length:(2 * sizeof(int))];
        [_neovim_server sendMessageWithId:NeoVimServerMsgIdUnmark data:unmarkData];
        [unmarkData release];
      }
    }

    delete_marked_text();
    nvim_input(vim_string_from(input));

    return nil;
  });
}

void neovim_vim_input_marked_text(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSString *markedText = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];

    if (_marked_text == nil) {
      _marked_row = _put_row;
      _marked_column = _put_column + _marked_delta;
      DLOG("marking position: %d:%d(%d + %d)", _put_row, _marked_column, _put_column, _marked_delta);
      _marked_delta = 0;
    } else {
      delete_marked_text();
    }

    DLOG("inserting marked text '%s' at %d:%d", markedText.cstr, _put_row, _put_column);
    insert_marked_text(markedText);

    return nil;
  });
}

void neovim_delete(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    const NSInteger *values = data.bytes;
    NSInteger count = values[0];

    _marked_delta = 0;

    // Very ugly: When we want to have the Hanja for 하, Cocoa first finalizes 하, then sets the Hanja as marked text.
    // The main app will call this method when this happens, thus compute how many cell we have to go backward to
    // correctly mark the will-be-soon-inserted Hanja... See also docs/notes-on-cocoa-text-input.md
    int emptyCounter = 0;
    for (int i = 0; i < count; i++) {
      _marked_delta -= 1;

      // TODO: -1 because we assume that the cursor is one cell ahead, probably not always correct...
      schar_T character = ScreenLines[_put_row * screen_Rows + _put_column - i - emptyCounter - 1];
      if (character == 0x00 || character == ' ') {
        // FIXME: dunno yet, why we have to also match ' '...
        _marked_delta -= 1;
        emptyCounter += 1;
      }
    }

    DLOG("put cursor: %d:%d, count: %li, delta: %d", _put_row, _put_column, count, _marked_delta);

    for (int i = 0; i < count; i++) {
      nvim_input(vim_string_from(_backspace));
    }

    return nil;
  });
}

void neovim_cursor_goto(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    const int *values = data.bytes;

    Array position = ARRAY_DICT_INIT;

    position.size = 2;
    position.capacity = 2;
    position.items = xmalloc(2 * sizeof(Object));

    Object row = OBJECT_INIT;
    row.type = kObjectTypeInteger;
    row.data.integer = values[0];

    Object col = OBJECT_INIT;
    col.type = kObjectTypeInteger;
    col.data.integer = values[1];

    position.items[0] = row;
    position.items[1] = col;

    Error err = ERROR_INIT;

    nvim_win_set_cursor(nvim_get_current_win(), position, &err);
    // The above call seems to be not enough...
    nvim_input((String) { .data="<ESC>", .size=5 });

    xfree(position.items);

    return nil;
  });
}
