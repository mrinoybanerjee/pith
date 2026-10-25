import AppKit
import PithCore
import Testing

@testable import Pith

// Native windows share the application's key window and first responder. `scripts/test.sh` runs
// each test of this suite in its own process.
@Suite(.serialized) @MainActor
struct NativeInteractionTests {}

extension NativeInteractionTests {
  @MainActor @Test func rowsReadAsSentences() throws {
    let w = try hostPanel(DemoSnapshots.tight)
    let labels = axLabels(in: w)
    #expect(labels.contains("Google Chrome, 6.4 GB memory, 41 processes"))
    #expect(labels.contains("Memory, 15.1 of 16 GB, Tight, 2.1 GB swap"))
    #expect(axInteractiveElements(in: w).allSatisfy { !($0.label ?? "").isEmpty })
  }

  @MainActor @Test func smallestReadableTextIsThirteenPoints() throws {
    #expect(
      try minimumReadableFontSize(hostPanel(DemoSnapshots.calm), excludingIdentifier: "pith.footer")
        >= 13)
  }

  @MainActor @Test func commandTwoSwitchesToCPU() throws {
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    sendKey("2", modifiers: .command, to: w)
    #expect(store.metric == .cpu)
  }

  @MainActor @Test func longNamesTruncateAndValuesStay() throws {
    let w = try hostPanel(
      DemoSnapshots.withAppName(String(repeating: "Extraordinarily Long App ", count: 6)))
    #expect(valueColumnFrames(in: w).allSatisfy { $0.maxX <= 352 })
  }

  @MainActor @Test func captureDesignStatesWhenRequested() throws {
    guard let dir = ProcessInfo.processInfo.environment["PITH_UI_SNAPSHOT_DIR"] else { return }
    for (name, snap) in [("calm", DemoSnapshots.calm), ("tight", DemoSnapshots.tight)] {
      for scheme in [NSAppearance.Name.aqua, .darkAqua] {
        try writePNG(
          hostPanel(snap, appearance: scheme), to: "\(dir)/\(name)-\(scheme.rawValue).png")
      }
    }
  }

  /// Spec 4.8: ↑ and ↓ move between the rows, "macOS system" last; Return opens and closes the
  /// row; ⌘1–⌘3 pick the metric; Escape closes the attached panel.
  @Test func theKeyboardMovesOpensSwitchesAndCloses() throws {
    let (w, store) = try hostPanelWithStore(DemoSnapshots.tight)
    sendKey("↓", to: w)
    sendKey("↓", to: w)
    #expect(store.selectedRowID == store.rows[1].id)
    sendKey("↩", to: w)
    #expect(store.expandedAppID == store.rows[1].id)
    sendKey("↩", to: w)
    #expect(store.expandedAppID == nil)
    sendKey("↑", to: w)
    sendKey("↑", to: w)
    #expect(store.selectedRowID == store.rows[0].id)
    for _ in 0..<10 { sendKey("↓", to: w) }
    #expect(store.selectedRowID == Store.systemRowID)
    sendKey("3", modifiers: .command, to: w)
    #expect(store.metric == .disk)
    sendKey("1", modifiers: .command, to: w)
    #expect(store.metric == .memory)
    sendKey("⎋", to: w)
    #expect(!w.isVisible)
  }

  /// Spec 4.3: an opened row shows the guide's explanation, its process count and what is inside.
  @Test func anOpenedRowExplainsTheAppAndListsWhatIsInside() async throws {
    let (w, store) = try hostPanelWithStore(DemoSnapshots.tight)
    #expect(!axLabels(in: w).contains("41 processes"))
    store.toggle(store.rows[0].id)
    #expect(try await eventually(w) { axLabels(in: w).contains("Tabs and sites (34), 5.1 GB") })
    let labels = axLabels(in: w)
    #expect(labels.contains("41 processes"))
    #expect(labels.contains("Graphics, 620 MB"))
    #expect(labels.contains("Google Chrome, 210 MB"))
    let chrome = try #require(
      try Guide.bundled().entry(name: "", bundleID: "com.google.Chrome", path: nil))
    #expect(labels.contains(chrome.explanation))
  }

  /// R49: a process outside any app shows its guide title, and its opened row explains it.
  @Test func aProcessWithAGuideEntryShowsItsTitle() async throws {
    let photos = AppUsage(
      id: "proc:photoanalysisd", name: "photoanalysisd", bundlePath: nil, bundleID: nil,
      pids: [7001], processCount: 1, memory: 180 << 20, cpu: .value(0.004),
      diskBytesPerSecond: .value(0),
      inside: [HelperGroup(label: "photoanalysisd", count: 1, memory: 180 << 20)])
    let (w, store) = try hostPanelWithStore(
      remake(DemoSnapshots.calm, apps: DemoSnapshots.calm.apps + [photos]))
    #expect(axLabels(in: w).contains("Photos analysis, 180 MB memory, 1 process"))
    store.toggle(photos.id)
    let entry = try #require(
      try Guide.bundled().entry(name: "photoanalysisd", bundleID: nil, path: nil))
    #expect(try await eventually(w) { axLabels(in: w).contains(entry.explanation) })
  }

  /// "Never 0 for unknown": the first open tick has no CPU yet, so the CPU tile and the rows show
  /// "—", and VoiceOver says "not available yet".
  @Test func unknownValuesShowADashNeverZero() async throws {
    let (w, store) = try hostPanelWithStore(remake(DemoSnapshots.calm, firstTick: true))
    #expect(axLabels(in: w).contains("CPU, not available yet"))
    store.metric = .cpu
    #expect(
      try await eventually(w) {
        axLabels(in: w).contains("Google Chrome, CPU not available yet, 22 processes")
      })
    #expect(!axLabels(in: w).contains { $0.contains("%") })
  }

  /// R59 and R47: opening "macOS system" measures once and says "Measuring…" until it is done.
  /// Then it lists the largest system processes and "Other system work", the residual less the
  /// listed items, so the rows add up to the total shown.
  @Test func theSystemRowMeasuresWhenOpenedAndAddsUp() async throws {
    let measurer = HeldMeasurer()
    let (w, store) = try hostPanelWithStore(
      DemoSnapshots.tight, store: testStore(measure: { try await measurer.measure() }))
    #expect(axLabels(in: w).contains("macOS system, 1.2 GB memory"))
    store.toggle(Store.systemRowID)
    #expect(try await eventually(w) { axLabels(in: w).contains("Measuring…") })
    #expect(measurer.calls == 1)
    measurer.release(.success(systemBreakdown))
    #expect(try await eventually(w) { axLabels(in: w).contains("Other system work, 290 MB") })
    let labels = axLabels(in: w)
    for row in ["Spotlight indexing, 420 MB", "Window server, 310 MB", "Photos analysis, 180 MB"] {
      #expect(labels.contains(row))
    }
    #expect(labels.contains("Measured once, just now. Pith asks macOS only when you open this."))
    #expect(labels.contains("Spotlight indexing: Builds the search index after files change."))
    #expect(labels.contains("Part of macOS. Pith never offers to quit it."))
  }

  /// R59 and spec 6.7: a failed measurement says so and offers Retry, which measures again.
  @Test func aFailedMeasurementOffersRetry() async throws {
    let measurer = HeldMeasurer()
    let (w, store) = try hostPanelWithStore(
      DemoSnapshots.tight, store: testStore(measure: { try await measurer.measure() }))
    store.toggle(Store.systemRowID)
    #expect(try await eventually(w) { measurer.calls == 1 })
    measurer.release(.failure(SystemDetailsError.failed("synthetic failure")))
    #expect(try await eventually(w) { axLabels(in: w).contains("Couldn't measure system details") })
    try press("Retry", in: w)
    #expect(
      try await eventually(w) { measurer.calls == 2 && axLabels(in: w).contains("Measuring…") })
    measurer.release(.success(systemBreakdown))
    #expect(try await eventually(w) { axLabels(in: w).contains("Other system work, 290 MB") })
  }

  /// R59: the panel's height follows its content up to 560 pt, and then the list scrolls. Each
  /// change resizes it once. Attached, its top edge stays under the status item; pinned, its
  /// top-left corner stays.
  @Test func thePanelHeightFollowsItsContentUpTo560() async throws {
    defer { UserDefaults().removePersistentDomain(forName: panelSuite) }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    var resizes = 0
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: w, queue: nil
    ) { _ in MainActor.assumeIsolated { resizes += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }
    let closed = w.frame
    let finder = try #require(store.rows.first { $0.name == "Finder" }).id
    store.toggle(finder)
    #expect(try await eventually(w) { w.frame.height > closed.height })
    #expect(w.frame.height < 560 && w.frame.maxY == closed.maxY && resizes == 1)
    store.toggle(store.rows[0].id)  // Google Chrome: too tall, so the list scrolls
    #expect(try await eventually(w) { w.frame.height == 560 })
    #expect(w.frame.maxY == closed.maxY && resizes == 2)
    store.toggle(store.rows[0].id)
    #expect(try await eventually(w) { w.frame.height == closed.height })
    #expect(w.frame.maxY == closed.maxY && resizes == 3)

    store.pinned = true
    store.toggle(finder)
    #expect(try await eventually(w) { w.frame.height > closed.height })
    #expect(w.frame.minX == closed.minX && w.frame.maxY == closed.maxY && resizes == 4)
  }

  /// R59: Settings shows whether Pith really opens at login, read when the panel opens. A refused
  /// change says so under the toggle, and the toggle goes back to the real state.
  @Test func aRefusedLoginItemChangeSaysSoAndShowsTheRealState() async throws {
    let item = FakeLoginItem(enabled: true)
    item.refuses = true
    let (w, store) = try hostPanelWithStore(
      DemoSnapshots.calm, store: testStore(loginItem: item.loginItem))
    #expect(store.launchesAtLogin)
    store.showingSettings = true
    store.setLaunchAtLogin(false)
    #expect(store.launchesAtLogin && store.loginItemFailed && !store.settings.launchAtLogin)
    let refusal = "Couldn't change this. Try again in System Settings → General → Login Items."
    #expect(try await eventually(w) { axLabels(in: w).contains(refusal) })
    #expect(axInteractiveElements(in: w).first { $0.label == "Launch at login" }?.value == "1")
    item.refuses = false
    store.setLaunchAtLogin(false)
    #expect(!store.launchesAtLogin && !store.loginItemFailed)
    #expect(try await eventually(w) { !axLabels(in: w).contains(refusal) })
    #expect(axInteractiveElements(in: w).first { $0.label == "Launch at login" }?.value == "0")
  }

  /// Spec 4.6: exactly three settings, and limited grouping is a visible degraded mode (spec 6.5).
  @Test func settingsShowTheThreeChoicesAndLimitedGrouping() async throws {
    let (w, store) = try hostPanelWithStore(remake(DemoSnapshots.calm, grouping: .limited))
    store.showingSettings = true
    #expect(
      try await eventually(w) {
        axLabels(in: w).contains("App grouping is limited on this macOS version.")
      })
    let controls = axInteractiveElements(in: w).compactMap(\.label)
    for name in [
      "Pin", "Settings", "Launch at login", "1 s", "2 s", "Memory, CPU or storage",
      "Memory or storage only",
    ] {
      #expect(controls.contains(name), "\(name)")
    }
    #expect(!axLabels(in: w).contains("Using the most"))
  }
}

