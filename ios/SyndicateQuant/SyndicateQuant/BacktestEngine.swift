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

// MARK: - BetRecord (Волна G, G8)

struct BetRecord: Codable, Hashable {
  var probability: Double
  var probabilityLow: Double
  var probabilityHigh: Double
  var ev: Double
  var actual: Double
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

  var perLeague: [String: SegmentStats] = [:]
  var perMarket: [String: SegmentStats] = [:]
  var byEVBucket: [String: SegmentStats] = [:]
  var byClassification: [String: SegmentStats] = [:]
  var byOddsBand: [String: SegmentStats] = [:]
  var byWeek: [String: SegmentStats] = [:]

  var betRecords: [BetRecord] = []

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
  var sharpe: Double {
    guard bets > 1 else { return 0 }
    let mean = returnSum / Double(bets)
    let variance = (returnSumSq / Double(bets)) - mean * mean
    let sd = variance > 0 ? sqrt(variance) : 0
    return sd > 0 ? mean / sd : 0
  }
  var sortino: Double {
    guard negativeReturnCount > 0 else { return 0 }
    let mean = returnSum / Double(bets)
    let downVar = negativeReturnSumSq / Double(negativeReturnCount)
    let sd = downVar > 0 ? sqrt(downVar) : 0
    return sd > 0 ? mean / sd : 0
  }
}

// MARK: - Backtester
//
// [7.25] ВАЖНО про углы и карточки:
//   Для того, чтобы walk-forward смог settle-ить CORNERS/CARDS, каждый Match
//   должен иметь заполненные `homeCorners / awayCorners / homeYellows / awayYellows`
//   (и опционально `homeReds / awayReds`). Это делает BacktestService,
//   догружая /Games/{id} для завершённых матчей. Если поля nil —
//   сигнал будет создан, но settle вернёт nil и ставка не попадёт в отчёт.
//
//   Котировки углов (marketId=45) и карточек (marketId=80) приходят из
//   /Odds/{id}. BacktestService объединяет их с /Games/{id} в Match.oddsJSON
//   перед вызовом run(...).

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

      // fullOdds передаётся пустым: предполагается, что BacktestService уже
      // вложил углы/карточки в oddsJSON (комбинированная структура).
      // parseQuotes умеет читать оба ключа: "data" (от /Games/{id})
      // и "bookmakers" (от /Odds/{id}) — см. Models.swift после патча.
      let signals = engine.portfolio(
        engine.signals(
          match: match, info: infoJSON, oddsJSON: oddsJSON,
          homeHistory: hs, awayHistory: awayRecords))

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

        guard let outcome = settle(match: match, signal: s) else { continue }

        let actualVal = outcome.probabilityValue
        let predicted = s.probability
        r.brierSum += (predicted - actualVal) * (predicted - actualVal)
        r.logLossSum += QuantMath.logLoss(predicted: predicted, actual: actualVal)

        r.betRecords.append(BetRecord(
          probability: predicted,
          probabilityLow: s.probabilityLow,
          probabilityHigh: s.probabilityHigh,
          ev: s.ev,
          actual: actualVal))

        let pnlMultiplier = outcome.pnlMultiplier(odds: s.odds)
        let pnl = s.stake * pnlMultiplier

        switch outcome {
        case .win:
          r.wins += 1
          r.grossWin += pnl
          lossStreak = 0
        case .halfWin:
          r.wins += 1
          r.grossWin += pnl
          lossStreak = 0
        case .push:
          r.pushes += 1
          lossStreak = 0
        case .halfLoss:
          r.losses += 1
          r.grossLoss += abs(pnl)
          lossStreak += 1
          r.maxLosingStreak = max(r.maxLosingStreak, lossStreak)
        case .loss:
          r.losses += 1
          r.grossLoss += abs(pnl)
          lossStreak += 1
          r.maxLosingStreak = max(r.maxLosingStreak, lossStreak)
        case .void:
          break
        }

        r.profit += pnl
        equity += pnl
        peak = max(peak, equity)
        r.maxDrawdown = max(r.maxDrawdown, peak - equity)
        r.equityCurve.append(equity)

        let ret = s.stake > 0 ? pnl / s.stake : 0
        r.returnSum += ret
        r.returnSumSq += ret * ret
        if ret < 0 {
          r.negativeReturnSumSq += ret * ret
          r.negativeReturnCount += 1
        }

        accumulate(&r.perLeague, key: match.league,
                   outcome: outcome, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.perMarket, key: s.market,
                   outcome: outcome, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byEVBucket, key: evBucket(s.ev),
                   outcome: outcome, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byClassification, key: s.classification,
                   outcome: outcome, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byOddsBand, key: oddsBand(s.odds),
                   outcome: outcome, stake: s.stake, odds: s.odds, pnl: pnl)
        accumulate(&r.byWeek, key: weekKey,
                   outcome: outcome, stake: s.stake, odds: s.odds, pnl: pnl)
      }
    }
    return r
  }

  // MARK: - Helpers

  private func accumulate(
    _ dict: inout [String: SegmentStats],
    key: String,
    outcome: AsianOutcome,
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
    switch outcome {
    case .win, .halfWin: seg.wins += 1
    case .push: seg.pushes += 1
    case .loss, .halfLoss: seg.losses += 1
    case .void: break
    }
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

  // [7.23] settle расширен на 4 рынка.
  // Для углов и карточек используем total = свои + чужие (либо карточки + красные).
  // Если у Match не заполнены corners/yellows/reds — возвращаем nil,
  // и ставка не попадёт в отчёт (без падения).
  private func settle(match: Match, signal: BetSignal) -> AsianOutcome? {
    switch signal.market {

    // [7.24] 1X2 сохранён: старые записи в снапшотах могут иметь market="1X2".
    // Новые сигналы по 1X2 не создаются (QuantEngine), но если что-то попало —
    // settlement работает корректно.
    case "1X2":
      guard let h = match.homeFT, let a = match.awayFT else { return nil }
      let sel = signal.selection.lowercased()
      let win: Bool
      if sel.contains("home") || sel == "1" { win = h > a }
      else if sel.contains("draw") || sel == "x" { win = h == a }
      else { win = a > h }
      return win ? .win : .loss

    case "GOALS":
      guard let line = signal.line,
            let h = match.homeFT, let a = match.awayFT else { return nil }
      let total = Int(h + a)
      return QuantMath.settleAsianTotal(
        total: total, line: line, isOver: isOverSignal(signal))

    case "CORNERS":
      guard let line = signal.line,
            let hc = match.homeCorners, let ac = match.awayCorners
      else { return nil }
      let total = hc + ac
      return QuantMath.settleAsianTotal(
        total: total, line: line, isOver: isOverSignal(signal))

    case "CARDS":
      guard let line = signal.line,
            let hy = match.homeYellows, let ay = match.awayYellows
      else { return nil }
      let hr = match.homeReds ?? 0
      let ar = match.awayReds ?? 0
      let total = hy + ay + hr + ar
      return QuantMath.settleAsianTotal(
        total: total, line: line, isOver: isOverSignal(signal))

    default:
      return nil
    }
  }

  private func isOverSignal(_ signal: BetSignal) -> Bool {
    let s = signal.selection.lowercased()
    return s.contains("over") || s.hasPrefix("o")
  }
}

