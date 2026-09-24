import Foundation

struct TeamRecord: Hashable, Codable {
  var id: String
  var date: Date?
  var gf: Double?
  var ga: Double?
  var corners: Double?
  var oppCorners: Double?
  var cards: Double?
  var oppCards: Double?
  var fouls: Double?
  var oppFouls: Double?
  var shots: Double?
  var sot: Double?
  var possession: Double?
  var xg: Double?
  var oppXg: Double?
  var referee: String?
  var players: [PlayerRow] = []
}

struct PlayerRow: Hashable, Codable {
  var id: String
  var name: String
  var minutes: Double
  var xg: Double
  var xa: Double
  var goals: Double
  var assists: Double
  var shots: Double
  var sot: Double
  var starts: Int
}
struct RefProfile {
  var n: Int
  var cards: Double?
  var fouls: Double?
  var confidence: Double
}
struct SharpGuard {
  var score: Double = 0
  var movement: Double = 0
  var sharpMovement: Double = 0
  var disagreement: Double = 0
  var sharpClose: Double?
  var sharpOpen: Double?
}

struct QuantEngine {
  static let goalLines = [0.5, 1.5, 2.5, 3.5, 4.5]
  static let countLines = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5]
  static let sharpBooks = ["pinnacle", "betfair", "sbo", "sbobet", "marathon"]

  // MARK: - Matches

  func matches(from json: JSONValue) -> [Match] {
    let items: [JSONValue]
    if let obj = json.object, let dataArr = obj["data"]?.array {
      items = dataArr
    } else if let arr = json.array {
      items = arr
    } else {
      items = json.allObjects().map { .object($0) }
    }

    var result: [Match] = []
    for item in items {
      guard let o = item.object else { continue }
      guard let idStr = string(o, ["id", "flashId", "gameid", "game_id"]), !idStr.isEmpty
      else { continue }
      guard let home = teamName(o, "home"), let away = teamName(o, "away") else { continue }
      let league = leagueName(o) ?? "Unknown"
      let m = Match(
        id: idStr, home: home, away: away, league: league, start: date(o),
        homeID: teamID(o, "home"), awayID: teamID(o, "away"),
        homeFT: number(o, ["homeFTResult", "homeResult"]),
        awayFT: number(o, ["awayFTResult", "awayResult"]),
        oddsJSON: o["odds"],
        numericID: intValue(o, ["id", "gameId"]))
      if !result.contains(where: { $0.id == idStr }) { result.append(m) }
    }
    return result
  }

  func allRecords(from json: JSONValue) -> [String: [TeamRecord]] {
    let items: [JSONValue] = json.object?["data"]?.array ?? json.array ?? []
    var out: [String: [TeamRecord]] = [:]
    for item in items {
      guard let o = item.object else { continue }
      if let hid = teamID(o, "home"), let rec = recordFromGame(o, teamID: hid, isHome: true) {
        out[hid, default: []].append(rec)
      }
      if let aid = teamID(o, "away"), let rec = recordFromGame(o, teamID: aid, isHome: false) {
        out[aid, default: []].append(rec)
      }
    }
    for (k, v) in out {
      out[k] = v.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }
    return out
  }

  private func recordFromGame(
    _ o: [String: JSONValue], teamID: String, isHome: Bool
  ) -> TeamRecord? {
    let pref = isHome ? "home" : "away"
    let opp = isHome ? "away" : "home"
    let gf = number(o, [pref + "FTResult", pref + "Result"])
    let ga = number(o, [opp + "FTResult", opp + "Result"])
    guard gf != nil || ga != nil else { return nil }
    return TeamRecord(
      id: string(o, ["id"]) ?? UUID().uuidString,
      date: date(o), gf: gf, ga: ga,
      corners: nil, oppCorners: nil,
      cards: nil, oppCards: nil,
      fouls: nil, oppFouls: nil,
      shots: nil, sot: nil, possession: nil, xg: nil, oppXg: nil,
      referee: string(o, ["refereeName", "referee"]), players: [])
  }

  func teamRecord(from payload: JSONValue, targetID: String) -> TeamRecord? {
    let g = fullGame(payload)
    let game = g["game"]?.object ?? g
    let hid = teamID(game, "home")
    let aid = teamID(game, "away")
    guard targetID == hid || targetID == aid else { return nil }
    return recordFromGame(game, teamID: targetID, isHome: targetID == hid)
  }

  // MARK: - Model

  func model(home: [TeamRecord], away: [TeamRecord], glicko: JSONValue? = nil) -> MatchModel? {
    guard let base = estimateLambdas(home, away) else { return nil }
    let ph = playerAssembly(home)
    let pa = playerAssembly(away)
    let player = (base.0 * ph.factor, base.1 * pa.factor)
    let final = glickoAdjust(player, glicko)
    let baseM = QuantMath.dixonColes(base.0, base.1, rho: -0.055, maxGoals: 12)
    let finalM = QuantMath.dixonColes(final.0, final.1, rho: -0.055, maxGoals: 12)
    let bo = QuantMath.outcomes(baseM)
    let fo = QuantMath.outcomes(finalM)
    return MatchModel(
      lh: final.0, la: final.1,
      baseLH: base.0, baseLA: base.1,
      baseMatrix: baseM, playerMatrix: baseM, matrix: finalM,
      outcomes: fo,
      components: [bo.home, bo.draw, bo.away, fo.home, fo.draw, fo.away],
      playerHome: ph, playerAway: pa)
  }

  // MARK: - Signals

  func signals(
    match: Match, info: JSONValue, oddsJSON: JSONValue,
    homeHistory: [TeamRecord], awayHistory: [TeamRecord],
    glicko: JSONValue? = nil
  ) -> [BetSignal] {
    guard let model = model(home: homeHistory, away: awayHistory, glicko: glicko)
    else { return [] }

    let quotes = parseQuotes(oddsJSON)
    var out: [BetSignal] = []
    let grouped = Dictionary(grouping: quotes, by: key(_:))
    let refereeName = string(info.allObjects().first ?? [:], ["refereeName", "referee"])
    let ref = refereeProfile(homeHistory + awayHistory, refereeName)

    let combinedSample = min(homeHistory.count, awayHistory.count)
    let sampleClass = SampleClass.classify(combinedSample)

    let sourceScore = 90.0
    let sampleScore = sampleClass.dcsScore
    let consensusScore = min(100, Double(max(quotes.count, 1)) * 12)
    let freshnessScore = 90.0
    let definitionScore = 85.0
    let dcs = 0.30 * sourceScore
      + 0.25 * sampleScore
      + 0.20 * consensusScore
      + 0.15 * freshnessScore
      + 0.10 * definitionScore

    for (_, qs) in grouped {
      guard !qs.isEmpty else { continue }
      guard let median = QuantMath.median(qs.map { $0.odds }), let q = qs.first
      else { continue }
      let sharp = sharpGuard(qs, median: median)

      let p: Double
      let modelName: String
      if q.market == "1X2" {
        let mc = QuantMath.monteCarloOutcome(model.matrix, n: 20000, seed: 17)
        p =
          0.80 * (q.selectionKey == "1"
            ? model.outcomes.home
            : (q.selectionKey == "X" ? model.outcomes.draw : model.outcomes.away))
          + 0.20 * (q.selectionKey == "1" ? mc.0 : (q.selectionKey == "X" ? mc.1 : mc.2))
        modelName = "DC+PLAYER+GLICKO+MC"
      } else if q.market == "GOALS" {
        p = totalProbability(
          q, mean: max(0.1, model.lh + model.la),
          variance: goalVariance(homeHistory + awayHistory))
        modelName = "POISSON/NB+MC"
      } else if q.market == "CARDS" {
        var mean = meanCount(homeHistory + awayHistory, \.cards) ?? 4.0
        if ref.n >= 6, let rv = ref.cards { mean = blendRef(base: mean, ref: rv, n: ref.n) }
        p = totalProbability(
          q, mean: mean,
          variance: countVariance(homeHistory + awayHistory, \.cards))
        modelName = "POISSON/NB+REFEREE"
      } else if q.market == "CORNERS" {
        let mean = meanCount(homeHistory + awayHistory, \.corners) ?? 10.0
        p = totalProbability(
          q, mean: mean,
          variance: countVariance(homeHistory + awayHistory, \.corners))
        modelName = "POISSON/NB+PRESSURE"
      } else {
        continue
      }

      if let s = finish(
        match: match, q: q, p: p, dcs: dcs, quotes: qs,
        sharp: sharp, modelOutcomes: model.outcomes, modelName: modelName,
        sampleClass: sampleClass,
        homeSample: homeHistory.count, awaySample: awayHistory.count)
      {
        out.append(s)
      }
    }
    return out.sorted { $0.qcs > $1.qcs }
  }

  // MARK: - Finish

  private func finish(
    match: Match, q: Quote, p: Double,
    dcs: Double, quotes: [Quote], sharp: SharpGuard,
    modelOutcomes: (home: Double, draw: Double, away: Double),
    modelName: String, sampleClass: SampleClass,
    homeSample: Int, awaySample: Int
  ) -> BetSignal? {

    let quoteProbs = quotes.map { 1.0 / max($0.odds, 1.01) }
    let marketProbability = QuantMath.median(quoteProbs) ?? 0.0
    let marketMAD = QuantMath.mad(quoteProbs.map { $0 * 100 }) ?? 0.0

    let interval = QuantMath.probabilityInterval(
      p, sample: min(homeSample, awaySample), dcs: dcs, marketMAD: marketMAD)

    let robustP = QuantMath.confidenceAdjustedProbability(
      p, uncertainty: interval.uncertainty)

    let ev = QuantMath.ev(p: p, odds: q.odds)
    var robustEV = QuantMath.ev(p: robustP, odds: q.odds)

    var ms = marketScore(qs: quotes.count, odds: q.odds, sharp: sharp)
    if sharp.disagreement > 0.05 {
      ms = max(0, ms - 15)
      robustEV *= 0.70
    }

    let fair = 1 / max(p, 0.001)
    let extreme = q.odds > fair * 1.25
    let anomaly = q.odds > fair * 1.35
    let conflict = abs(p - marketProbability) > 0.25

    if extreme || anomaly || conflict { robustEV = -abs(robustEV) }

    // MES
    let mes: Double = {
      let edge = max(0, ev)
      let robustBonus = robustEV > 0 ? 15 : 0
      let agreementBonus = q.market == "1X2"
        ? (1 - abs(p - (q.selectionKey == "1"
            ? modelOutcomes.home
            : (q.selectionKey == "X" ? modelOutcomes.draw : modelOutcomes.away)))) * 25
        : 15
      return max(0, min(100, 30 + edge * 500 + robustBonus + agreementBonus))
    }()

    let ts = max(20, min(100, 100 - interval.uncertainty * 220))
    let rs = max(0, 100 * (1 - interval.uncertainty))

    let qcs = 0.30 * mes + 0.20 * dcs + 0.20 * ms + 0.15 * ts + 0.15 * rs

    let classification: String
    if anomaly || extreme || conflict {
      classification = "X NO BET"
    } else if robustEV > 0 && ev >= 0.07 && qcs >= 85 && ms >= 50 && dcs >= 60 {
      classification = "S BET"
    } else if robustEV > 0 && ev >= 0.05 && qcs >= 78 && ms >= 50 && dcs >= 60 {
      classification = "A BET"
    } else if ev >= 0.03 && robustEV > 0 {
      classification = "B LEAN"
    } else if ev > 0 {
      classification = "C WATCH"
    } else {
      classification = "X NO BET"
    }

    guard classification != "X NO BET" else { return nil }

    let band = UncertaintyBand.from(interval.uncertainty)

    let fullKelly = QuantMath.kelly(p: robustP, odds: q.odds)
    let quarterKelly = 0.25 * fullKelly
    let stakeCap: Double = (classification == "S BET") ? 0.025 : 0.02
    let rawStake = min(stakeCap, quarterKelly * band.kellyMultiplier)

    return BetSignal(
      id: "\(match.id)-\(q.market)-\(q.selection)-\(q.line ?? 0)",
      gameID: match.id, home: match.home, away: match.away, league: match.league,
      market: q.market, selection: q.selection, line: q.line, odds: q.odds,
      probability: p, fairOdds: fair,
      ev: ev, robustEV: robustEV,
      model: modelName, timestamp: Date(),
      classification: classification, stake: rawStake,
      priceAnomaly: anomaly || extreme, bookmakers: quotes.count,
      dcs: dcs, ms: ms, mes: mes, ts: ts, rs: rs, qcs: qcs,
      sampleClass: sampleClass.rawValue,
      homeSample: homeSample, awaySample: awaySample,
      uncertainty: interval.uncertainty,
      uncertaintyBand: band.label,
      marketProbability: marketProbability, marketMAD: marketMAD,
      probabilityLow: interval.low, probabilityHigh: interval.high,
      kellyFraction: fullKelly, quarterKelly: quarterKelly, stakeCap: stakeCap,
      portfolioCorrelation: 0, correlationReason: "")
  }

  // MARK: - Portfolio

  func portfolio(_ signals: [BetSignal]) -> [BetSignal] {
    var chosen: [BetSignal] = []
    var totalExposure = 0.0
    let dailyCap = 0.10

    let candidates = signals
      .filter { $0.robustEV > 0 }
      .filter { $0.qcs >= 78 }
      .filter { $0.dcs >= 60 }
      .sorted { $0.robustEV > $1.robustEV }

    for s in candidates {
      var maxCorr = 0.0
      var reason = ""
      for prev in chosen {
        let c = correlation(s, prev)
        if c > maxCorr {
          maxCorr = c
          reason = correlationReason(s, prev)
        }
      }
      if maxCorr >= 0.65 { continue }
      guard totalExposure + s.stake <= dailyCap else { continue }

      var x = s
      x.portfolioCorrelation = maxCorr
      x.correlationReason = reason
      chosen.append(x)
      totalExposure += s.stake
      if chosen.count >= 8 { break }
    }
    return chosen
  }

  private func correlation(_ a: BetSignal, _ b: BetSignal) -> Double {
    if a.gameID == b.gameID {
      if a.market == b.market { return 0.82 }
      let set = Set([a.market, b.market])
      if set == Set(["GOALS", "CARDS"]) { return 0.20 }
      if set == Set(["GOALS", "CORNERS"]) { return 0.25 }
      if set == Set(["CARDS", "CORNERS"]) { return 0.15 }
      return 0.35
    }
    if a.home == b.home || a.home == b.away
      || a.away == b.home || a.away == b.away {
      return 0.20
    }
    return 0.03
  }

  private func correlationReason(_ a: BetSignal, _ b: BetSignal) -> String {
    if a.gameID == b.gameID && a.market == b.market { return "same market" }
    if a.gameID == b.gameID { return "same game" }
    if a.home == b.home || a.home == b.away
      || a.away == b.home || a.away == b.away { return "shared team" }
    return "independent"
  }

  // MARK: - Model helpers

  private func estimateLambdas(_ h: [TeamRecord], _ a: [TeamRecord]) -> (Double, Double)? {
    func shrink(_ x: [Double?]) -> Double? {
      QuantMath.shrink(x.compactMap { $0 }, baseline: nil, k: 8)
    }
    guard let hgf = shrink(h.map { $0.gf }), let hga = shrink(h.map { $0.ga }),
      let agf = shrink(a.map { $0.gf }), let aga = shrink(a.map { $0.ga })
    else { return nil }
    let hatt = 0.65 * (shrink(h.map { $0.xg }) ?? hgf) + 0.35 * hgf
    let aatt = 0.65 * (shrink(a.map { $0.xg }) ?? agf) + 0.35 * agf
    let hdef = 0.65 * hga + 0.35 * (shrink(h.map { $0.oppXg }) ?? hga)
    let adef = 0.65 * aga + 0.35 * (shrink(a.map { $0.oppXg }) ?? aga)
    return (max(0.08, 0.56 * hatt + 0.44 * adef),
            max(0.08, 0.56 * aatt + 0.44 * hdef))
  }

  private func glickoAdjust(
    _ pair: (Double, Double), _ json: JSONValue?
  ) -> (Double, Double) {
    guard let json,
      let ph = firstNumber(json, ["homeWinProbability"]),
      let pa = firstNumber(json, ["awayWinProbability"])
    else { return pair }
    let edge = max(-1, min(1, ph - pa))
    let f = max(-0.12, min(0.12, 0.20 * edge))
    return (pair.0 * (1 + f), pair.1 * (1 - f))
  }

  private func playerAssembly(_ history: [TeamRecord]) -> PlayerAssembly {
    var agg = [String: PlayerAgg]()
    for r in history {
      for p in r.players {
        var x = agg[p.id] ?? PlayerAgg(id: p.id, name: p.name)
        x.minutes += p.minutes; x.xg += p.xg; x.xa += p.xa
        x.goals += p.goals; x.assists += p.assists
        x.shots += p.shots; x.sot += p.sot; x.games += 1
        agg[p.id] = x
      }
    }
    let scored: [(PlayerAgg, Double)] = agg.values.filter { $0.minutes >= 180 }.map { p in
      let per90 = 90.0 / max(p.minutes, 1)
      return (p, 0.55 * p.xg * per90 + 0.25 * p.xa * per90
              + 0.12 * p.sot * per90 + 0.08 * p.goals * per90)
    }.sorted { $0.1 > $1.1 }
    let top = Array(scored.prefix(8))
    let baseline = top.reduce(0.0) { acc, item in
      let (p, score) = item
      let expMin = min(90.0, p.minutes / max(1.0, Double(p.games)))
      return acc + score * expMin / 90.0
    }
    let repl = scored.dropFirst(8).prefix(8).map { $0.1 }
    let replAvg = repl.isEmpty ? 0.0 : repl.reduce(0, +) / Double(repl.count)
    let gap = max(-1.0, min(1.0,
      (baseline - replAvg) / max(0.5, abs(baseline) + 0.5)))
    return PlayerAssembly(
      factor: max(0.94, min(1.06, 1.0 + 0.025 * gap)),
      baseline: baseline, playersUsed: scored.count, top: top.map { $0.0 })
  }

  private func refereeProfile(_ records: [TeamRecord], _ name: String?) -> RefProfile {
    guard let name else { return RefProfile(n: 0, cards: nil, fouls: nil, confidence: 0) }
    let r = records.filter {
      ($0.referee ?? "").caseInsensitiveCompare(name) == .orderedSame
    }
    let cards = r.map { ($0.cards ?? 0) + ($0.oppCards ?? 0) }
    let base = QuantMath.mean(records.compactMap { ($0.cards ?? 0) + ($0.oppCards ?? 0) }) ?? 4
    let w = Double(r.count) / Double(r.count + 8)
    let shrunk = cards.map { w * $0 + (1 - w) * base }
    return RefProfile(
      n: r.count, cards: QuantMath.mean(shrunk), fouls: nil,
      confidence: min(100, Double(r.count) / 15 * 100))
  }

  private func blendRef(base: Double, ref: Double, n: Int) -> Double {
    let w = min(0.55, Double(n) / Double(n + 8))
    return max(0.1, base * (1 - w) + ref * w)
  }

  private func meanCount(_ r: [TeamRecord], _ kp: (TeamRecord) -> Double?) -> Double? {
    QuantMath.shrink(r.compactMap(kp), baseline: nil, k: 8)
  }
  private func countVariance(_ r: [TeamRecord], _ kp: (TeamRecord) -> Double?) -> Double {
    let x = r.compactMap(kp)
    return QuantMath.variance(x) ?? max(1, QuantMath.mean(x) ?? 1)
  }
  private func goalVariance(_ r: [TeamRecord]) -> Double {
    let x = r.compactMap { $0.gf }
    return QuantMath.variance(x) ?? max(1, QuantMath.mean(x) ?? 2.5)
  }

  private func totalProbability(_ q: Quote, mean: Double, variance: Double) -> Double {
    guard let line = q.line else { return min(0.9, max(0.1, 1 - exp(-mean))) }
    let isUnder = q.selection.lowercased().contains("under")
      || q.selection.lowercased().hasPrefix("u")
    let over = distributionOver(mean: mean, variance: variance, line: line)
    return isUnder ? 1 - over : over
  }

  private func distributionOver(mean: Double, variance: Double, line: Double) -> Double {
    let frac = line.rounded() - line
    if abs(abs(frac) - 0.25) < 0.001 || abs(abs(frac) - 0.75) < 0.001 {
      let lo = floor(line * 2) / 2
      let hi = ceil(line * 2) / 2
      return 0.5 * distributionOver(mean: mean, variance: variance, line: lo)
        + 0.5 * distributionOver(mean: mean, variance: variance, line: hi)
    }
    if variance > mean * 1.08 {
      let k = Int(floor(line))
      var cdf = 0.0
      if k >= 0 {
        for i in 0...k {
          cdf += QuantMath.negativeBinomialPMF(i, mean: mean, variance: variance)
        }
      }
      return 1 - cdf
    }
    let m = QuantMath.dixonColes(mean / 2, mean / 2, rho: 0, maxGoals: 20)
    return QuantMath.monteCarloTotal(
      m, line: line, n: 20000, seed: UInt64(abs(Int(mean * 100)) + 17), over: true)
  }

  private func marketScore(qs: Int, odds: Double, sharp: SharpGuard) -> Double {
    var score = 25.0
    score += Double(min(qs, 8)) * 7.0
    if odds > 1.80 { score += 5 }
    if sharp.score >= 55 { score += 20 }
    if sharp.disagreement <= 0.03 { score += 10 }
    else if sharp.disagreement > 0.08 { score -= 15 }
    return max(0, min(100, score))
  }

  // MARK: - Odds parsing

  private func parseQuotes(_ json: JSONValue) -> [Quote] {
    var out: [Quote] = []
    if let arr = json.array {
      for mv in arr {
        guard let m = mv.object else { continue }
        let marketName = string(m, ["marketName", "market", "market_name"]) ?? ""
        guard let prices = m["odds"]?.array else { continue }
        for pv in prices {
          guard let p = pv.object,
            let value = number(p, ["value", "odds", "price"]),
            value > 1, value < 100
          else { continue }
          let selection = string(p, ["name", "selection", "outcome"]) ?? ""
          let market = normalizeMarket(marketName + " " + selection)
          guard !market.isEmpty else { continue }
          let line = extractLine(selection) ?? extractLine(marketName)
          out.append(Quote(
            market: market, selection: selection, line: line,
            odds: value, bookmaker: "sstats"))
        }
      }
    }
    return out
  }

  private func extractLine(_ s: String) -> Double? {
    let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)")
    if let m = regex?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
      let r = Range(m.range(at: 1), in: s)
    {
      return Double(s[r])
    }
    return nil
  }

  private func key(_ q: Quote) -> String {
    "\(q.market)|\(q.selection.lowercased())|\(q.line ?? -999)"
  }

  private func sharpGuard(_ qs: [Quote], median: Double) -> SharpGuard {
    let sharp = qs.filter { q in
      Self.sharpBooks.contains(where: { q.bookmaker.lowercased().contains($0) })
    }.map { $0.odds }
    guard let sm = QuantMath.median(sharp) else {
      return SharpGuard(score: 25, disagreement: 0)
    }
    let dis = abs(sm / median - 1)
    var score = 35.0
    if qs.count >= 4 { score += 25 }
    if dis <= 0.03 { score += 20 }
    return SharpGuard(
      score: score, movement: 0, sharpMovement: 0,
      disagreement: dis, sharpClose: sm, sharpOpen: nil)
  }

  private func normalizeMarket(_ x: String) -> String {
    let s = x.lowercased()
    if s.contains("corner") { return "CORNERS" }
    if s.contains("card") || s.contains("yellow") { return "CARDS" }
    if s.contains("goal") || s.contains("total")
      || s.contains("over") || s.contains("under") { return "GOALS" }
    if s.contains("1x2") || s.contains("winner") || s.contains("home")
      || s.trimmingCharacters(in: .whitespaces) == "1"
      || s.trimmingCharacters(in: .whitespaces) == "x"
      || s.trimmingCharacters(in: .whitespaces) == "2" { return "1X2" }
    return ""
  }

  // MARK: - JSON helpers

  private func teamName(_ o: [String: JSONValue], _ side: String) -> String? {
    if let team = o[side + "Team"]?.object, let name = team["name"]?.string { return name }
    return string(o, [side, side + "team", side + "_team"])
  }

  private func leagueName(_ o: [String: JSONValue]) -> String? {
    if let season = o["season"]?.object,
      let league = season["league"]?.object,
      let name = league["name"]?.string { return name }
    if let league = o["league"]?.object, let name = league["name"]?.string { return name }
    return string(o, ["league", "tournament"])
  }

  private func fullGame(_ p: JSONValue) -> [String: JSONValue] {
    if let o = p.object, let d = o["data"]?.object { return d }
    return p.object ?? [:]
  }

  private func teamID(_ o: [String: JSONValue], _ side: String) -> String? {
    if let x = o[side + "Team"]?.object {
      if let s = string(x, ["id", "teamid", "team_id", "flashid"]), !s.isEmpty { return s }
      if let n = x["id"]?.number { return String(Int(n)) }
    }
    if let s = string(o, [side + "TeamId", side + "Id"]), !s.isEmpty { return s }
    if let n = o[side + "TeamId"]?.number { return String(Int(n)) }
    return nil
  }

  private func string(_ o: [String: JSONValue], _ keys: [String]) -> String? {
    for k in keys { if let s = o[k]?.string { return s } }
    return nil
  }
  private func number(_ o: [String: JSONValue], _ keys: [String]) -> Double? {
    for k in keys { if let n = o[k]?.number { return n } }
    return nil
  }
  private func intValue(_ o: [String: JSONValue], _ keys: [String]) -> Int? {
    for k in keys {
      if let n = o[k]?.number { return Int(n) }
      if let s = o[k]?.string, let n = Int(s) { return n }
    }
    return nil
  }
  private func firstNumber(_ v: JSONValue, _ keys: [String]) -> Double? {
    v.firstNumber(keys: Set(keys.map { $0.lowercased() }))
  }
  private func date(_ o: [String: JSONValue]) -> Date? {
    if let s = string(o, ["date", "datetime", "starttime", "timestamp"]) {
      let f = ISO8601DateFormatter()
      if let d = f.date(from: s) { return d }
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let d = f.date(from: s) { return d }
      if let t = Double(s) {
        return Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t)
      }
    }
    return nil
  }
}

struct MatchModel {
  var lh: Double
  var la: Double
  var baseLH: Double
  var baseLA: Double
  var baseMatrix: Matrix2D
  var playerMatrix: Matrix2D
  var matrix: Matrix2D
  var outcomes: (home: Double, draw: Double, away: Double)
  var components: [Double]
  var playerHome: PlayerAssembly
  var playerAway: PlayerAssembly
}
struct PlayerAssembly {
  var factor: Double
  var baseline: Double
  var playersUsed: Int
  var top: [PlayerAgg]
}
struct PlayerAgg: Hashable, Codable {
  var id: String
  var name: String = ""
  var minutes = 0.0
  var xg = 0.0
  var xa = 0.0
  var goals = 0.0
  var assists = 0.0
  var shots = 0.0
  var sot = 0.0
  var games = 0
}
extension Quote {
  var selectionKey: String {
    let s = selection.lowercased()
    if market == "1X2" {
      if s == "1" || s.contains("home") { return "1" }
      if s == "x" || s.contains("draw") { return "X" }
      return "2"
    }
    return s.contains("under") ? "U" : "O"
  }
}