import Foundation

public enum GuideKind: String, Codable, Sendable { case app, helper, system }

/// How an entry finds its process. In JSON it is an object with exactly one key, for example
/// `{"bundleID": "com.apple.Safari"}`.
public enum GuideMatch: Codable, Hashable, Sendable {
  case name(String)
  case bundleID(String)
  /// Should end in "/": "/Applications/Foo" would also match "/Applications/FooBar.app".
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
    // A keyed container lists only the known keys, so a misspelled key would go unseen.
    let object = try decoder.singleValueContainer().decode([String: String].self)
    guard object.count == 1, let (name, text) = object.first, let key = CodingKeys(rawValue: name),
      !text.isEmpty
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription:
            "Expected one non-empty \"name\", \"bundleID\", \"pathPrefix\" or \"helperPattern\"; found \(object)."
        ))
    }
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

public enum GuideError: Error, Equatable {
  case missingResource(String)
  case duplicateMatch(GuideMatch)
}

public struct GuideEntry: Codable, Sendable, Equatable {
  public let match: GuideMatch
  public let title: String
  public let explanation: String
  public let kind: GuideKind
  public let quittable: Bool
  public let source: String?
  /// True for an app that runs other programs, such as a terminal: quitting it stops them too.
  public let programsInside: Bool?
}

/// The built-in guide (spec 7). Immutable; the lookups are indexed once, in `init`.
public struct Guide: Sendable, Equatable {
  public static let empty = Guide(entries: [])

  public let entries: [GuideEntry]
  private let byMatch: [GuideMatch: GuideEntry]
  private let pathPrefixes: [GuideEntry]  // longest first
  private let helperPatterns: [GuideEntry]  // longest first

  /// Traps on two entries with the same match, as a backstop for hand-built guides.
  /// `bundled(in:)` reports a duplicate as an error before it gets here.
  public init(entries: [GuideEntry]) {
    self.entries = entries
    byMatch = Dictionary(uniqueKeysWithValues: entries.map { ($0.match, $0) })
    pathPrefixes = Self.longestFirst(entries, .pathPrefix)
    helperPatterns = Self.longestFirst(entries, .helperPattern)
  }

  /// The app passes `.main`: scripts/build-app.sh puts guide.json in its Contents/Resources.
  /// Tests pass the source folder (their `Guide.bundled()`).
  public static func bundled(in bundle: Bundle) throws -> Guide {
    guard let url = bundle.url(forResource: "guide", withExtension: "json") else {
      throw GuideError.missingResource("guide.json")
    }
    return try decode(Data(contentsOf: url))
  }

  static func decode(_ json: Data) throws -> Guide {
    let entries = try JSONDecoder().decode([GuideEntry].self, from: json)
    var seen = Set<GuideMatch>()
    for entry in entries where !seen.insert(entry.match).inserted {
      throw GuideError.duplicateMatch(entry.match)
    }
    return Guide(entries: entries)
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
