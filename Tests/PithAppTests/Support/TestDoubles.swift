import Foundation
import PithCore
import Testing

@testable import Pith

/// The test's own defaults suite, "pith.tests.<test name>" (R70). One fixed name per test keeps the
/// preference files bounded.
func testSuite(_ test: String = #function) -> String {
  "pith.tests.\(test.replacing("()", with: ""))"
}

/// The test's suite, emptied first.
func testDefaults(_ test: String = #function) -> UserDefaults {
  clearDefaults(test)
  return UserDefaults(suiteName: testSuite(test))!
}

func clearDefaults(_ test: String = #function) {
  UserDefaults().removePersistentDomain(forName: testSuite(test))
}

/// The login item and `top` are never real in tests.
extension LoginItem {
  static let stub = LoginItem(isEnabled: { false }, set: { _ in })
}

@MainActor func testStore(
  guide: Guide = .empty, loginItem: LoginItem = .stub,
  measure: @escaping @Sendable () async throws -> SystemBreakdown = {
    throw SystemDetailsError.failed("no top in tests")
  }
) -> Store {
  Store(settings: Settings(), guide: guide, loginItem: loginItem, measureSystem: measure)
}

/// A login item that counts registrations and that a test can make refuse every change, or turn
/// off as a user does in System Settings.
@MainActor final class FakeLoginItem {
  var enabled: Bool
  var refuses = false
  private(set) var registrations = 0

  init(enabled: Bool) { self.enabled = enabled }

  var loginItem: LoginItem {
    LoginItem(
      isEnabled: { self.enabled },
      set: { enabled in
        if self.refuses { throw SystemDetailsError.failed("synthetic refusal") }
        if enabled, !self.enabled { self.registrations += 1 }
        self.enabled = enabled
      })
  }
}

/// Stands in for `SystemDetails.measure()`: each call waits until the test releases it.
@MainActor final class HeldMeasurer {
  private(set) var calls = 0
  private var waiting: [CheckedContinuation<SystemBreakdown, any Error>] = []

  func measure() async throws -> SystemBreakdown {
    calls += 1
    return try await withCheckedThrowingContinuation { waiting.append($0) }
  }

  func release(_ result: Result<SystemBreakdown, any Error>) {
    for continuation in waiting { continuation.resume(with: result) }
    waiting = []
  }
}

/// Synthetic `top` results whose items and "Other" match the tight mockup's opened system row.
let systemBreakdown = SystemBreakdown(
  items: [
    SystemItem(
      title: "Spotlight indexing", memory: 420 << 20,
      explanation: "Builds the search index after files change."),
    SystemItem(title: "Window server", memory: 310 << 20, explanation: nil),
    SystemItem(title: "Photos analysis", memory: 180 << 20, explanation: nil),
  ], other: 999 << 20)

/// `snapshot` with other apps, with no CPU or disk rates yet (an open panel's first tick), with
/// another "macOS system" residual, or with other grouping.
func remake(
  _ snapshot: Snapshot, apps: [AppUsage]? = nil, firstTick: Bool = false,
  system: Reading<SystemResidual>? = nil, grouping: GroupingQuality? = nil
) -> Snapshot {
  let t = snapshot.totals
  let rate = Reading<Double>.unavailable("first sample")
  return Snapshot(
    takenAtNs: snapshot.takenAtNs, mode: snapshot.mode,
    totals: SystemTotals(
      memoryUsed: t.memoryUsed, memoryTotal: t.memoryTotal, pressure: t.pressure,
      swapUsed: t.swapUsed, cpuBusy: firstTick ? rate : t.cpuBusy, storageFree: t.storageFree,
      storageTotal: t.storageTotal),
    apps: (apps ?? snapshot.apps).map { a in
      guard firstTick else { return a }
      return AppUsage(
        id: a.id, name: a.name, bundlePath: a.bundlePath, bundleID: a.bundleID, pids: a.pids,
        processCount: a.processCount, memory: a.memory, cpu: rate, diskBytesPerSecond: rate,
        inside: a.inside)
    },
    system: system
      ?? (firstTick
        ? .value(SystemResidual(memory: snapshot.system.value!.memory, cpu: rate))
        : snapshot.system),
    grouping: grouping ?? snapshot.grouping)
}

/// What a closed tick of `snapshot`'s Mac reads: its totals, no apps and no residual.
func closed(_ snapshot: Snapshot) -> Snapshot {
  Snapshot(
    takenAtNs: snapshot.takenAtNs, mode: .closed, totals: snapshot.totals, apps: [],
    system: .unavailable("closed"), grouping: snapshot.grouping)
}
