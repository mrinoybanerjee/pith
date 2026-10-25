import Foundation
import PithCore
import Testing
import os

@testable import Pith

/// Whether the observable state that `read` reads changed while `change` ran.
@MainActor private func notifies(_ read: () -> Void, when change: () -> Void) -> Bool {
  let changed = OSAllocatedUnfairLock(initialState: false)
  withObservationTracking(read) { changed.withLock { $0 = true } }
  change()
  return changed.withLock { $0 }
}

/// R71: a closed tick changes only the status, and only when the state changes, so the hidden
/// panel has nothing to redraw.
@MainActor @Test func closedTicksChangeOnlyTheStatus() {
  let store = testStore()
  store.apply(DemoSnapshots.calm)
  let shown = store.snapshot
  let rows = store.rows.map(\.id)
  let panel = { _ = (store.snapshot, store.rows, store.status) }
  #expect(!notifies(panel) { store.apply(closed(DemoSnapshots.calm)) })
  let status = { _ = store.status }
  #expect(notifies(status) { store.apply(closed(DemoSnapshots.tight)) })
  #expect(store.status.title == "Memory is tight")
  #expect(store.snapshot == shown && store.rows.map(\.id) == rows)
  store.apply(DemoSnapshots.tight)
  #expect(store.snapshot == DemoSnapshots.tight && store.rows.first?.name == "Google Chrome")
}

/// R74: the toggle shows what macOS says. A refusal is shown and the toggle goes back; opening the
/// panel reads macOS again and clears the refusal.
@MainActor @Test func theLoginItemToggleShowsWhatMacOSSays() {
  let item = FakeLoginItem(enabled: false)
  let store = testStore(loginItem: item.loginItem)
  store.setLaunchAtLogin(true)
  #expect(store.launchesAtLogin && !store.loginItemFailed && item.registrations == 1)
  item.refuses = true
  store.setLaunchAtLogin(false)
  #expect(store.launchesAtLogin && store.loginItemFailed)
  item.refuses = false
  item.enabled = false  // the user turns it off in System Settings
  store.readLoginItem()
  #expect(!store.launchesAtLogin && !store.loginItemFailed && item.registrations == 1)
}

/// R87: every type size the user must read is at least 13 pt (spec 4.2); only the decorative footer
/// is smaller.
@Test func everyReadableTypeSizeIsAtLeast13Points() {
  #expect(PanelType.allCases.filter { $0 != .footer }.allSatisfy { $0.rawValue >= 13 })
  #expect(PanelType.footer.rawValue == 11.5)
}

/// R78: the opened row's quit flow starts over when the row closes, when another row opens, when
/// the panel closes, and when the app leaves the list, so no confirm outlives its row. A quit
/// already sent stays sent.
@MainActor @Test func theQuitFlowStartsOverWithItsRow() {
  let apps = FakeRunningApps([chromeProcess])
  let store = apps.store(guide: .empty)
  store.apply(DemoSnapshots.tight)
  let chrome = store.rows[0].id
  let ask = {
    store.toggle(chrome)
    store.sendQuit(.tapQuit, pid: 410)
    #expect(store.quitFlow.state == .confirming)
  }
  ask()
  store.toggle(store.rows[1].id)  // another row opens
  #expect(store.quitFlow.state == .idle)
  ask()
  store.toggle(chrome)  // the row closes
  #expect(store.quitFlow.state == .idle && store.expandedAppID == nil)
  ask()
  store.apply(remake(DemoSnapshots.tight, apps: Array(DemoSnapshots.tight.apps.dropFirst())))
  #expect(store.quitFlow.state == .idle)
  store.apply(DemoSnapshots.tight)
  store.toggle(chrome)  // it was still open; this closes it
  ask()
  store.sendQuit(.confirm, pid: 410)
  #expect(store.quitFlow.state == .waiting(sinceNs: 0) && apps.terminated == [410])
  store.panelClosed()
  #expect(store.quitFlow.state == .idle && apps.terminated == [410] && apps.forced.isEmpty)
}

/// R78: `.tick` comes once per second, only while the flow waits: it stops when Force Quit is
/// offered and when the panel closes.
@MainActor @Test func theQuitFlowTicksOnlyWhileItWaits() async throws {
  let apps = FakeRunningApps([chromeProcess])
  let store = apps.store(guide: .empty)
  store.apply(DemoSnapshots.tight)
  store.toggle(store.rows[0].id)
  store.sendQuit(.tapQuit, pid: 410)
  store.sendQuit(.confirm, pid: 410)
  apps.nowNs = 5_000_000_000
  try await Task.sleep(for: .milliseconds(2300))
  #expect(store.quitFlow.state == .offerForce && apps.checks == 1)
  store.sendQuit(.tapForce, pid: 410)
  store.sendQuit(.confirmForce, pid: 410)
  #expect(store.quitFlow.state == .waiting(sinceNs: 5_000_000_000) && apps.forced == [410])
  store.panelClosed()
  try await Task.sleep(for: .milliseconds(1300))
  #expect(apps.checks == 1)
}
