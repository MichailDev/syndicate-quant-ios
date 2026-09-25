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
  var isHome: Bool = true
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
  var rsi: Double
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

  static let posteriorMinN = 20
  static let posteriorWeight = 0.15

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
      guard let idStr = string(o, ["id", "flashId", "gameid", "game_id"]),
            !idStr.isEmpty
      else { continue }
      guard let home = teamName(o, "home"), let away = teamName(o, "away")
      else { continue }
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
      if let hid = teamID(o, "home"),
         let rec = recordFromGame(o, teamID: hid, isHome: true) {
        out[hid, default: []].append(rec)
      }
      if let aid = teamID(o, "away"),
         let rec = recordFromGame(o, teamID: aid, isHome: false) {
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
      referee: string(o, ["refereeName", "referee"]),
      isHome: isHome,
      players: [])
  }

  func teamRecord(from payload: JSONValue, targetID: String) -> TeamRecord? {
    let g = fullGame(payload)
    let game = g["game"]?.object ?? g
    let hid = teamID(game, "home")
    let aid = teamID(game, "away")
    guard targetID == hid || targetID == aid else { return nil }
    return recordFromGame(game, teamID: targetID, isHome: targetID == hid)
  }

  // MARK: - Model (public API, без ratings/lineups — для backtest)

  func model(home: [TeamRecord], away: [TeamRecord], glicko: JSONValue? = nil) -> MatchModel? {
    modelWithRatings(
      home: home, away: away, glicko: glicko,
      teamRatings: (nil, nil),
      playerImpact: (1.0, 1.0))
  }

  // MARK: - Signals

  func signals(
    match: Match, info: JSONValue, oddsJSON: JSONValue,
    homeHistory: [TeamRecord], awayHistory: [TeamRecord],
    glicko: JSONValue? = nil,
    posteriorBuckets: [PosteriorBucket] = [],
    teamRatings: (home: Double?, away: Double?) = (nil, nil),
    upcomingLineups: (home: [String], away: [String])? = nil
  ) -> [BetSignal] {
    // B6: player impact
    let hImpact = playerImpact(
      history: homeHistory, expectedIDs: upcomingLineups?.home ?? [])
    let aImpact = playerImpact(
      history: awayHistory, expectedIDs: upcomingLineups?.away ?? [])

    guard let matchModel = modelWithRatings(
      home: homeHistory, away: awayHistory, glicko: glicko,
      teamRatings: teamRatings,
      playerImpact: (hImpact, aImpact))
    else { return [] }

    let quotes = parseQuotes(oddsJSON)
    var out: [BetSignal] = []
    let grouped = Dictionary(grouping: quotes, by: { key($0) })
    let refereeName = string(info.allObjects().first ?? [:], ["refereeName", "referee"])
    let ref = refereeProfile(homeHistory + awayHistory, refereeName)

    let combinedSample = min(homeHistory.count, awayHistory.count)
    let sampleClass = SampleClass.classify(combinedSample)

    let sourceScore = 90.0
    let sampleScore = sampleClass.dcsScore
    let consensusScore = min(100.0, Double(max(quotes.count, 1)) * 12.0)
    let freshnessScore = 90.0
    let definitionScore = 85.0
    let dcs = 0.30 * sourceScore
      + 0.25 * sampleScore
      + 0.20 * consensusScore
      + 0.15 * freshnessScore
      + 0.10 * definitionScore

    let totalDist = QuantMath.totalDistribution(matchModel.matrix)

    for (_, qs) in grouped {
      guard !qs.isEmpty else { continue }
      guard let median = QuantMath.median(qs.map { $0.odds }) else { continue }
      guard let q = qs.first else { continue }
      let sharp = sharpGuard(qs, median: median)

      let p: Double
      let modelName: String
      if q.market == "1X2" {
        p = compute1X2Probability(q: q, model: matchModel, n: 20000, seed: 17)
        modelName = "ENSEMBLE(DC+BIV+NB)+MC"
      } else if q.market == "GOALS" {
        p = totalProbabilityFromDistribution(q, dist: totalDist)
        modelName = "ENSEMBLE(DC/BIV/NB)+MC"
      } else if q.market == "CARDS" {
        p = computeCardsProbability(
          q: q, records: homeHistory + awayHistory, ref: ref)
        modelName = "POISSON/NB+REFEREE+RSI"
      } else if q.market == "CORNERS" {
        let mean = meanCount(homeHistory + awayHistory, \.corners) ?? 10.0
        p = totalProbability(
          q, mean: mean,
          variance: countVariance(homeHistory + awayHistory, \.corners))
        modelName = "POISSON/NB+PRESSURE"
      } else {
        continue
      }

      if var s = finish(
        match: match, q: q, p: p, dcs: dcs, quotes: qs,
        sharp: sharp, modelOutcomes: matchModel.outcomes, modelName: modelName,
        sampleClass: sampleClass,
        homeSample: homeHistory.count, awaySample: awayHistory.count,
        posteriorBuckets: posteriorBuckets) {
        if hImpact < 0.999 || aImpact < 0.999 {
          s.playerImpactHome = hImpact
          s.playerImpactAway = aImpact
        }
        out.append(s)
      }
    }
    return out.sorted { $0.qcs > $1.qcs }
  }

  // MARK: - Model with ratings & player impact

  private func modelWithRatings(
    home: [TeamRecord], away: [TeamRecord], glicko: JSONValue?,
    teamRatings: (home: Double?, away: Double?),
    playerImpact: (home: Double, away: Double)
  ) -> MatchModel? {
    guard let base = estimateLambdas(home, away) else { return nil }
    let ph = playerAssembly(home)
    let pa = playerAssembly(away)
    let player = (
      base.0 * ph.factor * playerImpact.home,
      base.1 * pa.factor * playerImpact.away
    )
    let final = glickoAdjust(player, teamRatings: teamRatings, glickoJSON: glicko)

    let maxGoals = 12
    let dcMatrix = QuantMath.dixonColes(
      final.0, final.1, rho: -0.055, maxGoals: maxGoals)
    let bivarMatrix = QuantMath.bivariatePoisson(
      final.0, final.1, l3: 0.05, maxGoals: maxGoals)
    let nbMatrix = QuantMath.dixonColes(
      final.0, final.1, rho: -0.020, maxGoals: maxGoals)

    let oDC = QuantMath.outcomes(dcMatrix)
    let oBiv = QuantMath.outcomes(bivarMatrix)
    let oNB = QuantMath.outcomes(nbMatrix)

    let combined = home + away
    let xgValues = combined.compactMap { $0.xg }
    let avgXG: Double? = xgValues.isEmpty
      ? nil
      : xgValues.reduce(0, +) / Double(xgValues.count)

    var wDC = 0.55
    var wBiv = 0.25
    var wNB = 0.20
    if let ax = avgXG {
      if ax < 1.0 {
        wDC = 0.30; wBiv = 0.55; wNB = 0.15
      } else if ax > 1.8 {
        wDC = 0.40; wBiv = 0.10; wNB = 0.50
      }
    }
    let wSum = wDC + wBiv + wNB
    wDC /= wSum; wBiv /= wSum; wNB /= wSum

    let ensembleHome = wDC * oDC.home + wBiv * oBiv.home + wNB * oNB.home
    let ensembleDraw = wDC * oDC.draw + wBiv * oBiv.draw + wNB * oNB.draw
    let ensembleAway = wDC * oDC.away + wBiv * oBiv.away + wNB * oNB.away

    let primaryMatrix: Matrix2D
    if wDC >= wBiv && wDC >= wNB { primaryMatrix = dcMatrix }
    else if wBiv >= wNB { primaryMatrix = bivarMatrix }
    else { primaryMatrix = nbMatrix }

    return MatchModel(
      lh: final.0, la: final.1,
      baseLH: base.0, baseLA: base.1,
      baseMatrix: dcMatrix, playerMatrix: dcMatrix, matrix: primaryMatrix,
      outcomes: (ensembleHome, ensembleDraw, ensembleAway),
      components: [oDC.home, oDC.draw, oDC.away, ensembleHome, ensembleDraw, ensembleAway],
      playerHome: ph, playerAway: pa,
      ensembleWeights: (dc: wDC, biv: wBiv, nb: wNB),
      ensembleAvgXG: avgXG)
  }

  // MARK: - B6: player impact

  /// Возвращает множитель λ на основе отсутствия ключевых игроков.
  /// Если данных о составах нет → 1.0.
  private func playerImpact(
    history: [TeamRecord], expectedIDs: [String]
  ) -> Double {
    guard !expectedIDs.isEmpty else { return 1.0 }
    let pa = playerAssembly(history)
    guard pa.playersUsed >= 6, !pa.top.isEmpty else { return 1.0 }

    let expectedSet = Set(expectedIDs.map { $0.lowercased() })

    var missing = 0
    for p in pa.top {
      let idMatch = expectedSet.contains(p.id.lowercased())
      let nameMatch = !p.name.isEmpty && expectedSet.contains(p.name.lowercased())
      if !idMatch && !nameMatch { missing += 1 }
    }

    if missing <= 2 { return 1.0 }
    if missing == 3 { return 0.95 }
    if missing == 4 { return 0.92 }
    return 0.88
  }

  // MARK: - Probability calculations

  private func compute1X2Probability(
    q: Quote, model: MatchModel, n: Int, seed: UInt64
  ) -> Double {
    let mc = QuantMath.monteCarloOutcome(model.matrix, n: n, seed: seed)
    let modelSide: Double
    switch q.selectionKey {
    case "1": modelSide = model.outcomes.home
    case "X": modelSide = model.outcomes.draw
    default:  modelSide = model.outcomes.away
    }
    let mcSide: Double
    switch q.selectionKey {
    case "1": mcSide = mc.0
    case "X": mcSide = mc.1
    default:  mcSide = mc.2
    }
    return 0.80 * modelSide + 0.20 * mcSide
  }

  private func totalProbabilityFromDistribution(_ q: Quote, dist: [Double]) -> Double {
    guard let line = q.line else { return 0.5 }
    let s = q.selection.lowercased()
    let isUnder = s.contains("under") || s.hasPrefix("u")
    if isUnder {
      return QuantMath.underAsianProbability(dist, line: line).under
    } else {
      return QuantMath.overAsianProbability(dist, line: line).over
    }
  }

  private func computeCardsProbability(
    q: Quote, records: [TeamRecord], ref: RefProfile
  ) -> Double {
    var mean = meanCount(records, \.cards) ?? 4.0
    if ref.n >= 6, let rv = ref.cards {
      mean = blendRef(base: mean, ref: rv, n: ref.n)
    }
    return totalProbability(
      q, mean: mean, variance: countVariance(records, \.cards))
  }

  // MARK: - Finish

  private func finish(
    match: Match, q: Quote, p: Double,
    dcs: Double, quotes: [Quote], sharp: SharpGuard,
    modelOutcomes: (home: Double, draw: Double, away: Double),
    modelName: String, sampleClass: SampleClass,
    homeSample: Int, awaySample: Int,
    posteriorBuckets: [PosteriorBucket]
  ) -> BetSignal? {

    let pRaw = p
    var pFinal = p
    var posteriorWeight: Double = 0
    var posteriorSource: String? = nil
    if !posteriorBuckets.isEmpty {
      let idx = min(9, max(0, Int(p * 10.0)))
      if idx < posteriorBuckets.count {
        let b = posteriorBuckets[idx]
        if b.n >= Self.posteriorMinN {
          let w = Self.posteriorWeight
          pFinal = (1 - w) * p + w * b.factHitRate
          posteriorWeight = w
          posteriorSource = String(
            format: "P %.0f–%.0f%% · n=%d",
            b.probabilityLow * 100, b.probabilityHigh * 100, b.n)
        }
      }
    }

    let quoteProbs = quotes.map { 1.0 / max($0.odds, 1.01) }
    let marketProbability = QuantMath.median(quoteProbs) ?? 0.0
    let marketMAD = QuantMath.mad(quoteProbs.map { $0 * 100 }) ?? 0.0

    let interval = QuantMath.probabilityInterval(
      pFinal, sample: min(homeSample, awaySample), dcs: dcs, marketMAD: marketMAD)

    let robustP = QuantMath.confidenceAdjustedProbability(
      pFinal, uncertainty: interval.uncertainty)

    let ev = QuantMath.ev(p: pFinal, odds: q.odds)
    var robustEV = QuantMath.ev(p: robustP, odds: q.odds)

    var ms = marketScore(qs: quotes.count, odds: q.odds, sharp: sharp)
    if sharp.disagreement > 0.05 {
      ms = max(0, ms - 15)
      robustEV *= 0.70
    }

    let fair = 1 / max(pFinal, 0.001)
    let extreme = q.odds > fair * 1.25
    let anomaly = q.odds > fair * 1.35
    let conflict = abs(pFinal - marketProbability) > 0.25

    if extreme || anomaly || conflict {
      robustEV = -abs(robustEV)
    }

    let mes = computeMES(
      ev: ev, robustEV: robustEV, q: q, p: pFinal, modelOutcomes: modelOutcomes)

    let ts = max(20, min(100, 100 - interval.uncertainty * 220))
    let rs = max(0, 100 * (1 - interval.uncertainty))
    let qcs = 0.30 * mes + 0.20 * dcs + 0.20 * ms + 0.15 * ts + 0.15 * rs

    let classification = classify(
      ev: ev, robustEV: robustEV, qcs: qcs, ms: ms, dcs: dcs,
      anomaly: anomaly, extreme: extreme, conflict: conflict)

    guard classification != "X NO BET" else { return nil }

    let band = UncertaintyBand.from(interval.uncertainty)
    let fullKelly = QuantMath.kelly(p: robustP, odds: q.odds)
    let quarterKelly = 0.25 * fullKelly
    let stakeCap: Double = (classification == "S BET") ? 0.025 : 0.02
    let rawStake = min(stakeCap, quarterKelly * band.kellyMultiplier)

    var signal = BetSignal(
      id: "\(match.id)-\(q.market)-\(q.selection)-\(q.line ?? 0)",
      gameID: match.id, home: match.home, away: match.away, league: match.league,
      market: q.market, selection: q.selection, line: q.line, odds: q.odds,
      probability: pFinal, fairOdds: fair,
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

    signal.probabilityRaw = pRaw
    signal.posteriorWeight = posteriorWeight > 0 ? posteriorWeight : nil
    signal.posteriorSource = posteriorSource
    return signal
  }

  // MARK: - MES

  private func computeMES(
    ev: Double, robustEV: Double, q: Quote, p: Double,
    modelOutcomes: (home: Double, draw: Double, away: Double)
  ) -> Double {
    let edge = max(0, ev)
    let robustBonus: Double = robustEV > 0 ? 15 : 0
    let agreementBonus: Double
    if q.market == "1X2" {
      let modelSelected: Double
      switch q.selectionKey {
      case "1": modelSelected = modelOutcomes.home
      case "X": modelSelected = modelOutcomes.draw
      default:  modelSelected = modelOutcomes.away
      }
      let agreement = max(0, 1 - abs(p - modelSelected))
      agreementBonus = agreement * 25
    } else {
      agreementBonus = 15
    }
    let raw = 30 + edge * 500 + robustBonus + agreementBonus
    return max(0, min(100, raw))
  }

  // MARK: - Classification

  private func classify(
    ev: Double, robustEV: Double, qcs: Double, ms: Double, dcs: Double,
    anomaly: Bool, extreme: Bool, conflict: Bool
  ) -> String {
    if anomaly || extreme || conflict { return "X NO BET" }
    if robustEV > 0 && ev >= 0.07 && qcs >= 85 && ms >= 50 && dcs >= 60 {
      return "S BET"
    }
    if robustEV > 0 && ev >= 0.05 && qcs >= 78 && ms >= 50 && dcs >= 60 {
      return "A BET"
    }
    if ev >= 0.03 && robustEV > 0 { return "B LEAN" }
    if ev > 0 { return "C WATCH" }
    return "X NO BET"
  }

  // MARK: - Portfolio (B4 + B5)

  func portfolio(
    _ signals: [BetSignal],
    excludedRules: [AutoExcludeRule] = [],
    stopLoss: VolatilityState = .normal,
    correlationMatrix: CorrelationMatrix? = nil
  ) -> [BetSignal] {
    if stopLoss.isPause { return [] }

    var chosen: [BetSignal] = []
    var totalExposure = 0.0
    let dailyCap = 0.10
    let cap: Double? = stopLoss.capValue

    let candidates = signals
      .filter { $0.robustEV > 0 }
      .filter { $0.qcs >= 78 }
      .filter { $0.dcs >= 60 }
      .filter {
        !AutoExclude.isExcluded(
          league: $0.league, market: $0.market, rules: excludedRules)
      }
      .sorted { $0.robustEV > $1.robustEV }

    for s in candidates {
      var maxCorr = 0.0
      var reason = ""
      for prev in chosen {
        let c = correlation(s, prev, matrix: correlationMatrix)
        if c > maxCorr {
          maxCorr = c
          reason = correlationReason(s, prev, corr: c, matrix: correlationMatrix)
        }
      }
      if maxCorr >= 0.65 { continue }

      var x = s
      if let cap {
        x.stakeBeforeStop = s.stake
        x.stake = min(s.stake, cap)
        x.stopApplied = "CAP \(Int(cap * 100))%"
      }

      guard totalExposure + x.stake <= dailyCap else { continue }
      x.portfolioCorrelation = maxCorr
      x.correlationReason = reason
      chosen.append(x)
      totalExposure += x.stake
      if chosen.count >= 8 { break }
    }
    return chosen
  }

  /// B4: если для пары есть эмпирика (n≥20), используем её. Иначе — hardcoded.
  private func correlation(
    _ a: BetSignal, _ b: BetSignal,
    matrix: CorrelationMatrix?
  ) -> Double {
    // Same game — жёстко, эмпирику не строим (данных мало).
    if a.gameID == b.gameID {
      if a.market == b.market { return 0.82 }
      let pair = Set([a.market, b.market])
      if pair == Set(["GOALS", "CARDS"]) { return 0.20 }
      if pair == Set(["GOALS", "CORNERS"]) { return 0.25 }
      if pair == Set(["CARDS", "CORNERS"]) { return 0.15 }
      return 0.35
    }
    if a.home == b.home || a.home == b.away
        || a.away == b.home || a.away == b.away {
      return 0.20
    }

    // B4: эмпирическая корреляция.
    if let m = matrix {
      let mk = [a.market, b.market].sorted().joined(separator: "|")
      if let corr = m.marketPairs[mk] { return corr }
      let lk = [a.league, b.league].sorted().joined(separator: "|")
      if let corr = m.leaguePairs[lk] { return corr }
    }
    return 0.03
  }

  private func correlationReason(
    _ a: BetSignal, _ b: BetSignal,
    corr: Double, matrix: CorrelationMatrix?
  ) -> String {
    if a.gameID == b.gameID && a.market == b.market { return "same market" }
    if a.gameID == b.gameID { return "same game" }
    if a.home == b.home || a.home == b.away
        || a.away == b.home || a.away == b.away { return "shared team" }
    if let m = matrix {
      let mk = [a.market, b.market].sorted().joined(separator: "|")
      if m.marketPairs[mk] != nil { return "empirical mkt (\(mk))" }
      let lk = [a.league, b.league].sorted().joined(separator: "|")
      if m.leaguePairs[lk] != nil { return "empirical league (\(lk))" }
    }
    return "independent"
  }

  // MARK: - Model helpers

  private func estimateLambdas(
    _ h: [TeamRecord], _ a: [TeamRecord]
  ) -> (Double, Double)? {
    let hHome = h.filter { $0.isHome }
    let aAway = a.filter { !$0.isHome }

    func shrink(_ x: [Double?]) -> Double? {
      QuantMath.shrink(x.compactMap { $0 }, baseline: nil, k: 8)
    }

    let hGfHome = shrink(hHome.map { $0.gf })
    let hGfAll = shrink(h.map { $0.gf })
    let hAtt = hGfHome ?? hGfAll

    let hGaHome = shrink(hHome.map { $0.ga })
    let hGaAll = shrink(h.map { $0.ga })
    let hDef = hGaHome ?? hGaAll

    let aGfAway = shrink(aAway.map { $0.gf })
    let aGfAll = shrink(a.map { $0.gf })
    let aAtt = aGfAway ?? aGfAll

    let aGaAway = shrink(aAway.map { $0.ga })
    let aGaAll = shrink(a.map { $0.ga })
    let aDef = aGaAway ?? aGaAll

    guard let hAttV = hAtt, let hDefV = hDef,
          let aAttV = aAtt, let aDefV = aDef
    else { return nil }

    let hXg = shrink(h.map { $0.xg })
    let aXg = shrink(a.map { $0.xg })
    let hAttFinal = hXg.map { 0.6 * $0 + 0.4 * hAttV } ?? hAttV
    let aAttFinal = aXg.map { 0.6 * $0 + 0.4 * aAttV } ?? aAttV

    let lh = max(0.08, 0.55 * hAttFinal + 0.45 * aDefV + 0.15)
    let la = max(0.08, 0.55 * aAttFinal + 0.45 * hDefV)
    return (lh, la)
  }

  private func glickoAdjust(
    _ pair: (Double, Double),
    teamRatings: (home: Double?, away: Double?),
    glickoJSON: JSONValue?
  ) -> (Double, Double) {
    if let h = teamRatings.home, let a = teamRatings.away {
      let diff = (h + 60) - a
      let expectedHome = 1.0 / (1.0 + pow(10.0, -diff / 400.0))
      let edge = max(-1, min(1, (expectedHome - 0.5) * 2.0))
      let f = max(-0.12, min(0.12, 0.20 * edge))
      return (pair.0 * (1 + f), pair.1 * (1 - f))
    }
    guard let json = glickoJSON,
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
    let scored: [(PlayerAgg, Double)] = agg.values
      .filter { $0.minutes >= 180 }
      .map { p -> (PlayerAgg, Double) in
        let per90 = 90.0 / max(p.minutes, 1)
        let score = 0.55 * p.xg * per90
          + 0.25 * p.xa * per90
          + 0.12 * p.sot * per90
          + 0.08 * p.goals * per90
        return (p, score)
      }
      .sorted { $0.1 > $1.1 }
    let top = Array(scored.prefix(8))
    var baseline = 0.0
    for item in top {
      let (p, score) = item
      let expMin = min(90.0, p.minutes / max(1.0, Double(p.games)))
      baseline += score * expMin / 90.0
    }
    let repl = scored.dropFirst(8).prefix(8).map { $0.1 }
    let replAvg = repl.isEmpty ? 0.0 : repl.reduce(0, +) / Double(repl.count)
    let gap = max(-1.0, min(1.0,
      (baseline - replAvg) / max(0.5, abs(baseline) + 0.5)))
    let factor = max(0.94, min(1.06, 1.0 + 0.025 * gap))
    return PlayerAssembly(
      factor: factor, baseline: baseline,
      playersUsed: scored.count, top: top.map { $0.0 })
  }

  private func refereeProfile(_ records: [TeamRecord], _ name: String?) -> RefProfile {
    guard let name else {
      return RefProfile(n: 0, cards: nil, fouls: nil, confidence: 0, rsi: 50)
    }
    let r = records.filter {
      ($0.referee ?? "").caseInsensitiveCompare(name) == .orderedSame
    }
    let cards = r.map { ($0.cards ?? 0) + ($0.oppCards ?? 0) }
    let allCards = records.compactMap { ($0.cards ?? 0) + ($0.oppCards ?? 0) }

    let leagueMean = QuantMath.mean(allCards) ?? 4.0
    let totalCardsInt = Int(cards.reduce(0, +))
    let totalGames = max(cards.count, 1)
    let shrunkAvg = QuantMath.betaShrink(
      totalCardsInt, totalGames * 4, priorMean: leagueMean / 8.0, priorStrength: 4) * 8.0

    let rsi = QuantMath.refereeRSI(
      cardsPerGame: shrunkAvg, leagueMean: leagueMean, n: cards.count)

    return RefProfile(
      n: r.count, cards: shrunkAvg, fouls: nil,
      confidence: min(100, Double(r.count) / 15 * 100),
      rsi: rsi)
  }

  private func blendRef(base: Double, ref: Double, n: Int) -> Double {
    let w = min(0.55, Double(n) / Double(n + 8))
    return max(0.1, base * (1 - w) + ref * w)
  }

  private func meanCount(
    _ r: [TeamRecord], _ kp: (TeamRecord) -> Double?
  ) -> Double? {
    QuantMath.shrink(r.compactMap(kp), baseline: nil, k: 8)
  }

  private func countVariance(
    _ r: [TeamRecord], _ kp: (TeamRecord) -> Double?
  ) -> Double {
    let x = r.compactMap(kp)
    return QuantMath.variance(x) ?? max(1, QuantMath.mean(x) ?? 1)
  }

  private func totalProbability(_ q: Quote, mean: Double, variance: Double) -> Double {
    guard let line = q.line else {
      return min(0.9, max(0.1, 1 - exp(-mean)))
    }
    let s = q.selection.lowercased()
    let isUnder = s.contains("under") || s.hasPrefix("u")
    let over = distributionOver(mean: mean, variance: variance, line: line)
    return isUnder ? 1 - over : over
  }

  private func distributionOver(
    mean: Double, variance: Double, line: Double
  ) -> Double {
    let lines = QuantMath.splitQuarterLine(line)

    if lines.count == 1 {
      return singleLineOver(mean: mean, variance: variance, line: lines[0])
    }

    let l1 = lines[0]
    let l2 = lines[1]
    let p1 = singleLineOver(mean: mean, variance: variance, line: l1)
    let p2 = singleLineOver(mean: mean, variance: variance, line: l2)
    return 0.5 * p1 + 0.5 * p2
  }

  private func singleLineOver(mean: Double, variance: Double, line: Double) -> Double {
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
    let seedValue = UInt64(abs(Int(mean * 100)) + 17)
    return QuantMath.monteCarloTotal(
      m, line: line, n: 20000, seed: seedValue, over: true)
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
          guard let p = pv.object else { continue }
          guard let value = number(p, ["value", "odds", "price"]),
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
       let r = Range(m.range(at: 1), in: s) {
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
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if s.contains("1x2") || s.contains("winner") || s.contains("home")
        || trimmed == "1" || trimmed == "x" || trimmed == "2" {
      return "1X2"
    }
    return ""
  }

  // MARK: - JSON helpers

  private func teamName(_ o: [String: JSONValue], _ side: String) -> String? {
    if let team = o[side + "Team"]?.object,
       let name = team["name"]?.string {
      return name
    }
    return string(o, [side, side + "team", side + "_team"])
  }

  private func leagueName(_ o: [String: JSONValue]) -> String? {
    if let season = o["season"]?.object,
       let league = season["league"]?.object,
       let name = league["name"]?.string {
      return name
    }
    if let league = o["league"]?.object,
       let name = league["name"]?.string {
      return name
    }
    return string(o, ["league", "tournament"])
  }

  private func fullGame(_ p: JSONValue) -> [String: JSONValue] {
    if let o = p.object, let d = o["data"]?.object { return d }
    return p.object ?? [:]
  }

  private func teamID(_ o: [String: JSONValue], _ side: String) -> String? {
    if let x = o[side + "Team"]?.object {
      if let s = string(x, ["id", "teamid", "team_id", "flashid"]),
         !s.isEmpty { return s }
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
  var ensembleWeights: (dc: Double, biv: Double, nb: Double) = (0, 0, 0)
  var ensembleAvgXG: Double? = nil
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