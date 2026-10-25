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

  /// A disk rate in decimal units, as storage, from "0 KB/s" up.
  public static func rate(_ bytesPerSecond: Double) -> String {
    let inKB = bytesPerSecond / 1000
    if inKB.rounded() < 1000 { return String(format: "%.0f KB/s", inKB) }
    return storage(UInt64(bytesPerSecond.rounded())) + "/s"
  }

  private static func format(_ bytes: UInt64, base: Double) -> String {
    let inMB = Double(bytes) / (base * base)
    let inGB = inMB / base
    // The rounded value picks the unit, so 1023.7 MB reads "1 GB", not "1024 MB".
    if inMB.rounded() < base { return String(format: "%.0f MB", inMB) }
    if inGB >= 100 { return String(format: "%.0f GB", inGB) }
    return String(format: "%.1f GB", inGB).replacing(".0 GB", with: " GB")
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
