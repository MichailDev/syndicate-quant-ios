import Foundation
import SwiftData

enum JournalService {
  /// Закрывает все открытые записи журнала, подтягивая результат матча и closing odds.
  @MainActor
  static func settleOpenEntries(
    context: ModelContext,
    client: SStatsClient
  ) async -> (closed: Int, failed: Int) {
    let descriptor = FetchDescriptor<JournalEntry>()
    guard let all = try? context.fetch(descriptor) else {
      return (0, 0)
    }
    let open = all.filter { $0.status == "OPEN" }
    var closed = 0
    var failed = 0

    for entry in open {
      guard let info = try? await client.gameInfo(entry.gameID) else {
        failed += 1
        continue
      }
      guard let data = info.object?["data"]?.object,
            let game = data["game"]?.object,
            let hFT = number(game, ["homeFTResult", "homeResult"]),
            let aFT = number(game, ["awayFTResult", "awayResult"])
      else {
        // Матч ещё не сыгран — не закрываем
        continue
      }

      let result = evaluateResult(entry: entry, home: hFT, away: aFT)
      entry.result = result
      entry.profit = computeProfit(
        result: result, odds: entry.odds, stake: entry.stake)

      // Closing odds из data.odds (если доступны)
      if let closingOdds = extractClosingOdds(data: data, entry: entry),
         closingOdds > 1 {
        entry.closingOdds = closingOdds
        entry.clv = entry.odds / closingOdds - 1
      }

      entry.status = "CLOSED"
      closed += 1

      // Пауза, чтобы не спровоцировать rate limit
      try? await Task.sleep(for: .milliseconds(120))
    }

    try? context.save()
    return (closed, failed)
  }

  // MARK: - Result evaluation

  private static func evaluateResult(
    entry: JournalEntry, home: Double, away: Double
  ) -> String {
    let sel = entry.selection.lowercased()
    if entry.market == "1X2" {
      let win: Bool
      if sel.contains("home") || sel == "1" {
        win = home > away
      } else if sel.contains("draw") || sel == "x" {
        win = home == away
      } else {
        win = away > home
      }
      return win ? "WIN" : "LOSS"
    }
    if entry.market == "GOALS" {
      guard let line = entry.line else { return "VOID" }
      let total = home + away
      let isOver = sel.contains("over") || sel.hasPrefix("o")
      // Push для целых линий
      if abs(line.rounded() - line) < 0.001,
         Double(Int(line)) == total {
        return "PUSH"
      }
      let hit = isOver ? total > line : total < line
      return hit ? "WIN" : "LOSS"
    }
    // CARDS / CORNERS: для settlement нужны данные stats — пока VOID
    // (в следующей итерации можно доработать через info.statistics)
    return "VOID"
  }

  private static func computeProfit(
    result: String, odds: Double, stake: Double
  ) -> Double {
    switch result {
    case "WIN": return stake * (odds - 1)
    case "LOSS": return -stake
    case "PUSH": return 0
    default: return 0
    }
  }

  // MARK: - Closing odds

  private static func extractClosingOdds(
    data: [String: JSONValue], entry: JournalEntry
  ) -> Double? {
    guard let oddsArr = data["odds"]?.array else { return nil }
    let targetMarket = entry.market
    let targetSelection = entry.selection.lowercased()
    let targetLine = entry.line

    for mv in oddsArr {
      guard let m = mv.object else { continue }
      let marketName = (m["marketName"]?.string ?? "").lowercased()
      let normalized = normalizeMarket(marketName)
      guard normalized == targetMarket else { continue }
      guard let prices = m["odds"]?.array else { continue }

      for pv in prices {
        guard let p = pv.object,
              let selName = p["name"]?.string?.lowercased(),
              let value = number(p, ["value", "odds", "price"]),
              value > 1
        else { continue }

        // Для GOALS/CARDS/CORNERS проверяем и линию
        if let line = targetLine {
          let hasLine = containsLine(selName, line: line)
          if !hasLine { continue }
        }

        // Проверяем selection
        if targetMarket == "1X2" {
          if !selName.contains(targetSelection) { continue }
        } else {
          // Over/Under
          let isOver = targetSelection.contains("over") || targetSelection.hasPrefix("o")
          let isUnder = targetSelection.contains("under") || targetSelection.hasPrefix("u")
          if isOver && !(selName.contains("over") || selName.hasPrefix("o")) { continue }
          if isUnder && !(selName.contains("under") || selName.hasPrefix("u")) { continue }
        }

        return value
      }
    }
    return nil
  }

  private static func normalizeMarket(_ s: String) -> String {
    if s.contains("corner") { return "CORNERS" }
    if s.contains("card") || s.contains("yellow") { return "CARDS" }
    if s.contains("goal") || s.contains("total")
        || s.contains("over") || s.contains("under") { return "GOALS" }
    if s.contains("1x2") || s.contains("winner") { return "1X2" }
    return ""
  }

  private static func containsLine(_ s: String, line: Double) -> Bool {
    let formats = [String(format: "%.1f", line), String(format: "%.2f", line)]
    for f in formats {
      if s.contains(f) { return true }
    }
    // Для целых линий: "2" матчит "over 2"
    if abs(line.rounded() - line) < 0.001 {
      if s.contains("\(Int(line))") { return true }
    }
    return false
  }

  private static func number(
    _ o: [String: JSONValue], _ keys: [String]
  ) -> Double? {
    for k in keys { if let n = o[k]?.number { return n } }
    return nil
  }
}