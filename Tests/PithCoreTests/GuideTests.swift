import Foundation
import PithTestSupport
import Testing

@testable import PithCore

private func entry(_ match: GuideMatch, _ title: String) -> GuideEntry {
  GuideEntry(
    match: match, title: title, explanation: "e", kind: .app, quittable: true, source: nil)
}

@Test func bundledGuideIsValid() throws {
  let g = try Guide.bundled()
  #expect(g.entries.count >= 20)
  #expect(Set(g.entries.map(\.match)).count == g.entries.count)
  #expect(g.entries.filter { $0.kind == .system }.allSatisfy { !$0.quittable && $0.source != nil })
  #expect(g.entries.filter { $0.kind == .helper }.allSatisfy { !$0.quittable })  // R84
}

/// The app's loader (`bundled(in: .main)`) reads only the bundle it is given. Every other guide
/// test reads the source folder through the same loader.
@Test func bundleWithoutGuideIsAMissingResource() throws {
  let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let bundle = try #require(Bundle(url: dir))
  #expect(throws: GuideError.missingResource("guide.json")) { try Guide.bundled(in: bundle) }
}

@Test func guideCoversCommonProcesses() throws {
  let g = try Guide.bundled()
  #expect(g.entries.count >= 150)
  for name in [
    "mds", "mdworker_shared", "WindowServer", "kernel_task", "backupd", "photoanalysisd",
    "mediaanalysisd", "softwareupdated", "cloudd", "bird", "fileproviderd", "trustd", "syspolicyd",
    "coreaudiod", "bluetoothd", "Spotlight", "Dock", "ControlCenter", "loginwindow", "sharingd",
  ] {
    #expect(g.entry(name: name, bundleID: nil, path: nil) != nil, "missing \(name)")
  }
}

@Test func explanationsArePlainAndShort() throws {
  for e in try Guide.bundled().entries {
    #expect(e.explanation.count <= 160 && !e.explanation.contains("daemon"))
  }
}

/// M9: the process name is at most 16 bytes (`pbsi_comm`, and `top` for other users' processes),
/// so a longer name entry would never match.
@Test func nameMatchesFitSixteenBytes() throws {
  for case .name(let name) in try Guide.bundled().entries.map(\.match) {
    #expect(name.utf8.count <= 16, "\(name)")
  }
}

/// R83: a system entry cites a man page, an Apple support page or the file that macOS runs.
@Test func systemEntriesCiteAManPageASupportPageOrASystemFile() throws {
  let prefixes = ["man:", "https://support.apple.com/", "file:/System/", "file:/usr/"]
  for e in try Guide.bundled().entries where e.kind == .system {
    #expect(prefixes.contains { e.source?.hasPrefix($0) == true }, "\(e.title): \(e.source ?? "")")
  }
}

@Test func noExplanationSaysDaemonInAnyCase() throws {
  for e in try Guide.bundled().entries {
    #expect(!e.explanation.lowercased().contains("daemon"), "\(e.title)")
  }
}

@Test func entryWithTwoMatchKeysIsRejected() {
  let bad =
    #"[{"match":{"name":"a","bundleID":"b"},"title":"t","explanation":"e","kind":"app","quittable":true}]"#
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode([GuideEntry].self, from: Data(bad.utf8))
  }
}

@Test func entryWithNoMatchKeyIsRejected() {
  let bad = #"[{"match":{},"title":"t","explanation":"e","kind":"app","quittable":true}]"#
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode([GuideEntry].self, from: Data(bad.utf8))
  }
}

@Test(arguments: [
  #"{"name":"a","bundleId":"b"}"#,  // a known key beside a misspelled one
  #"{"bundleId":"b"}"#,  // a misspelled key alone
  #"{"name":""}"#,
  #"{"helperPattern":""}"#,  // would match every process
])
func invalidMatchIsRejected(json: String) {
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(GuideMatch.self, from: Data(json.utf8))
  }
}

