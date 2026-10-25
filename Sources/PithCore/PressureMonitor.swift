// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/RAM/readers.swift L37-L103 at v3.0.22 (1282cd5).

import Darwin
import Dispatch
import os

extension Pressure {
  /// `kern.memorystatus_vm_pressure_level` defines only 1 (normal), 2 (warning) and 4 (critical).
  init(kernelLevel: Int32) {
    switch kernelLevel {
    case 1: self = .normal
    case 2: self = .warning
    case 4: self = .critical
    default:
      assertionFailure("Unknown memory pressure level \(kernelLevel)")
      self = .normal
    }
  }

  static func fromKernel() -> Pressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
    assert(status == 0, "sysctl kern.memorystatus_vm_pressure_level failed: errno \(errno)")
    return Pressure(kernelLevel: level)
  }
}

/// Follows memory pressure. On each pressure event it re-reads the kernel level, updates
/// `current`, then calls `onChange` on a background queue.
public final class PressureMonitor: Sendable {
  private let level: OSAllocatedUnfairLock<Pressure>
  private let source: any DispatchSourceMemoryPressure

  public var current: Pressure { level.withLock { $0 } }

  public init(onChange: @escaping @Sendable (Pressure) -> Void) {
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
