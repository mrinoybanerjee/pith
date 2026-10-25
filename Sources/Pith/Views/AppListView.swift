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
          .font(.system(size: 13, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        MetricPicker(metric: Bindable(store).metric)
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

/// Memory · CPU · Disk in the approved design's style: a well with the chosen segment raised, each
/// as wide as its name. VoiceOver reads a "Sort by" group of buttons, the chosen one selected; the
/// keyboard uses ⌘1–⌘3. Each segment keeps its text visible to VoiceOver, so its font is checked.
private struct MetricPicker: View {
  @Binding var metric: Metric
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 0) {
      ForEach([(Metric.memory, "Memory"), (.cpu, "CPU"), (.disk, "Disk")], id: \.0) {
        option, title in
        let chosen = option == metric
        Text(title)
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
          .onTapGesture { metric = option }
          .accessibilityElement(children: .contain)
          .accessibilityLabel(title)
          .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
          .accessibilityAction(.default) { metric = option }
      }
    }
    .padding(2)
    .background(.quinary, in: .rect(cornerRadius: 7))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sort by")
  }
}
