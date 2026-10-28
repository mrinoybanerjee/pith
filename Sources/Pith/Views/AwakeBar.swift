import SwiftUI

/// The bar at the bottom of the panel (Awake spec 3.2): "Keep awake" with 1 h, 4 h and ∞, or the
/// session's end with End. One click starts or ends, with no confirm. Its text changes only on
/// start and end, so the bar costs nothing while the panel is open.
struct AwakeBar: View {
  let store: Store

  var body: some View {
    HStack(spacing: 6) {
      if let awake = store.awake {
        Text(awake.title)
        Spacer()
        button("End", label: "End keeping awake") { store.endAwake() }
      } else {
        Text("Keep awake").foregroundStyle(.secondary)
        Spacer()
        button("1 h", label: "Keep awake for 1 hour") { store.startAwake(for: 3600) }
        button("4 h", label: "Keep awake for 4 hours") { store.startAwake(for: 4 * 3600) }
        button("∞", label: "Keep awake until you end it") { store.startAwake(for: nil) }
      }
    }
    .font(.panel(.body))
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
  }

  /// A small button in a grey well, as the segments of Memory · CPU · Disk.
  private func button(_ title: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.panel(.body, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(.quinary, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}
