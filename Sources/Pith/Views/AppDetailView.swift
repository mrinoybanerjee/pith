import PithCore
import SwiftUI

/// An opened app row (spec 4.3): the guide's explanation when the app has one, then what is inside
/// it, its processes grouped by role, each with its count and memory. Last, Quit, when Pith may
/// quit the app (spec 4.5).
struct AppDetailView: View {
  /// The scroll id of the confirm that shows.
  static let confirmID = "pith.confirm"

  let store: Store
  /// The row's name.
  let name: String
  let explanation: String?
  let inside: [HelperGroup]
  /// The process that Quit acts on, when Pith may quit the app; nil shows no Quit.
  let quitTarget: (any QuitTarget)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let explanation {
        Text(explanation).fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 3) {
        ForEach(inside, id: \.label) { group in
          HStack {
            Text(group.count > 1 ? "\(group.label) (\(group.count))" : group.label)
            Spacer()
            Text(ByteFormat.memory(group.memory))
          }
          .accessibilityElement(children: .combine)
        }
      }
      .font(.panel(.body).monospacedDigit())
      .foregroundStyle(.secondary)
      if let quitTarget { quit(quitTarget).padding(.top, 2) }
    }
    .detailWell()
  }

  /// Quit asks first. While the app quits, the row says so; after 5 s it offers Force Quit, which
  /// asks again (R79). The offer's button sits at the leading edge, as Quit does, away from the
  /// confirm's default button, so one double-click cannot press both (R93).
  @ViewBuilder private func quit(_ target: any QuitTarget) -> some View {
    let quitting = Text("Quitting \(name)…").foregroundStyle(.secondary)
    switch store.quitFlow.state {
    case .idle: Button("Quit") { store.askToQuit(target) }
    case .confirming:
      Confirm(
        store: store, question: "Quit \(name)?", detail: "It can ask you to save first.",
        action: "Quit")
    case .waiting: quitting
    case .offerForce:
      VStack(alignment: .leading, spacing: 8) {
        quitting
        Button("Force Quit") { store.offerForceQuit() }
      }
    case .confirmingForce:
      Confirm(
        store: store, question: "Force Quit \(name)?", detail: "Unsaved changes will be lost.",
        action: "Force Quit")
    case .done: EmptyView()
    }
  }
}

/// A confirm inside an opened row (design section 1): the question in semibold and what follows,
/// then Cancel and the default button. VoiceOver reads the sentence, then the two buttons. The
/// panel's keys reach them through the store (R80 and R94): Return presses the default button
/// only while it shows whole in the list. The button reports where it is in the list's content,
/// and the panel checks that against the list's scroll position (R147).
private struct Confirm: View {
  let store: Store
  let question: String
  let detail: String
  /// The default button's title.
  let action: String
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .trailing, spacing: 10) {
      Text("\(Text(question).fontWeight(.semibold)) \(detail)")
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        Button {
          store.cancelQuit()
        } label: {
          Text("Cancel")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        Button(action) { store.confirmQuit() }
          .buttonStyle(.borderedProminent)
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(AppListView.contentSpace))
          } action: {
            store.confirmButtonFrame = $0
          }
          .onDisappear { store.confirmButtonFrame = nil }
      }
    }
    .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    // The panel's own surface, lifted out of the well, with a hairline edge.
    .background(
      scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.5),
      in: .rect(cornerRadius: 8)
    )
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    .accessibilityElement(children: .contain)
    .id(AppDetailView.confirmID)
  }
}
