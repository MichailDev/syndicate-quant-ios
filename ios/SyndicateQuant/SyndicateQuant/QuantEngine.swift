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
  static let sharpBooks = ["pinnacle", "betfair", "sbo", "sbobet", "marathon", "bet365 exchange"]

  // MARK: - Matches (адаптировано под SStats {status, count, data: [...]})

  func matches(from json: JSONValue) -> [Match] {
    let items: [JSONValue]
    if let obj = json.object, let dataArr = obj["data"]?.array {
      items = dataArr
    } else if let arr = json.array {
      items = arr
    } else {
      // Fallback: если это уже плоский массив объектов
      items = json.allObjects().map { .object($0) }
    }

    var result: [Match] = []
    for item in items {
      guard let o = item.object else { continue }
      guard let id = string(o, ["id", "gameid", "game_id", "eventid", "event_id", "flashid"]),
        !id.isEmpty
      else { continue }

      guard let home = teamName(o, "home"), let away = teamName(o, "away") else { continue }

      let league = leagueName(o) ?? "Unknown"
      let m = Match(
        id: id, home: home, away: away, league: league, start: date(o),
        homeID: teamID(o, "home"), awayID: teamID(o, "away"))
      if !result.contains(where: { $0.id == id }) { result.append(m) }
    }
    return result
  }

  private func teamName(_ o: [String: JSONValue], _ side: String) -> String? {
    // SStats: homeTeam / awayTeam — это объект { uid, id, name }
    if let team = o[side + "Team"]?.object, let name = team["name"]?.string {
      return name
    }
    // Fallback: home / away как плоские строки
    return string(o, [side, side + "team", side + "_team", side + "TeamName", side + "name"])
  }

  private func leagueName(_ o: [String: JSONValue]) -> String? {
    // SStats: season.league.name
    if let season = o["season"]?.object,
      let league = season["league"]?.object,
      let name = league["name"]?.string
    {
      return name
    }
    // Fallback: league.name
    if let league = o["league"]?.object, let name = league["name"]?.string {
      return name
    }
    return string(o, ["league", "tournament", "competition", "league_name"])
  }

  func teamRecord(from payload: JSONValue, targetID: String) -> TeamRecord? {
    let g = fullGame(payload)
    let game = g["game"]?.object ?? g
    let hid = teamID(game, "home")
    let aid = teamID(game, "away")
    guard targetID == hid || targetID == aid else { return nil }
    let isHome = targetID == hid
    let pref = isHome ? "Home" : "Away"
    let opp = isHome ? "Away" : "Home"
    let stats = g["statistics"]?.object ?? [:]
    func s(_ k: String) -> Double? { number(stats, [k + pref]) }
    let gf = number(game, [isHome ? "homeFTResult" : "awayFTResult"])
    let ga = number(game, [isHome ? "awayFTResult" : "homeFTResult"])
    return TeamRecord(
      id: targetID, date: date(game), gf: gf, ga: ga,
      corners: s("cornerKicks"), oppCorners: number(stats, ["cornerKicks" + opp]),
      cards: s("yellowCards"), oppCards: number(stats, ["yellowCards" + opp]),
      fouls: s("fouls"), oppFouls: number(stats, ["fouls" + opp]),
      shots: s("totalShots"), sot: s("shotsOnGoal"), possession: s("ballPossession"),
      xg: s("expectedGoals"), oppXg: number(stats, ["expectedGoals" + opp]),
      referee: string(g, ["refereeName"]) ?? string(game, ["refereeName"]),
      players: extractPlayers(g, targetID))
  }

  func model(home: [TeamRecord], away: [TeamRecord], glicko: JSONValue? = nil) -> MatchModel? {
    guard let base = estimateLambdas(home, away) else { return nil }
    let ph = playerAssembly(home)
    let pa = playerAssembly(away)
    let player = (base.0 * ph.factor, base.1 * pa.factor)
    let final = glickoAdjust(player, glicko)
    let baseM = QuantMath.dixonColes(base.0, base.1, rho: -0.055, maxGoals: 12)
    let playerM = QuantMath.dixonColes(player.0, player.1, rho: -0.055, maxGoals: 12)
    let finalM = QuantMath.dixonColes(final.0, final.1, rho: -0.055, maxGoals: 12)
    let bo = QuantMath.outcomes(baseM)
    let po = QuantMath.outcomes(playerM)
    let fo = QuantMath.outcomes(finalM)
    return MatchModel(
      lh: final.0, la: final.1, baseLH: base.0, baseLA: base.1, baseMatrix: baseM,
      playerMatrix: playerM, matrix: finalM, outcomes: fo,
      components: [
        bo.home, bo.draw, bo.away, po.home, po.draw, po.away, fo.home, fo.draw, fo.away,
      ], playerHome: ph, playerAway: pa)
  }

  func signals(
    match: Match, info: JSONValue, oddsJSON: JSONValue, homeHistory: [TeamRecord],
    awayHistory: [TeamRecord], glicko: JSONValue? = nil
  ) -> [BetSignal] {
    guard let model = model(home: homeHistory, away: awayHistory, glicko: glicko) else { return [] }
    let quotes = parseQuotes(oddsJSON)
    var out: [BetSignal] = []
    let grouped = Dictionary(grouping: quotes, by: key(_:))
    let dcs = dcsScore(homeHistory, awayHistory)
    let refereeName = string(info.allObjects().first ?? [:], ["refereeName", "referee"])
    let ref = refereeProfile(homeHistory + awayHistory, refereeName)
    for (_, qs) in grouped {
      guard qs.count >= 3 else { continue }
      guard let median = QuantMath.median(qs.map { $0.odds }), let q = qs.first else { continue }
      let sharp = sharpGuard(qs, median: median)
      let p: Double
      let modelName: String
      if q.market == "1X2" {
        let mc = QuantMath.monteCarloOutcome(model.matrix, n: 20000, seed: 17)
        p =
          0.80
          * (q.selectionKey == "1"
            ? model.outcomes.home
            : (q.selectionKey == "X" ? model.outcomes.draw : model.outcomes.away)) + 0.20
          * (q.selectionKey == "1" ? mc.0 : (q.selectionKey == "X" ? mc.1 : mc.2))
        modelName = "DIXON_COLES+PLAYER+GLICKO+MC"
      } else if q.market == "GOALS" {
        p = totalProbability(
          q, mean: max(0.1, model.lh + model.la), variance: goalVariance(homeHistory + awayHistory))
        modelName = "POISSON/NB+MC+PLAYER"
      } else if q.market == "CARDS" {
        var mean = meanCount(homeHistory + awayHistory, \.cards) ?? 4.0
        if ref.n >= 6, let rv = ref.cards { mean = blendRef(base: mean, ref: rv, n: ref.n) }
        p = totalProbability(
          q, mean: mean, variance: countVariance(homeHistory + awayHistory, \.cards))
        modelName = "POISSON/NB+REFEREE+MC"
      } else if q.market == "CORNERS" {
        let mean = meanCount(homeHistory + awayHistory, \.corners) ?? 10.0
        p = totalProbability(
          q, mean: mean, variance: countVariance(homeHistory + awayHistory, \.corners))
        modelName = "POISSON/NB+PRESSURE+MC"
      } else {
        continue
      }
      if let s = finish(
        match, q, p, median, dcs, qs, sharp: sharp, modelOutcomes: model.outcomes, model: modelName)
      {
        out.append(s)
      }
    }
    return out.sorted { $0.qcs > $1.qcs }
  }

  func portfolio(_ signals: [BetSignal]) -> [BetSignal] {
    var chosen: [BetSignal] = []
    var total = 0.0
    for s in signals.filter({ $0.robustEV > 0 && $0.qcs >= 78 }).sorted(by: {
      $0.robustEV > $1.robustEV
    }) {
      let st = min(0.02, s.stake)
      guard total + st <= 0.10 else { continue }
      guard !chosen.contains(where: { correlation(s, $0) >= 0.65 }) else { continue }
      var x = s
      x.portfolioCorrelation = chosen.map { correlation(s, $0) }.max() ?? 0
      chosen.append(x)
      total += st
      if chosen.count >= 8 { break }
    }
    return chosen
  }

  // MARK: - Model components
  private func estimateLambdas(_ h: [TeamRecord], _ a: [TeamRecord]) -> (Double, Double)? {
    func b(_ x: [Double?]) -> Double? { QuantMath.shrink(x.compactMap { $0 }, baseline: nil, k: 8) }
    guard let hgf = b(h.map { $0.gf }), let hga = b(h.map { $0.ga }), let agf = b(a.map { $0.gf }),
      let aga = b(a.map { $0.ga })
    else { return nil }
    let hxg = b(h.map { $0.xg }) ?? hgf
    let axg = b(a.map { $0.xg }) ?? agf
    let hxga = b(h.map { $0.oppXg }) ?? hga
    let axga = b(a.map { $0.oppXg }) ?? aga
    let hatt = 0.65 * hxg + 0.35 * hgf
    let aatt = 0.65 * axg + 0.35 * agf
    let hdef = 0.65 * hga + 0.35 * hxga
    let adef = 0.65 * aga + 0.35 * axga
    return (max(0.08, 0.56 * hatt + 0.44 * adef), max(0.08, 0.56 * aatt + 0.44 * hdef))
  }

  private func glickoAdjust(_ pair: (Double, Double), _ json: JSONValue?) -> (Double, Double) {
    guard let json, let ph = firstNumber(json, ["homeWinProbability", "HomeWinProbability"]),
      let pa = firstNumber(json, ["awayWinProbability", "AwayWinProbability"])
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
        x.minutes += p.minutes
        x.xg += p.xg
        x.xa += p.xa
        x.goals += p.goals
        x.assists += p.assists
        x.shots += p.shots
        x.sot += p.sot
        x.games += 1
        agg[p.id] = x
      }
    }
    let scored: [(PlayerAgg, Double)] = agg.values.filter { $0.minutes >= 180 }.map { p in
      let per90 = 90.0 / max(p.minutes, 1)
      return (
        p, 0.55 * p.xg * per90 + 0.25 * p.xa * per90 + 0.12 * p.sot * per90 + 0.08 * p.goals * per90
      )
    }.sorted { $0.1 > $1.1 }
    let top = Array(scored.prefix(8))
    let baseline = top.reduce(0) { acc, item in
      let (p, score) = item
      let expectedMinutes = min(90.0, p.minutes / max(1.0, Double(p.games)))
      return acc + score * expectedMinutes / 90.0
    }
    let replacementScores = scored.dropFirst(8).prefix(8).map { $0.1 }
    let replacement =
      replacementScores.isEmpty
      ? 0.0 : replacementScores.reduce(0, +) / Double(replacementScores.count)
    let replacementGap = max(
      -1.0, min(1.0, (baseline - replacement) / max(0.5, abs(baseline) + 0.5)))
    return PlayerAssembly(
      factor: max(0.94, min(1.06, 1.0 + 0.025 * replacementGap)), baseline: baseline,
      playersUsed: scored.count, top: top.map { $0.0 })
  }

  private func refereeProfile(_ records: [TeamRecord], _ name: String?) -> RefProfile {
    guard let name else { return RefProfile(n: 0, cards: nil, fouls: nil, confidence: 0) }
    let r = records.filter {
      ($0.referee ?? "").caseInsensitiveCompare(name) == ComparisonResult.orderedSame
    }
    let cards = r.map { ($0.cards ?? 0) + ($0.oppCards ?? 0) }
    let fouls = r.map { ($0.fouls ?? 0) + ($0.oppFouls ?? 0) }
    let baseCards = QuantMath.mean(records.compactMap { ($0.cards ?? 0) + ($0.oppCards ?? 0) })
    let baseFouls = QuantMath.mean(records.compactMap { ($0.fouls ?? 0) + ($0.oppFouls ?? 0) })
    let w = Double(r.count) / Double(r.count + 8)
    let shrunkCards = cards.map { w * $0 + (1 - w) * (baseCards ?? 0) }
    let shrunkFouls = fouls.map { w * $0 + (1 - w) * (baseFouls ?? 0) }
    return RefProfile(
      n: r.count, cards: QuantMath.mean(shrunkCards), fouls: QuantMath.mean(shrunkFouls),
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
    let isUnder =
      q.selection.lowercased().contains("under") || q.selection.lowercased().hasPrefix("u")
    let over = distributionOver(mean: mean, variance: variance, line: line)
    return isUnder ? 1 - over : over
  }
  private func distributionOver(mean: Double, variance: Double, line: Double) -> Double {
    let frac = line.rounded() - line
    if abs(abs(frac) - 0.25) < 0.001 || abs(abs(frac) - 0.75) < 0.001 {
      let lo = floor(line * 2) / 2
      let hi = ceil(line * 2) / 2
      return 0.5 * distributionOver(mean: mean, variance: variance, line: lo) + 0.5
        * distributionOver(mean: mean, variance: variance, line: hi)
    }
    if variance > mean * 1.08 {
      let k = Int(floor(line))
      var cdf = 0.0
      if k >= 0 {
        for i in 0...k { cdf += QuantMath.negativeBinomialPMF(i, mean: mean, variance: variance) }
      }
      return 1 - cdf
    }
    let m = QuantMath.dixonColes(mean / 2, mean / 2, rho: 0, maxGoals: 20)
    return QuantMath.monteCarloTotal(
      m, line: line, n: 20000, seed: UInt64(abs(Int(mean * 100)) + 17), over: true)
  }

  private func finish(
    _ match: Match, _ q: Quote, _ p: Double, _ odds: Double, _ dcs: Double, _ quotes: [Quote],
    sharp: SharpGuard, modelOutcomes: (home: Double, draw: Double, away: Double), model: String
  ) -> BetSignal? {
    let quoteProbabilities = quotes.map { 1.0 / max($0.odds, 1.01) }
    let marketProbability = QuantMath.median(quoteProbabilities) ?? 0.0
    let marketMAD = QuantMath.mad(quoteProbabilities.map { $0 * 100 }) ?? 0.0
    let interval = QuantMath.probabilityInterval(p, sample: 15, dcs: dcs, marketMAD: marketMAD)
    let robustP = QuantMath.confidenceAdjustedProbability(p, uncertainty: interval.uncertainty)
    var ev = QuantMath.ev(p: p, odds: odds)
    var robust = QuantMath.ev(p: robustP, odds: odds)
    var ms = marketScore(qs: quotes.count, odds: odds, sharp: sharp)
    if sharp.disagreement > 0.05 {
      ms = max(0, ms - 15)
      robust *= 0.70
    }
    if sharp.score > 0 && sharp.score < 35 {
      ms = max(0, ms - 20)
      robust = -abs(robust)
    }
    let fair = 1 / max(p, 0.001)
    let extreme = odds > fair * 1.25
    let anomaly = odds > fair * 1.35
    let conflict = abs(p - marketProbability) > 0.18 && quotes.count >= 3
    if extreme || anomaly || quotes.count < 3 || conflict { robust = -abs(robust) }
    let agreement =
      q.market == "1X2"
      ? max(
        0,
        1
          - abs(
            p
              - (q.selectionKey == "1"
                ? modelOutcomes.home
                : (q.selectionKey == "X" ? modelOutcomes.draw : modelOutcomes.away))))
      : max(0, 1 - abs(p - marketProbability))
    let ts = max(20, min(100, 100 - interval.uncertainty * 220))
    let rs = 100 * agreement
    let qcs = 0.30 * min(100, dcs) + 0.20 * min(100, dcs) + 0.20 * ms + 0.15 * ts + 0.15 * rs
    let classification: String
    if anomaly || extreme || quotes.count < 3 || conflict {
      classification = "X NO BET"
    } else if robust > 0 && ev >= 0.07 && qcs >= 85 && ms >= 50 && dcs >= 60 {
      classification = "S BET"
    } else if robust > 0 && ev >= 0.05 && qcs >= 78 && ms >= 50 && dcs >= 60 {
      classification = "A BET"
    } else if ev >= 0.03 {
      classification = "B LEAN"
    } else if ev > 0 {
      classification = "C WATCH"
    } else {
      classification = "X NO BET"
    }
    guard classification != "X NO BET" else { return nil }
    return BetSignal(
      id: "\(match.id)-\(q.market)-\(q.selection)-\(q.line ?? 0)", gameID: match.id,
      home: match.home, away: match.away, league: match.league, market: q.market,
      selection: q.selection, line: q.line, odds: odds, probability: p, fairOdds: fair, ev: ev,
      robustEV: robust, qcs: qcs, dcs: dcs, model: model, timestamp: Date(),
      classification: classification, stake: QuantMath.kelly(p: robustP, odds: odds),
      priceAnomaly: anomaly || extreme, bookmakers: quotes.count, portfolioCorrelation: 0,
      marketProbability: marketProbability, marketMAD: marketMAD, probabilityLow: interval.low,
      probabilityHigh: interval.high, uncertainty: interval.uncertainty, modelAgreement: rs)
  }
  private func dcsScore(_ h: [TeamRecord], _ a: [TeamRecord]) -> Double {
    let n = Double(min(h.count, a.count))
    let sample = min(100, n / 15 * 100)
    return round(0.30 * 90 + 0.25 * sample + 0.20 * 75 + 0.15 * 85 + 0.10 * 95)
  }
  private func marketScore(qs: Int, odds: Double, sharp: SharpGuard) -> Double {
    var score = 25.0
    score += Double(min(qs, 8)) * 7.0
    if odds > 1.80 { score += 5 }
    if sharp.score >= 55 { score += 20 }
    if sharp.disagreement <= 0.03 { score += 10 } else if sharp.disagreement > 0.08 { score -= 15 }
    return max(0, min(100, score))
  }
  private func correlation(_ a: BetSignal, _ b: BetSignal) -> Double {
    if a.gameID == b.gameID {
      if a.market == b.market { return 0.82 }
      if Set([a.market, b.market]) == Set(["GOALS", "CARDS"]) { return 0.20 }
      if Set([a.market, b.market]) == Set(["GOALS", "CORNERS"]) { return 0.25 }
      return 0.35
    }
    if a.home == b.home || a.home == b.away || a.away == b.home || a.away == b.away { return 0.20 }
    return 0.03
  }

  // MARK: - Odds / sharp
  private func parseQuotes(_ json: JSONValue) -> [Quote] {
    var out: [Quote] = []
    for o in json.allObjects() {
      guard let odds = number(o, ["odds", "value", "odd", "price"]), odds > 1, odds < 100 else {
        continue
      }
      let m = string(o, ["market", "marketname", "market_name", "type", "markettype"]) ?? ""
      let s = string(o, ["selection", "outcome", "outcomename", "name", "label"]) ?? ""
      guard !m.isEmpty || !s.isEmpty else { continue }
      let book = string(o, ["bookmaker", "bookmakername", "book", "source"]) ?? "unknown"
      let line = number(o, ["line", "handicap", "total", "param", "parameter"])
      let market = normalizeMarket(m + " " + s)
      guard !market.isEmpty else { continue }
      out.append(Quote(market: market, selection: s, line: line, odds: odds, bookmaker: book))
    }
    return out
  }
  private func key(_ q: Quote) -> String {
    "\(q.market)|\(q.selection.lowercased())|\(q.line ?? -999)"
  }
  private func sharpGuard(_ qs: [Quote], median: Double) -> SharpGuard {
    let sharp = qs.filter { q in
      Self.sharpBooks.contains(where: { q.bookmaker.lowercased().contains($0) })
    }.map { $0.odds }
    guard let sm = QuantMath.median(sharp) else { return SharpGuard(score: 0, disagreement: 0) }
    let dis = abs(sm / median - 1)
    var score = 35.0
    if qs.count >= 4 { score += 25 }
    if dis <= 0.03 { score += 20 }
    return SharpGuard(
      score: score, movement: 0, sharpMovement: 0, disagreement: dis, sharpClose: sm, sharpOpen: nil
    )
  }
  private func normalizeMarket(_ x: String) -> String {
    let s = x.lowercased()
    if s.contains("corner") { return "CORNERS" }
    if s.contains("card") || s.contains("yellow") { return "CARDS" }
    if s.contains("goal") || s.contains("total") || s.contains("over") || s.contains("under") {
      return "GOALS"
    }
    if s.contains("1x2") || s.contains("winner") || s.trimmingCharacters(in: .whitespaces) == "1"
      || s.trimmingCharacters(in: .whitespaces) == "x"
      || s.trimmingCharacters(in: .whitespaces) == "2"
    {
      return "1X2"
    }
    return ""
  }

  // MARK: - JSON normalization
  private func extractPlayers(_ g: [String: JSONValue], _ teamID: String) -> [PlayerRow] {
    let arr = (g["playerStats"] ?? g["players"] ?? g["lineupPlayers"])?.allObjects() ?? []
    return arr.compactMap { p in
      let tid = string(p, ["teamId", "team_id"])
      guard tid == nil || tid == teamID else { return nil }
      let mins =
        number(p, ["minutes", "minutesPlayed", "minutes_played", "mins", "timePlayed"])
        ?? ((p["startXI"]?.bool ?? false || p["started"]?.bool ?? false) ? 90 : 0)
      guard mins > 0 else { return nil }
      return PlayerRow(
        id: string(p, ["playerId", "id"]) ?? UUID().uuidString,
        name: string(p, ["playerName", "name"]) ?? "", minutes: mins,
        xg: number(p, ["expectedGoals", "xG", "xg"]) ?? 0,
        xa: number(p, ["expectedAssists", "xA", "xa"]) ?? 0,
        goals: number(p, ["goals", "goal"]) ?? 0, assists: number(p, ["assists", "assist"]) ?? 0,
        shots: number(p, ["shots", "totalShots"]) ?? 0,
        sot: number(p, ["shotsOnGoal", "sot"]) ?? 0, starts: (p["startXI"]?.bool ?? false) ? 1 : 0)
    }
  }
  private func fullGame(_ p: JSONValue) -> [String: JSONValue] {
    if let o = p.object, let d = o["data"]?.object { return d }
    return p.object ?? [:]
  }
  private func teamID(_ o: [String: JSONValue], _ side: String) -> String? {
    if let x = o[side + "Team"]?.object {
      // SStats: приоритет — uid (UUID). Fallback — id / teamId / flashId.
      return string(x, ["uid", "id", "teamid", "team_id", "flashid"])
    }
    return string(o, [side + "TeamId", side + "TeamID", side + "Id", side + "ID"])
  }
  private func string(_ o: [String: JSONValue], _ keys: [String]) -> String? {
    for k in keys { if let s = o[k]?.string { return s } }
    return nil
  }
  private func number(_ o: [String: JSONValue], _ keys: [String]) -> Double? {
    for k in keys { if let n = o[k]?.number { return n } }
    return nil
  }
  private func firstNumber(_ v: JSONValue, _ keys: [String]) -> Double? {
    v.firstNumber(keys: Set(keys.map { $0.lowercased() }))
  }
  private func nestedID(_ o: [String: JSONValue], _ keys: [String]) -> String? {
    for k in keys {
      if let x = o[k]?.object, let id = string(x, ["uid", "id", "teamid", "team_id", "flashid"]) {
        return id
      }
    }
    return nil
  }
  private func date(_ o: [String: JSONValue]) -> Date? {
    if let s = string(o, ["date", "datetime", "starttime", "start_time", "timestamp"]) {
      let f = ISO8601DateFormatter()
      if let d = f.date(from: s) { return d }
      // Для строк с миллисекундами
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let d = f.date(from: s) { return d }
      if let t = Double(s) { return Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t) }
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