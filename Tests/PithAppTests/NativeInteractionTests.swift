import AppKit
import PithCore
import PithTestSupport
import SwiftUI
import Testing

@testable import Pith

// Native windows share the application's key window and first responder. `scripts/test.sh` runs
// each test of this suite in its own process. AppKit is set up before each one, including those
// that make a panel without the hosting helpers (R127).
@Suite(.serialized) @MainActor
struct NativeInteractionTests {
  init() { startAppKit() }
}

extension NativeInteractionTests {
  @MainActor @Test func rowsReadAsSentences() throws {
    let w = try hostPanel(DemoSnapshots.tight)
    let labels = axLabels(in: w)
    #expect(labels.contains("Google Chrome, 6.4 GB memory, 41 processes"))
    #expect(labels.contains("Memory, 15.1 of 16 GB, Tight, 2.1 GB swap"))
    // R148: VoiceOver hears each row once, through its button; the texts it repeats are hidden.
    #expect(labels.count { $0 == "Google Chrome, 6.4 GB memory, 41 processes" } == 1)
    #expect(!labels.contains("Google Chrome") && !labels.contains("6.4 GB"))
    #expect(axInteractiveElements(in: w).allSatisfy { !($0.label ?? "").isEmpty })
  }

  @MainActor @Test func smallestReadableTextIsThirteenPoints() throws {
    RowTextFrames.recorded = [:]  // the rows' own texts, which VoiceOver does not read (R148)
    #expect(
      try minimumReadableFontSize(hostPanel(DemoSnapshots.calm), excludingIdentifier: "pith.footer")
        >= 13)
    let rowSizes = rowTextPointSizes()
    #expect(rowSizes.count == 12 && rowSizes.allSatisfy { $0 >= 13 }, "\(rowSizes)")  // 6 rows
  }

  @MainActor @Test func commandTwoSwitchesToCPU() throws {
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    sendKey("2", modifiers: .command, to: w)
    #expect(store.metric == .cpu)
  }

  @MainActor @Test func longNamesTruncateAndValuesStay() throws {
    RowTextFrames.recorded = [:]
    _ = try hostPanel(
      DemoSnapshots.withAppName(String(repeating: "Extraordinarily Long App ", count: 6)))
    #expect(valueColumnFrames().allSatisfy { $0.maxX <= 352 })
  }

  /// R75: a tool for the design check and the README images, so it is skipped, not passed, unless
  /// asked for. The last states are Google Chrome opened, asking to quit (spec 4.5). Each demo app
  /// must be on this Mac, at the row's path with the row's bundle ID, so every row shows its own
  /// icon (R153).
  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["PITH_UI_SNAPSHOT_DIR"] != nil))
  func captureDesignStatesWhenRequested() async throws {
    defer { clearDefaults() }
    let missing = (DemoSnapshots.calm.apps + DemoSnapshots.tight.apps).compactMap {
      Bundle(path: $0.bundlePath!)?.bundleIdentifier == $0.bundleID ? nil : $0.bundlePath!
    }
    try #require(missing.isEmpty, "not on this Mac with the row's bundle ID")
    let dir = ProcessInfo.processInfo.environment["PITH_UI_SNAPSHOT_DIR"]!
    for scheme in [NSAppearance.Name.aqua, .darkAqua] {
      for (name, snap) in [("calm", DemoSnapshots.calm), ("tight", DemoSnapshots.tight)] {
        try writePNG(
          hostPanel(snap, appearance: scheme), to: "\(dir)/\(name)-\(scheme.rawValue).png")
      }
      // The tight panel's Google Chrome is taller than the list with its confirm, so the list shows
      // the whole confirm and the row's name scrolls away (R98); the calm panel's fits whole.
      for (name, snapshot) in [
        ("quit-confirm", DemoSnapshots.tight), ("quit-confirm-calm", DemoSnapshots.calm),
      ] {
        let (w, _, _) = try await hostOpened("Google Chrome", in: snapshot, appearance: scheme)
        try press("Quit", in: w)
        #expect(try await eventually(w) { axLabels(in: w).contains(quitSentence) })
        try await Task.sleep(for: .milliseconds(100))
        try writePNG(w, to: "\(dir)/\(name)-\(scheme.rawValue).png")
      }
    }
  }

  /// R153: the offscreen capture draws at 2x on any screen, so the README images are sharp.
  @MainActor @Test func theCaptureIsTwiceThePanelsPointSize() throws {
    let w = try hostPanel(DemoSnapshots.calm)
    let image = try #require(NSBitmapImageRep(data: w.pngData()))
    let points = w.contentView!.bounds.size
    #expect(image.pixelsWide == 720 && image.pixelsHigh == Int(points.height) * 2, "\(points)")
  }

  /// R145: the hook's `open` does nothing while the panel waits for its reading, so it cannot cancel
  /// that open; `close` cancels it, so the reading that lands then does not show the panel.
  @Test func theHookOpensOnceAndClosesWhileOpening() throws {
    defer { clearDefaults() }
    let store = testStore(guide: try Guide.bundled())
    let controller = PanelController(
      store: store, defaults: testDefaults(), onChange: { _, _, _ in })
    controller.uptimeNs = { 0 }  // the open comes before the readings (R121)
    controller.open(under: try anchor())
    controller.open(under: try anchor())  // a second open while it waits
    store.apply(DemoSnapshots.calm)
    #expect(controller.panel.isVisible)
    controller.dismiss()
    controller.open(under: try anchor())
    controller.dismiss()  // while it waits
    store.apply(DemoSnapshots.tight)
    #expect(!controller.panel.isVisible)
  }

  /// R71: the click asks for an open reading, and the panel shows only once it is applied, at its
  /// final rows and height. It does not resize after it shows until the content changes, and a
  /// closed reading never reaches it.
  @Test func thePanelOpensAtItsFinalSizeWithTheFirstOpenReading() async throws {
    enableAccessibilityTree()
    let store = testStore(guide: try Guide.bundled())
    store.apply(closed(DemoSnapshots.tight))
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      // The lifecycle's open reading lands a moment after the click.
      onChange: { visible, _, _ in if visible { Task { store.apply(DemoSnapshots.tight) } } })
    controller.uptimeNs = { 0 }  // the clicks come before the readings (R121)
    let w = controller.panel
    var resizesWhileShown = 0
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: w, queue: nil
    ) { _ in MainActor.assumeIsolated { if controller.panel.isVisible { resizesWhileShown += 1 } } }
    defer { NotificationCenter.default.removeObserver(observer) }
    let screen = try #require(NSScreen.main).visibleFrame
    controller.toggle(
      under: (CGRect(x: screen.midX, y: screen.maxY, width: 22, height: 24), screen))
    #expect(!w.isVisible)
    #expect(try await eventually(w) { w.isVisible })
    let shown = w.frame
    #expect(axLabels(in: w).contains("Google Chrome, 6.4 GB memory, 41 processes"))
    try await Task.sleep(for: .milliseconds(500))
    w.contentView!.layoutSubtreeIfNeeded()
    #expect(resizesWhileShown == 0 && w.frame == shown)
    // A closed reading with other totals and the same status changes nothing on the panel.
    let t = DemoSnapshots.tight.totals
    store.apply(
      Snapshot(
        takenAtNs: 2_000_000_000, mode: .closed,
        totals: SystemTotals(
          memoryUsed: .value(12 << 30), footprintTotal: .value(12 << 30),
          memoryTotal: t.memoryTotal, pressure: t.pressure,
          swapUsed: t.swapUsed, cpuBusy: t.cpuBusy, storageFree: t.storageFree,
          storageTotal: t.storageTotal),
        apps: [], system: .unavailable("closed"), grouping: .full))
    try await Task.sleep(for: .milliseconds(200))
    w.contentView!.layoutSubtreeIfNeeded()
    #expect(axLabels(in: w).contains("Memory, 15.1 of 16 GB, Tight, 2.1 GB swap"))
    #expect(resizesWhileShown == 0 && w.frame == shown)
  }

  /// R85: an open never animates from what the panel drew before. The capture at show and the one
  /// 300 ms later are the same pixels: at the first open, and at a re-open whose rows changed
  /// while it was closed, with a row that was open when it closed.
  @Test func anOpenIsNeverAnimated() async throws {
    let store = testStore(guide: try Guide.bundled())
    let reading = NextReading(DemoSnapshots.calm)
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, _, _ in if visible { store.apply(reading.snapshot) } })
    controller.uptimeNs = { 0 }  // the clicks come before the readings (R121)
    let w = controller.panel
    controller.toggle(under: try anchor())
    let first = w.pngData()
    try await Task.sleep(for: .milliseconds(300))
    #expect(w.pngData() == first)
    store.toggle(store.rows[0].id)
    try await Task.sleep(for: .milliseconds(300))
    controller.toggle(under: try anchor())  // closes it
    reading.snapshot = DemoSnapshots.tight  // other apps, in another order
    controller.toggle(under: try anchor())
    #expect(w.isVisible && store.expandedAppID == nil)
    let reopened = w.pngData()
    try await Task.sleep(for: .milliseconds(300))
    #expect(w.pngData() == reopened)
  }

  /// R165: with CPU chosen, an open's first reading keeps Memory order, and the next one, with
  /// rates, sorts the rows by CPU at once: the capture right after it and the one 300 ms later are
  /// the same pixels.
  @Test func theFirstRatesSortTheRowsWithoutAnimation() async throws {
    let store = testStore(guide: try Guide.bundled())
    store.metric = .cpu
    let rated = reversingCPU(DemoSnapshots.tight)
    let first = remake(rated, firstTick: true)
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, _, _ in if visible { store.apply(first) } })
    controller.uptimeNs = { 0 }  // the click comes before the reading (R121)
    let w = controller.panel
    controller.toggle(under: try anchor())
    #expect(w.isVisible)
    store.apply(rated)
    w.contentView!.layoutSubtreeIfNeeded()
    let sorted = w.pngData()
    try await Task.sleep(for: .milliseconds(300))
    #expect(w.pngData() == sorted)
    #expect(
      store.rows.map(\.id)
        == RowOrder.stable(previous: [], apps: rated.apps, metric: .cpu).map(\.id))
  }

  /// R172: a row's icon is kept as two small bitmaps, the rows' 24 pt at 1x and 2x, drawn once
  /// from the app's icon, so no open reads the icon store's files again. The same holds for the
  /// generic icons of a tool and of an app whose bundle is gone.
  @Test func rowIconsAreKeptAsSmallBitmaps() {
    for path in ["/System/Applications/Calculator.app", nil, "/Applications/Gone Example.app"] {
      let icon = AppIcons.icon(forFile: path)
      #expect(icon.size == NSSize(width: 24, height: 24), "\(path ?? "tool")")
      #expect(icon.representations.allSatisfy { $0 is NSBitmapImageRep }, "\(path ?? "tool")")
      #expect(Set(icon.representations.map(\.pixelsWide)) == [24, 48], "\(path ?? "tool")")
    }
  }

  /// R88: while an open waits for its reading, a late occlusion note from the closed panel still
  /// reports it shown and not covered, so the speed stays open, attached or pinned.
  @Test func aLateOcclusionNoteKeepsAPendingOpenOpen() throws {
    let store = testStore(guide: try Guide.bundled())
    var reports: [String] = []
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, pinned, occluded in reports.append("\(visible) \(pinned) \(occluded)") })
    controller.uptimeNs = { 0 }  // the click comes before the reading (R121)
    let note = Notification(name: NSWindow.didChangeOcclusionStateNotification)
    reports = []  // the closed panel's own report when it starts
    controller.toggle(under: try anchor())
    controller.windowDidChangeOcclusionState(note)
    #expect(reports == ["true false false", "true false false"])
    store.apply(DemoSnapshots.calm)
    #expect(controller.panel.isVisible)
  }

  /// Spec 4.8: ↑ and ↓ move between the rows, "macOS system" last, and stop at the ends; Return
  /// opens and closes the row; ⌘1–⌘3 pick the metric; Escape closes the attached panel.
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
    #expect(store.selectedRowID == store.rows[0].id)
    sendKey("↑", to: w)  // past the top
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

  /// R73: ⌘1–⌘3 go by key, so they work on a layout whose number row types other characters, such
  /// as French AZERTY.
  @Test func commandDigitsWorkOnAnyLayout() throws {
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    sendKey("2", modifiers: .command, characters: "é", to: w)
    #expect(store.metric == .cpu)
    sendKey("3", modifiers: .command, characters: "\"", to: w)
    #expect(store.metric == .disk)
    sendKey("1", modifiers: .command, characters: "&", to: w)
    #expect(store.metric == .memory)
  }

  /// R73: while Settings show, ↑, ↓ and Return go to the focused control, not to the hidden list.
  @Test func inSettingsTheArrowsAndReturnReachTheControls() async throws {
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    let control = KeyRecorder()
    w.contentView!.addSubview(control)
    #expect(w.makeFirstResponder(control))
    store.showingSettings = true
    for key in ["↓", "↑", "↩"] { sendKey(key, to: w) }
    #expect(store.selectedRowID == nil && store.expandedAppID == nil)
    #expect(control.keyCodes == [125, 126, 36])
    store.showingSettings = false
    sendKey("↓", to: w)
    #expect(store.selectedRowID == store.rows[0].id && control.keyCodes == [125, 126, 36])
  }

  /// VoiceOver hears each state: the selected row and whether a row is open, the chosen metric in
  /// the "Sort by" group, and the Settings button while Settings show.
  @Test func voiceOverHearsTheStateOfRowsAndControls() async throws {
    let (w, store) = try hostPanelWithStore(DemoSnapshots.tight)
    let chrome = "Google Chrome, 6.4 GB memory, 41 processes"
    #expect(try axNode(chrome, in: w).role == "AXButton")
    #expect(try axNode(chrome, in: w).value == "collapsed")
    #expect(try axNode("Memory", in: w).selected && !(try axNode("CPU", in: w).selected))
    #expect(axNodes(in: w).contains { $0.label == "Sort by" && $0.children.count == 3 })
    sendKey("↓", to: w)
    #expect(try await eventually(w) { (try? axNode(chrome, in: w).selected) == true })
    sendKey("↩", to: w)
    #expect(try await eventually(w) { (try? axNode(chrome, in: w).value) == "expanded" })
    #expect(!(try axNode("Settings", in: w).selected))
    store.showingSettings = true
    #expect(try await eventually(w) { (try? axNode("Settings", in: w).selected) == true })
  }

  /// Spec 4.3: an opened row shows the guide's explanation, its process count and what is inside,
  /// with the app's own executable as the "Main process".
  @Test func anOpenedRowExplainsTheAppAndListsWhatIsInside() async throws {
    RowTextFrames.recorded = [:]  // the count is a row text, which VoiceOver does not read (R148)
    let count = "Google Chrome, 6.4 GB memory, 41 processes | 41 processes"
    let (w, store) = try hostPanelWithStore(DemoSnapshots.tight)
    #expect(RowTextFrames.recorded?[count] == nil)
    store.toggle(store.rows[0].id)
    #expect(try await eventually(w) { axLabels(in: w).contains("Tabs and sites (34), 5.1 GB") })
    let labels = axLabels(in: w)
    #expect(RowTextFrames.recorded?[count] != nil)
    #expect(labels.contains("Graphics, 620 MB"))
    #expect(labels.contains("Main process, 210 MB"))
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
      inside: [HelperGroup(label: "Main process", count: 1, memory: 180 << 20)])
    let (w, store) = try hostPanelWithStore(
      remake(DemoSnapshots.calm, apps: DemoSnapshots.calm.apps + [photos]))
    #expect(axLabels(in: w).contains("Photos analysis, 180 MB memory, 1 process"))
    store.toggle(photos.id)
    let entry = try #require(
      try Guide.bundled().entry(name: "photoanalysisd", bundleID: nil, path: nil))
    #expect(try await eventually(w) { axLabels(in: w).contains(entry.explanation) })
  }

  /// "Never 0 for unknown": the first open tick has no CPU or disk rates yet, so the CPU tile and
  /// the rows show "—" and VoiceOver says "not available yet". "macOS system" has no disk reading
  /// at all, so on Disk it says "not measured" (R76).
  @Test func unknownValuesShowADashAndMissingOnesSayNotMeasured() async throws {
    RowTextFrames.recorded = [:]  // what the rows draw, which VoiceOver reads in a sentence (R148)
    let (w, store) = try hostPanelWithStore(remake(DemoSnapshots.calm, firstTick: true))
    #expect(axLabels(in: w).contains("CPU, not available yet"))
    store.metric = .cpu
    #expect(
      try await eventually(w) {
        axLabels(in: w).contains("Google Chrome, CPU not available yet, 22 processes")
      })
    #expect(!axLabels(in: w).contains { $0.contains("%") })
    store.metric = .disk
    #expect(
      try await eventually(w) {
        axLabels(in: w).contains("Google Chrome, disk not available yet, 22 processes")
      })
    let labels = axLabels(in: w)
    #expect(labels.contains("macOS system, disk not measured"))
    #expect(RowTextFrames.recorded?["macOS system, disk not measured | not measured"] != nil)
    #expect(!labels.contains { $0.hasSuffix("/s") })
  }

  /// R110 and R122: a missing value says whether the next reading has it. Google Chrome's first CPU
  /// sample reads "not available yet". Claude's CPU mismatch, the accounting mismatch of "macOS
  /// system", and failed memory, CPU and storage reads read "not available", and their tooltip says,
  /// in plain words, that Pith couldn't measure them.
  @Test func aMissingValueSaysWhetherTheNextReadingHasIt() async throws {
    defer { clearDefaults() }
    let calm = DemoSnapshots.calm
    let t = calm.totals
    let chrome = remake(calm, firstTick: true).apps[0]
    let c = calm.apps[1]
    let claude = AppUsage(
      id: c.id, name: c.name, bundlePath: c.bundlePath, bundleID: c.bundleID, pids: c.pids,
      processCount: c.processCount, memory: c.memory, cpu: .unavailable("accounting mismatch"),
      diskBytesPerSecond: c.diskBytesPerSecond, inside: c.inside)
    let missing = Snapshot(
      takenAtNs: calm.takenAtNs, mode: .open,
      totals: SystemTotals(
        memoryUsed: .unavailable("host_statistics64 failed: 5"),
        footprintTotal: .unavailable("host_statistics64 failed: 5"), memoryTotal: t.memoryTotal,
        pressure: t.pressure, swapUsed: t.swapUsed,
        cpuBusy: .unavailable("host_processor_info failed: 4"),
        storageFree: .unavailable("volume unmounted"), storageTotal: t.storageTotal),
      apps: [chrome, claude] + calm.apps.dropFirst(2), system: .unavailable("accounting mismatch"),
      grouping: .full)
    let (w, store) = try hostPanelWithStore(missing)
    let plain = "Pith couldn't measure this right now."
    // A row's value is part of its button's sentence, and its tooltip is the button's help (R148).
    #expect(try axNode("macOS system, memory not available", in: w).help == plain)
    #expect(try axNode("CPU, not available", in: w).help == plain)
    let tiles = axNodes(in: w).filter { node in
      ["Memory, ", "Storage, "].contains { node.spoken?.hasPrefix($0) == true }
    }
    #expect(tiles.map { $0.spoken } == ["Memory, not available, Plenty", "Storage, not available"])
    #expect(tiles.allSatisfy { $0.help == plain })
    store.metric = .cpu
    #expect(
      try await eventually(w) {
        axLabels(in: w).contains("Google Chrome, CPU not available yet, 22 processes")
      })
    #expect(
      (try axNode("Google Chrome, CPU not available yet, 22 processes", in: w).help ?? "").isEmpty)
    #expect(try axNode("Claude, CPU not available, 9 processes", in: w).help == plain)
  }

  /// R120: on a screen whose visible frame is 540 pt tall, the panel is at most 524 pt tall, so it
  /// lies 8 pt inside the frame, with its header controls in view and its list scrolling. That holds
  /// at open with 560 pt or more of content, at a resize when a row opens, and for a pinned open.
  @Test func thePanelFitsAShortScreen() async throws {
    defer { clearDefaults() }
    enableAccessibilityTree()
    let screen = try #require(NSScreen.main).visibleFrame
    let short = CGRect(x: screen.minX, y: screen.maxY - 540, width: screen.width, height: 540)
    let extra = (0..<3).map { index in
      let path = "/Applications/Example \(index).app"
      return AppUsage(
        id: path, name: "Example \(index)", bundlePath: path, bundleID: nil,
        pids: [Int32(6000 + index)], processCount: 1, memory: UInt64(300 - index) << 20,
        cpu: .value(0.001), diskBytesPerSecond: .value(0), inside: [])
    }
    let eightRows = remake(DemoSnapshots.tight, apps: DemoSnapshots.tight.apps + extra)
    let store = testStore(guide: try Guide.bundled())
    let reading = NextReading(eightRows)
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, _, _ in if visible { store.apply(reading.snapshot) } })
    controller.uptimeNs = { 0 }  // the clicks come before the readings (R121)
    controller.ownScreenFrame = { _ in short }
    let w = controller.panel
    let item = CGRect(x: short.midX, y: short.maxY, width: 22, height: 24)
    func fits(_ when: String) throws {
      #expect(short.insetBy(dx: 8, dy: 8).contains(w.frame), "\(when): \(w.frame)")
      #expect(w.frame.height == 524, "\(when): \(w.frame)")
      for control in ["Pin", "Settings"] {
        #expect(w.frame.contains(try axNode(control, in: w).frame), "\(when): \(control)")
      }
      let list = try #require(scrollView(in: w.contentView!))
      #expect(
        try #require(list.documentView).frame.height > list.contentView.bounds.height,
        "\(when): the list scrolls")
    }
    controller.toggle(under: (item, short))
    #expect(w.isVisible)
    try fits("at open")
    controller.toggle(under: (item, short))  // closes it
    reading.snapshot = DemoSnapshots.tight  // 521 pt, under the cap
    controller.toggle(under: (item, short))
    #expect(w.isVisible && w.frame.height == 521)
    store.toggle(store.rows[0].id)  // Google Chrome opens, so the content grows past 560 pt
    #expect(try await eventually(w) { w.frame.height > 521 })
    try fits("after a resize")
    controller.toggle(under: (item, short))
    reading.snapshot = eightRows
    store.pinned = true
    controller.toggle(under: (item, short))
    #expect(try await eventually(w) { w.isVisible && w.isMovableByWindowBackground })
    try fits("pinned")
  }

  /// R121: a panel opens only on a reading taken after its click. A reading that started for an
  /// open the user then closed, and lands after the next click, does not open it; the next reading
  /// does.
  @Test func anOpenShowsOnlyOnAReadingTakenAfterItsClick() throws {
    defer { clearDefaults() }
    let store = testStore(guide: try Guide.bundled())
    var now: UInt64 = 10 * seconds
    let controller = PanelController(
      store: store, defaults: testDefaults(), onChange: { _, _, _ in })
    controller.uptimeNs = { now }
    let w = controller.panel
    let calm = DemoSnapshots.calm
    func reading(takenAt ns: UInt64) -> Snapshot {
      Snapshot(
        takenAtNs: ns, mode: .open, totals: calm.totals, apps: calm.apps, system: calm.system,
        grouping: .full)
    }
    controller.toggle(under: try anchor())  // a reading starts at 15 s
    controller.toggle(under: try anchor())  // closes it while that reading is in flight
    now = 20 * seconds
    controller.toggle(under: try anchor())  // opens again; another reading starts at 25 s
    store.apply(reading(takenAt: 15 * seconds))
    #expect(!w.isVisible)
    store.apply(reading(takenAt: 25 * seconds))
    #expect(w.isVisible)
  }

  /// R118: each open draws one panel view tree, and no earlier one lives on to watch the store.
  /// Before, the last open's tree saw the next open's reading; an animated row change then kept it
  /// alive, watching, after `show()` replaced it. The opens alternate two readings whose rows come
  /// in other orders, which animates the rows. Each tree has its own list, a scroll view, so a
  /// weak tally of the lists counts the trees: one after each of 5 opens, and none once closed.
  @Test func onlyOnePanelViewTreeLivesAcrossOpens() async throws {
    defer { clearDefaults() }
    let store = testStore()
    let reading = NextReading(DemoSnapshots.calm)
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, _, _ in if visible { store.apply(reading.snapshot) } })
    controller.uptimeNs = { 0 }  // the clicks come before the readings (R121)
    let w = controller.panel
    var lists: [WeakView] = []
    for open in 1...5 {
      reading.snapshot = open.isMultiple(of: 2) ? DemoSnapshots.tight : DemoSnapshots.calm
      controller.toggle(under: try anchor())
      await settle()
      for list in scrollViews(in: w.contentView!) where !lists.contains(where: { $0.view === list })
      {
        lists.append(WeakView(list))
      }
      #expect(lists.count(where: { $0.view != nil }) == 1, "open \(open)")
      controller.toggle(under: try anchor())  // closes it
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try await eventually(w) { lists.allSatisfy { $0.view == nil } })
  }

  /// R112: the store itself prunes the icon cache at each open snapshot, so no view has to be
  /// there to do it. Opened with apps A and B, whose icons the rows drew, closed, then opened with
  /// C and D only: the cache holds C and D. This runs in its own process, as the cache is shared.
  @Test func theStorePrunesTheIconCacheAtEachOpenSnapshot() {
    let store = testStore()
    let paths = ["a", "b", "c", "d"].map { "/Applications/Example \($0.uppercased()).app" }
    let snapshots = [paths[0...1], paths[2...3]].map { pair in
      remake(
        DemoSnapshots.calm,
        apps: pair.map {
          AppUsage(
            id: $0, name: $0, bundlePath: $0, bundleID: nil, pids: [5000], processCount: 1,
            memory: 1 << 28, cpu: .value(0.01), diskBytesPerSecond: .value(0), inside: [])
        })
    }
    store.apply(snapshots[0])
    for path in paths[0...1] { _ = AppIcons.icon(forFile: path) }  // as the rows draw them
    store.panelClosed()
    store.apply(snapshots[1])
    #expect(Set(AppIcons.icons.keys).isSubset(of: paths[2...3]))
    for path in paths[2...3] { _ = AppIcons.icon(forFile: path) }
    #expect(Set(AppIcons.icons.keys) == Set(paths[2...3]))
  }

  /// R112, through the real panel: opened with apps A and B and closed, then opened with C and D
  /// only, the cache holds C and D; the open reading lands a moment after the click, as the
  /// lifecycle's does. The same holds when C and D come while Settings take the list's place.
  @Test func theIconCacheKeepsOnlyTheRowsShown() async throws {
    defer { clearDefaults() }
    let store = testStore()
    let paths = ["a", "b", "c", "d"].map { "/Applications/Example \($0.uppercased()).app" }
    let apps = paths.enumerated().map { index, path in
      AppUsage(
        id: path, name: "Example \(index)", bundlePath: path, bundleID: nil,
        pids: [Int32(5000 + index)], processCount: 1, memory: UInt64(4 - index) << 28,
        cpu: .value(0.01), diskBytesPerSecond: .value(0), inside: [])
    }
    let ab = remake(DemoSnapshots.calm, apps: Array(apps[0...1]))
    let cd = remake(DemoSnapshots.calm, apps: Array(apps[2...3]))
    let reading = NextReading(ab)
    // As the lifecycle does, it reads when the panel opens, not again at each later report, such
    // as an occlusion change that lands after the test's own readings.
    var open = false
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, _, _ in
        if visible, !open { Task { store.apply(reading.snapshot) } }
        open = visible
      })
    controller.uptimeNs = { 0 }  // the clicks come before the readings (R121)
    let w = controller.panel
    controller.toggle(under: try anchor())
    #expect(try await eventually(w) { Set(AppIcons.icons.keys) == Set(paths[0...1]) })
    controller.toggle(under: try anchor())  // closes it
    reading.snapshot = cd
    controller.toggle(under: try anchor())
    #expect(try await eventually(w) { w.isVisible })
    #expect(try await eventually(w) { Set(AppIcons.icons.keys) == Set(paths[2...3]) }, "reopened")

    store.apply(ab)
    #expect(try await eventually(w) { Set(AppIcons.icons.keys) == Set(paths[0...1]) })
    store.showingSettings = true
    try await Task.sleep(for: .milliseconds(100))
    store.apply(cd)
    store.showingSettings = false
    #expect(
      try await eventually(w) { Set(AppIcons.icons.keys) == Set(paths[2...3]) }, "after Settings")
  }

  /// R76: an unknown pressure reads "—", and swap that is 0 is not shown.
  @Test func anUnknownPressureIsADashAndNoSwapIsNotShown() throws {
    let tight = DemoSnapshots.tight
    let t = tight.totals
    let unknown = Snapshot(
      takenAtNs: tight.takenAtNs, mode: .open,
      totals: SystemTotals(
        memoryUsed: t.memoryUsed, footprintTotal: t.footprintTotal, memoryTotal: t.memoryTotal,
        pressure: .unavailable("synthetic"), swapUsed: .value(0), cpuBusy: .value(0.296),
        storageFree: t.storageFree, storageTotal: t.storageTotal),
      apps: tight.apps, system: tight.system, grouping: .full)
    let labels = axLabels(in: try hostPanel(unknown))
    #expect(labels.contains("Memory, 15.1 of 16 GB, pressure not available"))
    // 29.6% shows as 30%, so the word is Moderate, not Light.
    #expect(labels.contains("CPU, 30%, Moderate"))
  }

  /// R89: the CPU word comes from the percent the tile shows, rounded once, as `PercentFormat`
  /// rounds it. At 70.5% the tile and the word agree.
  @Test func theCPUWordMatchesTheShownPercentAt70Point5() throws {
    let calm = DemoSnapshots.calm
    let t = calm.totals
    let busy = Snapshot(
      takenAtNs: calm.takenAtNs, mode: .open,
      totals: SystemTotals(
        memoryUsed: t.memoryUsed, footprintTotal: t.footprintTotal, memoryTotal: t.memoryTotal,
        pressure: t.pressure, swapUsed: t.swapUsed, cpuBusy: .value(0.705),
        storageFree: t.storageFree,
        storageTotal: t.storageTotal),
      apps: calm.apps, system: calm.system, grouping: .full)
    let shown = PercentFormat.total(0.705)
    let word = Int(shown.dropLast())! <= 70 ? "Moderate" : "Busy"
    #expect(axLabels(in: try hostPanel(busy)).contains("CPU, \(shown), \(word)"))
  }

  /// R89: VoiceOver calls the pin "Pin", selected while pinned; its tooltip says what a click does.
  @Test func thePinsTooltipSaysUnpinWhilePinned() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    #expect(try axNode("Pin", in: w).help == "Pin")
    store.pinned = true
    #expect(
      try await eventually(w) {
        (try? axNode("Pin", in: w)).map { $0.help == "Unpin" && $0.selected } == true
      })
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

  /// R47: without a residual, "Other system work" is what `top` found beyond the listed items;
  /// when the listed items exceed the residual, it is "—", never a made-up number.
  @Test func otherSystemWorkFallsBackToTopAndNeverGoesNegative() async throws {
    let unknown = remake(DemoSnapshots.tight, system: .unavailable("accounting mismatch"))
    let (w, store) = try hostPanelWithStore(
      unknown, store: testStore(measure: { systemBreakdown }))
    store.toggle(Store.systemRowID)
    #expect(try await eventually(w) { axLabels(in: w).contains("Other system work, 999 MB") })

    let small = remake(
      DemoSnapshots.tight, system: .value(SystemResidual(memory: 500 << 20, cpu: .value(0.01))))
    let (w2, store2) = try hostPanelWithStore(
      small, store: testStore(measure: { systemBreakdown }))
    store2.toggle(Store.systemRowID)
    #expect(
      try await eventually(w2) { axLabels(in: w2).contains("Other system work, not available") })
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

  /// R59: the panel's height follows its content up to 560 pt, and then the list scrolls while the
  /// status line and the tiles keep their size. Attached, its top edge stays under the status
  /// item; pinned, its top-left corner stays. How many resizes AppKit makes on the way is not
  /// checked, nor how far under 560 pt a row's content ends (the Air's fonts leave 5 pt).
  @Test func thePanelHeightFollowsItsContentUpTo560() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    let closed = w.frame
    let fixed = try ["All calm", "Memory, 9.8 of 16 GB, Plenty"].map { try axNode($0, in: w).frame }
    let finder = try #require(store.rows.first { $0.name == "Finder" }).id
    store.toggle(finder)
    #expect(try await eventually(w) { w.frame.height > closed.height })
    #expect(w.frame.height <= 560 && w.frame.maxY == closed.maxY)
    store.toggle(store.rows[0].id)  // Google Chrome: too tall, so the list scrolls
    #expect(try await eventually(w) { w.frame.height == 560 })
    #expect(w.frame.maxY == closed.maxY)
    let capped = try ["All calm", "Memory, 9.8 of 16 GB, Plenty"].map {
      try axNode($0, in: w).frame
    }
    #expect(capped == fixed)
    store.toggle(store.rows[0].id)
    #expect(try await eventually(w) { w.frame.height == closed.height })
    #expect(w.frame.maxY == closed.maxY)

    store.pinned = true
    store.toggle(finder)
    #expect(try await eventually(w) { w.frame.height > closed.height })
    #expect(w.frame.height <= 560 && w.frame.minX == closed.minX && w.frame.maxY == closed.maxY)
  }

  /// A pinned panel refits when the screens change, as when a display's resolution drops: it ends
  /// 8 pt inside its own screen's visible frame (the PR 2 council's minor).
  @Test func aPinnedPanelRefitsWhenTheScreensChange() async throws {
    defer { clearDefaults() }
    let (controller, store) = try hostPanelController(DemoSnapshots.tight)
    let w = controller.panel
    store.pinned = true
    #expect(try await eventually(w) { w.isMovableByWindowBackground })
    let short = CGRect(x: w.frame.minX + 100, y: w.frame.minY + 60, width: 800, height: 400)
    controller.ownScreenFrame = { _ in short }
    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    #expect(try await eventually(w) { short.insetBy(dx: 8, dy: 8).contains(w.frame) }, "\(w.frame)")
  }

  /// R72: a pinned panel partly past the left edge, above the top, or with its corner exactly at the
  /// top of the screen comes back on screen at its next height change, and never traps. A pinned
  /// panel's moves are clamped too, 0.25 s after the last one (R106), so this resize usually comes
  /// first; `anAttachedPanelOffTheScreenComesBackWhenItResizes` checks the resize clamp alone.
  @Test func aPinnedPanelOffTheScreenComesBackWhenItResizes() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    store.pinned = true
    #expect(try await eventually(w) { w.isMovableByWindowBackground })
    let screen = try #require(NSScreen.main)
    let inside = screen.visibleFrame.insetBy(dx: 8, dy: 8)
    let finder = try #require(store.rows.first { $0.name == "Finder" }).id
    // Each frame keeps the panel's height, so only the toggle changes it: the row opens, closes
    // and opens again.
    for place in 0..<3 {
      let height = w.frame.height
      let frame = [
        CGRect(x: screen.frame.minX - 200, y: 300, width: 360, height: height),
        CGRect(x: 400, y: screen.frame.maxY + 50, width: 360, height: height),
        CGRect(x: 400, y: screen.frame.maxY - height, width: 360, height: height),
      ][place]
      w.setFrame(frame, display: false)
      store.toggle(finder)
      #expect(try await eventually(w) { w.frame.height != height }, "\(frame)")
      #expect(inside.contains(w.frame), "\(frame) became \(w.frame)")
    }
  }

  /// R107: an attached panel is not clamped when it moves, so only the resize clamp brings it back:
  /// past the left edge, or growing past the bottom edge, it ends 8 pt inside the screen.
  @Test func anAttachedPanelOffTheScreenComesBackWhenItResizes() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    let visible = try #require(NSScreen.main).visibleFrame
    let finder = try #require(store.rows.first { $0.name == "Finder" }).id
    for origin in [CGPoint(x: visible.minX - 200, y: 300), CGPoint(x: 400, y: visible.minY + 8)] {
      w.setFrameOrigin(origin)
      let height = w.frame.height
      store.toggle(finder)  // the row opens, so the panel grows
      #expect(try await eventually(w) { w.frame.height > height }, "\(origin)")
      #expect(visible.insetBy(dx: 8, dy: 8).contains(w.frame), "\(origin) became \(w.frame)")
      store.toggle(finder)
      #expect(try await eventually(w) { w.frame.height == height }, "\(origin)")
    }
  }

  /// A pinned panel whose drag checks and mouse button the test runs (R106), with no saved frame.
  private func hostPinnedPanel(test: String = #function) async throws -> (
    PanelController, ManualChecks, MouseButton
  ) {
    let (controller, store) = try hostPanelController(DemoSnapshots.calm, test: test)
    let checks = ManualChecks()
    let mouse = MouseButton()
    controller.nextDragCheck = {  // throws once cancelled, as `Task.sleep` does
      await checks.wait()
      try Task.checkCancellation()
    }
    controller.mouseIsDown = { mouse.down }
    store.pinned = true
    #expect(try await eventually(controller.panel) { controller.panel.isMovableByWindowBackground })
    return (controller, checks, mouse)
  }

  /// R106: a drag may report each step as a move. While a mouse button is down, a pinned panel
  /// passes any edge unclamped, so it can reach another display, and each step replaces the
  /// pending check. At the first check with no button down, the panel comes back 8 pt inside the
  /// screen, once, and saves that frame. The bottom, left, right and top edges.
  @Test func aPinnedPanelIsClampedOnlyAfterTheDragEnds() async throws {
    defer { clearDefaults() }
    let (controller, checks, mouse) = try await hostPinnedPanel()
    let w = controller.panel
    let visible = try #require(NSScreen.main).visibleFrame
    controller.ownScreenFrame = { _ in visible }  // the same on a Mac with more displays
    var moves = 0
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: w, queue: nil
    ) { _ in MainActor.assumeIsolated { moves += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }
    let inside = visible.insetBy(dx: 8, dy: 8)
    // macOS itself keeps the panel's top under the menu bar, so the top case moves only the last
    // 8 pt.
    for origin in [
      CGPoint(x: 400, y: visible.minY - 100), CGPoint(x: visible.minX - 100, y: 300),
      CGPoint(x: visible.maxX - 100, y: 300), CGPoint(x: 400, y: visible.maxY - 100),
    ] {
      mouse.down = true
      w.setFrameOrigin(CGPoint(x: origin.x + 10, y: origin.y))  // two steps of the drag
      w.setFrameOrigin(origin)
      await settle()
      await checks.fire()
      #expect(!inside.contains(w.frame), "clamped during the drag at \(origin)")
      #expect(checks.waiting == 1, "the second step left two checks at \(origin)")
      mouse.down = false
      moves = 0
      await checks.fire()
      #expect(inside.contains(w.frame), "\(origin) ended at \(w.frame)")
      #expect(UserDefaults(suiteName: testSuite())!.pinnedFrame == w.frame, "\(origin)")
      await checks.fire()  // the clamp's own move is checked too, and changes nothing
      #expect(moves == 1, "\(origin)")
    }
  }

  /// R106: closing a pinned panel drops its pending check, so a panel closed within 0.25 s of a
  /// move is neither clamped nor saved when the button comes up. The check is against the origin
  /// AppKit accepted for the move, which may differ from the one asked for (R131).
  @Test func closingAPinnedPanelDropsItsPendingClamp() async throws {
    defer { clearDefaults() }
    let (controller, checks, mouse) = try await hostPinnedPanel()
    let w = controller.panel
    let origin = CGPoint(x: try #require(NSScreen.main).visibleFrame.minX - 100, y: 300)
    mouse.down = true
    w.setFrameOrigin(origin)
    await settle()
    let accepted = w.frame.origin
    try clickStatusItem(of: w)
    #expect(!w.isVisible && w.isMovableByWindowBackground)  // closed, and still pinned
    mouse.down = false
    await checks.fire()
    #expect(w.frame.origin == accepted)
    #expect(UserDefaults(suiteName: testSuite())!.pinnedFrame == nil)
  }

  /// R126: a 560 pt pinned panel dragged onto a shorter screen, here a faked 540 pt one, refits
  /// when the drag ends: 524 pt tall, its top-left corner kept, 8 pt inside that screen.
  @Test func aPinnedPanelDraggedOntoAShorterScreenRefits() async throws {
    defer { clearDefaults() }
    let (controller, checks, mouse) = try await hostPinnedPanel()
    let w = controller.panel
    sendKey("↓", to: w)  // Google Chrome, the first row
    sendKey("↩", to: w)  // opens it, so the content grows past 560 pt
    #expect(try await eventually(w) { w.frame.height == 560 })
    let main = try #require(NSScreen.main).visibleFrame
    let short = CGRect(x: main.minX, y: main.maxY - 540, width: main.width, height: 540)
    controller.ownScreenFrame = { _ in short }
    mouse.down = false
    w.setFrameOrigin(CGPoint(x: short.minX + 100, y: short.maxY - 8 - 560))
    let top = w.frame.maxY
    await settle()
    await checks.fire()
    #expect(short.insetBy(dx: 8, dy: 8).contains(w.frame), "ended at \(w.frame)")
    #expect(w.frame.height == 524 && w.frame.maxY == top && w.frame.minX == short.minX + 100)
    #expect(UserDefaults(suiteName: testSuite())!.pinnedFrame == w.frame)
  }

  /// R106: a pinned panel dropped mostly on a second display stays there, 8 pt inside that
  /// display's visible frame (the display is faked). A panel off every display comes back onto
  /// the main one.
  @Test func aPinnedPanelIsClampedToItsOwnScreen() async throws {
    defer { clearDefaults() }
    let (controller, checks, _) = try await hostPinnedPanel()
    let w = controller.panel
    let main = try #require(NSScreen.main).visibleFrame
    let beyond = NSScreen.screens.map(\.frame).reduce(main) { $0.union($1) }.maxX + 500
    w.setFrameOrigin(CGPoint(x: beyond, y: 300))
    #expect(w.screen == nil)
    await settle()
    await checks.fire()
    #expect(main.insetBy(dx: 8, dy: 8).contains(w.frame), "ended at \(w.frame)")

    let second = CGRect(x: main.maxX, y: main.minY + 200, width: 1920, height: 1080)
    controller.ownScreenFrame = { $0.frame.midX > main.maxX ? second : main }
    w.setFrameOrigin(CGPoint(x: second.maxX - 300, y: second.minY - 100))
    await settle()
    await checks.fire()
    #expect(second.insetBy(dx: 8, dy: 8).contains(w.frame), "ended at \(w.frame)")
  }

  /// R118: drawing the panel offscreen leaves no view tree alive. The warm store is held only by
  /// that tree here, so it is gone once the run loop turns.
  @Test func preparingThePanelLeavesNoViewTreeAlive() async throws {
    startAppKit()
    weak var warm: Store?
    try {
      let store = testStore(guide: try Guide.bundled())
      store.apply(DemoSnapshots.calm)
      PanelController.prepare(store)
      warm = store
    }()
    for _ in 0..<200 where warm != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(warm == nil)
  }

  /// Spec 10: drawing the panel once before the first click loads the icons of the rows it shows.
  @Test func preparingThePanelLoadsTheRowIcons() throws {
    startAppKit()
    let store = testStore(guide: try Guide.bundled())
    store.apply(DemoSnapshots.calm)
    #expect(Set(AppIcons.icons.keys) != Set(store.rows.compactMap(\.bundlePath)))
    PanelController.prepare(store)
    #expect(Set(AppIcons.icons.keys) == Set(store.rows.compactMap(\.bundlePath)))
  }

  /// Spec 10: the click does not wait for macOS's answer about the login item, which can take
  /// 15 ms. The panel asks once it has drawn (R74).
  @Test func theLoginItemIsReadAfterThePanelShows() async throws {
    let item = FakeLoginItem(enabled: true)
    let (w, store) = try hostPanelWithStore(
      DemoSnapshots.calm, store: testStore(loginItem: item.loginItem))
    #expect(w.isVisible && item.reads == 0)
    #expect(try await eventually(w) { item.reads == 1 && store.launchesAtLogin })
  }

  /// R74: Settings show whether Pith opens at login as macOS says, read when the panel opens. A
  /// refused change says so under the toggle and the toggle goes back; the next open clears it.
  @Test func aRefusedLoginItemChangeSaysSoUntilThePanelOpensAgain() async throws {
    let item = FakeLoginItem(enabled: true)
    item.refuses = true
    let (w, store) = try hostPanelWithStore(
      DemoSnapshots.calm, store: testStore(loginItem: item.loginItem))
    #expect(try await eventually(w) { store.launchesAtLogin })
    store.showingSettings = true
    store.setLaunchAtLogin(false)
    #expect(store.launchesAtLogin && store.loginItemFailed)
    let refusal = "Couldn't change this. Try again in System Settings → General → Login Items."
    #expect(try await eventually(w) { axLabels(in: w).contains(refusal) })
    #expect(axInteractiveElements(in: w).first { $0.label == "Launch at login" }?.value == "1")
    try clickStatusItem(of: w)
    item.enabled = false  // the user turns it off in System Settings
    try clickStatusItem(of: w)
    store.showingSettings = true
    #expect(try await eventually(w) { !store.loginItemFailed && !store.launchesAtLogin })
    #expect(
      try await eventually(w) {
        axInteractiveElements(in: w).first { $0.label == "Launch at login" }?.value == "0"
      })
    #expect(!axLabels(in: w).contains(refusal) && item.registrations == 0)
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

  /// R76 and R87: the font check reads headings by their height and a font that a container
  /// passes down, and it sees the 11.5 pt footer when it is not left out. A button's label has no
  /// font for VoiceOver, so buttons use the `PanelType` sizes, which a unit test checks.
  @Test func theFontCheckSeesHeadingsAndInheritedFonts() throws {
    let w = try hostPanel(DemoSnapshots.calm)
    let title = try axNode("All calm", in: w).fontSizes
    #expect(title.count == 1 && abs(title[0] - 17) < 1, "\(title)")
    #expect(try axNode("Using the most", in: w).fontSizes.allSatisfy { abs($0 - 13) < 1 })
    #expect(try axNode("Memory", in: w).role == "AXButton")
    #expect(minimumReadableFontSize(w, excludingIdentifier: "none") == 11.5)
    let inherited = hostView(VStack { Text("Inherited") }.font(.system(size: 12)))
    #expect(axNodes(in: inherited).flatMap(\.fontSizes) == [12])
  }
}

