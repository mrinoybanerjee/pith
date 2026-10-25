import AppKit
import PithCore

// The debug modes (spec 10, R128, R129) run and then exit. None makes a status item, so none
// starts a second Pith next to the one running:
// - `--snapshot-json <seconds>`: two open readings that many seconds apart; the second as JSON on
//   stdout, with each process's footprint and CPU share between them (R138);
// - `--benchmark-sweep <n>`: the mean and longest time of n open readings back to back;
// - `--render-panel <dir>`: the real panel with the second of two live open readings 1 s apart,
//   in light and dark, as real-light.png and real-dark.png. They show real process names, so they
//   are never committed;
// - `--demo <calm | tight>`: the panel with that `DemoSnapshots` state and no real reads, for
//   README captures, until it closes.
// Otherwise Pith starts as usual, and `--debug-hooks` adds the panel notification (R128).
let arguments = CommandLine.arguments

/// The argument after `flag`, if `flag` was given.
func argument(after flag: String) -> String? {
  arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
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

/// The second of two open readings `seconds` apart, and each of its processes by PID: its
/// footprint, and its share of the whole Mac between the readings when it ran the same executable
/// in both, as the engine counts it (R132). For `scripts/accuracy.sh`, which compares only the
/// PIDs that `top` saw too (R138).
struct LiveReading: Encodable {
  struct Process: Encodable {
    let footprint: UInt64
    let cpu: Double?
  }

  let snapshot: Snapshot
  let processes: [String: Process]
}

func liveReading(_ seconds: Double) async -> LiveReading {
  let engine = Engine.live(SystemReader(), guide: try! Guide.bundled(in: .main))
  _ = await engine.tick(mode: .open)
  let first = await engine.lastTable!
  try! await Task.sleep(for: .seconds(seconds))
  let snapshot = await engine.tick(mode: .open)
  let second = await engine.lastTable!
  let before = Dictionary(uniqueKeysWithValues: first.samples.map { ($0.key.pid, $0) })
  let wallNs = Double(second.takenAtNs - first.takenAtNs)
  let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
  return LiveReading(
    snapshot: snapshot,
    processes: Dictionary(
      uniqueKeysWithValues: second.samples.map { s in
        let p = before[s.key.pid].flatMap {
          $0.key == s.key && $0.idVersion == s.idVersion ? $0 : nil
        }
        let cpu = p.map { Double(s.cpuTimeNs - $0.cpuTimeNs) / (wallNs * cores) }
        return ("\(s.key.pid)", LiveReading.Process(footprint: s.footprint, cpu: cpu))
      }))
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
/// its own with no lifecycle, that shows `snapshot` at each open. No row offers Quit. `closed`
/// runs when the panel closes after it opened.
@MainActor func openPanel(
  _ snapshot: Snapshot, appearance: NSAppearance.Name?,
  closed: @escaping @MainActor () -> Void = {}
) -> PanelController {
  _ = NSApplication.shared  // R124
  let store = Store(
    settings: .load(.standard), guide: try! Guide.bundled(in: .main), loginItem: .main,
    runningApps: .none, measureSystem: { throw SystemDetailsError.failed("not measured here") },
    nowNs: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
  let controller = PanelController(store: store, defaults: .standard) { visible, _, _ in
    if visible { store.apply(snapshot) } else if store.snapshot != nil { closed() }
  }
  controller.uptimeNs = { 0 }  // the reading comes before the click (R121)
  controller.panel.appearance = appearance.map { NSAppearance(named: $0)! }
  let screen = NSScreen.main!.visibleFrame
  controller.toggle(under: (CGRect(x: screen.midX, y: screen.maxY, width: 22, height: 24), screen))
  assert(controller.panel.isVisible)
  return controller
}

// `NSApplication.delegate` is weak; this global keeps the delegate alive.
var delegate: AppDelegate?
// The `--demo` panel.
var demo: PanelController?
if let seconds = argument(after: "--snapshot-json") {
  runAndExit {
    FileHandle.standardOutput.write(try! JSONEncoder().encode(await liveReading(Double(seconds)!)))
  }
} else if let count = argument(after: "--benchmark-sweep") {
  runAndExit { print(await benchmark(Int(count)!)) }
} else if let dir = argument(after: "--render-panel") {
  runAndExit(appKit: true) {
    let snapshot = await liveReading(1).snapshot
    try! FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      try! openPanel(snapshot, appearance: appearance).panel.pngData().write(
        to: URL(fileURLWithPath: dir).appending(path: "real-\(name).png"))
    }
  }
} else if let state = argument(after: "--demo") {
  let snapshot = ["calm": DemoSnapshots.calm, "tight": DemoSnapshots.tight][state]!
  Task { demo = openPanel(snapshot, appearance: nil) { exit(0) } }
  NSApplication.shared.run()
} else {
  delegate = AppDelegate(debugHooks: arguments.contains("--debug-hooks"))
  NSApplication.shared.delegate = delegate
  NSApplication.shared.run()
}
