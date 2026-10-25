import PithCore
import SwiftUI

/// An opened app row (spec 4.3): the guide's explanation when the app has one, then what is inside
/// it, its processes grouped by role, each with its count and memory. Last, Quit, when Pith may
/// quit the app (spec 4.5).
struct AppDetailView: View {
  /// The scroll id of Quit and its confirms.
  static let quitID = "pith.quit"

  let store: Store
  /// The row's name.
  let name: String
  let explanation: String?
  let inside: [HelperGroup]
  /// The app's own process when Pith may quit it; nil shows no Quit.
  let quitPID: Int32?

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
      if let quitPID { quit(quitPID).padding(.top, 2).id(Self.quitID) }
    }
    .detailWell()
  }

  /// Quit asks first. While the app quits, the row says so; after 5 s it offers Force Quit, which
  /// asks again (R79).
  @ViewBuilder private func quit(_ pid: Int32) -> some View {
    let send = { (event: QuitFlow.Event) in store.sendQuit(event, pid: pid) }
    let quitting = Text("Quitting \(name)…").foregroundStyle(.secondary)
    switch store.quitFlow.state {
    case .idle: Button("Quit") { send(.tapQuit) }
    case .confirming:
      Confirm(
        question: "Quit \(name)?", detail: "It can ask you to save first.", action: "Quit",
        confirm: .confirm, send: send)
    case .waiting: quitting
    case .offerForce:
      HStack {
        quitting
        Spacer()
        Button("Force Quit") { send(.tapForce) }
      }
    case .confirmingForce:
      Confirm(
        question: "Force Quit \(name)?", detail: "Unsaved changes will be lost.",
        action: "Force Quit", confirm: .confirmForce, send: send)
    case .done: EmptyView()
    }
  }
}

/// A confirm inside an opened row (design section 1): the question in semibold and what follows,
/// then Cancel and the default button. Return presses the default button and Escape cancels
/// (R80). VoiceOver reads the sentence, then the two buttons.
private struct Confirm: View {
  let question: String
  let detail: String
  /// The default button's title, and the event it sends. Cancel sends `.cancel`.
  let action: String
  let confirm: QuitFlow.Event
  let send: (QuitFlow.Event) -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .trailing, spacing: 10) {
      Text("\(Text(question).fontWeight(.semibold)) \(detail)")
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        Button {
          send(.cancel)
        } label: {
          Text("Cancel")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        Button(action) { send(confirm) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
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
  }
}
