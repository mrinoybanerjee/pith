import Foundation
import Testing

@testable import Pith

/// What a stand-in lid hold did: the flag clears that Pith made, and the `ended` calls.
@MainActor private final class Counts {
  var clears = 0
  var ends = 0
}

/// A lid hold whose copy is a shell that logs "start <pid>", reads its input to the end, as
/// `--hold-lid` does, then logs "end <pid>". It never sets the real flag.
@MainActor private func standIn(_ counts: Counts) -> (hold: LidHold, log: URL) {
  let log = FileManager.default.temporaryDirectory.appending(path: "pith.tests.\(UUID()).log")
  let hold = LidHold.process(
    URL(fileURLWithPath: "/bin/sh"),
    arguments: [
      "-c", "echo start $$ >> '\(log.path)'; cat > /dev/null; echo end $$ >> '\(log.path)'",
    ],
    hasLid: true, clear: { counts.clears += 1 })
  return (hold, log)
}

/// The log's lines, with each PID replaced by its copy's letter: "start A", "end A", "start B".
private func lines(_ log: URL) -> [String] {
  let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
  var letters: [Substring: String] = [:]
  return lines.map { line in
    let pid = line.split(separator: " ")[1]
    let letter = letters[pid, default: ["A", "B", "C"][letters.count]]
    letters[pid] = letter
    return "\(line.split(separator: " ")[0]) \(letter)"
  }
}

/// The PID of the copy that logged `start` at `index`.
private func pid(_ log: URL, _ index: Int) -> pid_t {
  let starts = try! String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    .filter { $0.hasPrefix("start") }
  return pid_t(starts[index].split(separator: " ")[1])!
}

private func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// Waits up to 2 s for `condition`, letting the main actor run.
@MainActor private func within2s(_ condition: () -> Bool) async throws -> Bool {
  for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  return condition()
}

/// Awake spec 4.2: `stop` ends the copy at the end of its input, and Pith clears the flag when it
/// exits, with no `ended`. A child that Pith starts after the copy does not keep its input open.
@MainActor @Test func stopEndsTheCopyAndPithClearsOnItsExit() async throws {
  let counts = Counts()
  let (hold, log) = standIn(counts)
  defer { try? FileManager.default.removeItem(at: log) }
  hold.start { counts.ends += 1 }
  #expect(try await within2s { lines(log) == ["start A"] })
  let later = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
  defer { later.terminate() }
  hold.stop()
  #expect(try await within2s { lines(log) == ["start A", "end A"] && counts.clears == 1 })
  #expect(counts.ends == 0)
}

/// Awake spec 4.2: a stop before the copy has run, and a start right after, cannot leave the flag
/// set nor have the old copy clear the new hold: the new copy starts only once the old one exited.
@MainActor @Test func aQuickRetickWaitsForTheOldCopy() async throws {
  let counts = Counts()
  let (hold, log) = standIn(counts)
  defer { try? FileManager.default.removeItem(at: log) }
  hold.start { counts.ends += 1 }
  hold.stop()
  hold.start { counts.ends += 1 }
  #expect(try await within2s { lines(log) == ["start A", "end A", "start B"] })
  #expect(counts.clears == 1)
  hold.stop()
  #expect(try await within2s { lines(log).last == "end B" && counts.clears == 2 })
  #expect(counts.ends == 0)
}

/// Awake spec 4.2: a copy that dies makes Pith clear the flag and call `ended`, once. One that
/// dies just before `stop` is cleared once, with no `ended`.
@MainActor @Test func aCopyThatDiesIsCleared() async throws {
  let counts = Counts()
  let (hold, log) = standIn(counts)
  defer { try? FileManager.default.removeItem(at: log) }
  hold.start { counts.ends += 1 }
  #expect(try await within2s { lines(log) == ["start A"] })
  kill(pid(log, 0), SIGKILL)
  #expect(try await within2s { counts.ends == 1 })
  #expect(counts.clears == 1)

  hold.start { counts.ends += 1 }
  #expect(try await within2s { lines(log).last == "start B" })
  let second = pid(log, 1)
  kill(second, SIGKILL)
  // A busy wait holds the main actor, so Pith hears of the exit only after `stop`.
  for _ in 0..<2000 where isRunning(second) { usleep(1000) }
  #expect(!isRunning(second))
  hold.stop()
  #expect(try await within2s { counts.clears == 2 })
  #expect(counts.ends == 1)
}
