import AppKit
import PithCore
import SwiftUI
import UniformTypeIdentifiers

/// One app (spec 4.2 and 4.3). Clicking it opens it in place: "N processes" under the value, then
/// the explanation and what is inside.
struct AppRowView: View {
  let store: Store
  let app: AppUsage
  let value: RowValue?
  let fraction: Double?

  var body: some View {
    let entry = store.guide.entry(name: app.name, bundleID: app.bundleID, path: app.bundlePath)
    // R49: a process outside any app shows its guide title when the guide has one.
    let name = app.id.hasPrefix("proc:") ? entry?.title ?? app.name : app.name
    let expanded = store.expandedAppID == app.id
    VStack(spacing: 0) {
      RowLayout(
        icon: Image(nsImage: AppIcons.icon(forFile: app.bundlePath)).resizable(),
        name: Text(name), fraction: fraction, value: value?.text,
        processes: expanded && app.processCount > 1 ? app.processCount : nil,
        highlighted: expanded || store.selectedRowID == app.id,
        sentence: rowSentence(name, value, store.metric, processes: app.processCount)
      ) { store.toggle(app.id) }
      if expanded { AppDetailView(explanation: entry?.explanation, inside: app.inside) }
    }
  }
}

/// What every row shows (spec 4.2): a 24 pt icon, the name over a 3 pt bar, and the value on the
/// right, which stays whole while a long name truncates. VoiceOver reads it as one sentence.
struct RowLayout<Icon: View, Name: View>: View {
  let icon: Icon
  let name: Name
  let fraction: Double?
  /// Nil when the reading is not available.
  let value: String?
  /// Shown under the value.
  let processes: Int?
  let highlighted: Bool
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
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Bar(fraction: fraction, height: 3, fill: .secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 0) {
        Group {
          if let value {
            Text(value)
          } else {
            Text("—").accessibilityLabel("not available yet")
          }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .accessibilityIdentifier("pith.value")
        if let processes {
          Text("\(processes) processes")
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("pith.value")
        }
      }
      .fixedSize()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quinary.opacity(highlighted || hovering ? 1 : 0), in: .rect(cornerRadius: 8))
    .contentShape(.rect)
    .onTapGesture(perform: action)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(sentence)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, action)
  }
}

/// A row's value for one metric: the text it shows and its length on the rows' shared bar scale.
struct RowValue {
  let text: String
  let amount: Double

  /// Nil when the reading is not available, so the row shows "—".
  static func of(_ metric: Metric, memory: UInt64, cpu: Reading<Double>, disk: Reading<Double>)
    -> RowValue?
  {
    switch metric {
    case .memory: RowValue(text: ByteFormat.memory(memory), amount: Double(memory))
    case .cpu: cpu.value.map { RowValue(text: PercentFormat.app($0), amount: $0) }
    case .disk: disk.value.map { RowValue(text: ByteFormat.rate($0), amount: $0) }
    }
  }
}

/// "{App}, {value} {metric}, {N} processes" (spec 4.8). An unknown value is "not available yet".
func rowSentence(_ name: String, _ value: RowValue?, _ metric: Metric, processes: Int?) -> String {
  let word =
    switch metric {
    case .memory: "memory"
    case .cpu: "CPU"
    case .disk: "disk"
    }
  let reading = value.map { "\($0.text) \(word)" } ?? "\(word) not available yet"
  let count = processes.map { $0 == 1 ? "1 process" : "\($0) processes" }
  return ([name, reading] + [count].compactMap { $0 }).joined(separator: ", ")
}

/// Each app's own icon, read once (spec 6.1). A process outside any app shows the icon of a
/// command-line tool.
@MainActor private enum AppIcons {
  private static let tool = NSWorkspace.shared.icon(for: .unixExecutable)
  private static var icons: [String: NSImage] = [:]

  static func icon(forFile path: String?) -> NSImage {
    guard let path else { return tool }
    if let icon = icons[path] { return icon }
    let icon = NSWorkspace.shared.icon(forFile: path)
    icons[path] = icon
    return icon
  }
}
