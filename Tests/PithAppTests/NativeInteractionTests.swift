import AppKit
import PithCore
import SwiftUI
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

  /// R75: a tool for the design check and the README images, so it is skipped, not passed, unless
  /// asked for. The last states are Google Chrome opened, asking to quit (spec 4.5).
  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["PITH_UI_SNAPSHOT_DIR"] != nil))
  func captureDesignStatesWhenRequested() async throws {
    defer { clearDefaults() }
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
          memoryUsed: .value(12 << 30), memoryTotal: t.memoryTotal, pressure: t.pressure,
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
    let w = controller.panel
    controller.toggle(under: try anchor())
    let first = try pixels(w)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try pixels(w) == first)
    store.toggle(store.rows[0].id)
    try await Task.sleep(for: .milliseconds(300))
    controller.toggle(under: try anchor())  // closes it
    reading.snapshot = DemoSnapshots.tight  // other apps, in another order
    controller.toggle(under: try anchor())
    #expect(w.isVisible && store.expandedAppID == nil)
    let reopened = try pixels(w)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try pixels(w) == reopened)
  }

  /// R88: while an open waits for its reading, a late occlusion note from the closed panel still
  /// reports it shown and not covered, so the speed stays open, attached or pinned.
  @Test func aLateOcclusionNoteKeepsAPendingOpenOpen() throws {
    let store = testStore(guide: try Guide.bundled())
    var reports: [String] = []
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, pinned, occluded in reports.append("\(visible) \(pinned) \(occluded)") })
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
    let (w, store) = try hostPanelWithStore(DemoSnapshots.tight)
    #expect(!axLabels(in: w).contains("41 processes"))
    store.toggle(store.rows[0].id)
    #expect(try await eventually(w) { axLabels(in: w).contains("Tabs and sites (34), 5.1 GB") })
    let labels = axLabels(in: w)
    #expect(labels.contains("41 processes"))
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
    #expect(labels.contains("macOS system, disk not measured") && labels.contains("not measured"))
    #expect(!labels.contains { $0.hasSuffix("/s") })
  }

  /// R76: an unknown pressure reads "—", and swap that is 0 is not shown.
  @Test func anUnknownPressureIsADashAndNoSwapIsNotShown() throws {
    let tight = DemoSnapshots.tight
    let t = tight.totals
    let unknown = Snapshot(
      takenAtNs: tight.takenAtNs, mode: .open,
      totals: SystemTotals(
        memoryUsed: t.memoryUsed, memoryTotal: t.memoryTotal,
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
        memoryUsed: t.memoryUsed, memoryTotal: t.memoryTotal, pressure: t.pressure,
        swapUsed: t.swapUsed, cpuBusy: .value(0.705), storageFree: t.storageFree,
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
  /// status line and the tiles keep their size. Each change resizes it once. Attached, its top edge
  /// stays under the status item; pinned, its top-left corner stays.
  @Test func thePanelHeightFollowsItsContentUpTo560() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    var resizes = 0
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: w, queue: nil
    ) { _ in MainActor.assumeIsolated { resizes += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }
    let closed = w.frame
    let fixed = try ["All calm", "Memory, 9.8 of 16 GB, Plenty"].map { try axNode($0, in: w).frame }
    let finder = try #require(store.rows.first { $0.name == "Finder" }).id
    store.toggle(finder)
    #expect(try await eventually(w) { w.frame.height > closed.height })
    #expect(w.frame.height < 560 && w.frame.maxY == closed.maxY && resizes == 1)
    store.toggle(store.rows[0].id)  // Google Chrome: too tall, so the list scrolls
    #expect(try await eventually(w) { w.frame.height == 560 })
    #expect(w.frame.maxY == closed.maxY && resizes == 2)
    let capped = try ["All calm", "Memory, 9.8 of 16 GB, Plenty"].map {
      try axNode($0, in: w).frame
    }
    #expect(capped == fixed)
    store.toggle(store.rows[0].id)
    #expect(try await eventually(w) { w.frame.height == closed.height })
    #expect(w.frame.maxY == closed.maxY && resizes == 3)

    store.pinned = true
    store.toggle(finder)
    #expect(try await eventually(w) { w.frame.height > closed.height })
    #expect(w.frame.minX == closed.minX && w.frame.maxY == closed.maxY && resizes == 4)
  }

  /// R72: a pinned panel partly past the left edge, above the top, or with its corner exactly at the
  /// top of the screen comes back on screen at its next height change, and never traps.
  @Test func aPinnedPanelOffTheScreenComesBackWhenItResizes() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    store.pinned = true
    #expect(try await eventually(w) { w.isMovableByWindowBackground })
    let screen = try #require(NSScreen.main)
    let inside = screen.visibleFrame.insetBy(dx: 8, dy: 8)
    let finder = try #require(store.rows.first { $0.name == "Finder" }).id
    let h = w.frame.height
    for frame in [
      CGRect(x: screen.frame.minX - 200, y: 300, width: 360, height: h),
      CGRect(x: 400, y: screen.frame.maxY + 50, width: 360, height: h),
      CGRect(x: 400, y: screen.frame.maxY - h, width: 360, height: h),
    ] {
      w.setFrame(frame, display: false)
      let height = w.frame.height
      store.toggle(finder)
      #expect(try await eventually(w) { w.frame.height != height }, "\(frame)")
      #expect(inside.contains(w.frame), "\(frame) became \(w.frame)")
    }
  }

  /// R104: a pinned panel dragged partly past the bottom, left or right edge comes back 8 pt inside
  /// the screen when the drag ends, and the frame it saves is the one it comes back to.
  @Test func aPinnedPanelDraggedPastAnEdgeComesBackAndSavesThatFrame() async throws {
    defer { clearDefaults() }
    let (w, store) = try hostPanelWithStore(DemoSnapshots.calm)
    store.pinned = true
    #expect(try await eventually(w) { w.isMovableByWindowBackground })
    let visible = try #require(NSScreen.main).visibleFrame
    let inside = visible.insetBy(dx: 8, dy: 8)
    for origin in [
      CGPoint(x: 400, y: visible.minY - 100), CGPoint(x: visible.minX - 100, y: 300),
      CGPoint(x: visible.maxX - 100, y: 300),
    ] {
      w.setFrameOrigin(origin)  // where the drag ends
      #expect(inside.contains(w.frame), "\(origin) ended at \(w.frame)")
      #expect(UserDefaults(suiteName: testSuite())!.pinnedFrame == w.frame, "\(origin)")
    }
  }

  /// R74: Settings show whether Pith opens at login as macOS says, read when the panel opens. A
  /// refused change says so under the toggle and the toggle goes back; the next open clears it.
  @Test func aRefusedLoginItemChangeSaysSoUntilThePanelOpensAgain() async throws {
    let item = FakeLoginItem(enabled: true)
    item.refuses = true
    let (w, store) = try hostPanelWithStore(
      DemoSnapshots.calm, store: testStore(loginItem: item.loginItem))
    #expect(store.launchesAtLogin)
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
    #expect(!store.loginItemFailed && !store.launchesAtLogin)
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

/// The first confirm for the mockups' Google Chrome, as VoiceOver reads it (spec 4.5).
private let quitSentence = "Quit Google Chrome? It can ask you to save first."

/// The frame of the button `label` in `w`, in the window's coordinates.
@MainActor private func buttonFrame(_ label: String, in w: NSWindow) throws -> CGRect {
  w.convertFromScreen(
    try #require(axInteractiveElements(in: w).first { $0.label == label }, "no \(label)").frame)
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
  /// takes Slack's confirm out of view, and to the last row, which brings it back. Out of view,
  /// Return does nothing. Back in view, the button's 0.4 s start again, and then Return quits.
  @Test func returnDoesNothingWhileTheConfirmIsScrolledAway() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Slack", in: DemoSnapshots.calm)
    let slack = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    apps.passTheConfirmGuard()
    store.moveSelection(-1)  // the last row, "macOS system"
    store.moveSelection(-10)  // the first row, Google Chrome
    #expect(
      try await eventually(w) { !showsInTheList("Quit", in: w) && !store.confirmButtonInView })
    sendKey("↩", to: w)
    #expect(slack.terminations == 0 && store.quitFlow.state == .confirming)
    store.moveSelection(10)  // "macOS system"
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) && store.confirmButtonInView })
    sendKey("↩", to: w)
    #expect(slack.terminations == 0)
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(slack.terminations == 1)
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
    store.metric = .cpu  // the rows draw again, now with no process to quit
    #expect(try await eventually(w) { !axLabels(in: w).contains(quitSentence) })
    #expect(store.quitFlow.state == .confirming)
    sendKey("⎋", to: w)
    #expect(store.quitFlow.state == .idle && w.isVisible && chrome.terminations == 0)
  }

  /// Spec 4.5, R79 and R93: an app still running 5 s after Quit is offered Force Quit, which asks
  /// again; only its confirm forces the quit. The list scrolls to the top row and back to Slack,
  /// which puts Slack's opened row at the list's bottom edge, where the offer shows. Its confirm
  /// grows the row, which scrolls the confirm's buttons to that same edge. The offer's button is at
  /// the leading edge and the confirm's default button at the trailing edge, so one double-click
  /// cannot press both.
  @Test func anAppStillRunningAfterFiveSecondsIsOfferedForceQuit() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Slack", in: DemoSnapshots.tight)
    let slack = try target(apps, store)
    try press("Quit", in: w)
    #expect(try await eventually(w) { store.confirmButtonInView })
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(slack.terminations == 1)
    await settle()
    apps.nowNs += 5_000_000_000
    await apps.checks.fire()
    #expect(store.quitFlow.state == .offerForce)
    #expect(try await eventually(w) { axLabels(in: w).contains("Quitting Slack…") })
    sendKey("↓", to: w)  // Google Chrome, the first row
    #expect(try await eventually(w) { !showsInTheList("Force Quit", in: w) })
    for _ in 0..<4 { sendKey("↓", to: w) }  // Slack
    #expect(try await eventually(w) { showsInTheList("Force Quit", in: w) })
    let offer = try buttonFrame("Force Quit", in: w)
    #expect(offer.minY - (try listFrame(in: w)).minY < 30, "the offer sits at the bottom edge")
    try press("Force Quit", in: w)
    let force = "Force Quit Slack? Unsaved changes will be lost."
    #expect(try await eventually(w) { axLabels(in: w).contains(force) })
    #expect(try await eventually(w) { store.confirmButtonInView })
    let confirm = try buttonFrame("Force Quit", in: w)
    #expect(!offer.intersects(confirm), "\(offer) and \(confirm)")
    let spoken = axNodes(in: w).compactMap(\.spoken)
    let sentence = try #require(spoken.firstIndex(of: force))
    #expect(Array(spoken[(sentence + 1)...].prefix(2)) == ["Cancel", "Force Quit"])
    #expect(slack.forcedTerminations == 0)
    apps.passTheConfirmGuard()
    sendKey("↩", to: w)
    #expect(slack.forcedTerminations == 1 && slack.terminations == 1)
    #expect(store.quitFlow.state == .waiting(sinceNs: apps.nowNs))
  }

  /// Spec 4.5: Quit shows only for an app of the user's own that macOS runs as an app: not for
  /// another user's Slack, not for Finder, which the guide marks not quittable, and not for
  /// "macOS system".
  @Test func onlyTheUsersOwnQuittableAppsShowQuit() async throws {
    defer { clearDefaults() }
    let (w, store, apps) = try await hostOpened("Google Chrome", in: DemoSnapshots.calm)
    apps.owners[730] = getuid() + 1  // Slack
    for name in ["Slack", "Finder", "macOS system"] {
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
  /// may scroll away, as the confirm names the app. Slack fits with its confirm, so both show.
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
      ("Slack", DemoSnapshots.calm, "Slack, 710 MB memory, 7 processes"),
    ] {
      let (w, store, apps) = try await hostOpened(name, in: snapshot)
      let app = try target(apps, store)
      let list = try listFrame(in: w).insetBy(dx: 0, dy: -0.5)
      func headerShows() throws -> Bool {
        list.contains(w.convertFromScreen(try axNode(header, in: w).frame))
      }
      #expect(try headerShows(), "\(name) opens name first")
      #expect(name == "Slack" || !showsInTheList("Quit", in: w), "Chrome is taller than the list")
      try press("Quit", in: w)
      #expect(
        try await eventually(w) {
          showsInTheList("Quit", in: w) && showsInTheList("Cancel", in: w)
            && store.confirmButtonInView
        }, "\(name)")
      #expect(try headerShows() == (name == "Slack"), "\(name)")
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
    let store = testStore(guide: try Guide.bundled())
    let controller = PanelController(
      store: store, defaults: testDefaults(),
      onChange: { visible, _, _ in if visible { store.apply(DemoSnapshots.calm) } })
    var covered = true
    controller.isCovered = { _ in covered }
    let w = controller.panel
    let note = Notification(name: NSWindow.didChangeOcclusionStateNotification)
    controller.toggle(under: try anchor())
    controller.windowDidChangeOcclusionState(note)
    #expect(w.isVisible && !store.panelCovered)
    store.pinned = true
    #expect(try await eventually(w) { w.isMovableByWindowBackground })
    #expect(store.panelCovered)
    covered = false
    controller.windowDidChangeOcclusionState(note)
    #expect(!store.panelCovered)
  }

  /// R102: a row opened again shows itself, and a later reading that changes what is inside it
  /// does not scroll the list. Tight's Slack opens at the list's bottom edge.
  @Test func aReadingAfterAReopenDoesNotScroll() async throws {
    defer { clearDefaults() }
    let (w, store, _) = try await hostOpened("Slack", in: DemoSnapshots.tight)
    let slack = try #require(store.rows.first { $0.name == "Slack" })
    store.toggle(slack.id)
    #expect(try await eventually(w) { store.expandedAppID == nil })
    try await Task.sleep(for: .milliseconds(100))
    store.toggle(slack.id)
    #expect(try await eventually(w) { showsInTheList("Quit", in: w) })
    try await Task.sleep(for: .milliseconds(100))
    w.contentView!.layoutSubtreeIfNeeded()
    let header = {
      try #require(axNodes(in: w).first { $0.label?.hasPrefix("Slack,") == true }).frame
    }
    let before = try header()
    let grown = AppUsage(
      id: slack.id, name: slack.name, bundlePath: slack.bundlePath, bundleID: slack.bundleID,
      pids: slack.pids, processCount: slack.processCount, memory: slack.memory, cpu: slack.cpu,
      diskBytesPerSecond: slack.diskBytesPerSecond,
      inside: slack.inside + [HelperGroup(label: "Utilities", count: 1, memory: 20 << 20)])
    store.apply(
      remake(
        DemoSnapshots.tight, apps: DemoSnapshots.tight.apps.map { $0.id == slack.id ? grown : $0 }))
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
