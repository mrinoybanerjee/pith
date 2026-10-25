import SwiftUI

/// The panel (spec 4.2): the status line, the three tiles, "Using the most" with the rows, and the
/// footer. Settings take the place of everything under the status line.
struct PanelView: View {
  let store: Store

  var body: some View {
    VStack(spacing: 0) {
      HeaderView(store: store)
      if store.showingSettings {
        SettingsView(store: store)
      } else {
        TilesView(totals: store.snapshot?.totals)
        AppListView(store: store)
        // Decorative, so it is the one text under 13 pt (spec 4.2).
        HStack {
          Text("Updated just now")
          Spacer()
          Text("Pith")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pith.footer")
      }
    }
    .frame(width: 360)
  }
}

/// Memory · CPU · Disk and 1 s · 2 s, in the approved design's style: a well with the chosen
/// segment raised, each segment as wide as its name. VoiceOver reads the segments as buttons, the
/// chosen one selected.
struct Segmented<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(value: Value, title: String)]
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { option in
        let chosen = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(option.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(chosen ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background {
              if chosen {
                RoundedRectangle(cornerRadius: 5)
                  .fill(.white.opacity(scheme == .dark ? 0.16 : 1))
                  .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
              }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
      }
    }
    .padding(2)
    .background(.quinary, in: .rect(cornerRadius: 7))
  }
}

/// A thin proportional bar of plain shapes (spec 4.2 and 9). An unknown value has no fill.
struct Bar<Fill: ShapeStyle>: View {
  let fraction: Double?
  let height: CGFloat
  let fill: Fill

  var body: some View {
    Capsule()
      .fill(Color(nsColor: .secondarySystemFill))
      .overlay(alignment: .leading) {
        if let fraction {
          GeometryReader { Capsule().fill(fill).frame(width: $0.size.width * fraction) }
        }
      }
      .frame(height: height)
      .accessibilityHidden(true)
  }
}

extension View {
  /// The rounded well under an opened row (spec 4.3 and 4.4), its left edge under the row's name.
  func detailWell() -> some View {
    font(.system(size: 13))
      .lineSpacing(2)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quinary, in: .rect(cornerRadius: 9))
      .padding(EdgeInsets(top: 2, leading: 42, bottom: 6, trailing: 8))
  }
}
