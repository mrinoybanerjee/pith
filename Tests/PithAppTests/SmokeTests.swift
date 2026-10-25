import PithCore
import Testing

@testable import Pith

@Test func appModuleLoads() { #expect(PithCore.version == "0.1.0") }
