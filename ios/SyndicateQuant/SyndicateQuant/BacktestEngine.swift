import Foundation

struct BacktestResult {
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
  var equityCurve: [Double] = []

  var roi: Double { staked > 0 ? profit / staked : 0 }
  var yieldPct: Double { staked > 0 ? profit / staked : 0 }
  var hitRate: Double { wins + losses > 0 ? Double(wins) / Double(wins + losses) : 0 }
  var brier: Double { bets > 0 ? brierSum / Double(bets) : 0 }
  var logLoss: Double { bets > 0 ? logLossSum / Double(bets) : 0 }
  var avgCLV: Double { clvCount > 0 ? clvSum / Double(clvCount) : 0 }

  var sharpe: Double {
    guard equityCurve.count > 1 else { return 0 }
    var returns: [Double] = []
    for i in 1..<equityCurve.count {
      returns.append(equityCurve[i] - equityCurve[i - 1])
    }
    guard !returns.isEmpty else { return 0 }
    let mean = returns.reduce(0, +) / Double(returns.count)
    let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
      / Double(returns.count)
    let sd = sqrt(variance)
    return sd > 0 ? mean / sd : 0
  }

  var perLeague: [String: SegmentStats] = [:]
  var perMarket: [String: SegmentStats] = [:]
}

struct SegmentStats {
  var matches = 0
  var bets = 0
  var wins = 0
  var losses = 0
  var pushes = 0
  var profit = 0.0
  var staked = 0.0
  var roi: Double { staked > 0 ? profit / staked : 0 }
  var hitRate: Double { wins + losses > 0 ? Double(wins) / Double(wins + losses) : 0 }
}

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

struct WalkForwardBacktester {
  func run(matches: [Match], histories: [String: [TeamRecord]]) -> BacktestResult {
    let engine = QuantEngine()
    var r = BacktestResult()
    var equity = 0.0
    var peak = 0.0
    var lossStreak = 0

    for match in matches.sorted(by: {
      ($0.start ?? .distantPast) < ($1.start ?? .distantPast)
    }) {
      guard let h = match.homeID, let a = match.awayID,
        let hFT = match.homeFT, let aFT = match.awayFT else { continue }

      r.matches += 1

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

      for s in signals {
        r.bets += 1
        r.staked += s.stake
        guard let actual = actualResult(match: match, signal: s) else { continue }

        let predicted = s.probability
        r.brierSum += (predicted - actual) * (predicted - actual)

        let eps = 1e-9
        let clamped = min(1 - eps, max(eps, predicted))
        let ll: Double = actual == 1 ? -log(clamped) : -log(1 - clamped)
        r.logLossSum += ll

        let pnl: Double
        if actual == 1 {
          r.wins += 1
          pnl = s.stake * (s.odds - 1)
          lossStreak = 0
        } else if actual == 0.5 {
          r.pushes += 1
          pnl = 0
        } else {
          r.losses += 1
          pnl = -s.stake
          lossStreak += 1
          r.maxLosingStreak = max(r.maxLosingStreak, lossStreak)
        }
        r.profit += pnl
        equity += pnl
        peak = max(peak, equity)
        r.maxDrawdown = max(r.maxDrawdown, peak - equity)
        r.equityCurve.append(equity)

        var l = r.perLeague[match.league] ?? SegmentStats()
        l.matches += 1; l.bets += 1; l.staked += s.stake; l.profit += pnl
        if actual == 1 { l.wins += 1 }
        else if actual == 0.5 { l.pushes += 1 }
        else { l.losses += 1 }
        r.perLeague[match.league] = l

        var m = r.perMarket[s.market] ?? SegmentStats()
        m.matches += 1; m.bets += 1; m.staked += s.stake; m.profit += pnl
        if actual == 1 { m.wins += 1 }
        else if actual == 0.5 { m.pushes += 1 }
        else { m.losses += 1 }
        r.perMarket[s.market] = m
      }
    }
    return r
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