// MARK: - Hosting

/// The login item and `top` are never real in tests.
extension LoginItem {
  static let stub = LoginItem(isEnabled: { false }, set: { _ in })
}

@MainActor func testStore(
  guide: Guide = .empty, loginItem: LoginItem = .stub,
  measure: @escaping @Sendable () async throws -> SystemBreakdown = {
    throw SystemDetailsError.failed("no top in tests")
  }
) -> Store {
  Store(settings: Settings(), guide: guide, loginItem: loginItem, measureSystem: measure)
}

/// Only a pinned panel saves its frame here; a test that pins removes it.
let panelSuite = "pith.tests.panel"

/// The panels a test shows stay alive until its process ends.
@MainActor private var hostedPanels: [PanelController] = []

/// The real panel with `snapshot`, attached under a status item in the middle of the main
/// screen's menu bar, laid out and with its accessibility tree built.
@MainActor func hostPanelWithStore(
  _ snapshot: Snapshot, appearance: NSAppearance.Name = .aqua, store: Store? = nil
) throws -> (NSWindow, Store) {
  // SwiftUI builds its accessibility tree only for an assistive client, which sets this.
  _ = NSApplication.shared.perform(
    NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
    with: "AXEnhancedUserInterface")
  let store = try store ?? testStore(guide: Guide.bundled())
  store.apply(snapshot)
  let controller = PanelController(
    store: store, defaults: UserDefaults(suiteName: panelSuite)!,
    onChange: { _, _, _ in })
  controller.panel.appearance = NSAppearance(named: appearance)
  let screen = try #require(NSScreen.main).visibleFrame
  controller.toggle(
    under: (CGRect(x: screen.midX, y: screen.maxY, width: 22, height: 24), screen))
  controller.panel.contentView!.layoutSubtreeIfNeeded()
  hostedPanels.append(controller)
  return (controller.panel, store)
}

