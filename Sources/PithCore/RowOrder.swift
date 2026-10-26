/// The visible order of the app rows (spec 4.8): a value that moves within 2% never reorders them.
public enum RowOrder {
  /// The ids of `previous` that still exist keep their order, and new ids follow in `metric`
  /// order. Then a row moves above its neighbour while it is more than 2% larger. Returns the
  /// first `limit` rows.
  public static func stable(
    previous: [String], apps: [AppUsage], metric: Metric, limit: Int = 8
  ) -> [AppUsage] {
    let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
    let kept = Set(previous)
    let new = apps.filter { !kept.contains($0.id) }.sorted {
      value($0, metric) != value($1, metric) ? value($0, metric) > value($1, metric) : $0.id < $1.id
    }
    var rows = previous.compactMap { byID[$0] } + new
    var swapped = true
    while swapped {
      swapped = false
      for i in rows.indices.dropLast()
      where value(rows[i + 1], metric) > value(rows[i], metric) * 1.02 {
        rows.swapAt(i, i + 1)
        swapped = true
      }
    }
    return Array(rows.prefix(limit))
  }

  /// The ranking value. A CPU or disk rate that is unavailable ranks as 0.
  private static func value(_ app: AppUsage, _ metric: Metric) -> Double {
    switch metric {
    case .memory: Double(app.memory)
    case .cpu: app.cpu.value ?? 0
    case .disk: app.diskBytesPerSecond.value ?? 0
    }
  }
}