// MARK: - Волна E (E5): сравнение 4 моделей

struct MultiModelBacktester {

  /// Максимум матчей для оценки — чтобы не гонять всё 2-летнее полотно.
  static let maxMatches = 1500

  func run(
    matches: [Match], histories: [String: [TeamRecord]]
  ) -> [ModelComparison] {
    let engine = QuantEngine()
    let configs = ["DC", "BIV", "NB", "ENS"]

    let sorted = matches.sorted {
      ($0.start ?? .distantPast) < ($1.start ?? .distantPast)
    }
    let step = max(1, sorted.count / Self.maxMatches)
    let sampled = sorted.enumerated().compactMap { (i, m) -> Match? in
      i % step == 0 ? m : nil
    }

    var brierSum: [String: Double] = [:]
    var logLossSum: [String: Double] = [:]
    var counts: [String: Int] = [:]
    var homePSum: [String: Double] = [:]
    var drawPSum: [String: Double] = [:]
    var awayPSum: [String: Double] = [:]

    for match in sampled {
      guard let h = match.homeID, let a = match.awayID,
            let hFT = match.homeFT, let aFT = match.awayFT
      else { continue }

      let matchStart = match.start ?? .distantFuture
      let hs = (histories[h] ?? []).filter {
        ($0.date ?? .distantPast) < matchStart
      }
      let as_ = (histories[a] ?? []).filter {
        ($0.date ?? .distantPast) < matchStart
      }
      guard let model = engine.model(home: hs, away: as_) else { continue }

      let actualIdx: Int = hFT > aFT ? 0 : (hFT == aFT ? 1 : 2)
      let outs: [String: (Double, Double, Double)] = [
        "DC":  (model.outcomesDC.home, model.outcomesDC.draw, model.outcomesDC.away),
        "BIV": (model.outcomesBIV.home, model.outcomesBIV.draw, model.outcomesBIV.away),
        "NB":  (model.outcomesNB.home, model.outcomesNB.draw, model.outcomesNB.away),
        "ENS": (model.outcomes.home, model.outcomes.draw, model.outcomes.away),
      ]

      for name in configs {
        guard let o = outs[name] else { continue }
        let ps = [o.0, o.1, o.2]
        let sumP = ps.reduce(0, +)
        guard sumP > 0 else { continue }
        let nps = ps.map { $0 / sumP }

        var brier = 0.0
        for i in 0..<3 {
          let y = (i == actualIdx) ? 1.0 : 0.0
          brier += (nps[i] - y) * (nps[i] - y)
        }
        brierSum[name, default: 0] += brier

        let eps = 1e-9
        let p = min(1 - eps, max(eps, nps[actualIdx]))
        logLossSum[name, default: 0] += -log(p)

        counts[name, default: 0] += 1
        homePSum[name, default: 0] += nps[0]
        drawPSum[name, default: 0] += nps[1]
        awayPSum[name, default: 0] += nps[2]
      }
    }

    return configs.map { name in
      let n = max(1, counts[name] ?? 0)
      return ModelComparison(
        name: name,
        matches: counts[name] ?? 0,
        brier: (brierSum[name] ?? 0) / Double(n),
        logLoss: (logLossSum[name] ?? 0) / Double(n),
        avgHomeP: (homePSum[name] ?? 0) / Double(n),
        avgDrawP: (drawPSum[name] ?? 0) / Double(n),
        avgAwayP: (awayPSum[name] ?? 0) / Double(n))
    }
  }
}

// MARK: - CalibrationEngine (совместимость)

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