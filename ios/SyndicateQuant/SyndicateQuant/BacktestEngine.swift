import Foundation

// MARK: - Segment buckets

struct SegmentStats {
  var matches = 0
  var bets = 0
  var wins = 0
  var losses = 0
  var pushes = 0
  var profit = 0.0
  var staked = 0.0
  var oddsSum = 0.0

  var roi: Double { staked > 0 ? profit / staked : 0 }
  var hitRate: Double { wins + losses > 0 ? Double(wins) / Double(wins + losses) : 0 }
  var avgOdds: Double { bets > 0 ? oddsSum / Double(bets) : 0 }
  var expectancy: Double { bets > 0 ? profit / Double(bets) : 0 }
}

// MARK: - Full report

struct WalkForwardReport {
  var matches = 0
  var bets = 0
  var wins = 0
  var losses = 0
  var pushes = 0
  var profit = 0.0
  var staked = 0.0
  var maxDrawdown = 0.0
  var maxLosingStreak = 0

  var brierSum = 0.0
  var logLossSum = 0.0
  var clvSum = 0.0
  var clvCount = 0

  var grossWin = 0.0
  var grossLoss = 0.0
  var returnSum = 0.0
  var returnSumSq = 0.0
  var negativeReturnSumSq = 0.0
  var negativeReturnCount = 0
  var oddsSum = 0.0

  var equityCurve: [Double] = []

  // Разбивки
  var perLeague: [String: SegmentStats] = [:]
  var perMarket: [String: SegmentStats] = [:]
  var byEVBucket: [String: SegmentStats] = [:]
  var byClassification: [String: SegmentStats] = [:]
  var byOddsBand: [String: SegmentStats] = [:]
  var byWeek: [String: SegmentStats] = [:]

  // MARK: - Computed metrics

  var roi: Double { staked > 0 ? profit / staked : 0 }
  var yieldPct: Double { roi }
  var hitRate: Double { wins + losses > 0 ? Double(wins) / Double(wins + losses) : 0 }
  var brier: Double { bets > 0 ? brierSum / Double(bets) : 0 }
  var logLoss: Double { bets > 0 ? logLossSum / Double(bets) : 0 }
  var avgCLV: Double { clvCount > 0 ? clvSum / Double(clvCount) : 0 }
  var avgOdds: Double { bets > 0 ? oddsSum / Double(bets) : 0 }
  var expectancy: Double { bets > 0 ? profit / Double(bets) : 0 }

  var profitFactor: Double {
    grossLoss > 0 ? grossWin / grossLoss : (grossWin > 0 ? 99 : 0)
  }

  /// Sharpe: среднее / sd(returns) — без нормировки на длину (посмотреть в относительных величинах)
  var sharpe: Double {
    guard bets > 1 else { return 0 }
    let mean = returnSum / Double(bets)
    let variance = (returnSumSq / Double(bets)) - mean * mean
    let sd = variance > 0 ? sqrt(variance) : 0
    return sd > 0 ? mean / sd : 0
  }

  /// Sortino: среднее / sd(только отрицательных returns)
  var sortino: Double {
    guard negativeReturnCount > 0 else { return 0 }
    let mean = returnSum / Double(bets)
    let downVar = negativeReturnSumSq / Double(negativeReturnCount)
    let sd = downVar > 0 ? sqrt(downVar) : 0
    return sd > 0 ? mean / sd : 0
  }
}

// MARK: - Backtester

struct WalkForwardBacktester {