/// One second, in nanoseconds.
private let seconds: UInt64 = 1_000_000_000

/// The first confirm for the mockups' Google Chrome, as VoiceOver reads it (spec 4.5).
private let quitSentence = "Quit Google Chrome? It can ask you to save first."

/// The frame of the button `label` in `w`, in the window's coordinates.
@MainActor private func buttonFrame(_ label: String, in w: NSWindow) throws -> CGRect {
  w.convertFromScreen(
    try #require(axInteractiveElements(in: w).first { $0.label == label }, "no \(label)").frame)
}

/// A left click at the middle of `frame`, in the window's coordinates, as mouse-down and mouse-up
/// events through the window, as AppKit delivers a real click (R154).
@MainActor private func click(_ frame: CGRect, in window: NSWindow) {
  for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
    window.sendEvent(
      NSEvent.mouseEvent(
        with: type, location: CGPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)!)
  }
}

/// The visible part of the panel's list, in the window's coordinates.
@MainActor private func listFrame(in w: NSWindow) throws -> CGRect {
  let list = try #require(scrollView(in: w.contentView!))
  return list.convert(list.bounds, to: nil)
}

/// The list's scroll view.
@MainActor private func scrollView(in view: NSView) -> NSScrollView? {
  view as? NSScrollView ?? view.subviews.lazy.compactMap(scrollView).first
}