@MainActor func hostPanel(_ snapshot: Snapshot, appearance: NSAppearance.Name = .aqua) throws
  -> NSWindow
{
  try hostPanelWithStore(snapshot, appearance: appearance).0
}

/// Whether `condition` holds within 2 s, laying out the panel between checks.
@MainActor func eventually(_ w: NSWindow, _ condition: () -> Bool) async throws -> Bool {
  for _ in 0..<200 where !condition() {
    try await Task.sleep(for: .milliseconds(10))
    w.contentView!.layoutSubtreeIfNeeded()
  }
  return condition()
}

/// `snapshot` with other apps, with no CPU or disk rates yet (an open panel's first tick), or with
/// other grouping.
func remake(
  _ snapshot: Snapshot, apps: [AppUsage]? = nil, firstTick: Bool = false,
  grouping: GroupingQuality? = nil
) -> Snapshot {
  let t = snapshot.totals
  let rate = Reading<Double>.unavailable("first sample")
  return Snapshot(
    takenAtNs: snapshot.takenAtNs, mode: snapshot.mode,
    totals: SystemTotals(
      memoryUsed: t.memoryUsed, memoryTotal: t.memoryTotal, pressure: t.pressure,
      swapUsed: t.swapUsed, cpuBusy: firstTick ? rate : t.cpuBusy, storageFree: t.storageFree,
      storageTotal: t.storageTotal),
    apps: (apps ?? snapshot.apps).map { a in
      guard firstTick else { return a }
      return AppUsage(
        id: a.id, name: a.name, bundlePath: a.bundlePath, bundleID: a.bundleID, pids: a.pids,
        processCount: a.processCount, memory: a.memory, cpu: rate, diskBytesPerSecond: rate,
        inside: a.inside)
    },
    system: firstTick
      ? .value(SystemResidual(memory: snapshot.system.value!.memory, cpu: rate)) : snapshot.system,
    grouping: grouping ?? snapshot.grouping)
}

