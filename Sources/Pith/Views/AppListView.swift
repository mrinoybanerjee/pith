import PithCore
import SwiftUI

/// "Using the most" with Memory, CPU and Disk, then the top apps and "macOS system", always last
/// (spec 4.2). The rows ease into a new order; with Reduce Motion they crossfade (spec 4.8). Over
/// 560 pt the list scrolls under the fixed status line and tiles.
struct AppListView: View {
  let store: Store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The height of the list's visible part, and the opened row with its height (R92).
  @State private var listHeight: CGFloat = 0
  @State private var opened = OpenedRow(id: "", height: 0)
  /// A row opened, or its details or quit flow changed, and the row is not yet shown for it.
  @State private var revealPending = false

  var body: some View {
    let metric = store.metric
    let values = store.rows.map {
      RowValue.of(metric, memory: $0.memory, cpu: $0.cpu, disk: $0.diskBytesPerSecond)
    }
    let system =
      store.snapshot?.system.value.map {
        RowValue.of(metric, memory: $0.memory, cpu: $0.cpu, disk: nil)
      } ?? (metric == .disk ? .notMeasured : .notYet)
    let top = (values + [system]).compactMap(\.amount).max() ?? 0
    let fraction = { (value: RowValue) in value.amount.map { top > 0 ? $0 / top : 0 } }
    let order = store.rows.map(\.id)
    VStack(spacing: 0) {
      HStack {
        Text("Using the most")
          .font(.panel(.body, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Segmented(
          label: "Sort by", selection: Bindable(store).metric,
          options: [(.memory, "Memory"), (.cpu, "CPU"), (.disk, "Disk")])
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      ScrollViewReader { proxy in
        ScrollView {
          ZStack {
            VStack(spacing: 0) {
              ForEach(Array(zip(store.rows, values)), id: \.0.id) { app, value in
                AppRowView(store: store, app: app, value: value, fraction: fraction(value))
                  .onGeometryChange(for: CGFloat.self, of: \.size.height) { measured(app.id, $0) }
              }
              SystemRowView(store: store, value: system, fraction: fraction(system))
                .id(Store.systemRowID)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                  measured(Store.systemRowID, $0)
                }
            }
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
            // With Reduce Motion a new order is a new list, which fades in over the old one.
            .id(reduceMotion ? order : [])
            .transition(.opacity)
          }
          .animation(.easeInOut(duration: 0.25), value: order)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
        .onChange(of: store.selectedRowID) { _, id in if let id { proxy.scrollTo(id) } }
        .onChange(of: store.expandedAppID) { revealPending = true }
        .onChange(of: store.systemDetails) { revealPending = true }
        .onChange(of: store.quitFlow.state) { revealPending = true }
        .onChange(of: opened) {
          if revealPending {
            revealPending = false
            reveal(proxy)
          }
        }
        .onChange(of: listHeight) { reveal(proxy) }
        .onChange(of: order) { AppIcons.keep(Set(store.rows.compactMap(\.bundlePath))) }
      }
    }
  }

  /// Keeps the opened row's height, which changes when it opens, when its details load, when its
  /// quit flow changes, and when a reading changes what is inside it.
  private func measured(_ id: String, _ height: CGFloat) {
    if id == store.expandedAppID { opened = OpenedRow(id: id, height: height) }
  }

  /// The row opens in place (spec 4.3). When a row opens, or its details or quit flow change, the
  /// list scrolls once they are laid out, and again when the panel's height then changes around
  /// it. It scrolls the least that shows the whole row, its details and any confirm included.
  /// When the row is taller than the list, its top goes to the list's top instead, so a change
  /// never scrolls the row's name out of view (R92). A reading that only changes what is inside
  /// the row does not scroll.
  private func reveal(_ proxy: ScrollViewProxy) {
    guard opened.id == store.expandedAppID else { return }
    proxy.scrollTo(opened.id, anchor: opened.height <= listHeight ? nil : .top)
  }
}

private struct OpenedRow: Equatable {
  let id: String
  let height: CGFloat
}