/// Every scroll view in `view`.
@MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
  (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
}

/// A view that a test watches without keeping it alive.
private final class WeakView {
  weak var view: NSView?

  init(_ view: NSView) { self.view = view }
}

/// Whether the button `label` shows whole in the list, not scrolled out of it. A button that is
/// not there yet does not show; `eventually` polls with this.
@MainActor private func showsInTheList(_ label: String, in w: NSWindow) -> Bool {
  guard let button = axInteractiveElements(in: w).first(where: { $0.label == label }),
    let list = scrollView(in: w.contentView!)
  else { return false }
  return list.convert(list.bounds, to: nil).contains(w.convertFromScreen(button.frame))
}

extension NativeInteractionTests {
  /// The panel showing `snapshot`, with the row `name` opened and offering Quit. Each mockup app's
  /// first process is its own.
  private func hostOpened(
    _ name: String, in snapshot: Snapshot, appearance: NSAppearance.Name = .aqua,
    test: String = #function
  ) async throws -> (NSWindow, Store, FakeRunningApps) {
    let apps = FakeRunningApps(
      snapshot.apps.map {
        FakeApp(pid: $0.pids[0], bundlePath: $0.bundlePath!, bundleID: $0.bundleID)
      })
    let (w, store) = try hostPanelWithStore(
      snapshot, appearance: appearance, store: apps.store(guide: Guide.bundled()), test: test)
    store.toggle(try #require(store.rows.first { $0.name == name }).id)
    #expect(
      try await eventually(w) { axInteractiveElements(in: w).contains { $0.label == "Quit" } })
    try await Task.sleep(for: .milliseconds(100))
    return (w, store, apps)
  }

