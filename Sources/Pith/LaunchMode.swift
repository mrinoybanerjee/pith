/// How Pith was launched: the app, or one debug mode that runs and exits (spec 10, R128, R144).
enum LaunchMode: Equatable {
  case app(debugHooks: Bool)
  case snapshotJSON(seconds: Double)
  case benchmarkSweep(count: Int)
  case renderPanel
  case demo(Demo)

  enum Demo: String { case calm, tight }

  static let usage =
    "usage: Pith [--debug-hooks] | --snapshot-json <seconds> | --benchmark-sweep <n> | "
    + "--render-panel | --demo <calm | tight>"

  /// The mode that `arguments` asks for. Nil, a usage error, when a debug flag lacks its value or
  /// has a wrong one, or when `--render-panel` has one: it takes no directory (R144).
  static func parse(_ arguments: [String]) -> LaunchMode? {
    func value(_ flag: String) -> String? {
      let next = arguments.firstIndex(of: flag)! + 1
      return next < arguments.count ? arguments[next] : nil
    }
    if arguments.contains("--snapshot-json") {
      return value("--snapshot-json").flatMap(Double.init).flatMap {
        $0 >= 0 ? .snapshotJSON(seconds: $0) : nil
      }
    }
    if arguments.contains("--benchmark-sweep") {
      return value("--benchmark-sweep").flatMap { Int($0) }.flatMap {
        $0 > 0 ? .benchmarkSweep(count: $0) : nil
      }
    }
    if arguments.contains("--render-panel") {
      return value("--render-panel") == nil ? .renderPanel : nil
    }
    if arguments.contains("--demo") {
      return value("--demo").flatMap(Demo.init(rawValue:)).map { .demo($0) }
    }
    return .app(debugHooks: arguments.contains("--debug-hooks"))
  }
}
