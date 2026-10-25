import PithCore
import SwiftUI

/// The "macOS system" row, always last (spec 4.2 and 4.4): what the user's own processes leave
/// unexplained (spec 6.6). Opening it measures the largest system processes once, with `top`.
struct SystemRowView: View {
  let store: Store
  let value: RowValue
  let fraction: Double?

  var body: some View {
    let expanded = store.expandedAppID == Store.systemRowID
    VStack(spacing: 0) {
      RowLayout(
        icon: RoundedRectangle(cornerRadius: 6)
          .fill(.quinary)
          .overlay { Image(systemName: "cpu").font(.panel(.body)).foregroundStyle(.secondary) },
        name: HStack(spacing: 5) {
          Text("macOS system").foregroundStyle(.secondary)
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.panel(.body, weight: .semibold))
            .imageScale(.small)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        },
        fraction: fraction, value: value, processes: nil,
        selected: store.selectedRowID == Store.systemRowID, expanded: expanded,
        sentence: rowSentence("macOS system", value, store.metric, processes: nil)
      ) { store.toggle(Store.systemRowID) }
      if expanded { details.detailWell() }
    }
  }

  @ViewBuilder private var details: some View {
    switch store.systemDetails {
    case .idle, .measuring:
      Text("Measuring…").foregroundStyle(.secondary)
    case .failed:
      VStack(alignment: .leading, spacing: 8) {
        Text("Couldn't measure system details").foregroundStyle(.secondary)
        Button("Retry") { store.openSystemDetails() }
      }
    case .loaded(let breakdown):
      VStack(alignment: .leading, spacing: 0) {
        Text("Measured once, just now. Pith asks macOS only when you open this.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 3) {
          ForEach(Array(breakdown.items.enumerated()), id: \.offset) { _, item in
            line(item.title, item.memory)
          }
          line("Other system work", other(breakdown))
        }
        .font(.panel(.body).monospacedDigit())
        .padding(.top, 8)
        ForEach(Array(breakdown.items.enumerated()), id: \.offset) { _, item in
          if let explanation = item.explanation {
            Text("\(Text("\(item.title):").bold()) \(explanation)")
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 10)
          }
        }
        Text("Part of macOS. Pith never offers to quit it.")
          .foregroundStyle(.secondary)
          .padding(.top, 4)
      }
    }
  }

  private func line(_ title: String, _ memory: UInt64?) -> some View {
    HStack {
      Text(title)
      Spacer()
      if let memory {
        Text(ByteFormat.memory(memory))
      } else {
        Text("—").accessibilityLabel("not available")
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// R47: the residual less the listed items, so the lines add up to the row's total; top's own
  /// remainder when the residual is not available. "—" when the items exceed the residual.
  private func other(_ breakdown: SystemBreakdown) -> UInt64? {
    guard let residual = store.snapshot?.system.value?.memory else { return breakdown.other }
    let listed = breakdown.items.reduce(0) { $0 + $1.memory }
    return residual >= listed ? residual - listed : nil
  }
}