  /// The confirm's button counts as seen only inside the visible frame of the panel's own screen,
  /// so Return does nothing while it is off it (the PR 2 council's minor).
  @Test func returnDoesNothingWhileTheConfirmIsOffItsScreen() async throws {
    defer { clearDefaults() }
    let apps = FakeRunningApps(
      DemoSnapshots.calm.apps.map {
        FakeApp(pid: $0.pids[0], bundlePath: $0.bundlePath!, bundleID: $0.bundleID)
      })
    let (controller, store) = try hostPanelController(
      DemoSnapshots.calm, store: apps.store(guide: Guide.bundled()))
    let w = controller.panel
    store.toggle(try #require(store.rows.first { $0.name == "Google Chrome" }).id)
    #expect(
      try await eventually(w) { axInteractiveElements(in: w).contains { $0.label == "Quit" } })
    let chrome = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    apps.passTheConfirmGuard()
    // The screen ends just above the button, which stays in the list.
    let button = try axNode("Quit", in: w).frame
    controller.ownScreenFrame = { _ in
      CGRect(x: w.frame.minX, y: button.maxY + 1, width: w.frame.width, height: 2_000)
    }
    sendKey("↩", to: w)
    #expect(chrome.terminations == 0 && store.quitFlow.state == .confirming)
  }

