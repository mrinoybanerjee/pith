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
  /// What to show once the opened row is laid out again, and whether that is still to do.
  @State private var reveal = Reveal.row
  @State private var revealPending = false

  var body: some View {
    let metric = store.metric
    let values = store.rows.map {
      RowValue.of(metric, memory: $0.memory, cpu: $0.cpu, disk: $0.diskBytesPerSecond)
    }
    let system: RowValue =
      switch (metric, store.snapshot?.system) {
      case (_, .value(let residual)?):
        .of(metric, memory: residual.memory, cpu: residual.cpu, disk: nil)
      case (.disk, _): .notMeasured
      case (_, let reading?): .missing(reading)
      case (_, nil): .notYet
      }
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
        .onChange(of: store.selectedRowID) { _, id in
          print("R139 scrollTo selected \(id ?? "-")")
          if let id { proxy.scrollTo(id) }
        }
        .onChange(of: store.expandedAppID) {
          // A row that opens again at its last height must still be shown.
          opened = OpenedRow(id: "", height: 0)
          request(.row)
        }
        .onChange(of: store.systemDetails) { request(.row) }
        .onChange(of: store.quitFlow.state) { _, state in
          request([.confirming, .confirmingForce].contains(state) ? .confirm : .row)
        }
        .onChange(of: opened) {
          print("R139 opened \(opened.id) \(opened.height) pending \(revealPending)")
          if revealPending { show(proxy) }
        }
        .onChange(of: listHeight) {
          print("R139 listHeight \(listHeight)")
          show(proxy)
        }
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
  /// it. A reading that only changes what is inside the row does not scroll.
  private func request(_ next: Reveal) {
    reveal = next
    revealPending = true
  }

  /// For the row, the list scrolls the least that shows all of it; when it is taller than the
  /// list, its top goes to the list's top instead, so its name stays in view (R92). A confirm that
  /// has just appeared is shown whole, scrolling the least that does it, even if the row's name
  /// goes; the confirm names the app (R98).
  private func show(_ proxy: ScrollViewProxy) {
    guard opened.id == store.expandedAppID else { return }
    print("R139 show \(reveal) \(opened.id) height \(opened.height) list \(listHeight)")
    revealPending = false
    switch reveal {
    case .row: proxy.scrollTo(opened.id, anchor: opened.height <= listHeight ? nil : .top)
    case .confirm: proxy.scrollTo(AppDetailView.confirmID)
    }
  }
}

private enum Reveal { case row, confirm }

private struct OpenedRow: Equatable {
  let id: String
  let height: CGFloat
}
