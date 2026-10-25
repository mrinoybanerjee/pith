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

  /// "15.1 of 16 GB", then Plenty, Tight or Critical. Swap is added when pressure is not normal or
  /// swap is over 1 GB.
  private var memory: some View {
    let pressure = totals?.pressure.value
    let tint: Color? =
      switch pressure {
      case .warning: .orange
      case .critical: .red
      default: nil
      }
    let word: String? =
      switch pressure {
      case .normal: "Plenty"
      case .warning: "Tight"
      case .critical: "Critical"
      case nil: nil
      }
    let swap = totals?.swapUsed.value.flatMap { swap in
      pressure != .normal || swap > 1 << 30 ? "\(ByteFormat.memory(swap)) swap" : nil
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
      words: [word, swap].compactMap { $0 }, tint: tint)
  }

  /// "38%", then Light under 30%, Moderate to 70%, Busy above.
  private var cpu: some View {
    let busy = totals?.cpuBusy.value
    let word = busy.map { $0 < 0.3 ? "Light" : $0 <= 0.7 ? "Moderate" : "Busy" }
    return Tile(
      caption: "CPU", value: busy.map { split(PercentFormat.total($0)) }, fraction: busy,
      words: word.map { [$0] } ?? [], tint: nil)
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
      words: space.map { ["of \(ByteFormat.storage($1))"] } ?? [], tint: nil)
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
  let words: [String]
  /// Amber for Tight, red for Critical.
  let tint: Color?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(caption)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
      Group {
        if let value {
          let number = Text(value.number).font(
            .system(size: 19, weight: .semibold).monospacedDigit())
          let unit = Text(value.unit).font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
          Text("\(number)\(unit)")
        } else {
          Text("—").font(.system(size: 19, weight: .semibold))
            .accessibilityLabel("not available yet")
        }
      }
      .kerning(-0.19)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 5)
      Bar(fraction: fraction, height: 4, fill: tint ?? .primary.opacity(0.8))
        .padding(.top, 7)
      ForEach(words, id: \.self) { word in
        Text(word)
          .font(.system(size: 13).monospacedDigit())
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