/// Synthetic `top` results whose items and "Other" match the tight mockup's opened system row.
let systemBreakdown = SystemBreakdown(
  items: [
    SystemItem(
      title: "Spotlight indexing", memory: 420 << 20,
      explanation: "Builds the search index after files change."),
    SystemItem(title: "Window server", memory: 310 << 20, explanation: nil),
    SystemItem(title: "Photos analysis", memory: 180 << 20, explanation: nil),
  ], other: 999 << 20)

/// Stands in for `SystemDetails.measure()`: each call waits until the test releases it.
@MainActor final class HeldMeasurer {
  private(set) var calls = 0
  private var waiting: [CheckedContinuation<SystemBreakdown, any Error>] = []

  func measure() async throws -> SystemBreakdown {
    calls += 1
    return try await withCheckedThrowingContinuation { waiting.append($0) }
  }

  func release(_ result: Result<SystemBreakdown, any Error>) {
    for continuation in waiting { continuation.resume(with: result) }
    waiting = []
  }
}

/// A login item that a test can make refuse every change.
@MainActor final class FakeLoginItem {
  var enabled: Bool
  var refuses = false

  init(enabled: Bool) { self.enabled = enabled }

  var loginItem: LoginItem {
    LoginItem(
      isEnabled: { self.enabled },
      set: {
        if self.refuses { throw SystemDetailsError.failed("synthetic refusal") }
        self.enabled = $0
      })
  }
}

// MARK: - Keys and images

