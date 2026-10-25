import Foundation

public enum GuideKind: String, Codable, Sendable { case app, helper, system }

/// How an entry finds its process. In JSON it is an object with exactly one key, for example
/// `{"bundleID": "com.apple.Safari"}`.
public enum GuideMatch: Codable, Hashable, Sendable {
  case name(String)
  case bundleID(String)
  case pathPrefix(String)
  case helperPattern(String)

  fileprivate enum CodingKeys: String, CodingKey {
    case name, bundleID, pathPrefix, helperPattern
  }

  fileprivate var parts: (key: CodingKeys, text: String) {
    switch self {
    case .name(let text): (key: .name, text: text)
    case .bundleID(let text): (key: .bundleID, text: text)
    case .pathPrefix(let text): (key: .pathPrefix, text: text)
    case .helperPattern(let text): (key: .helperPattern, text: text)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard let key = container.allKeys.first, container.allKeys.count == 1 else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription:
            "Expected exactly one of \"name\", \"bundleID\", \"pathPrefix\" and \"helperPattern\"."
        ))
    }
    let text = try container.decode(String.self, forKey: key)
    switch key {
    case .name: self = .name(text)
    case .bundleID: self = .bundleID(text)
    case .pathPrefix: self = .pathPrefix(text)
    case .helperPattern: self = .helperPattern(text)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(parts.text, forKey: parts.key)
  }
}

public struct GuideEntry: Codable, Sendable, Equatable {
  public let match: GuideMatch
  public let title: String
  public let explanation: String
  public let kind: GuideKind
  public let quittable: Bool
  public let source: String?
}

/// The built-in guide (spec 7). Immutable; the lookups are indexed once, in `init`.
public struct Guide: Sendable, Equatable {
  public static let empty = Guide(entries: [])

  public let entries: [GuideEntry]
  private let byMatch: [GuideMatch: GuideEntry]
  private let pathPrefixes: [GuideEntry]  // longest first
  private let helperPatterns: [GuideEntry]  // longest first

  /// Two entries with the same match are a bug in the guide, so `init` traps on them.
  public init(entries: [GuideEntry]) {
    self.entries = entries
    byMatch = Dictionary(uniqueKeysWithValues: entries.map { ($0.match, $0) })
    pathPrefixes = Self.longestFirst(entries, .pathPrefix)
    helperPatterns = Self.longestFirst(entries, .helperPattern)
  }

  public static func bundled() throws -> Guide {
    let url = Bundle.module.url(forResource: "guide", withExtension: "json")!
    return Guide(entries: try JSONDecoder().decode([GuideEntry].self, from: Data(contentsOf: url)))
  }

  /// A bundle ID match wins, then an exact name, then the longest path prefix. Helper patterns
  /// never match here; `helperLabel` reads them.
  public func entry(name: String, bundleID: String?, path: String?) -> GuideEntry? {
    bundleID.flatMap { byMatch[.bundleID($0)] }
      ?? byMatch[.name(name)]
      ?? path.flatMap { path in pathPrefixes.first { path.hasPrefix($0.match.parts.text) } }
  }

  /// The title of the longest helper pattern that ends the process name.
  public func helperLabel(processName: String) -> String? {
    helperPatterns.first { processName.hasSuffix($0.match.parts.text) }?.title
  }

  private static func longestFirst(
    _ entries: [GuideEntry], _ key: GuideMatch.CodingKeys
  ) -> [GuideEntry] {
    entries.filter { $0.match.parts.key == key }
      .sorted { $0.match.parts.text.count > $1.match.parts.text.count }
  }
}
