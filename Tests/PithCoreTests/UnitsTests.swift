import Foundation
import Testing

@testable import PithCore

@Test func appleSiliconTicksConvert() {
  #expect(MachTimebase(numer: 125, denom: 3).nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
  #expect(MachTimebase(numer: 1, denom: 1).nanoseconds(fromTicks: 42) == 42)
}

@Test func largeTickCountsDoNotOverflow() {
  // ticks × 125 overflows UInt64
  #expect(
    MachTimebase(numer: 125, denom: 3).nanoseconds(fromTicks: 1 << 58) == 12_009_599_006_321_322_666
  )
}

@Test func memoryUsesBinaryUnits() {
  #expect(ByteFormat.memory(16 << 30) == "16 GB")
  #expect(ByteFormat.memory(UInt64(6.4 * Double(1 << 30))) == "6.4 GB")
  #expect(ByteFormat.memory(710 << 20) == "710 MB")
  #expect(ByteFormat.memory(180 << 20) == "180 MB")
  #expect(ByteFormat.memory(UInt64(15.1 * Double(1 << 30))) == "15.1 GB")
}

@Test func storageUsesDecimalUnits() {
  #expect(ByteFormat.storage(112_000_000_000) == "112 GB")
  #expect(ByteFormat.storage(228_300_000_000) == "228 GB")
  #expect(ByteFormat.storage(9_400_000_000) == "9.4 GB")
}

@Test func diskRatesUseDecimalUnitsWithTheSizesPrecision() {
  #expect(ByteFormat.rate(0) == "0 KB/s")
  #expect(ByteFormat.rate(5_500) == "5.5 KB/s")
  #expect(ByteFormat.rate(340_000) == "340 KB/s")
  #expect(ByteFormat.rate(999_600) == "1 MB/s")
  #expect(ByteFormat.rate(1_200_000) == "1.2 MB/s")
  #expect(ByteFormat.rate(12_400_000) == "12.4 MB/s")
  #expect(ByteFormat.rate(150_000_000) == "150 MB/s")
  #expect(ByteFormat.rate(2_500_000_000) == "2.5 GB/s")
}

@Test func percentages() {
  #expect(PercentFormat.app(0.062) == "6.2%")
  #expect(PercentFormat.app(0.312) == "31%")
  #expect(PercentFormat.total(0.38) == "38%")
  #expect(PercentFormat.total(0.004) == "0%")
}

@Test func roundedValuePicksTheFormat() {
  #expect(PercentFormat.app(0.0996) == "10%")
  #expect(ByteFormat.memory((1023 << 20) + 800_000) == "1 GB")
  #expect(ByteFormat.storage(999_600_000) == "1 GB")
  #expect(ByteFormat.storage(99_960_000_000) == "100 GB")
}

@Test func justBelowTheBoundaryKeepsTheLowerFormat() {
  #expect(PercentFormat.app(0.099) == "9.9%")
  #expect(ByteFormat.memory(1023 << 20) == "1023 MB")
}

@Test func currentTimebaseMatchesTheUptimeClock() {
  let converted = MachTimebase.current.nanoseconds(fromTicks: mach_absolute_time())
  let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  #expect(uptime >= converted && uptime - converted < 1_000_000_000)
}

@Test func readingValue() {
  #expect(Reading<Int>.value(3).value == 3)
  #expect(Reading<Int>.unavailable("x").value == nil)
}

@Test func readingEncodesAsPlainJSON() throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  func json(_ reading: Reading<Double>) throws -> String {
    String(decoding: try encoder.encode(reading), as: UTF8.self)
  }
  #expect(try json(.value(0.38)) == #"{"value":0.38}"#)
  #expect(try json(.unavailable("first tick")) == #"{"unavailable":"first tick"}"#)
}

@Test func readingDecodingNeedsExactlyOneKey() throws {
  func decode(_ text: String) throws -> Reading<Int> {
    try JSONDecoder().decode(Reading<Int>.self, from: Data(text.utf8))
  }
  #expect(try decode(#"{"value":3}"#) == .value(3))
  #expect(try decode(#"{"unavailable":"x"}"#) == .unavailable("x"))
  #expect(throws: DecodingError.self) { try decode(#"{"value":3,"unavailable":"x"}"#) }
  #expect(throws: DecodingError.self) { try decode("{}") }
}

@Test func snapshotRoundTripsThroughJSON() throws {
  let snapshot = Snapshot(
    takenAtNs: 2_000_000_000,
    mode: .open,
    totals: SystemTotals(
      memoryUsed: .value(6 << 30), footprintTotal: .value(9 << 30), memoryTotal: 16 << 30,
      pressure: .value(.warning),
      swapUsed: .unavailable("vm.swapusage failed: errno 5"),
      cpuBusy: .value(0.38), storageFree: .unavailable("no volume"), storageTotal: .value(500)),
    apps: [
      AppUsage(
        id: "/Applications/Browser.app", name: "Browser", bundlePath: "/Applications/Browser.app",
        bundleID: "com.example.Browser", pids: [300, 301], processCount: 2, memory: 3 << 30,
        cpu: .unavailable("first tick"), diskBytesPerSecond: .value(1024),
        inside: [HelperGroup(label: "Tabs and sites", count: 1, memory: 1 << 30)])
    ],
    system: .value(SystemResidual(memory: 1 << 30, cpu: .value(0.01))),
    grouping: .limited)
  let data = try JSONEncoder().encode(snapshot)
  #expect(try JSONDecoder().decode(Snapshot.self, from: data) == snapshot)
}
