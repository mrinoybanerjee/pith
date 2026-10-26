import Darwin
import Foundation

/// Converts Mach absolute-time ticks (the unit of `ri_user_time` on Apple Silicon) to nanoseconds.
public struct MachTimebase: Sendable {
  private let numer: UInt32
  private let denom: UInt32

  public init(numer: UInt32, denom: UInt32) {
    self.numer = numer
    self.denom = denom
  }

  public static let current: MachTimebase = {
    var info = mach_timebase_info_data_t()
    let status = mach_timebase_info(&info)
    assert(status == KERN_SUCCESS)
    return MachTimebase(numer: info.numer, denom: info.denom)
  }()

  public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
    UInt64(UInt128(ticks) * UInt128(numer) / UInt128(denom))
  }
}

public enum ByteFormat {
  /// Binary units (1 GB = 2^30 bytes), labeled "GB" and "MB" as Activity Monitor and `top` do.
  public static func memory(_ bytes: UInt64) -> String { format(bytes, base: 1024) }

  /// Decimal units (1 GB = 10^9 bytes), as Finder and System Settings show storage.
  public static func storage(_ bytes: UInt64) -> String { format(bytes, base: 1000) }

  /// A disk rate in decimal units, as storage, with the precision of gigabytes at every unit:
  /// "0 KB/s", "5.5 KB/s", "340 KB/s", "1.2 MB/s".
  public static func rate(_ bytesPerSecond: Double) -> String {
    var value = bytesPerSecond / 1000
    var unit = "KB/s"
    for next in ["MB/s", "GB/s"] where value.rounded() >= 1000 {
      value /= 1000
      unit = next
    }
    return "\(decimal(value)) \(unit)"
  }

  private static func format(_ bytes: UInt64, base: Double) -> String {
    let inMB = Double(bytes) / (base * base)
    // The rounded value picks the unit, so 1023.7 MB reads "1 GB", not "1024 MB".
    if inMB.rounded() < base { return String(format: "%.0f MB", inMB) }
    return "\(decimal(inMB / base)) GB"
  }

  /// One decimal under 100, none from 100 up, and never ".0". The rounded value picks the format.
  private static func decimal(_ value: Double) -> String {
    let text = String(format: (value * 10).rounded() < 1000 ? "%.1f" : "%.0f", value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
  }
}

public enum PercentFormat {
  /// One decimal below 10%, a whole number from 10% up. The rounded value picks the format.
  public static func app(_ fraction: Double) -> String {
    let percent = fraction * 100
    return String(format: (percent * 10).rounded() < 100 ? "%.1f%%" : "%.0f%%", percent)
  }

  public static func total(_ fraction: Double) -> String {
    String(format: "%.0f%%", fraction * 100)
  }
}
