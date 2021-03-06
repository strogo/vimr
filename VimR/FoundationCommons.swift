/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Foundation

extension URL {

  func isDirectParent(of url: URL) -> Bool {
    guard self.isFileURL && url.isFileURL else {
      return false
    }

    let myPathComps = self.pathComponents
    let targetPathComps = url.pathComponents

    guard targetPathComps.count == myPathComps.count + 1 else {
      return false
    }

    return Array(targetPathComps[0..<myPathComps.count]) == myPathComps
  }

  func isParent(of url: URL) -> Bool {
    guard self.isFileURL && url.isFileURL else {
      return false
    }

    let myPathComps = self.pathComponents
    let targetPathComps = url.pathComponents

    guard targetPathComps.count > myPathComps.count else {
      return false
    }

    return Array(targetPathComps[0..<myPathComps.count]) == myPathComps
  }

  func isContained(in parentUrl: URL) -> Bool {
    if parentUrl == self {
      return false
    }

    let pathComps = self.pathComponents
    let parentPathComps = parentUrl.pathComponents

    guard pathComps.count > parentPathComps.count else {
      return false
    }

    guard Array(pathComps[0..<parentPathComps.endIndex]) == parentPathComps else {
      return false
    }

    return true
  }

  var parent: URL {
    if self.path == "/" {
      return self
    }

    return self.deletingLastPathComponent()
  }

  /// Wrapper function for NSURL.getResourceValue for Bool values.
  /// Returns also `false` when
  /// - there is no value for the given `key` or
  /// - the value cannot be converted to `NSNumber`.
  ///
  /// - parameters:
  ///   - key: The `key`-parameter of `NSURL.getResourceValue`.
  func resourceValue(_ key: String) -> Bool {
    var rsrc: AnyObject?

    do {
      try (self as NSURL).getResourceValue(&rsrc, forKey: URLResourceKey(rawValue: key))
    } catch let error as NSError {
      // FIXME error handling
      print("\(#function): \(self) -> ERROR while getting \(key): \(error)")
      return false
    }

    if let result = rsrc as? NSNumber {
      return result.boolValue
    }

    return false
  }

  var isDir: Bool {
    return self.resourceValue(URLResourceKey.isDirectoryKey.rawValue)
  }

  var isHidden: Bool {
    return self.resourceValue(URLResourceKey.isHiddenKey.rawValue)
  }

  var isPackage: Bool {
    return self.resourceValue(URLResourceKey.isPackageKey.rawValue)
  }
}
