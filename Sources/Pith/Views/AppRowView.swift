import AppKit
import PithCore
import SwiftUI
import UniformTypeIdentifiers

/// One app (spec 4.2 and 4.3). Clicking it opens it in place: "N processes" under the value, then
/// the explanation, what is inside and Quit (spec 4.5).
struct AppRowView: View {
  let store: Store
  let app: AppUsage
  let value: RowValue
  let fraction: Double?

  var body: some View {
    let entry = store.guide.entry(name: app.name, bundleID: app.bundleID, path: app.bundlePath)
    // R49: a process outside any app shows its guide title when the guide has one.
    let name = app.id.hasPrefix("proc:") ? entry?.title ?? app.name : app.name
    let expanded = store.expandedAppID == app.id
    VStack(spacing: 0) {
      RowLayout(
        icon: Image(nsImage: AppIcons.icon(forFile: app.bundlePath)).resizable(),
        name: Text(name), fraction: fraction, value: value,
        processes: expanded && app.processCount > 1 ? app.processCount : nil,
        selected: store.selectedRowID == app.id, expanded: expanded,
        sentence: rowSentence(name, value, store.metric, processes: app.processCount)
      ) { store.toggle(app.id) }
      if expanded {
        AppDetailView(
          store: store, name: name, explanation: entry?.explanation,
          programsInside: entry?.programsInside == true, inside: app.inside,
          quitTarget: store.quitTarget(for: app))
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// What every row shows (spec 4.2): a 24 pt icon, the name over a 3 pt bar, and the value on the
/// right, which stays whole while a long name truncates. VoiceOver reads it once, as one button: the
/// sentence, then "expanded" or "collapsed", and the value's tooltip as its help. One tree on every
/// macOS (R148): on macOS 15 an element with children is a group with no value, so the button is a
/// leaf over the row, and the texts that it repeats are hidden from VoiceOver.
struct RowLayout<Icon: View, Name: View>: View {
  let icon: Icon
  let name: Name
  let fraction: Double?
  let value: RowValue
  /// Shown under the value.
  let processes: Int?
  /// The row that ↑ and ↓ moved to.
  let selected: Bool
  let expanded: Bool
  let sentence: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      icon
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 4) {
        name
          .font(.panel(.body, weight: .medium))
          .lineLimit(1)
          .recordsFrame(sentence, "name")
        Bar(fraction: fraction, height: 3, fill: .secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 0) {
        Text(value.text)
          .font(.panel(.body, weight: .medium).monospacedDigit())
          .foregroundStyle(value.amount == nil ? .secondary : .primary)
          .help(value.help ?? "")
          .recordsFrame(sentence, value.text)
        if let processes {
          Text("\(processes) processes")
            .font(.panel(.body).monospacedDigit())
            .foregroundStyle(.secondary)
            .recordsFrame(sentence, "\(processes) processes")
        }
      }
      .fixedSize()
    }
    .accessibilityHidden(true)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      .quinary.opacity(selected || expanded || hovering ? 1 : 0), in: .rect(cornerRadius: 8)
    )
    .contentShape(.rect)
    .onTapGesture(perform: action)
    // The click that brings a panel forward must open the row, as it presses a button (R163).
    .allowsWindowActivationEvents(true)
    .onHover { hovering = $0 }
    .overlay {
      Color.clear
        .accessibilityElement()
        .accessibilityLabel(sentence)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityHint(value.help ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
  }
}

/// R148: VoiceOver reads a row through its button, so the row's own texts are hidden from it.
/// While a test sets `recorded`, each of them records where it draws, in the window, under
/// "<row sentence> | <name, the value or the process count>", so the test can check its size and
/// place. It is nil in the app, where nothing records.
@MainActor enum RowTextFrames {
  static var recorded: [String: CGRect]?
}

extension View {
  @ViewBuilder fileprivate func recordsFrame(_ sentence: String, _ part: String) -> some View {
    if RowTextFrames.recorded != nil {
      let key = "\(sentence) | \(part)"
      onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        RowTextFrames.recorded?[key] = $0
      }
      .onDisappear { RowTextFrames.recorded?[key] = nil }
    } else {
      self
    }
  }
}

/// A row's value for one metric: what it shows, what VoiceOver says, its tooltip, and its length on
/// the rows' shared bar scale, nil when there is no number.
struct RowValue {
  /// A first sample: the next reading has it.
  static let notYet = RowValue(text: "—", label: "not available yet", amount: nil)
  /// Any other missing reading, such as an accounting mismatch or a failed read. Its reason stays
  /// in the log; the user reads one plain sentence (R110).
  static let unavailable = RowValue(
    text: "—", label: "not available", amount: nil, help: "Pith couldn't measure this right now.")
  /// A value that Pith never measures, such as disk activity for "macOS system".
  static let notMeasured = RowValue(text: "not measured", label: "not measured", amount: nil)

  let text: String
  let label: String
  let amount: Double?
  var help: String?

  /// What a reading with no value shows: "not available yet" for a first sample, and "not
  /// available" for anything else (R110).
  static func missing<Value>(_ reading: Reading<Value>) -> RowValue {
    assert(reading.value == nil, "\(reading) has a value")
    return reading.isFirstSample ? .notYet : .unavailable
  }

  /// `disk` is nil when the row has no disk reading at all.
  static func of(_ metric: Metric, memory: UInt64, cpu: Reading<Double>, disk: Reading<Double>?)
    -> RowValue
  {
    switch metric {
    case .memory: known(ByteFormat.memory(memory), Double(memory))
    case .cpu: cpu.value.map { known(PercentFormat.app($0), $0) } ?? missing(cpu)
    case .disk:
      disk.map { $0.value.map { known(ByteFormat.rate($0), $0) } ?? missing($0) } ?? .notMeasured
    }
  }

  private static func known(_ text: String, _ amount: Double) -> RowValue {
    RowValue(text: text, label: text, amount: amount)
  }
}

/// "{App}, {value} {metric}, {N} processes" (spec 4.8). A missing value says why: "CPU not
/// available yet" for a first sample, "CPU not available" when Pith couldn't measure it (R110),
/// or "disk not measured" for a value that Pith never measures.
func rowSentence(_ name: String, _ value: RowValue, _ metric: Metric, processes: Int?) -> String {
  let word =
    switch metric {
    case .memory: "memory"
    case .cpu: "CPU"
    case .disk: "disk"
    }
  let reading = value.amount == nil ? "\(word) \(value.label)" : "\(value.text) \(word)"
  let count = processes.map { $0 == 1 ? "1 process" : "\($0) processes" }
  return ([name, reading] + [count].compactMap { $0 }).joined(separator: ", ")
}

/// Each app's own icon, read once and kept while its row shows (spec 6.1); the store prunes the
/// rest at each open snapshot (R112). A process outside any app shows the icon of a command-line
/// tool, and an app whose bundle is gone the generic one (R69).
@MainActor enum AppIcons {
  private static let tool = small(NSWorkspace.shared.icon(for: .unixExecutable))
  private static let app = small(NSWorkspace.shared.icon(for: .applicationBundle))
  private(set) static var icons: [String: NSImage] = [:]

  static func icon(forFile path: String?) -> NSImage {
    guard let path else { return tool }
    if let icon = icons[path] { return icon }
    let icon =
      FileManager.default.fileExists(atPath: path)
      ? small(NSWorkspace.shared.icon(forFile: path)) : app
    icons[path] = icon
    return icon
  }

  /// `icon` drawn once at the rows' 24 pt, at 1x and 2x. The image keeps only these bitmaps, about
  /// 11 KB, so a later draw reads none of the icon store's files, as a first open did (R172).
  private static func small(_ icon: NSImage) -> NSImage {
    let size = NSSize(width: 24, height: 24)
    let image = NSImage(size: size)
    for scale in [1, 2] {
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 24 * scale, pixelsHigh: 24 * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
      bitmap.size = size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
      icon.draw(in: NSRect(origin: .zero, size: size))
      NSGraphicsContext.restoreGraphicsState()
      image.addRepresentation(bitmap)
    }
    return image
  }

  /// Keeps only the icons of `paths`, the rows that show now.
  static func keep(_ paths: Set<String>) { icons = icons.filter { paths.contains($0.key) } }
}
