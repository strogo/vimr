/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

@import Cocoa;


@protocol NeoVimUiBridgeProtocol;
@class NeoVimBuffer;
@class NeoVimTab;
@class NeoVimWindow;


NS_ASSUME_NONNULL_BEGIN

@interface NeoVimAgent : NSObject

@property (nonatomic) bool useInteractiveZsh;
@property (readonly, atomic) bool neoVimIsQuitting;
@property (nonatomic, weak) id <NeoVimUiBridgeProtocol> bridge;

- (instancetype)initWithUuid:(NSString *)uuid;

- (void)debug;

- (void)quit;

- (bool)runLocalServerAndNeoVim;

- (void)vimCommand:(NSString *)string;

- (void)vimInput:(NSString *)string;
- (void)vimInputMarkedText:(NSString *)markedText;
- (void)deleteCharacters:(NSInteger)count;

- (void)resizeToWidth:(int)width height:(int)height;
- (void)cursorGoToRow:(int)row column:(int)column;

- (bool)hasDirtyDocs;
- (NSString * _Nullable)escapedFileName:(NSString *)fileName;
- (NSArray<NSString *> *)escapedFileNames:(NSArray<NSString *> *)fileNames;
- (NSArray<NeoVimBuffer *> *)buffers;
- (NSArray<NeoVimTab*> *)tabs;
- (void)selectWindow:(NeoVimWindow *)window;

// WAITS
- (NSString * _Nullable)vimCommandOutput:(NSString *)string;
- (NSNumber * _Nullable)boolOption:(NSString *)option;
- (void)setBoolOption:(NSString *)option to:(bool)value;

@end

NS_ASSUME_NONNULL_END
