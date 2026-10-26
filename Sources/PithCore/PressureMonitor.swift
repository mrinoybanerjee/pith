// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/RAM/readers.swift L37-L103 at v3.0.22 (1282cd5).

import Darwin
import Dispatch
import os

extension Pressure {
  /// `kern.memorystatus_vm_pressure_level` defines only 1 (normal), 2 (warning) and 4 (critical).
  /// Any other level is unavailable.
  static func reading(kernelLevel: Int32) -> Reading<Pressure> {
    switch kernelLevel {
    case 1: .value(.normal)
    case 2: .value(.warning)
    case 4: .value(.critical)
    default: .unavailable("unknown pressure level \(kernelLevel)")
    }
  }

  static func fromKernel() -> Reading<Pressure> {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
      return .unavailable("pressure sysctl failed: errno \(errno)")
    }
    return reading(kernelLevel: level)
  }
}

/// Follows memory pressure. On each pressure event it re-reads the kernel level, updates
/// `current`, then calls `onChange` on a background queue.
public final class PressureMonitor: Sendable {
  private let level: OSAllocatedUnfairLock<Reading<Pressure>>
  private let source: any DispatchSourceMemoryPressure

  public var current: Reading<Pressure> { level.withLock { $0 } }

  public init(onChange: @escaping @Sendable (Reading<Pressure>) -> Void) {
    let level = OSAllocatedUnfairLock(initialState: Pressure.fromKernel())
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical])
    source.setEventHandler {
      let pressure = Pressure.fromKernel()
      level.withLock { $0 = pressure }
      onChange(pressure)
    }
    source.resume()
    self.level = level
    self.source = source
  }

  deinit { source.cancel() }
}
