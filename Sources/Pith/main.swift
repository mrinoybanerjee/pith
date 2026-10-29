import AppKit
import PithCore

// The debug modes (spec 10, R128, R129) run and then exit. None makes a status item, so none
// starts a second Pith next to the one running:
// - `--snapshot-json <seconds>`: two open readings that many seconds apart; the second as JSON on
//   stdout, with each process's footprint and CPU share between them (R138);
// - `--benchmark-sweep <n>`: the mean and longest time of n open readings back to back;
// - `--render-panel`: the real panel with the second of two live open readings 1 s apart, in
//   light and dark, as real-light.png and real-dark.png in a new folder under the temporary
//   directory, whose path it prints. They show real process names, so they never land in the
//   repo (R129, R144). Beside them, awake-light.png and awake-dark.png show the calm demo with
//   a session running (Awake spec 6);
// - `--demo <calm | tight>`: the panel with that `DemoSnapshots` state and no real reads, for
//   README captures, until it closes;
// - `--hold-lid`: not for people. The app starts it to keep the Mac awake with the lid closed,
//   and it ends when the app tells it to or ends (Awake spec 4.2).
// The panels of the last two keep their settings and pinned frame in a suite of their own,
// removed at exit, and never touch the real login item (R144). Otherwise Pith starts as usual,
// and `--debug-hooks` adds the panel notification (R128). A bad flag is a usage error (exit 2).
guard let mode = LaunchMode.parse(CommandLine.arguments) else {
  FileHandle.standardError.write(Data((LaunchMode.usage + "\n").utf8))
  exit(2)
}

/// The defaults suite of the `--demo` and `--render-panel` panels.
let debugSuite = "com.mrinoy.pith.debug.\(getpid())"

/// Removes `debugSuite`, then exits.
func exitDebugMode() -> Never {
  UserDefaults.standard.removePersistentDomain(forName: debugSuite)
  exit(0)
}

/// Runs `work`, then exits. With `appKit`, the main thread runs AppKit's loop, as windows need;
/// otherwise `dispatchMain()` parks it, and the main queue's work runs on another thread.
@MainActor func runAndExit(appKit: Bool = false, _ work: @escaping @MainActor () async -> Void)
  -> Never
{
  Task {
    await work()
    exit(0)
  }
  if appKit { NSApplication.shared.run() }
  dispatchMain()
}

func liveReading(_ seconds: Double) async -> LiveReading {
  let engine = Engine.live(SystemReader(), guide: try! Guide.bundled(in: .main))
  _ = await engine.tick(mode: .open)
  let first = await engine.lastTable!
  try! await Task.sleep(for: .seconds(seconds))
  let snapshot = await engine.tick(mode: .open)
  return LiveReading(
    snapshot: snapshot, previous: first, current: await engine.lastTable!,
    cpuCount: ProcessInfo.processInfo.activeProcessorCount)
}

/// The first reading fills the path cache and is not counted (R21).
func benchmark(_ count: Int) async -> String {
  let engine = Engine.live(SystemReader(), guide: try! Guide.bundled(in: .main))
  var snapshot = await engine.tick(mode: .open)
  var times: [Double] = []
  for _ in 0..<count {
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    snapshot = await engine.tick(mode: .open)
    times.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
  }
  return String(
    format: "sweep n=%d processes=%d mean_ms=%.3f max_ms=%.3f", count,
    snapshot.apps.reduce(0) { $0 + $1.processCount }, times.reduce(0, +) / Double(count),
    times.max()!)
}

/// The panel opened as a click opens it, under the top middle of the main screen, on a store of
/// its own with no lifecycle, that shows `snapshot` at each open. No row offers Quit, and no
/// session holds the Mac awake. The bar is drawn as on a Mac with a lid. With `awake`, it reads
/// "Awake until 3:40 PM". `closed` runs when the panel closes after it opened.
@MainActor func openPanel(
  _ snapshot: Snapshot, appearance: NSAppearance.Name?, awake: Bool = false,
  closed: @escaping @MainActor () -> Void = {}
) -> PanelController {
  _ = NSApplication.shared  // R124
  let defaults = UserDefaults(suiteName: debugSuite)!
  let store = Store(
    settings: .load(defaults), guide: try! Guide.bundled(in: .main), loginItem: .none,
    sleepHold: .none, lidHold: LidHold(hasLid: true, start: { _ in }, stop: {}),
    runningApps: .none,
    measureSystem: { throw SystemDetailsError.failed("not measured here") },
    nowNs: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
  if awake {
    store.startAwake(
      for: 3600, now: Calendar.current.date(bySettingHour: 14, minute: 40, second: 0, of: .now)!)
  }
  let controller = PanelController(store: store, defaults: defaults) { visible, _, _ in
    if visible { store.apply(snapshot) } else if store.snapshot != nil { closed() }
  }
  controller.uptimeNs = { 0 }  // the reading comes before the click (R121)
  controller.panel.appearance = appearance.map { NSAppearance(named: $0)! }
  let screen = NSScreen.main!.visibleFrame
  controller.toggle(under: (CGRect(x: screen.midX, y: screen.maxY, width: 22, height: 24), screen))
  precondition(controller.panel.isVisible, "the panel did not open")
  return controller
}

// `NSApplication.delegate` is weak; this global keeps the delegate alive.
var delegate: AppDelegate?
// The `--demo` panel.
var demo: PanelController?
switch mode {
case .snapshotJSON(let seconds):
  runAndExit {
    FileHandle.standardOutput.write(try! JSONEncoder().encode(await liveReading(seconds)))
  }
case .benchmarkSweep(let count):
  runAndExit { print(await benchmark(count)) }
case .renderPanel:
  runAndExit(appKit: true) {
    let snapshot = await liveReading(1).snapshot
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pith-render-\(UUID())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      try! openPanel(snapshot, appearance: appearance).panel.pngData().write(
        to: dir.appending(path: "real-\(name).png"))
      try! openPanel(DemoSnapshots.calm, appearance: appearance, awake: true).panel.pngData()
        .write(to: dir.appending(path: "awake-\(name).png"))
    }
    print(dir.path)
    UserDefaults.standard.removePersistentDomain(forName: debugSuite)
  }
case .demo(let state):
  let snapshot = [.calm: DemoSnapshots.calm, .tight: DemoSnapshots.tight][state]!
  Task { demo = openPanel(snapshot, appearance: nil) { exitDebugMode() } }
  NSApplication.shared.run()
case .holdLid:
  holdLid()
case .app(let debugHooks):
  delegate = AppDelegate(debugHooks: debugHooks)
  NSApplication.shared.delegate = delegate
  NSApplication.shared.run()
}
