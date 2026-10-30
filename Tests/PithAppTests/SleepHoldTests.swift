import Foundation
import IOKit.pwr_mgt
import Testing

@testable import Pith

/// The kinds of Pith's assertions that this process holds now, as powerd reports them.
private func heldKinds() -> Set<String> {
  var all: Unmanaged<CFDictionary>?
  #expect(IOPMCopyAssertionsByProcess(&all) == kIOReturnSuccess)
  let byPID = all!.takeRetainedValue() as NSDictionary
  let mine = byPID[NSNumber(value: getpid())] as? [[String: Any]] ?? []
  return Set(
    mine.filter { $0[kIOPMAssertionNameKey] as? String == "Pith: keep awake" }
      .compactMap { $0[kIOPMAssertionTypeKey] as? String })
}

/// Awake spec 4.1: a session's hold keeps the Mac from idle sleep, also with the lid closed, and
/// its display on while the lid is open; its release ends both.
@MainActor @Test func theHoldKeepsTheMacAndItsDisplayAwake() {
  let ids = SleepHold.main.acquire()
  let both: Set = [
    kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep,
  ]
  #expect(heldKinds() == both)
  SleepHold.main.release(ids)
  #expect(heldKinds().isEmpty)
}
