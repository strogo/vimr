/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Foundation

class FileMonitorReducer {

  typealias Pair = StateActionPair<AppState, FileMonitor.Action>

  func reduce(_ pair: Pair) -> Pair {
    var state = pair.state

    switch pair.action {

    case let .change(in: url):
      guard let fileItem = FileItemUtils.item(for: url, root: state.root, create: false) else {
        return pair
      }

      fileItem.needsScanChildren = true

      state.mainWindows
        .filter { (uuid, mainWindow) in url == mainWindow.cwd || url.isContained(in: mainWindow.cwd) }
        .map { $0.0 }
        .forEach { uuid in
          state.mainWindows[uuid]?.lastFileSystemUpdate = Marked(fileItem)
        }

    }

    return StateActionPair(state: state, action: pair.action)
  }
}
