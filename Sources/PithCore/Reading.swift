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
extension Reading: Codable where Value: Codable {}
