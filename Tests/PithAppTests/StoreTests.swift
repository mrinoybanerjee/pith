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

/// The tight mockup with Google Chrome opened and asked to quit; the confirm shows.
@MainActor private func askToQuitChrome(_ apps: FakeRunningApps) throws -> Store {
  let store = apps.store(guide: .empty)
  store.apply(DemoSnapshots.tight)
  store.toggle(store.rows[0].id)
  store.askToQuit(try #require(store.quitTarget(for: store.rows[0])))
  #expect(store.quitFlow.state == .confirming)
  return store
}

/// The tight mockup with Google Chrome running as `pids`.
private func tight(chromePIDs pids: [Int32]) -> Snapshot {
  let c = DemoSnapshots.tight.apps[0]
  let chrome = AppUsage(
    id: c.id, name: c.name, bundlePath: c.bundlePath, bundleID: c.bundleID, pids: pids,
    processCount: c.processCount, memory: c.memory, cpu: c.cpu,
    diskBytesPerSecond: c.diskBytesPerSecond, inside: c.inside)
  return remake(DemoSnapshots.tight, apps: [chrome] + DemoSnapshots.tight.apps.dropFirst())
}

/// R78: the opened row's quit flow starts over when the row closes, when another row opens, when
/// the panel closes, and when the app leaves the list, so no confirm outlives its row. A quit
/// already sent stays sent.
@MainActor @Test func theQuitFlowStartsOverWithItsRow() throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  var store = try askToQuitChrome(apps)
  store.toggle(store.rows[1].id)  // another row opens
  #expect(store.quitFlow.state == .idle)
  store = try askToQuitChrome(apps)
  store.toggle(store.rows[0].id)  // the row closes
  #expect(store.quitFlow.state == .idle && store.expandedAppID == nil)
  store = try askToQuitChrome(apps)
  store.apply(remake(DemoSnapshots.tight, apps: Array(DemoSnapshots.tight.apps.dropFirst())))
  #expect(store.quitFlow.state == .idle)
  store = try askToQuitChrome(apps)
  apps.passTheConfirmGuard()
  store.confirmQuit()
  #expect(store.quitFlow.state == .waiting(sinceNs: 400_000_000) && chrome.terminations == 1)
  store.panelClosed()
  #expect(store.quitFlow.state == .idle && chrome.terminations == 1)
  #expect(chrome.forcedTerminations == 0)
}

/// R95: after a quit, the app ends and starts again with a new PID in the same row. The flow
/// starts over, so the new launch is offered Quit afresh and nothing reaches it.
@MainActor @Test func aRelaunchedAppStartsOverAndIsNeverCalled() throws {
  let first = fakeChrome()
  let apps = FakeRunningApps([first])
  let store = try askToQuitChrome(apps)
  apps.passTheConfirmGuard()
  store.confirmQuit()
  #expect(first.terminations == 1)
  first.isTerminated = true
  let second = FakeApp(pid: 990, bundlePath: "/Applications/Google Chrome.app")
  apps.apps = [990: second]
  store.apply(tight(chromePIDs: [990, 991]))
  #expect(store.quitFlow.state == .idle)
  #expect(store.quitTarget(for: store.rows[0]) === second)
  #expect(second.terminations == 0 && second.forcedTerminations == 0)
  #expect(first.terminations == 1 && first.forcedTerminations == 0)
}

/// R95: when the app ends while Force Quit is offered, the next check finds it gone. The flow is
/// done, the offer goes, and nothing is forced.
@MainActor @Test func anAppThatEndsWhileForceQuitIsOfferedIsDone() async throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  let store = try askToQuitChrome(apps)
  apps.passTheConfirmGuard()
  store.confirmQuit()
  await settle()
  apps.nowNs += 5_000_000_000
  await apps.checks.fire()
  #expect(store.quitFlow.state == .offerForce)
  chrome.isTerminated = true
  await apps.checks.fire()
  #expect(store.quitFlow.state == .done && chrome.forcedTerminations == 0)
}

/// R95: a new process with the PID of the one the user asked to quit cannot take its place. At
/// the confirm, the row has another instance, so the flow starts over and calls nothing.
@MainActor @Test func aReusedPIDCannotRedirectAQuit() throws {
  let asked = fakeChrome()
  let apps = FakeRunningApps([asked])
  let store = try askToQuitChrome(apps)
  asked.isTerminated = true
  let reused = fakeChrome()  // the same PID, 410
  apps.apps = [410: reused]
  apps.passTheConfirmGuard()
  store.confirmQuit()
  #expect(store.quitFlow.state == .idle)
  #expect(asked.terminations == 0 && reused.terminations == 0)
}

/// R95 and R97: the flow checks the app once per check while it quits, while Force Quit is
/// offered and while it is asked. The checks stop when the flow is done and when the panel closes:
/// a check that went on would begin another wait.
@MainActor @Test func theQuitChecksRunOnlyWhileTheAppQuits() async throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  var store = try askToQuitChrome(apps)
  #expect(apps.checks.waits == 0)  // asking to quit does not check
  apps.passTheConfirmGuard()
  store.confirmQuit()
  await settle()
  #expect(apps.checks.waits == 1)
  await apps.checks.fire()
  #expect(apps.checks.waits == 2 && store.quitFlow.state == .waiting(sinceNs: 400_000_000))
  apps.nowNs += 5_000_000_000
  await apps.checks.fire()
  #expect(apps.checks.waits == 3 && store.quitFlow.state == .offerForce)
  store.offerForceQuit()
  await apps.checks.fire()
  #expect(apps.checks.waits == 4 && store.quitFlow.state == .confirmingForce)
  store.panelClosed()
  await apps.checks.fire()
  #expect(apps.checks.waits == 4 && store.quitFlow.state == .idle)

  let waits = apps.checks.waits
  store = try askToQuitChrome(apps)
  apps.passTheConfirmGuard()
  store.confirmQuit()
  await settle()
  chrome.isTerminated = true
  await apps.checks.fire()
  #expect(store.quitFlow.state == .done && apps.checks.waits == waits + 1)
  await apps.checks.fire()
  #expect(apps.checks.waits == waits + 1)
}

/// R93 and R99: the default button of each confirm, Quit and Force Quit, does nothing for 0.4 s
/// after the confirm shows, so a double-click cannot pass it. Cancel works at once.
@MainActor @Test func aConfirmWaits0Point4SecondsButCancelDoesNot() async throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  var store = try askToQuitChrome(apps)
  store.cancelQuit()
  #expect(store.quitFlow.state == .idle)
  store = try askToQuitChrome(apps)
  apps.nowNs += 399_000_000
  store.confirmQuit()
  #expect(store.quitFlow.state == .confirming && chrome.terminations == 0)
  apps.nowNs += 1_000_000
  store.confirmQuit()
  #expect(chrome.terminations == 1)
  await settle()
  apps.nowNs += 5_000_000_000
  await apps.checks.fire()
  store.offerForceQuit()
  store.cancelQuit()
  #expect(store.quitFlow.state == .offerForce)
  store.offerForceQuit()
  apps.nowNs += 399_000_000
  store.confirmQuit()
  #expect(store.quitFlow.state == .confirmingForce && chrome.forcedTerminations == 0)
  apps.nowNs += 1_000_000
  store.confirmQuit()
  #expect(chrome.forcedTerminations == 1)
  store.panelClosed()
  await apps.checks.fire()
}
