/// The quit flow of an opened app row (spec 4.5): Quit asks first, then asks the app to quit, so it
/// can ask to save. An app still running 5 s later is offered Force Quit, which asks again. It is
/// pure: the caller passes the time, and the app's calls run only on a confirm.
public struct QuitFlow {
  public enum State: Equatable, Sendable {
    case idle, confirming
    case waiting(sinceNs: UInt64)
    case offerForce, confirmingForce, done
  }

  public enum Event: Sendable { case tapQuit, cancel, confirm, tick, tapForce, confirmForce }

  /// How long a quit may take before Force Quit is offered.
  static let forceAfterNs: UInt64 = 5_000_000_000

  public private(set) var state: State

  public init(state: State = .idle) { self.state = state }

  /// A tick while waiting checks whether the app is gone. Force Quit waits again, in case even that
  /// does not end the app. An event that the state does not offer, such as a second click on a
  /// button that has just gone, changes nothing.
  public mutating func send(
    _ e: Event, nowNs: UInt64, isRunning: () -> Bool, terminate: () -> Void,
    forceTerminate: () -> Void
  ) {
    switch (state, e) {
    case (.idle, .tapQuit): state = .confirming
    case (.confirming, .cancel): state = .idle
    case (.confirming, .confirm):
      terminate()
      state = .waiting(sinceNs: nowNs)
    case (.waiting, .tick) where !isRunning(): state = .done
    case (.waiting(let since), .tick) where nowNs - since >= Self.forceAfterNs: state = .offerForce
    case (.offerForce, .tapForce): state = .confirmingForce
    case (.confirmingForce, .cancel): state = .offerForce
    case (.confirmingForce, .confirmForce):
      forceTerminate()
      state = .waiting(sinceNs: nowNs)
    default: break
    }
  }
}