  /// R164: ⌘2 while a confirm shows cancels it, then sorts by CPU.
  @Test func commandTwoCancelsAConfirm() async throws {
    defer { clearDefaults() }
    let (w, store, _) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    try press("Quit", in: w)
    #expect(try await eventually(w) { axLabels(in: w).contains(quitSentence) })
    sendKey("2", modifiers: .command, to: w)
    #expect(store.metric == .cpu && store.quitFlow.state == .idle)
    #expect(try await eventually(w) { !axLabels(in: w).contains(quitSentence) })
  }

  /// When Quit turns into the confirm, VoiceOver hears the confirm's sentence at once, whether or
  /// not its cursor is on it (the PR 2 council's minor).
  @Test func theConfirmIsAnnounced() async throws {
    defer { clearDefaults() }
    let (w, store, _) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    var heard: [String] = []
    store.announce = { heard.append($0) }
    try press("Quit", in: w)
    #expect(try await eventually(w) { heard == [quitSentence] })
  }

  /// The confirm of an app that runs other programs, such as a terminal, says that they stop too.
  /// The guide marks those apps.
  @Test func theConfirmSaysThatProgramsInsideATerminalStopToo() async throws {
    defer { clearDefaults() }
    let terminal = AppUsage(
      id: "/System/Applications/Utilities/Terminal.app", name: "Terminal",
      bundlePath: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal",
      pids: [990], processCount: 1, memory: 9 << 30, cpu: .value(0.01),
      diskBytesPerSecond: .value(0), inside: [])
    let snapshot = remake(DemoSnapshots.calm, apps: [terminal] + DemoSnapshots.calm.apps)
    let (w, _, _) = try await hostOpened("Terminal", in: snapshot)
    try press("Quit", in: w)
    #expect(
      try await eventually(w) {
        axLabels(in: w).contains(
          "Quit Terminal? It can ask you to save first. Programs running inside it stop too.")
      })
  }

  /// R154 and R163: a real click, as the window gets it from the mouse, opens a row. A row's
  /// VoiceOver button is a clear overlay (R148) that must leave the click to the row. Another
  /// window is key, so the click is one that would activate the panel, and a row must accept it
  /// as a button does. Quit is then pressed by its accessibility action: a version of this test
  /// that clicked it did not end on the macos-15 runner.
  @Test func aMouseClickOpensARowAndPressesQuit() async throws {
    defer { clearDefaults() }
    let snapshot = DemoSnapshots.calm
    let apps = FakeRunningApps(
      snapshot.apps.map {
        FakeApp(pid: $0.pids[0], bundlePath: $0.bundlePath!, bundleID: $0.bundleID)
      })
    let (w, store) = try hostPanelWithStore(snapshot, store: apps.store(guide: Guide.bundled()))
    let other = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled,
      backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    other.makeKeyAndOrderFront(nil)
    defer { other.close() }
    #expect(!w.isKeyWindow)
    let chrome = try #require(store.rows.first { $0.name == "Google Chrome" })
    let row = try #require(axNodes(in: w).first { $0.label?.hasPrefix("Google Chrome,") == true })
    click(w.convertFromScreen(row.frame), in: w)
    #expect(try await eventually(w) { store.expandedAppID == chrome.id })
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) })
    try press("Quit", in: w)
    #expect(try await eventually(w) { store.quitFlow.state == .confirming })
  }

  /// The process that Quit acts on for the opened row.
  private func target(_ apps: FakeRunningApps, _ store: Store) throws -> FakeApp {
    let row = try #require(store.rows.first { $0.id == store.expandedAppID })
    return try #require(apps.apps[row.pids[0]])
  }

  /// Spec 4.5 and R79–R80: Quit asks first, and VoiceOver reads the confirm as one sentence, then
  /// Cancel and Quit. Once the confirm has shown for 0.4 s, Return presses Quit, the default
  /// button: the app is asked to quit once, and the row says so while it quits.
  @Test func quitAsksFirstThenReturnQuitsOnce() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    let chrome = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { axLabels(in: w).contains(quitSentence) })
    let spoken = axNodes(in: w).compactMap(\.spoken)
    let sentence = try #require(spoken.firstIndex(of: quitSentence))
    #expect(Array(spoken[(sentence + 1)...].prefix(2)) == ["Cancel", "Quit"])
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    #expect(chrome.terminations == 0)
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(try await eventually(w) { axLabels(in: w).contains("Quitting Google Chrome…") })
    #expect(chrome.terminations == 1 && store.expandedAppID == store.rows[0].id)
    #expect(!axInteractiveElements(in: w).contains { $0.label == "Quit" })
  }

  /// R93: within 0.4 s of the confirm showing, a press of its default button does nothing, by
  /// VoiceOver or Return; after that it works.
  @Test func aConfirmIgnoresPressesForItsFirst0Point4Seconds() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    let chrome = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    apps.nowNs += 399_000_000
    try press("Quit", in: w)
    sendKey("↩", to: w)
    try await Task.sleep(for: .milliseconds(50))
    #expect(chrome.terminations == 0 && store.quitFlow.state == .confirming)
    apps.nowNs += 1_000_000
    try press("Quit", in: w)
    #expect(chrome.terminations == 1)
  }

  /// R80 and R94: the first Escape cancels the confirm, and only the next one closes the panel.
  /// Cancel does the same as the first Escape, at once (R99).
  @Test func escapeCancelsTheConfirmBeforeItClosesThePanel() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    let chrome = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { axLabels(in: w).contains(quitSentence) })
    sendKey("⎋", to: w)
    #expect(try await eventually(w) { !axLabels(in: w).contains(quitSentence) })
    #expect(w.isVisible && store.quitFlow.state == .idle)
    try press("Quit", in: w)
    #expect(try await eventually(w) { axLabels(in: w).contains(quitSentence) })
    try press("Cancel", in: w)
    #expect(try await eventually(w) { store.quitFlow.state == .idle })
    sendKey("⎋", to: w)
    #expect(!w.isVisible && chrome.terminations == 0)
  }

  /// R94: while a confirm shows, ↑ and ↓ cancel it and do not move; then Return opens or closes a
  /// row, as without a confirm, and quits nothing.
  @Test func arrowsCancelAConfirmBeforeReturnCanReachIt() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    let chrome = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    apps.passTheConfirmGuard()
    sendKey("↓", to: w)
    #expect(store.quitFlow.state == .idle && store.selectedRowID == nil)
    sendKey("↓", to: w)
    sendKey("↓", to: w)
    sendKey("↩", to: w)
    try await Task.sleep(for: .milliseconds(50))
    #expect(chrome.terminations == 0 && store.quitFlow.state == .idle)
  }

  /// R94 and R101: Return presses the default button only while it shows whole in the list. The
  /// list scrolls as the app scrolls it, to a selected row: to Google Chrome at the top, which
  /// takes Music's confirm out of view, and to the last row, which brings it back. Out of view,
  /// Return does nothing. Back in view, the button's 0.4 s start again, and then Return quits.
  @Test func returnDoesNothingWhileTheConfirmIsScrolledAway() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Music", in: DemoSnapshots.calm)
    let music = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    apps.passTheConfirmGuard()
    store.moveSelection(-1)  // the last row, "macOS system"
    store.moveSelection(-10)  // the first row, Google Chrome
    #expect(
      try await eventually(w) { !showsInTheList("Quit", in: w) && !store.confirmButtonInView })
    sendKey("↩", to: w)
    #expect(music.terminations == 0 && store.quitFlow.state == .confirming)
    store.moveSelection(10)  // "macOS system"
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    sendKey("↩", to: w)
    #expect(music.terminations == 0)
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(music.terminations == 1)
  }

  /// R147: Return reads the list's scroll position from AppKit, so the list must be an NSScrollView
  /// whose flipped document has the list content's coordinates: the default button's reported frame
  /// is where the window draws it.
  @Test func theListIsAnNSScrollViewInTheContentsCoordinates() async throws {
    defer { clearDefaults() }
    let (w, store, _) = try await hostOpened("Music", in: DemoSnapshots.calm)
    try press("Quit", in: w)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    let document = try #require(scrollView(in: w.contentView!)?.documentView)
    #expect(document.isFlipped)
    let drawn = document.convert(try buttonFrame("Quit", in: w), from: nil)
    let reported = try #require(store.confirmButtonFrame)
    #expect(
      abs(drawn.minX - reported.minX) < 1 && abs(drawn.minY - reported.minY) < 1
        && abs(drawn.height - reported.height) < 1, "drawn \(drawn), reported \(reported)")
  }

  /// R92: a reading that only changes what is inside the opened row does not scroll the list, so
  /// a confirm in view stays in view.
  @Test func aReadingDoesNotScrollAwayAConfirm() async throws {
    defer { clearDefaults() }
    let (w, store, _) = try await hostOpened("Google Chrome", in: DemoSnapshots.tight)
    try press("Quit", in: w)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) })
    let c = DemoSnapshots.tight.apps[0]
    let grown = AppUsage(
      id: c.id, name: c.name, bundlePath: c.bundlePath, bundleID: c.bundleID, pids: c.pids,
      processCount: c.processCount + 2, memory: c.memory, cpu: c.cpu,
      diskBytesPerSecond: c.diskBytesPerSecond,
      inside: c.inside + [HelperGroup(label: "Utilities", count: 2, memory: 40 << 20)])
    store.apply(remake(DemoSnapshots.tight, apps: [grown] + DemoSnapshots.tight.apps.dropFirst()))
    #expect(try await eventually(w) { axLabels(in: w).contains("Utilities (2), 40 MB") })
    try await Task.sleep(for: .milliseconds(100))
    w.contentView!.layoutSubtreeIfNeeded()
    #expect(showsInTheList("Quit", in: w) && store.quitFlow.state == .confirming)
  }

  /// R94: Escape cancels a confirm even when it is not drawn, as when the row's process went.
  @Test func escapeCancelsAConfirmThatIsNotDrawn() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    let chrome = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { axLabels(in: w).contains(quitSentence) })
    apps.apps[chrome.processIdentifier] = nil
    // The rows draw again, now with no process to quit. Another metric would cancel the confirm
    // (R164), so the selection moves instead, as the store moves it.
    store.moveSelection(1)
    #expect(try await eventually(w) { !axLabels(in: w).contains(quitSentence) })
    #expect(store.quitFlow.state == .confirming)
    sendKey("⎋", to: w)
    #expect(store.quitFlow.state == .idle && w.isVisible && chrome.terminations == 0)
  }

  /// Spec 4.5, R79 and R93: an app still running 5 s after Quit is offered Force Quit, which asks
  /// again; only its confirm forces the quit. The list scrolls to the top row and back to Music,
  /// which puts Music's opened row at the list's bottom edge, where the offer shows. Its confirm
  /// grows the row, which scrolls the confirm's buttons to that same edge. The offer's button is at
  /// the leading edge and the confirm's default button at the trailing edge, so one double-click
  /// cannot press both.
  @Test func anAppStillRunningAfterFiveSecondsIsOfferedForceQuit() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Music", in: DemoSnapshots.tight)
    let music = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { store.confirmButtonInView })
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(music.terminations == 1)
    await settle()
    apps.nowNs += 5_000_000_000
    await apps.timer.fire()
    #expect(store.quitFlow.state == .offerForce)
    #expect(try await eventually(w) { axLabels(in: w).contains("Quitting Music…") })
    sendKey("↓", to: w)  // Google Chrome, the first row
    #expect(try await eventually(w) { !showsInTheList("Force Quit", in: w) })
    for _ in 0..<4 { sendKey("↓", to: w) }  // Music
    #expect(try await eventually(w) { showsInTheList("Force Quit", in: w) })
    let offer = try buttonFrame("Force Quit", in: w)
    #expect(offer.minY - (try listFrame(in: w)).minY < 30, "the offer sits at the bottom edge")
    try press("Force Quit", in: w)
    let force = "Force Quit Music? Unsaved changes will be lost."
    #expect(try await eventually(w) { axLabels(in: w).contains(force) })
    #expect(try await eventually(w) { store.confirmButtonInView })
    let confirm = try buttonFrame("Force Quit", in: w)
    #expect(!offer.intersects(confirm), "\(offer) and \(confirm)")
    let spoken = axNodes(in: w).compactMap(\.spoken)
    let sentence = try #require(spoken.firstIndex(of: force))
    #expect(Array(spoken[(sentence + 1)...].prefix(2)) == ["Cancel", "Force Quit"])
    #expect(music.forcedTerminations == 0)
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(music.forcedTerminations == 1 && music.terminations == 1)
    #expect(store.quitFlow.state == .waiting(sinceNs: apps.nowNs))
  }

  /// Spec 4.5: Quit shows only for an app of the user's own that macOS runs as an app: not for
  /// another user's Music, not for Finder, which the guide marks not quittable, and not for
  /// "macOS system".
  @Test func onlyTheUsersOwnQuittableAppsShowQuit() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    apps.owners[730] = getuid() + 1  // Music
    for name in ["Music", "Finder", "macOS system"] {
      let id =
        name == "macOS system"
        ? Store.systemRowID : try #require(store.rows.first { $0.name == name }).id
      store.toggle(id)
      #expect(try await eventually(w) { store.expandedAppID == id })
      try await Task.sleep(for: .milliseconds(100))
      w.contentView!.layoutSubtreeIfNeeded()
      #expect(!axInteractiveElements(in: w).contains { $0.label == "Quit" }, "\(name)")
    }
  }

  /// R92 and R98: a row opens name first. Google Chrome, here with more helper groups than fit in
  /// the tight panel's list, opens with its name at the list's top. When a confirm appears, the
  /// list scrolls the least that shows the whole confirm, so Return works at once; the row's name
  /// may scroll away, as the confirm names the app. Music fits with its confirm, so both show.
  @Test func aRowOpensNameFirstAndAConfirmShowsWhole() async throws {
    defer { clearDefaults() }
    let c = DemoSnapshots.tight.apps[0]
    let tallChrome = AppUsage(
      id: c.id, name: c.name, bundlePath: c.bundlePath, bundleID: c.bundleID, pids: c.pids,
      processCount: c.processCount, memory: c.memory, cpu: c.cpu,
      diskBytesPerSecond: c.diskBytesPerSecond,
      inside: c.inside
        + ["Audio", "Network", "Storage", "Printing", "Speech", "Utilities"].map {
          HelperGroup(label: $0, count: 1, memory: 20 << 20)
        })
    let tall = remake(
      DemoSnapshots.tight, apps: [tallChrome] + DemoSnapshots.tight.apps.dropFirst())
    for (name, snapshot, header) in [
      ("Google Chrome", tall, "Google Chrome, 6.4 GB memory, 41 processes"),
      ("Music", DemoSnapshots.calm, "Music, 710 MB memory, 7 processes"),
    ] {
      let (w, store, apps) = try await hostOpened(name, in: snapshot)
      let app = try target(apps, store)
      let list = try listFrame(in: w).insetBy(dx: 0, dy: -0.5)
      func headerShows() throws -> Bool {
        list.contains(w.convertFromScreen(try axNode(header, in: w).frame))
      }
      #expect(try headerShows(), "\(name) opens name first")
      #expect(name == "Music" || !showsInTheList("Quit", in: w), "Chrome is taller than the list")
      try press("Quit", in: w)
      #expect(
        try await eventually(w) {
          showsInTheList("Quit", in: w) && showsInTheList("Cancel", in: w)
            && store.confirmButtonInView
        }, "\(name)")
      #expect(try headerShows() == (name == "Music"), "\(name)")
      apps.passTheConfirmGuard()
      sendKey("↩", to: w)
      #expect(app.terminations == 1, "\(name)")
    }
  }

  /// R91 and R101: Settings end with Quit Pith, and ⌘Q quits Pith while the panel is key, at
  /// once. While a confirm shows, ⌘Q does nothing, as it could be read as the confirm's Quit.
  @Test func quitPithInSettingsAndCommandQ() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    try press("Quit", in: w)
    #expect(try await eventually(w) { axLabels(in: w).contains(quitSentence) })
    sendKey("q", modifiers: .command, to: w)
    #expect(apps.pithQuits == 0 && store.quitFlow.state == .confirming)
    sendKey("⎋", to: w)
    sendKey("q", modifiers: .command, to: w)
    #expect(apps.pithQuits == 1)
    store.showingSettings = true
    #expect(
      try await eventually(w) { axInteractiveElements(in: w).contains { $0.label == "Quit Pith" } })
    try press("Quit Pith", in: w)
    #expect(apps.pithQuits == 2)
  }

  /// R101: back from Settings, the confirm's default button waits 0.4 s again before Return or
  /// VoiceOver can press it.
  @Test func aConfirmBackFromSettingsWaitsAgain() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    let chrome = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { store.confirmButtonInView })
    apps.passTheConfirmGuard()
    store.showingSettings = true
    #expect(try await eventually(w) { !store.confirmButtonInView })
    store.showingSettings = false
    #expect(try await eventually(w) { store.confirmButtonInView })
    sendKey("↩", to: w)
    try press("Quit", in: w)
    #expect(chrome.terminations == 0 && store.quitFlow.state == .confirming)
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(chrome.terminations == 1)
  }

  /// R101: a pinned panel tells the store whether other windows cover it, as the speed does, so
  /// a confirm on a covered panel cannot be pressed. An attached panel never counts as covered.
  /// The test sets what macOS reports, so it means the same on any screen (R104).
  @Test func aPinnedPanelReportsWhetherItIsCovered() async throws {
    defer { clearDefaults() }
    let (controller, store) = try hostPanelController(DemoSnapshots.calm)
    var covered = true
    controller.isCovered = { _ in covered }
    let w = controller.panel
    let note = Notification(name: NSWindow.didChangeOcclusionStateNotification)
    controller.windowDidChangeOcclusionState(note)
    #expect(w.isVisible && !store.panelCovered)
    store.pinned = true
    #expect(try await eventually(w) { w.isMovableByWindowBackground })
    #expect(store.panelCovered)
    covered = false
    controller.windowDidChangeOcclusionState(note)
    #expect(!store.panelCovered)
  }

  /// R107: by default the panel is covered exactly when macOS does not report it visible. A panel
  /// that was never shown is not visible on any machine, so it is covered.
  @Test func isCoveredReadsThePanelsOcclusion() throws {
    defer { clearDefaults() }
    let hidden = PanelController(
      store: testStore(), defaults: testDefaults(), onChange: { _, _, _ in })
    #expect(!hidden.panel.occlusionState.contains(.visible))
    #expect(hidden.isCovered(hidden.panel))
    let (shown, _) = try hostPanelController(DemoSnapshots.calm)
    #expect(shown.isCovered(shown.panel) == !shown.panel.occlusionState.contains(.visible))
  }

  /// R102: a row opened again shows itself, and a later reading that changes what is inside it
  /// does not scroll the list. Tight's Music opens at the list's bottom edge.
  @Test func aReadingAfterAReopenDoesNotScroll() async throws {
    defer { clearDefaults() }
    let (w, store, _) = try await hostOpened("Music", in: DemoSnapshots.tight)
    let music = try #require(store.rows.first { $0.name == "Music" })
    store.toggle(music.id)
    #expect(try await eventually(w) { store.expandedAppID == nil })
    try await Task.sleep(for: .milliseconds(100))
    store.toggle(music.id)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) })
    try await Task.sleep(for: .milliseconds(100))
    w.contentView!.layoutSubtreeIfNeeded()
    let header = {
      try #require(axNodes(in: w).first { $0.label?.hasPrefix("Music,") == true }).frame
    }
    let before = try header()
    let grown = AppUsage(
      id: music.id, name: music.name, bundlePath: music.bundlePath, bundleID: music.bundleID,
      pids: music.pids, processCount: music.processCount, memory: music.memory, cpu: music.cpu,
      diskBytesPerSecond: music.diskBytesPerSecond,
      inside: music.inside + [HelperGroup(label: "Utilities", count: 1, memory: 20 << 20)])
    store.apply(
      remake(
        DemoSnapshots.tight, apps: DemoSnapshots.tight.apps.map { $0.id == music.id ? grown : $0 }))
    #expect(try await eventually(w) { axLabels(in: w).contains("Utilities, 20 MB") })
    try await Task.sleep(for: .milliseconds(100))
    w.contentView!.layoutSubtreeIfNeeded()
    #expect(try header() == before)
  }

  /// Task 11 review: pressing a segment chooses it. VoiceOver hears the "Sort by" group with the
  /// chosen segment selected.
  @Test func pressingTheCPUSegmentSortsByCPU() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    try press("CPU", in: w)
    #expect(store.metric == .cpu)
    #expect(
      try await eventually(w) {
        axNodes(in: w).contains {
          $0.label == "Sort by"
            && $0.children.map { "\($0.label ?? "none") \($0.selected)" }
              == ["Memory false", "CPU true", "Disk false"]
        }
      })
  }

  /// Task 11 review: pressing "2 s" in Settings changes the refresh setting, and VoiceOver hears the
  /// "Refresh while open" group with "2 s" selected.
  @Test func pressingTwoSecondsInSettingsChangesTheRefresh() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    store.showingSettings = true
    #expect(try await eventually(w) { axInteractiveElements(in: w).contains { $0.label == "2 s" } })
    try press("2 s", in: w)
    #expect(store.settings.refresh == .twoSeconds)
    #expect(
      try await eventually(w) {
        axNodes(in: w).contains {
          $0.label == "Refresh while open"
            && $0.children.map { "\($0.label ?? "none") \($0.selected)" }
              == ["1 s false", "2 s true"]
        }
      })
  }
}

/// The reading that the stand-in lifecycle takes when the panel opens.
@MainActor private final class NextReading {
  var snapshot: Snapshot

  init(_ snapshot: Snapshot) { self.snapshot = snapshot }
}

/// A control that has the keyboard focus, as full keyboard access gives one.
private final class KeyRecorder: NSView {
  private(set) var keyCodes: [UInt16] = []

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
}
