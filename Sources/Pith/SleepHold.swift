import IOKit.pwr_mgt

/// What keeps the Mac awake during a session (Awake spec 4): power assertions in the app, a
/// stand-in in tests. One keeps the Mac from sleeping while idle, with the lid closed too; the
/// other keeps the display on while the lid is open. macOS ends both when Pith's process ends, so
/// a crash leaves nothing behind. They have no powerd timeout: once powerd ends a timed
/// assertion, its release fails.
struct SleepHold {
  /// The assertions each session holds (Awake spec 4.1).
  static let kinds = [
    kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep,
  ]

  static let main = SleepHold(
    acquire: {
      SleepHold.kinds.map { kind in
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
          kind as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
          "Pith: keep awake" as CFString, &id)
        precondition(result == kIOReturnSuccess, "cannot keep the Mac awake: \(result)")
        return id
      }
    },
    release: { ids in
      for id in ids {
        let result = IOPMAssertionRelease(id)
        precondition(result == kIOReturnSuccess, "cannot release assertion \(id): \(result)")
      }
    })

  /// Holds nothing: for tests and for the stores of `--demo` and `--render-panel`, which must not
  /// keep the real Mac awake.
  static let none = SleepHold(acquire: { [] }, release: { _ in })

  /// Keeps the Mac awake and its display on while idle, and returns the holds' IDs.
  let acquire: @MainActor @Sendable () -> [IOPMAssertionID]
  /// Ends the holds with those IDs.
  let release: @MainActor @Sendable ([IOPMAssertionID]) -> Void
}
