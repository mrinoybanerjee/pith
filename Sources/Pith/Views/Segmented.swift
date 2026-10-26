import SwiftUI

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
