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
  /// Each new key's grouping and the path it was grouped by. It is kept once the next table has the
  /// same path, as a new exec can briefly report its old executable's path (R175).
  private var unconfirmed: [ExecutableKey: (path: String, app: AppIdentity)] = [:]

  /// What an `.app` says about itself: its bundle ID, its name and its main executable's file name.
  public typealias BundleInfo = (bundleID: String?, name: String, executable: String?)

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
    return AppGrouper(responsible: responsible, bundleInfo: readBundle)
  }

  /// What the `.app` at `appPath` says about itself in its `Contents/Info.plist`, or nil when that
  /// cannot be read, as in the middle of an update. `Bundle(path:)` would keep a bundle that it
  /// could not read for the process's life. A bundle with no bundle ID is still read (R175).
  static func readBundle(_ appPath: String) -> BundleInfo? {
    let url = URL(fileURLWithPath: appPath).appending(path: "Contents/Info.plist")
    guard let plist = NSDictionary(contentsOf: url) else { return nil }
    let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
    return (
      plist["CFBundleIdentifier"] as? String, name ?? FilePath(appPath).stem!,
      plist["CFBundleExecutable"] as? String
    )
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

  /// The app of each process in `t`. Each `ExecutableKey` is grouped once, and kept once two tables
  /// in a row have its path (R175); keys not in `t` leave the cache, so it holds only live
  /// processes. A reused PID has a new start time and an
  /// `exec` a new ID version, so either is a new key. A PID that appears twice in `t` traps. A
  /// grouping that missed a process, or could not read a bundle, is not kept, as the next table
  /// may hold the process and the next read may succeed (R157 and R168).
  ///
  /// Then a Chromium clone (the only identity with a bundle ID and no path) takes the identity of
  /// the one installation with its bundle ID that holds its own child processes, whose parent
  /// unique ID is the clone's; with none or several, it stays apart (R156). That is decided once
  /// for each clone identity, from the children of all its processes. Then every process of the
  /// identity moves with it, such as an unbundled child of the clone (R162). That depends on the
  /// whole table, so it runs on every call, and the cache keeps the clone itself.
  public mutating func assign(_ t: ProcessTable) -> [ProcessKey: AppIdentity] {
    let table = Dictionary(uniqueKeysWithValues: t.samples.map { ($0.key.pid, $0) })
    var groups = [ProcessKey: AppIdentity](minimumCapacity: t.samples.count)
    var live = [ExecutableKey: AppIdentity](minimumCapacity: t.samples.count)
    var seenOnce: [ExecutableKey: (path: String, app: AppIdentity)] = [:]
    for s in t.samples {
      let key = s.executableKey
      if let app = cache[key] ?? unconfirmed[key].flatMap({ $0.path == s.path ? $0.app : nil }) {
        groups[s.key] = app
        live[key] = app
      } else {
        let (app, complete) = group(s, table)
        groups[s.key] = app
        if complete { seenOnce[key] = (s.path, app) }
      }
    }
    cache = live
    unconfirmed = seenOnce
    let clones = Dictionary(
      grouping: t.samples.filter {
        groups[$0.key]!.bundlePath == nil && groups[$0.key]!.bundleID != nil
      }, by: { groups[$0.key]!.id })
    guard !clones.isEmpty else { return groups }
    let assigned = groups
    let children = Dictionary(grouping: t.samples, by: \.parentUniqueID)
    for members in clones.values {
      let bundleID = assigned[members[0].key]!.bundleID
      let homes = Dictionary(
        members.flatMap { children[$0.uniqueID] ?? [] }.map { assigned[$0.key]! }
          .filter { $0.bundlePath != nil && $0.bundleID == bundleID }.map { ($0.id, $0) }
      ) { first, _ in first }
      if homes.count == 1 { for member in members { groups[member.key] = homes.first!.value } }
    }
    return groups
  }

  /// Spec 6.5, in order (the first that names an app wins):
  /// 1. The responsible process's app: its innermost, as for any app responsible for itself.
  ///    Skipped when that PID started after this process (reused) or the app is a Chromium clone,
  ///    so Chrome's helpers keep the real app path from step 2.
  /// 2. The process's own app: the innermost when it is responsible for itself, else the outermost.
  /// 3. The outermost app of up to 5 parents, following only processes in the table and stopping
  ///    at launchd. An edge holds only while the parent's unique ID is the one that the child
  ///    recorded, as a reused PID has a new one (R151).
  /// Otherwise the process stands alone, named by its file name.
  ///
  /// `complete` is false when the answer depended on a process that is not in the table: the
  /// responsible owner, or the parent PID where the walk stopped without an app (R157). It is
  /// also false when an app's bundle could not be read, as an app in the middle of an update
  /// cannot (R168).
  private func group(_ s: ProcessSample, _ table: [Int32: ProcessSample]) -> (
    app: AppIdentity, complete: Bool
  ) {
    let responsiblePID = responsible?(s.key.pid)
    let owner = responsiblePID.flatMap { table[$0] }
    if let owner, owner.key.startTime <= s.key.startTime,
      let app = Self.appPaths(owner.path).last, !Self.isCodeSignClone(app)
    {
      let (found, readable) = identity(app)
      return (found!, readable)
    }
    let ownerSeen = responsiblePID == nil || owner != nil
    let own = Self.appPaths(s.path)
    let parents = Array(
      sequence(first: s) { child in
        child.parent == 1
          ? nil : table[child.parent].flatMap { $0.uniqueID == child.parentUniqueID ? $0 : nil }
      }.dropFirst().prefix(5))
    let apps =
      [responsiblePID == s.key.pid ? own.last : own.first]
      + parents.map { Self.enclosingAppPath($0.path) }
    var readable = true
    for case let app? in apps {
      let (found, read) = identity(app)
      readable = readable && read
      if let found { return (found, ownerSeen && readable) }
    }
    let last = parents.last ?? s
    let walked = parents.count == 5 || last.parent == 1 || table[last.parent] != nil
    return (
      AppIdentity(
        id: "proc:\(s.fileName)", name: s.fileName, bundlePath: nil, bundleID: nil, executable: nil),
      ownerSeen && walked && readable
    )
  }

  /// An app's id is its path. A Chromium clone runs from a temporary path, so it has no path and
  /// its id is "clone:" and its `.app.bundle` path until `assign` joins it to its installation.
  /// So clones of two installations stay apart. A clone whose bundle can't be read is no app.
  /// `readable` is false when `bundleInfo` failed (R168).
  private func identity(_ app: String) -> (identity: AppIdentity?, readable: Bool) {
    let info = bundleInfo(app)
    guard !Self.isCodeSignClone(app) else {
      return (
        info.flatMap { i in
          i.bundleID.map {
            AppIdentity(
              id: "clone:\(app)", name: i.name, bundlePath: nil, bundleID: $0,
              executable: i.executable)
          }
        }, info != nil
      )
    }
    return (
      AppIdentity(
        id: app, name: info?.name ?? FilePath(app).stem!, bundlePath: app, bundleID: info?.bundleID,
        executable: info?.executable),
      info != nil
    )
  }
}
