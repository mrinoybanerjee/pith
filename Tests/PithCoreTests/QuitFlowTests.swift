import Testing

@testable import PithCore

@Test func quitAsksFirstThenTerminatesOnce() {
  var f = QuitFlow()
  var terms = 0
  f.send(.tapQuit, nowNs: 0, isRunning: { true }, terminate: { terms += 1 }, forceTerminate: {})
  #expect(f.state == .confirming && terms == 0)
  f.send(.confirm, nowNs: 0, isRunning: { true }, terminate: { terms += 1 }, forceTerminate: {})
  #expect(f.state == .waiting(sinceNs: 0) && terms == 1)
}

@Test func cancelReturnsToIdle() {
  var f = QuitFlow(state: .confirming)
  f.send(.cancel, nowNs: 0, isRunning: { true }, terminate: {}, forceTerminate: {})
  #expect(f.state == .idle)
}

@Test func forceOfferedAfterFiveSeconds() {
  var f = QuitFlow(state: .waiting(sinceNs: 0))
  f.send(.tick, nowNs: 4_900_000_000, isRunning: { true }, terminate: {}, forceTerminate: {})
  #expect(f.state == .waiting(sinceNs: 0))
  f.send(.tick, nowNs: 5_000_000_000, isRunning: { true }, terminate: {}, forceTerminate: {})
  #expect(f.state == .offerForce)
}

@Test func quitFinishesWhenAppExits() {
  var f = QuitFlow(state: .waiting(sinceNs: 0))
  f.send(.tick, nowNs: 1, isRunning: { false }, terminate: {}, forceTerminate: {})
  #expect(f.state == .done)
}

@Test func forceNeedsSecondConfirm() {
  var f = QuitFlow(state: .offerForce)
  var forced = 0
  f.send(.tapForce, nowNs: 0, isRunning: { true }, terminate: {}, forceTerminate: { forced += 1 })
  #expect(forced == 0)
  f.send(
    .confirmForce, nowNs: 0, isRunning: { true }, terminate: {}, forceTerminate: { forced += 1 })
  #expect(forced == 1)
}

/// Cancel on the second confirm goes back to the offer. A Force Quit waits again, so an app that
/// even that does not end is offered Force Quit once more.
@Test func forceQuitCanBeCancelledAndWaitsAgain() {
  var f = QuitFlow(state: .confirmingForce)
  var forced = 0
  f.send(.cancel, nowNs: 0, isRunning: { true }, terminate: {}, forceTerminate: { forced += 1 })
  #expect(f.state == .offerForce && forced == 0)
  f.send(.tapForce, nowNs: 0, isRunning: { true }, terminate: {}, forceTerminate: {})
  f.send(
    .confirmForce, nowNs: 7_000_000_000, isRunning: { true }, terminate: {},
    forceTerminate: { forced += 1 })
  #expect(f.state == .waiting(sinceNs: 7_000_000_000) && forced == 1)
  f.send(.tick, nowNs: 12_000_000_000, isRunning: { true }, terminate: {}, forceTerminate: {})
  #expect(f.state == .offerForce)
}

/// An event that the state does not offer, such as a second click on a button that has just gone
/// or a tick that is not waiting, changes nothing and calls nothing.
@Test func anEventTheStateDoesNotOfferChangesNothing() {
  let offered: [(QuitFlow.State, [QuitFlow.Event])] = [
    (.idle, [.tapQuit]), (.confirming, [.cancel, .confirm]), (.waiting(sinceNs: 0), [.tick]),
    (.offerForce, [.tapForce, .tick]), (.confirmingForce, [.cancel, .confirmForce, .tick]),
    (.done, []),
  ]
  for (state, events) in offered {
    for event in [QuitFlow.Event.tapQuit, .cancel, .confirm, .tick, .tapForce, .confirmForce]
    where !events.contains(event) {
      var f = QuitFlow(state: state)
      var calls = 0
      f.send(
        event, nowNs: 0, isRunning: { true }, terminate: { calls += 1 },
        forceTerminate: { calls += 1 })
      #expect(f.state == state && calls == 0, "\(event) in \(state)")
    }
  }
}

/// R95: while Force Quit is offered or asked, a tick that finds the app gone ends the flow, and
/// nothing is forced. A tick that finds it running changes nothing.
@Test func aTickWhileForceQuitIsOfferedOrAskedSeesTheAppGone() {
  for state in [QuitFlow.State.offerForce, .confirmingForce] {
    var f = QuitFlow(state: state)
    var forced = 0
    f.send(.tick, nowNs: 9, isRunning: { true }, terminate: {}, forceTerminate: { forced += 1 })
    #expect(f.state == state)
    f.send(.tick, nowNs: 9, isRunning: { false }, terminate: {}, forceTerminate: { forced += 1 })
    #expect(f.state == .done && forced == 0, "\(state)")
  }
}
