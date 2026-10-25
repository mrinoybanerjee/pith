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
