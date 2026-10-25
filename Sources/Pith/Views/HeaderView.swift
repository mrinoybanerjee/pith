import PithCore
import SwiftUI

/// The status line (spec 4.2 and 7.3): a colored dot, the title and the sentence, with Pin and
/// Settings on the right.
struct HeaderView: View {
  let store: Store

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(dotColor)
        .frame(width: 10, height: 10)
        .padding(.top, 7)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(store.status.title)
          .font(.system(size: 17, weight: .semibold))
          .kerning(-0.17)
          .accessibilityAddTraits(.isHeader)
        // "6.4 GB" stays on one line.
        Text(
          store.status.sentence.replacing(" GB", with: "\u{A0}GB")
            .replacing(" MB", with: "\u{A0}MB")
        )
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineSpacing(1.5)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 2) {
        IconButton(symbol: "pin", label: "Pin", on: store.pinned) {
          store.pinned.toggle()
        }
        IconButton(symbol: "gearshape", label: "Settings", on: store.showingSettings) {
          store.showingSettings.toggle()
        }
      }
    }
    .padding(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
  }

  private var dotColor: Color {
    switch store.status.dot {
    case .calm: .green
    case .tight: .orange
    case .critical: .red
    }
  }
}

/// A 26 pt icon button. When on, it sits in a well, and VoiceOver reads it as selected.
private struct IconButton: View {
  let symbol: String
  let label: String
  let on: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(on ? .primary : .secondary)
        .frame(width: 26, height: 26)
        .background(.quinary.opacity(on ? 1 : 0), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(on ? .isSelected : [])
    .help(label)
  }
}
