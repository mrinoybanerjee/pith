// Portions adapted from Stats (https://github.com/exelban/stats), MIT License,
// Copyright (c) 2020 Serhiy Mytrovtsiy. Source: Modules/RAM/readers.swift L210-L227 at v3.0.22 (1282cd5).

import Darwin
import Foundation
import System

/// Maps each process to the app it belongs to (spec 6.5), so helpers count toward their app.
public struct AppGrouper: Sendable {
  private let responsible: (@Sendable (Int32) -> Int32?)?
  private let bundleInfo: @Sendable (String) -> BundleInfo?
  private var cache: [ExecutableKey: AppIdentity] = [:]

  /// What an `.app` says about itself: its bundle ID, its name and its main executable's file name.
  public typealias BundleInfo = (bundleID: String, name: String, executable: String?)

  /// `responsible` is nil when the responsibility call is missing. `bundleInfo` reads an `.app`.
  public init(
    responsible: (@Sendable (Int32) -> Int32?)?,
    bundleInfo: @escaping @Sendable (String) -> BundleInfo?
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
        return (
          id, name ?? FilePath(appPath).stem!,
          bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        )
      })
  }

  /// Whether `path` lies in a Chromium code-sign clone: a `code_sign_clone.<suffix>` folder, then
  /// an `<App>.app.bundle` inside it, where a Chromium browser runs its main process (R125). The
  /// one rule for a clone, here and when Quit picks the row's own app.
  public static func isCodeSignClone(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    return zip(parts, parts.dropFirst()).contains { folder, app in
      folder.count > "code_sign_clone.".count && folder.hasPrefix("code_sign_clone.")
        && app.count > ".app.bundle".count && app.hasSuffix(".app.bundle")
    }
  }

  /// The outermost `*.app` directory on `path`, so a helper app inside an app resolves to it.
  public static func enclosingAppPath(_ path: String) -> String? { appPaths(path).first }

  /// Every app directory on `path`, outermost first: each `*.app`, and the `*.app.bundle` that a
  /// Chromium browser runs its main process from (a temporary code-sign clone).
  private static func appPaths(_ path: String) -> [String] {
    path.split(separator: "/")
      .filter { c in [".app", ".app.bundle"].contains { c.count > $0.count && c.hasSuffix($0) } }
      .map { String(path[..<$0.endIndex]) }
  }

  /// The app of each process in `t`. Each `ExecutableKey` is grouped once, and keys not in `t`
  /// leave the cache, so it holds only live processes. A reused PID has a new start time and an
  /// `exec` a new ID version, so either is a new key. A PID that appears twice in `t` traps.
  ///
  /// Then a Chromium clone (the only identity with a bundle ID and no path) takes the identity of
  /// the one installation in `t` with its bundle ID; with none or several, it stays apart. That
  /// depends on the whole table, so it runs on every call, and the cache keeps the clone itself.
  public mutating func assign(_ t: ProcessTable) -> [ProcessKey: AppIdentity] {
    let table = Dictionary(uniqueKeysWithValues: t.samples.map { ($0.key.pid, $0) })
    var groups = [ProcessKey: AppIdentity](minimumCapacity: t.samples.count)
    var live = [ExecutableKey: AppIdentity](minimumCapacity: t.samples.count)
    for s in t.samples {
      let app = cache[s.executableKey] ?? group(s, table)
      groups[s.key] = app
      live[s.executableKey] = app
    }
    cache = live
    let clones = groups.filter { $0.value.bundlePath == nil && $0.value.bundleID != nil }
    guard !clones.isEmpty else { return groups }
    let cloneIDs = Set(clones.values.map(\.bundleID))
    var installations: [String?: [String: AppIdentity]] = [:]  // by bundle ID, then by id
    for app in groups.values where app.bundlePath != nil && cloneIDs.contains(app.bundleID) {
      installations[app.bundleID, default: [:]][app.id] = app
    }
    for (key, clone) in clones {
      if let only = installations[clone.bundleID], only.count == 1 {
        groups[key] = only.first!.value
      }
    }
    return groups
  }

  /// Spec 6.5, in order (the first that names an app wins):
  /// 1. The responsible process's app: its innermost, as for any app responsible for itself.
  ///    Skipped when that PID started after this process (reused) or the app is a Chromium clone,
  ///    so Chrome's helpers keep the real app path from step 2.
  /// 2. The process's own app: the innermost when it is responsible for itself, else the outermost.
  /// 3. The outermost app of up to 5 parents, following only processes in the table and stopping
  ///    at launchd.
  /// Otherwise the process stands alone, named by its file name.
  private func group(_ s: ProcessSample, _ table: [Int32: ProcessSample]) -> AppIdentity {
    let responsiblePID = responsible?(s.key.pid)
    if let owner = responsiblePID.flatMap({ table[$0] }), owner.key.startTime <= s.key.startTime,
      let app = Self.appPaths(owner.path).last, !Self.isCodeSignClone(app)
    {
      return identity(app)!
    }
    let own = Self.appPaths(s.path)
    let parents = sequence(first: s) { $0.parent == 1 ? nil : table[$0.parent] }.dropFirst()
    let apps =
      [responsiblePID == s.key.pid ? own.last : own.first]
      + parents.prefix(5).map { Self.enclosingAppPath($0.path) }
    for case let app? in apps { if let found = identity(app) { return found } }
    return AppIdentity(
      id: "proc:\(s.fileName)", name: s.fileName, bundlePath: nil, bundleID: nil, executable: nil)
  }

  /// An app's id is its path. A Chromium clone runs from a temporary path, so it has no path and
  /// its id is "clone:" and its `.app.bundle` path until `assign` joins it to its installation.
  /// So clones of two installations stay apart. A clone whose bundle can't be read is no app.
  private func identity(_ app: String) -> AppIdentity? {
    let info = bundleInfo(app)
    guard !Self.isCodeSignClone(app) else {
      return info.map {
        AppIdentity(
          id: "clone:\(app)", name: $0.name, bundlePath: nil, bundleID: $0.bundleID,
          executable: $0.executable)
      }
    }
    return AppIdentity(
      id: app, name: info?.name ?? FilePath(app).stem!, bundlePath: app, bundleID: info?.bundleID,
      executable: info?.executable)
  }
}