  func run(matches: [Match], histories: [String: [TeamRecord]]) -> WalkForwardReport {
    let engine = QuantEngine()
    var r = WalkForwardReport()
    var equity = 0.0
    var peak = 0.0
    var lossStreak = 0

    let cal = Calendar(identifier: .gregorian)

    for match in matches.sorted(by: {
      ($0.start ?? .distantPast) < ($1.start ?? .distantPast)
    }) {
      guard let h = match.homeID, let a = match.awayID,
            let hFT = match.homeFT, let aFT = match.awayFT
      else { continue }

      r.matches += 1

      // Walk-forward: только записи ДО даты матча
      let matchStart = match.start ?? .distantFuture
      let hs = (histories[h] ?? []).filter { ($0.date ?? .distantPast) < matchStart }
      let awayRecords = (histories[a] ?? []).filter {
        ($0.date ?? .distantPast) < matchStart
      }

      let oddsJSON = match.oddsJSON ?? .array([])
      let infoJSON: JSONValue = .object([
        "homeFTResult": .number(hFT),
        "awayFTResult": .number(aFT),
      ])

      let signals = engine.portfolio(
        engine.signals(
          match: match, info: infoJSON, oddsJSON: oddsJSON,
          homeHistory: hs, awayHistory: awayRecords))

      // Ключ недели (год + номер ISO-недели)
      let weekKey: String = {
        guard let d = match.start else { return "unknown" }
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        let y = c.yearForWeekOfYear ?? 0
        let w = c.weekOfYear ?? 0
        return String(format: "%04d-W%02d", y, w)
      }()

      for s in signals {
        r.bets += 1
        r.staked += s.stake
        r.oddsSum += s.odds

        guard let actual = actualResult(match: match, signal: s) else { continue }

        // Brier
        let predicted = s.probability
        r.brierSum += (predicted - actual) * (predicted - actual)

        // LogLoss
        let eps = 1e-9
        let clamped = min(1 - eps, max(eps, predicted))
        let ll: Double = actual == 1 ? -log(clamped) : -log(1 - clamped)
        r.logLossSum += ll

        let pnl: Double
        if actual == 1 {
          r.wins += 1
          pnl = s.stake * (s.odds - 1)
          r.grossWin += pnl
          lossStreak = 0
        } else if actual == 0.5 {
          r.pushes += 1
          pnl = 0
        } else {
          r.losses += 1
          pnl = -s.stake
          r.grossLoss += s.stake
          lossStreak += 1
          r.maxLosingStreak = max(r.maxLosingStreak, lossStreak)
        }

        r.profit += pnl
        equity += pnl
        peak = max(peak, equity)
        r.maxDrawdown = max(r.maxDrawdown, peak - equity)
        r.equityCurve.append(equity)

        // Returns для Sharpe/Sortino (нормированные на stake)
        let ret = s.stake > 0 ? pnl / s.stake : 0
        r.returnSum += ret
        r.returnSumSq += ret * ret
        if ret < 0 {
          r.negativeReturnSumSq += ret * ret
          r.negativeReturnCount += 1
        }

        // Сегментация
        accumulate(&r.perLeague, key: match.league,
                   actual: actual, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.perMarket, key: s.market,
                   actual: actual, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byEVBucket, key: evBucket(s.ev),
                   actual: actual, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byClassification, key: s.classification,
                   actual: actual, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byOddsBand, key: oddsBand(s.odds),
                   actual: actual, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byWeek, key: weekKey,
                   actual: actual, stake: s.stake, odds: s.odds, pnl: pnl)
      }
    }
    return r
  }

  // MARK: - Helpers

  private func accumulate(
    _ dict: inout [String: SegmentStats],
    key: String,
    actual: Double,
    stake: Double,
    odds: Double,
    pnl: Double
  ) {
    var seg = dict[key] ?? SegmentStats()
    seg.matches += 1
    seg.bets += 1
    seg.staked += stake
    seg.oddsSum += odds
    seg.profit += pnl
    if actual == 1 { seg.wins += 1 }
    else if actual == 0.5 { seg.pushes += 1 }
    else { seg.losses += 1 }
    dict[key] = seg
  }

  private func evBucket(_ ev: Double) -> String {
    if ev < 0.03 { return "EV <3%" }
    if ev < 0.05 { return "EV 3-5%" }
    if ev < 0.07 { return "EV 5-7%" }
    return "EV ≥7%"
  }

  private func oddsBand(_ odds: Double) -> String {
    if odds < 2.0 { return "Odds 1.5–2.0" }
    if odds < 3.0 { return "Odds 2.0–3.0" }
    if odds < 5.0 { return "Odds 3.0–5.0" }
    return "Odds 5.0+"
  }

  private func actualResult(match: Match, signal: BetSignal) -> Double? {
    guard let h = match.homeFT, let a = match.awayFT else { return nil }
    if signal.market == "1X2" {
      let sel = signal.selection.lowercased()
      let win: Bool
      if sel.contains("home") || sel == "1" { win = h > a }
      else if sel.contains("draw") || sel == "x" { win = h == a }
      else { win = a > h }
      return win ? 1 : 0
    }
    guard let line = signal.line else { return nil }
    let total = h + a
    let over = signal.selection.lowercased().contains("over")
      || signal.selection.lowercased().hasPrefix("o")
    if abs(line.rounded() - line) < 0.001 && Double(Int(line)) == total { return 0.5 }
    return over ? (total > line ? 1 : 0) : (total < line ? 1 : 0)
  }
}

// MARK: - CalibrationEngine (оставлен для совместимости)

struct CalibrationEngine {
  static func brier(_ samples: [CalibrationSample]) -> Double {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0) { $0 + ($1.predicted - $1.actual) * ($1.predicted - $1.actual) }
      / Double(samples.count)
  }
  static func bias(_ samples: [CalibrationSample]) -> Double {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0) { $0 + ($1.predicted - $1.actual) } / Double(samples.count)
  }
}