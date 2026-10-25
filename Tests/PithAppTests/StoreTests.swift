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

/// The tight mockup with Google Chrome opened and asked to quit; the confirm shows, and its
/// button reports itself in view, as the view does.
@MainActor private func askToQuitChrome(_ apps: FakeRunningApps) throws -> Store {
  let store = apps.store(guide: .empty)
  store.apply(DemoSnapshots.tight)
  store.toggle(store.rows[0].id)
  store.askToQuit(try #require(store.quitTarget(for: store.rows[0])))
  store.confirmButtonInView = true
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
  let second = FakeApp(
    pid: 990, bundlePath: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome")
  apps.apps = [990: second]
  store.apply(tight(chromePIDs: [990, 991]))
  #expect(store.quitFlow.state == .idle)
  #expect(store.quitTarget(for: store.rows[0]) === second)
  #expect(second.terminations == 0 && second.forcedTerminations == 0)
  #expect(first.terminations == 1 && first.forcedTerminations == 0)
}

/// R111: macOS's exit notice for the flow's own process ends the flow, while the app quits and
/// while Force Quit is offered, and nothing is forced. A notice for another app changes nothing.
@MainActor @Test func theAppsExitNoticeEndsTheFlow() async throws {
  for offered in [false, true] {
    let chrome = fakeChrome()
    let apps = FakeRunningApps([chrome])
    let store = try askToQuitChrome(apps)
    apps.passTheConfirmGuard()
    store.confirmQuit()
    await settle()
    if offered {
      apps.nowNs += 5_000_000_000
      await apps.timer.fire()
      #expect(store.quitFlow.state == .offerForce)
    }
    let state = store.quitFlow.state
    await apps.exit(fakeChrome())  // another instance, with the same PID
    #expect(store.quitFlow.state == state)
    await apps.exit(chrome)
    #expect(store.quitFlow.state == .done && chrome.forcedTerminations == 0, "offered: \(offered)")
  }
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

/// R111 and spec 10: nothing polls. An app that ignores Quit, on a covered panel for 60 s, wakes
/// Pith once, at the 5 s offer. No timer runs while the offer or its confirm shows.
@MainActor @Test func aQuitThatTheAppIgnoresWakesPithOnce() async throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  let store = try askToQuitChrome(apps)
  #expect(apps.timer.waits == 0)  // asking to quit starts no timer
  apps.passTheConfirmGuard()
  store.confirmQuit()
  store.panelCovered = true
  await settle()
  #expect(apps.timer.waits == 1)
  apps.nowNs += 60_000_000_000
  await apps.timer.fire()
  #expect(store.quitFlow.state == .offerForce)
  await apps.timer.fire()
  store.offerForceQuit()
  await apps.timer.fire()
  #expect(store.quitFlow.state == .confirmingForce && apps.timer.waits == 1)
  #expect(apps.timer.waiting == 0)
}

/// R111: starting over removes the exit watch, and a late timer or exit notice changes nothing.
@MainActor @Test func aLateTimerOrExitNoticeAfterAResetChangesNothing() async throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  let store = try askToQuitChrome(apps)
  apps.passTheConfirmGuard()
  store.confirmQuit()
  await settle()
  #expect(apps.timer.waiting == 1 && apps.exits.observers == 1)
  store.panelClosed()
  #expect(apps.exits.observers == 0)
  apps.nowNs += 5_000_000_000
  await apps.timer.fire()
  await apps.exit(chrome)
  #expect(store.quitFlow.state == .idle && chrome.forcedTerminations == 0)
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
  await apps.timer.fire()
  store.offerForceQuit()
  store.cancelQuit()
  #expect(store.quitFlow.state == .offerForce)
  store.offerForceQuit()
  store.confirmButtonInView = true
  apps.nowNs += 399_000_000
  store.confirmQuit()
  #expect(store.quitFlow.state == .confirmingForce && chrome.forcedTerminations == 0)
  apps.nowNs += 1_000_000
  store.confirmQuit()
  #expect(chrome.forcedTerminations == 1)
  store.panelClosed()
}

/// R101: `confirmQuit()` is the one gate for a click, Space, Return and VoiceOver. It does
/// nothing while the default button is out of view or the pinned panel is covered, and each time
/// the button comes back into view, its 0.4 s start again.
@MainActor @Test func theConfirmGateNeedsTheButtonInViewFor0Point4Seconds() throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  let store = try askToQuitChrome(apps)
  apps.passTheConfirmGuard()
  store.confirmButtonInView = false  // scrolled away, in Settings, or not drawn
  store.confirmQuit()
  store.confirmButtonInView = true
  store.confirmQuit()  // in view again: its 0.4 s start again
  #expect(store.quitFlow.state == .confirming && chrome.terminations == 0)
  apps.passTheConfirmGuard()
  store.panelCovered = true
  store.confirmQuit()
  store.panelCovered = false
  apps.nowNs += 399_000_000
  store.confirmQuit()
  #expect(store.quitFlow.state == .confirming && chrome.terminations == 0)
  apps.nowNs += 1_000_000
  store.confirmQuit()
  #expect(chrome.terminations == 1)
}

/// R101: a stale event, such as a late click on a button that has gone, does nothing and never
/// traps. Quit on another process while a flow is in progress does not take it over.
@MainActor @Test func aStaleEventDoesNothing() throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  let idle = apps.store(guide: .empty)
  idle.offerForceQuit()
  idle.cancelQuit()
  idle.confirmQuit()
  #expect(idle.quitFlow.state == .idle)
  let store = try askToQuitChrome(apps)
  let other = FakeApp(
    pid: 411, bundlePath: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome")
  store.askToQuit(other)
  store.offerForceQuit()
  apps.passTheConfirmGuard()
  store.confirmQuit()
  #expect(chrome.terminations == 1 && other.terminations == 0)
  store.confirmQuit()
  store.askToQuit(other)
  #expect(chrome.terminations == 1 && store.quitFlow.state == .waiting(sinceNs: 400_000_000))
  store.panelClosed()
}

/// R95 and R102: at the confirm, the same process that Pith may no longer quit, here because it
/// now belongs to another user, starts the flow over, and nothing is called.
@MainActor @Test func aProcessThatBecameIneligibleIsNotQuit() throws {
  let chrome = fakeChrome()
  let apps = FakeRunningApps([chrome])
  let store = try askToQuitChrome(apps)
  apps.owners[410] = getuid() + 1
  apps.passTheConfirmGuard()
  store.confirmQuit()
  #expect(store.quitFlow.state == .idle)
  #expect(chrome.terminations == 0 && chrome.forcedTerminations == 0)
}

/// R125: the confirm's check uses the same rule as Quit. A flow that was given another
/// installation of the row's app, with the same bundle ID, does not hold at the confirm: it starts
/// over, and that installation is not quit.
@MainActor @Test func theConfirmRejectsAnotherInstallation() throws {
  let other = FakeApp(
    pid: 410, bundlePath: "/Users/Shared/Google Chrome.app", bundleID: "com.google.Chrome")
  let apps = FakeRunningApps([other])
  let store = apps.store(guide: .empty)
  store.apply(DemoSnapshots.tight)
  store.toggle(store.rows[0].id)
  #expect(store.quitTarget(for: store.rows[0]) == nil)
  store.askToQuit(other)  // as a late click on a Quit that showed for it would
  store.confirmButtonInView = true
  apps.passTheConfirmGuard()
  store.confirmQuit()
  #expect(store.quitFlow.state == .idle && other.terminations == 0)
}
