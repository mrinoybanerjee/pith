import Testing

@testable import PithCore

@Test func versionIsSet() { #expect(PithCore.version == "0.1.0") }
