import PithCore
import SwiftUI

/// Memory, CPU and Storage (spec 4.2), each a caption, a value, a meter and a word. VoiceOver
/// reads each tile as one sentence. A value that is not available shows "—", never 0.
struct TilesView: View {
  let totals: SystemTotals?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      memory
      cpu
      storage
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
  }

  /// "15.1 of 16 GB", then Plenty, Tight or Critical, or "—" when the pressure is unknown. Swap
  /// in use is added when pressure is not normal or swap is over 1 GB.
  private var memory: some View {
    let pressure = totals?.pressure.value
    let tint: Color? =
      switch pressure {
      case .warning: .orange
      case .critical: .red
      default: nil
      }
    let word =
      switch pressure {
      case .normal: Text("Plenty")
      case .warning: Text("Tight")
      case .critical: Text("Critical")
      case nil: Text("—").accessibilityLabel("pressure not available")
      }
    let swap = totals?.swapUsed.value.flatMap { swap in
      swap > 0 && (pressure != .normal || swap > 1 << 30)
        ? Text("\(ByteFormat.memory(swap)) swap") : nil
    }
    let memory = totals.flatMap { t in t.memoryUsed.value.map { (used: $0, total: t.memoryTotal) } }
    return Tile(
      caption: "Memory",
      value: memory.map { used, total in
        let (number, unit) = split(ByteFormat.memory(used))
        let total = ByteFormat.memory(total)
        // The unit is said once when both share it. Only the space before "of" may break.
        let own = total.hasSuffix(" " + unit) ? "" : " " + unit
        return (number, "\(own) of \(total)".noBreaks(after: 1))
      },
      fraction: memory.map { Double($0.used) / Double($0.total) },
      words: [word] + [swap].compactMap { $0 }, tint: tint)
  }

  /// "38%", then Light under 30%, Moderate to 70%, Busy above, judged on the percent shown, so the
  /// two never disagree.
  private var cpu: some View {
    let busy = totals?.cpuBusy.value
    let shown = busy.map { split(PercentFormat.total($0)) }
    let word = shown.map { number, _ in
      let percent = Int(number)!
      return Text(percent < 30 ? "Light" : percent <= 70 ? "Moderate" : "Busy")
    }
    return Tile(
      caption: "CPU", value: shown, fraction: busy, words: word.map { [$0] } ?? [], tint: nil)
  }

  /// "112 GB free", then "of 228 GB"; the meter is the used share.
  private var storage: some View {
    let space = totals.flatMap { t in
      t.storageFree.value.flatMap { free in t.storageTotal.value.map { (free, $0) } }
    }
    return Tile(
      caption: "Storage",
      value: space.map { free, _ in
        let (number, unit) = split(ByteFormat.storage(free))
        return (number, " \(unit) free".noBreaks(after: 1))
      },
      fraction: space.map { free, total in Double(total - free) / Double(total) },
      words: space.map { [Text("of \(ByteFormat.storage($1))")] } ?? [], tint: nil)
  }

  /// "15.1 GB" is ("15.1", "GB") and "38%" is ("38", "%").
  private func split(_ text: String) -> (String, String) {
    let unit = text.firstIndex { !$0.isNumber && $0 != "." }!
    return (String(text[..<unit]), text[unit...].trimmingCharacters(in: .whitespaces))
  }
}

/// Its spacing is the mockup's margins plus the leading that the mockup's CSS line height adds.
private struct Tile: View {
  let caption: String
  /// The number and its unit, or nil when the reading is not available.
  let value: (number: String, unit: String)?
  let fraction: Double?
  /// One line each.
  let words: [Text]
  /// Amber for Tight, red for Critical.
  let tint: Color?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(caption)
        .font(.panel(.body, weight: .medium))
        .foregroundStyle(.secondary)
      Group {
        if let value {
          let number = Text(value.number).font(
            .panel(.value, weight: .semibold).monospacedDigit())
          let unit = Text(value.unit).font(.panel(.body, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
          Text("\(number)\(unit)")
        } else {
          Text("—").font(.panel(.value, weight: .semibold))
            .accessibilityLabel("not available yet")
        }
      }
      .kerning(-0.19)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 5)
      Bar(fraction: fraction, height: 4, fill: tint ?? .primary.opacity(0.8))
        .padding(.top, 7)
      ForEach(words.indices, id: \.self) { line in
        words[line]
          .font(.panel(.body).monospacedDigit())
          .foregroundStyle(tint ?? .secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 2)
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.quinary, in: .rect(cornerRadius: 10))
    .accessibilityElement(children: .combine)
  }
}

extension String {
  /// Keeps the first `count` spaces and makes the rest no-break spaces, so a wrapped line breaks
  /// only there.
  fileprivate func noBreaks(after count: Int) -> String {
    var spaces = 0
    return String(
      map { character in
        guard character == " " else { return character }
        spaces += 1
        return spaces > count ? "\u{A0}" : " "
      })
  }
}
