import Foundation
import PithCore

extension Guide {
  /// The guide in the source tree, read the way the app reads its Contents/Resources copy.
  public static func bundled() throws -> Guide {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    return try bundled(in: Bundle(url: root.appending(path: "Sources/PithCore/Resources"))!)
  }
}
