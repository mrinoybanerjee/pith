import IOKit.pwr_mgt

/// What keeps the Mac awake during a session (Awake spec 4): a power assertion in the app, a
/// stand-in in tests. macOS ends the assertion when Pith's process ends, so a crash leaves nothing
/// behind. It has no powerd timeout: once powerd ends a timed assertion, its release fails.
struct SleepHold {
  static let main = SleepHold(
    acquire: {
      var id = IOPMAssertionID(0)
      let result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Pith: keep awake" as CFString, &id)
      precondition(result == kIOReturnSuccess, "cannot keep the Mac awake: \(result)")
      return id
    },
    release: { id in
      let result = IOPMAssertionRelease(id)
      precondition(result == kIOReturnSuccess, "cannot release assertion \(id): \(result)")
    })

  /// Holds nothing: for tests and for the stores of `--demo` and `--render-panel`, which must not
  /// keep the real Mac awake.
  static let none = SleepHold(acquire: { 0 }, release: { _ in })

  /// Keeps the Mac from sleeping while idle, and returns the hold's ID.
  let acquire: @MainActor @Sendable () -> IOPMAssertionID
  /// Ends the hold with that ID.
  let release: @MainActor @Sendable (IOPMAssertionID) -> Void
}