@Test func duplicateMatchIsReportedAsAnError() {
  let entry = #"{"match":{"name":"a"},"title":"t","explanation":"e","kind":"app","quittable":true}"#
  #expect(throws: GuideError.duplicateMatch(.name("a"))) {
    try Guide.decode(Data("[\(entry),\(entry)]".utf8))
  }
}

@Test func matchEncodesAsOneKeyObject() throws {
  let all: [GuideMatch] = [
    .name("a"), .bundleID("b"), .pathPrefix("/c"), .helperPattern("d"),
  ]
  let json = try JSONEncoder().encode(all)
  #expect(
    String(decoding: json, as: UTF8.self)
      == #"[{"name":"a"},{"bundleID":"b"},{"pathPrefix":"\/c"},{"helperPattern":"d"}]"#)
  #expect(try JSONDecoder().decode([GuideMatch].self, from: json) == all)
}

@Test func matching() throws {
  let g = try Guide.bundled()
  #expect(g.entry(name: "mds_stores", bundleID: nil, path: nil)?.title == "Spotlight indexing")
  #expect(g.helperLabel(processName: "Google Chrome Helper (Renderer)") == "Tabs and sites")
  #expect(g.helperLabel(processName: "Slack Helper (GPU)") == "Graphics")
  #expect(g.entry(name: "unknownd", bundleID: nil, path: nil) == nil)
}

@Test func entryPrecedenceIsBundleIDThenNameThenLongestPath() {
  let g = Guide(entries: [
    entry(.name("Foo"), "by name"),
    entry(.bundleID("com.example.foo"), "by bundle ID"),
    entry(.pathPrefix("/Applications"), "short prefix"),
    entry(.pathPrefix("/Applications/Foo.app"), "long prefix"),
  ])
  let path = "/Applications/Foo.app/Contents/MacOS/Foo"
  #expect(g.entry(name: "Foo", bundleID: "com.example.foo", path: path)?.title == "by bundle ID")
  #expect(g.entry(name: "Foo", bundleID: "com.example.other", path: path)?.title == "by name")
  #expect(g.entry(name: "Bar", bundleID: nil, path: path)?.title == "long prefix")
  #expect(
    g.entry(name: "Bar", bundleID: nil, path: "/Applications/Baz.app")?.title == "short prefix")
  #expect(g.entry(name: "Bar", bundleID: nil, path: "/opt/bar") == nil)
  #expect(g.entry(name: "Bar", bundleID: nil, path: nil) == nil)
}

@Test func helperPatternsNeverMatchAnEntry() {
  let g = Guide(entries: [entry(.helperPattern("Helper"), "Helpers")])
  #expect(g.entry(name: "Helper", bundleID: "Helper", path: "Helper") == nil)
}

@Test func helperLabelUsesTheLongestMatchingSuffix() {
  // "(Renderer)" comes first and is a suffix of "Helper (Renderer)", so only the length can pick
  // the winner.
  let g = Guide(entries: [
    entry(.helperPattern("Helper"), "Helpers"),
    entry(.helperPattern("(Renderer)"), "Renderers"),
    entry(.helperPattern("Helper (Renderer)"), "Tabs and sites"),
    entry(.name("Slack Helper (GPU)"), "not a pattern"),
  ])
  #expect(g.helperLabel(processName: "Slack Helper (Renderer)") == "Tabs and sites")
  #expect(g.helperLabel(processName: "Slack Worker (Renderer)") == "Renderers")
  #expect(g.helperLabel(processName: "Slack Helper") == "Helpers")
  #expect(g.helperLabel(processName: "Slack Helper (GPU)") == nil)
  #expect(g.helperLabel(processName: "Helper Tool") == nil)
}

@Test func emptyGuideMatchesNothing() {
  #expect(Guide.empty.entries.isEmpty)
  #expect(Guide.empty.entry(name: "mds_stores", bundleID: nil, path: nil) == nil)
  #expect(Guide.empty.helperLabel(processName: "Slack Helper") == nil)
}