/// Sends a key press to `window` as the application does. `key` is a digit or ↑ ↓ ↩ ⎋.
@MainActor func sendKey(_ key: String, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
  let keys: [String: (code: UInt16, characters: String)] = [
    "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "↑": (126, "\u{F700}"),
    "↓": (125, "\u{F701}"), "↩": (36, "\r"), "⎋": (53, "\u{1B}"),
  ]
  let (code, characters) = keys[key]!
  // A real arrow key also carries the function-key and keypad flags.
  let flags = code >= 125 ? modifiers.union([.function, .numericPad]) : modifiers
  window.sendEvent(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
}

/// Renders the panel offscreen, as `screencapture` cannot run over SSH.
@MainActor func writePNG(_ window: NSWindow, to path: String) throws {
  let view = try #require(window.contentView)
  view.layoutSubtreeIfNeeded()
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.cacheDisplay(in: view.bounds, to: bitmap)
  let url = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
}

// MARK: - Accessibility

/// One element of a window's accessibility tree, read as VoiceOver reads it.
@MainActor struct AXNode {
  let element: NSObject
  let role: String
  let label: String?
  let value: String?
  let identifier: String?
  /// In screen coordinates.
  let frame: CGRect
  /// The point sizes of the text runs, for text elements.
  let fontSizes: [CGFloat]
  let children: [AXNode]

  /// What VoiceOver speaks. It reads a no-break space as a space.
  var spoken: String? { (label ?? value)?.replacing("\u{A0}", with: " ") }
  var flattened: [AXNode] { [self] + children.flatMap(\.flattened) }

  /// SwiftUI's elements answer the NSAccessibility selectors without declaring the protocol, so
  /// the walk sends the selectors, as AppKit does.
  init(_ element: NSObject) {
    func object(_ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }
    func text(_ value: Any?) -> String? {
      switch value {
      case let string as String: string
      case let number as NSNumber: number.stringValue
      default: nil
      }
    }
    self.element = element
    role = object("accessibilityRole") as? String ?? "AXUnknown"
    label = (object("accessibilityLabel") as? String).flatMap { $0.isEmpty ? nil : $0 }
    value = text(object("accessibilityValue"))
    identifier = object("accessibilityIdentifier") as? String
    frame = Self.frame(of: element)
    let attributed = NSSelectorFromString("accessibilityAttributedStringForRange:")
    if let text = value ?? label, element.responds(to: attributed),
      let method = class_getInstanceMethod(type(of: element), attributed)
    {
      typealias Getter = @convention(c) (AnyObject, Selector, NSRange) -> NSAttributedString?
      let string = unsafeBitCast(method_getImplementation(method), to: Getter.self)(
        element, attributed, NSRange(location: 0, length: (text as NSString).length))
      var sizes: [CGFloat] = []
      string?.enumerateAttribute(
        NSAttributedString.Key("AXFont"), in: NSRange(location: 0, length: string!.length)
      ) { font, _, _ in
        if let size = (font as? [String: Any])?["AXFontSize"] as? NSNumber {
          sizes.append(CGFloat(size.doubleValue))
        }
      }
      fontSizes = sizes
    } else {
      fontSizes = []
    }
    children = (object("accessibilityChildren") as? [NSObject] ?? []).map(AXNode.init)
  }

  private static func frame(of element: NSObject) -> CGRect {
    let selector = NSSelectorFromString("accessibilityFrame")
    guard element.responds(to: selector),
      let method = class_getInstanceMethod(type(of: element), selector)
    else { return .zero }
    typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
    return unsafeBitCast(method_getImplementation(method), to: Getter.self)(element, selector)
  }

  /// Presses the element, as VoiceOver's VO-Space does.
  func press() {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    let method = class_getInstanceMethod(type(of: element), selector)!
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    #expect(unsafeBitCast(method_getImplementation(method), to: Press.self)(element, selector))
  }
}

private let interactiveRoles: Set<String> = [
  "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
  "AXDisclosureTriangle", "AXLink", "AXSwitch",
]

@MainActor func axNodes(in window: NSWindow) -> [AXNode] { AXNode(window).flattened }

/// Everything VoiceOver speaks in `window`.
@MainActor func axLabels(in window: NSWindow) -> [String] {
  axNodes(in: window).compactMap(\.spoken)
}

@MainActor func axInteractiveElements(in window: NSWindow) -> [AXNode] {
  axNodes(in: window).filter { interactiveRoles.contains($0.role) }
}

@MainActor func press(_ label: String, in window: NSWindow) throws {
  try #require(axInteractiveElements(in: window).first { $0.label == label }).press()
}

/// The smallest font of any text VoiceOver can read in `window`, leaving out the element with
/// `identifier` and everything inside it.
@MainActor func minimumReadableFontSize(_ window: NSWindow, excludingIdentifier identifier: String)
  -> CGFloat
{
  func sizes(_ node: AXNode) -> [CGFloat] {
    node.identifier == identifier ? [] : node.fontSizes + node.children.flatMap(sizes)
  }
  let all = sizes(AXNode(window))
  #expect(all.count > 10, "found \(all.count) text runs")
  return all.min() ?? 0
}

/// The frames of the rows' values and process counts, in the window's coordinates.
@MainActor func valueColumnFrames(in window: NSWindow) -> [CGRect] {
  let frames = axNodes(in: window).filter { $0.identifier == "pith.value" }.map {
    window.convertFromScreen($0.frame)
  }
  #expect(frames.count >= 5, "found \(frames.count) values")
  return frames
}
