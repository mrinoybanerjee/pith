import AppKit
import PithCore
import SwiftUI
import UniformTypeIdentifiers

/// One app (spec 4.2 and 4.3). Clicking it opens it in place: "N processes" under the value, then
/// the explanation and what is inside.
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
      if expanded { AppDetailView(explanation: entry?.explanation, inside: app.inside) }
    }
  }
}

/// What every row shows (spec 4.2): a 24 pt icon, the name over a 3 pt bar, and the value on the
/// right, which stays whole while a long name truncates. VoiceOver reads it as one sentence, then
/// "expanded" or "collapsed".
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
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        name
          .font(.panel(.body, weight: .medium))
          .lineLimit(1)
        Bar(fraction: fraction, height: 3, fill: .secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 0) {
        Text(value.text)
          .font(.panel(.body, weight: .medium).monospacedDigit())
          .foregroundStyle(value.amount == nil ? .secondary : .primary)
          .accessibilityLabel(value.label)
          .accessibilityIdentifier("pith.value")
        if let processes {
          Text("\(processes) processes")
            .font(.panel(.body).monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("pith.value")
        }
      }
      .fixedSize()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      .quinary.opacity(selected || expanded || hovering ? 1 : 0), in: .rect(cornerRadius: 8)
    )
    .contentShape(.rect)
    .onTapGesture(perform: action)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(sentence)
    .accessibilityValue(expanded ? "expanded" : "collapsed")
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction(.default, action)
  }
}

/// A row's value for one metric: what it shows, what VoiceOver says, and its length on the rows'
/// shared bar scale, nil when there is no number.
struct RowValue {
  /// A first sample: the next reading has it.
  static let notYet = RowValue(text: "—", label: "not available yet", amount: nil)
  /// A value that Pith never measures, such as disk activity for "macOS system".
  static let notMeasured = RowValue(text: "not measured", label: "not measured", amount: nil)

  let text: String
  let label: String
  let amount: Double?

  /// `disk` is nil when the row has no disk reading at all.
  static func of(_ metric: Metric, memory: UInt64, cpu: Reading<Double>, disk: Reading<Double>?)
    -> RowValue
  {
    switch metric {
    case .memory: known(ByteFormat.memory(memory), Double(memory))
    case .cpu: cpu.value.map { known(PercentFormat.app($0), $0) } ?? .notYet
    case .disk:
      disk.map { $0.value.map { known(ByteFormat.rate($0), $0) } ?? .notYet } ?? .notMeasured
    }
  }

  private static func known(_ text: String, _ amount: Double) -> RowValue {
    RowValue(text: text, label: text, amount: amount)
  }
}

/// "{App}, {value} {metric}, {N} processes" (spec 4.8). A missing value says why: "CPU not
/// available yet" or "disk not measured".
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

/// Each app's own icon, read once and kept while its row shows (spec 6.1). A process outside any
/// app shows the icon of a command-line tool, and an app whose bundle is gone the generic one
/// (R69).
@MainActor enum AppIcons {
  private static let tool = NSWorkspace.shared.icon(for: .unixExecutable)
  private static let app = NSWorkspace.shared.icon(for: .applicationBundle)
  private static var icons: [String: NSImage] = [:]

  static func icon(forFile path: String?) -> NSImage {
    guard let path else { return tool }
    if let icon = icons[path] { return icon }
    let icon =
      FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : app
    icons[path] = icon
    return icon
  }

  /// Keeps only the icons of `paths`, the rows that show now.
  static func keep(_ paths: Set<String>) { icons = icons.filter { paths.contains($0.key) } }
}
