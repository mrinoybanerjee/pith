import PithCore
import SwiftUI

/// An opened app row (spec 4.3): the guide's explanation when the app has one, then what is inside
/// it, its processes grouped by role, each with its count and memory.
struct AppDetailView: View {
  let explanation: String?
  let inside: [HelperGroup]

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
      .font(.system(size: 13).monospacedDigit())
      .foregroundStyle(.secondary)
    }
    .detailWell()
  }
}
