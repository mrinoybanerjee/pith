import SwiftUI

/// The panel (spec 4.2): the status line, the three tiles, "Using the most" with the rows, and the
/// footer. Settings take the place of everything under the status line.
struct PanelView: View {
  let store: Store
  /// Which open this is. Each open draws a new view, so nothing animates from the rows of the last
  /// open (R85); animations run only for changes while the panel shows.
  let open: Int

  var body: some View {
    VStack(spacing: 0) {
      HeaderView(store: store)
      if store.showingSettings {
        SettingsView(store: store)
      } else {
        TilesView(totals: store.snapshot?.totals)
        AppListView(store: store)
        // Decorative, so it is the one text under 13 pt (spec 4.2). VoiceOver reports a font only
        // when it is set on the text itself, in a combined element.
        HStack {
          Text("Updated just now").font(.panel(.footer))
          Spacer()
          Text("Pith").font(.panel(.footer))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pith.footer")
      }
    }
    .frame(width: 360)
    .id(open)
  }
}

/// The panel's type sizes, all in one place (spec 4.2): SF Pro, 13 pt or more for anything the user
/// must read. Only the decorative footer is smaller.
enum PanelType: CGFloat, CaseIterable {
  case title = 17
  case value = 19
  case body = 13
  case footer = 11.5
}

extension Font {
  static func panel(_ type: PanelType, weight: Font.Weight = .regular) -> Font {
    .system(size: type.rawValue, weight: weight)
  }
}

/// Memory · CPU · Disk and 1 s · 2 s, the panel's one segmented style (design section 1): a well
/// with the chosen segment raised, each as wide as its name. The segments are buttons, so full
/// keyboard access reaches them; VoiceOver reads a group named `label`, the chosen one selected.
struct Segmented<Value: Hashable>: View {
  let label: String
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
            .font(.panel(.body, weight: .medium))
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
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
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
    font(.panel(.body))
      .lineSpacing(2)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quinary, in: .rect(cornerRadius: 9))
      .padding(EdgeInsets(top: 2, leading: 42, bottom: 6, trailing: 8))
  }
}
