import Foundation

// Kept out of files that import Testing: the Command Line Tools ship no `_Testing_Foundation`
// overlay, so a file that imports both Foundation and Testing does not compile without Xcode.
func jsonRoundTrip<T: Codable>(_ value: T) throws -> T {
  try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}
