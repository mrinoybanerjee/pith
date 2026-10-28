import SwiftUI

/// The panel (spec 4.2): the status line, the three tiles, "Using the most" with the rows, and the
/// awake bar. Settings take the place of everything under the status line.
struct PanelView: View {
  let store: Store
  /// Which open this is. Each open draws a new view, so nothing animates from the rows of the last
  /// open (R85); animations run only for changes while the panel shows. Nil while the panel is
  /// closed, so no view of a closed panel lives on to watch the store (R118).
  let open: Int?

  var body: some View {
    if let open {
      VStack(spacing: 0) {
        HeaderView(store: store)
        if store.showingSettings {
          SettingsView(store: store)
        } else {
          TilesView(totals: store.snapshot?.totals)
          AppListView(store: store)
          AwakeBar(store: store)
        }
      }
      .frame(width: 360)
      .id(open)
    }
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
