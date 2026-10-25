import PithCore
import SwiftUI

/// "Using the most" with Memory, CPU and Disk, then the top apps and "macOS system", always last
/// (spec 4.2). The rows ease into a new order; with Reduce Motion they crossfade (spec 4.8). Over
/// 560 pt the list scrolls under the fixed status line and tiles.
struct AppListView: View {
  let store: Store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
              }
              SystemRowView(store: store, value: system, fraction: fraction(system))
                .id(Store.systemRowID)
            }
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
            // With Reduce Motion a new order is a new list, which fades in over the old one.
            .id(reduceMotion ? order : [])
            .transition(.opacity)
          }
          .animation(.easeInOut(duration: 0.25), value: order)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: store.selectedRowID) { _, id in if let id { proxy.scrollTo(id) } }
        .onChange(of: store.expandedAppID) { reveal(proxy) }
        .onChange(of: store.systemDetails) { reveal(proxy) }
        .onChange(of: order) { AppIcons.keep(Set(store.rows.compactMap(\.bundlePath))) }
      }
    }
  }

  /// Scrolls the least that shows an opened row with its details, once they are laid out and
  /// again when they grow. The row opens in place (spec 4.3).
  private func reveal(_ proxy: ScrollViewProxy) {
    guard let id = store.expandedAppID else { return }
    Task { proxy.scrollTo(id) }
  }
}
