/// A measurement that can be missing. A missing reading is never shown as 0.
public enum Reading<Value: Sendable>: Sendable {
  case value(Value)
  case unavailable(String)

  public var value: Value? {
    if case .value(let value) = self { return value }
    return nil
  }
}

extension Reading: Equatable where Value: Equatable {}

extension Reading {
  /// A value that the next reading has: a new app's rate, or the first reading after a fresh
  /// baseline. The panel says "not available yet"; every other reason is "not available" (R110).
  public static var firstSample: Reading { .unavailable(firstSampleReason) }

  public var isFirstSample: Bool {
    if case .unavailable(let reason) = self { reason == firstSampleReason } else { false }
  }
}

private let firstSampleReason = "first sample"

/// Encodes as `{"value": x}` or `{"unavailable": "reason"}`. Decoding needs exactly one key.
extension Reading: Codable where Value: Codable {
  private enum CodingKeys: String, CodingKey { case value, unavailable }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch (container.contains(.value), container.contains(.unavailable)) {
    case (true, false): self = .value(try container.decode(Value.self, forKey: .value))
    case (false, true): self = .unavailable(try container.decode(String.self, forKey: .unavailable))
    default:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Expected exactly one of \"value\" and \"unavailable\"."))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .value(let value): try container.encode(value, forKey: .value)
    case .unavailable(let reason): try container.encode(reason, forKey: .unavailable)
    }
  }
}
