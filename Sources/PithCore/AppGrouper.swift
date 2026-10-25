// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/RAM/readers.swift L210-L227 at v3.0.22 (1282cd5).

import Darwin
import Foundation
import System

/// Maps each process to the app it belongs to (spec 6.5), so helpers count toward their app.
public struct AppGrouper: Sendable {
  private let responsible: (@Sendable (Int32) -> Int32?)?
  private let bundleInfo: @Sendable (String) -> (id: String, name: String)?
  private var cache: [ProcessKey: AppIdentity] = [:]

  /// `responsible` is nil when the responsibility call is missing. `bundleInfo` reads an `.app`.
  public init(
    responsible: (@Sendable (Int32) -> Int32?)?,
    bundleInfo: @escaping @Sendable (String) -> (id: String, name: String)?
  ) {
    self.responsible = responsible
    self.bundleInfo = bundleInfo
  }

  public var quality: GroupingQuality { responsible == nil ? .limited : .full }

  public static func live() -> AppGrouper {
    typealias ResponsibleFor = @convention(c) (CInt) -> CInt
    // A private call, so it can be missing. Looked up in every loaded image (RTLD_DEFAULT).
    let symbol = dlsym(
      UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    let responsible = symbol.map { symbol -> @Sendable (Int32) -> Int32? in
      let call = unsafeBitCast(symbol, to: ResponsibleFor.self)
      return { pid in
        let owner = call(pid)
        return owner == -1 ? nil : owner
      }
    }
    return AppGrouper(
      responsible: responsible,
      bundleInfo: { appPath in
        guard let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier else {
          return nil
        }
        let name =
          bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
          ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return (id, name ?? FilePath(appPath).stem!)
      })
  }

  /// The outermost `*.app` directory on `path`, so a helper app inside an app resolves to it.
  public static func enclosingAppPath(_ path: String) -> String? {
    path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
  }

  /// The app of each process in `t`. Each `ProcessKey` is grouped once, and keys not in `t` leave
  /// the cache, so it holds only live processes. A reused PID has a new start time, so a new key.
  /// A PID that appears twice in `t` traps.
  public mutating func assign(_ t: ProcessTable) -> [ProcessKey: AppIdentity] {
    let table = Dictionary(uniqueKeysWithValues: t.samples.map { ($0.key.pid, $0) })
    var groups = [ProcessKey: AppIdentity](minimumCapacity: t.samples.count)
    for s in t.samples { groups[s.key] = cache[s.key] ?? group(s, table) }
    cache = groups
    return groups
  }

  /// Spec 6.5 order: the responsible process's app, then the process's own app, then the first app
  /// up to 5 parents up, following only processes in the table and stopping at launchd.
  private func group(_ s: ProcessSample, _ table: [Int32: ProcessSample]) -> AppIdentity {
    let owner = responsible?(s.key.pid).flatMap { table[$0] }  // often `s`, checked again below
    let chain = sequence(first: s) { $0.parent == 1 ? nil : table[$0.parent] }.prefix(6)
    let candidates = [owner].compactMap { $0 } + chain
    guard let app = candidates.lazy.compactMap({ Self.enclosingAppPath($0.path) }).first else {
      return AppIdentity(id: "proc:\(s.name)", name: s.name, bundlePath: nil)
    }
    let info = bundleInfo(app)
    return AppIdentity(
      id: info?.id ?? app, name: info?.name ?? FilePath(app).stem!, bundlePath: app)
  }
}
