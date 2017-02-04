/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Foundation
import CocoaMarkdown

class PreviewNewService: Service {

  typealias Pair = StateActionPair<UuidState<MainWindow.State>, MainWindow.Action>

  init() {
    guard let templateUrl = Bundle.main.url(forResource: "template",
                                            withExtension: "html",
                                            subdirectory: "markdown")
      else {
      preconditionFailure("ERROR Cannot load markdown template")
    }

    guard let template = try? String(contentsOf: templateUrl) else {
      preconditionFailure("ERROR Cannot load markdown template")
    }

    self.template = template
  }

  func apply(_ pair: Pair) {

    guard case .setCurrentBuffer = pair.action else {
      return
    }

    let uuid = pair.state.uuid

    switch pair.state.payload.preview {

    case let .markdown(file:file, html:html, server:_):
      NSLog("\(file) -> \(html)")
      do {
        try self.render(file, to: html)
        self.previewFiles[uuid] = html
      } catch let error as NSError {
        // FIXME: error handling!
        NSLog("ERROR rendering \(file) to \(html): \(error)")
        return
      }

    default:
      guard let previewUrl = self.previewFiles[uuid] else {
        return
      }

      try? FileManager.default.removeItem(at: previewUrl)
      self.previewFiles.removeValue(forKey: uuid)

    }
  }

  fileprivate func filledTemplate(body: String, title: String) -> String {
    return self.template
      .replacingOccurrences(of: "{{ title }}", with: title)
      .replacingOccurrences(of: "{{ body }}", with: body)
  }

  fileprivate func render(_ bufferUrl: URL, to htmlUrl: URL) throws {
    let doc = CMDocument(contentsOfFile: bufferUrl.path, options: .sourcepos)
    let renderer = CMHTMLRenderer(document: doc)

    guard let body = renderer?.render() else {
      // FIXME: error handling!
      return
    }

    let html = filledTemplate(body: body, title: bufferUrl.lastPathComponent)
    let htmlFilePath = htmlUrl.path

    try html.write(toFile: htmlFilePath, atomically: true, encoding: .utf8)
  }

  fileprivate let template: String
  fileprivate let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  fileprivate var previewFiles = [String: URL]()
}
