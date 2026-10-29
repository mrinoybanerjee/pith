import Testing

@testable import Pith

/// R144: each debug flag with its value gives its mode. A flag without its value, with a wrong
/// one, or `--render-panel` with a directory, is a usage error (nil), not a trap.
@Test func launchArgumentsGiveTheirMode() {
  let cases: [([String], LaunchMode?)] = [
    ([], .app(debugHooks: false)),
    (["--debug-hooks"], .app(debugHooks: true)),
    (["--snapshot-json", "10"], .snapshotJSON(seconds: 10)),
    (["--snapshot-json", "0"], .snapshotJSON(seconds: 0)),
    (["--benchmark-sweep", "200"], .benchmarkSweep(count: 200)),
    (["--render-panel"], .renderPanel),
    (["--demo", "tight"], .demo(.tight)),
    (["--hold-lid"], .holdLid),
    (["--snapshot-json"], nil),
    (["--snapshot-json", "soon"], nil),
    (["--snapshot-json", "-1"], nil),
    (["--snapshot-json", "inf"], nil),
    (["--benchmark-sweep"], nil),
    (["--benchmark-sweep", "0"], nil),
    (["--render-panel", "render-real"], nil),
    (["--demo"], nil),
    (["--demo", "busy"], nil),
    (["--hold-lid", "now"], nil),
  ]
  for (arguments, mode) in cases {
    #expect(
      LaunchMode.parse(["/Applications/Pith.app/Contents/MacOS/Pith"] + arguments) == mode,
      "\(arguments)")
  }
}
