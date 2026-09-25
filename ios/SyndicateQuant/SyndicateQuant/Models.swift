import Foundation
import SwiftData
import SwiftUI

// MARK: - League whitelist

enum LeaguePool {
  static let pool: [(id: Int, name: String)] = [
    (39, "Premier League"),
    (78, "Bundesliga"),
    (140, "La Liga"),
    (135, "Serie A"),
    (61, "Ligue 1"),
    (235, "RPL"),
    (2, "Champions League"),
    (3, "Europa League"),
    (94, "Liga Portugal"),
    (88, "Eredivisie"),
    (144, "Pro League"),
  ]
  static func id(for name: String) -> Int? { pool.first(where: { $0.name == name })?.id }
  static func name(for id: Int) -> String? { pool.first(where: { $0.id == id })?.name }
}

// MARK: - League baselines

struct LeagueBaseline: Identifiable, Hashable {
  let id: Int
  let name: String
  let homeLambda: Double
  let awayLambda: Double
  let homeAdvantage: Double
  let rho: Double
  let sampleSize: Int
}

enum LeagueBaselines {
  static let all: [LeagueBaseline] = [
    LeagueBaseline(id: 39,  name: "Premier League",   homeLambda: 1.55, awayLambda: 1.20, homeAdvantage: 0.22, rho: -0.08, sampleSize: 0),
    LeagueBaseline(id: 78,  name: "Bundesliga",       homeLambda: 1.68, awayLambda: 1.28, homeAdvantage: 0.18, rho: -0.06, sampleSize: 0),
    LeagueBaseline(id: 140, name: "La Liga",          homeLambda: 1.45, awayLambda: 1.10, homeAdvantage: 0.24, rho: -0.09, sampleSize: 0),
    LeagueBaseline(id: 135, name: "Serie A",          homeLambda: 1.48, awayLambda: 1.15, homeAdvantage: 0.21, rho: -0.07, sampleSize: 0),
    LeagueBaseline(id: 61,  name: "Ligue 1",          homeLambda: 1.42, awayLambda: 1.12, homeAdvantage: 0.20, rho: -0.08, sampleSize: 0),
    LeagueBaseline(id: 235, name: "RPL",              homeLambda: 1.35, awayLambda: 1.05, homeAdvantage: 0.25, rho: -0.10, sampleSize: 0),
    LeagueBaseline(id: 2,   name: "Champions League", homeLambda: 1.55, awayLambda: 1.25, homeAdvantage: 0.20, rho: -0.08, sampleSize: 0),
    LeagueBaseline(id: 3,   name: "Europa League",    homeLambda: 1.50, awayLambda: 1.20, homeAdvantage: 0.20, rho: -0.08, sampleSize: 0),
    LeagueBaseline(id: 94,  name: "Liga Portugal",    homeLambda: 1.40, awayLambda: 1.05, homeAdvantage: 0.23, rho: -0.09, sampleSize: 0),
    LeagueBaseline(id: 88,  name: "Eredivisie",       homeLambda: 1.70, awayLambda: 1.30, homeAdvantage: 0.16, rho: -0.05, sampleSize: 0),
    LeagueBaseline(id: 144, name: "Pro League",       homeLambda: 1.55, awayLambda: 1.20, homeAdvantage: 0.20, rho: -0.08, sampleSize: 0),
  ]
  static func baseline(for name: String) -> LeagueBaseline? {
    all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }
}

// MARK: - Sample classification

enum SampleClass: String, Codable {
  case full = "FULL"
  case good = "GOOD"
  case usable = "USABLE"
  case insufficient = "INS."

  static func classify(_ n: Int) -> SampleClass {
    if n >= 15 { return .full }
    if n >= 10 { return .good }
    if n >= 6 { return .usable }
    return .insufficient
  }
  var trustWeight: Double {
    switch self {
    case .full: return 1.0
    case .good: return 0.85
    case .usable: return 0.65
    case .insufficient: return 0.0
    }
  }
  var dcsScore: Double {
    switch self {
    case .full: return 100
    case .good: return 80
    case .usable: return 55
    case .insufficient: return 20
    }
  }
}

// MARK: - Uncertainty band

enum UncertaintyBand {
  case low, medium, high
  static func from(_ u: Double) -> UncertaintyBand {
    if u < 0.10 { return .low }
    if u < 0.22 { return .medium }
    return .high
  }
  var kellyMultiplier: Double {
    switch self {
    case .low: return 1.00
    case .medium: return 0.75
    case .high: return 0.50
    }
  }
  var label: String {
    switch self {
    case .low: return "LOW"
    case .medium: return "MED"
    case .high: return "HIGH"
    }
  }
}

// MARK: - Match

struct Match: Identifiable, Codable, Hashable {
  let id: String
  let home: String
  let away: String
  let league: String
  let start: Date?
  let homeID: String?
  let awayID: String?
  var homeFT: Double?
  var awayFT: Double?
  var oddsJSON: JSONValue?
  var numericID: Int?
}

struct Quote: Codable, Hashable {
  let market: String
  let selection: String
  let line: Double?
  let odds: Double
  let bookmaker: String
}

// MARK: - BetSignal

struct BetSignal: Identifiable, Codable, Hashable {
  let id: String
  let gameID: String
  let home: String
  let away: String
  let league: String
  let market: String
  let selection: String
  let line: Double?
  let odds: Double
  let probability: Double
  let fairOdds: Double
  let ev: Double
  let robustEV: Double
  let model: String
  let timestamp: Date
  let classification: String
  var stake: Double
  let priceAnomaly: Bool
  let bookmakers: Int

  let dcs: Double
  let ms: Double
  let mes: Double
  let ts: Double
  let rs: Double
  let qcs: Double

  let sampleClass: String
  let homeSample: Int
  let awaySample: Int
  let uncertainty: Double
  let uncertaintyBand: String
  let marketProbability: Double
  let marketMAD: Double
  let probabilityLow: Double
  let probabilityHigh: Double

  let kellyFraction: Double
  let quarterKelly: Double
  let stakeCap: Double
  var portfolioCorrelation: Double
  var correlationReason: String

  var probabilityRaw: Double? = nil
  var posteriorWeight: Double? = nil
  var posteriorSource: String? = nil

  var stopApplied: String? = nil
  var stakeBeforeStop: Double? = nil

  var playerImpactHome: Double? = nil
  var playerImpactAway: Double? = nil

  var stakeMoney: Double? = nil
  var bestOdds: Double? = nil
  var bestBook: String? = nil
  var worstOdds: Double? = nil
  var worstBook: String? = nil
  var avgOdds: Double? = nil

  var sharpMoney: Bool? = nil
  var sharpMovement: Double? = nil
  var liveMovement: Double? = nil

  var modelVote: Int? = nil
  var modelVoteDetail: String? = nil
}

// MARK: - Team rating

@Model final class TeamRating {
  @Attribute(.unique) var teamID: String
  var name: String
  var rating: Double
  var matches: Int
  var lastDelta: Double
  var updatedAt: Date

  init(teamID: String, name: String = "",
       rating: Double = 1500, matches: Int = 0) {
    self.teamID = teamID
    self.name = name
    self.rating = rating
    self.matches = matches
    self.lastDelta = 0
    self.updatedAt = Date()
  }
}

// MARK: - Tuning config

@Model final class TuningConfig {
  @Attribute(.unique) var id: String

  var autoExcludeEnabled: Bool
  var posteriorEnabled: Bool
  var stopLossEnabled: Bool
  var correlationEnabled: Bool
  var playerImpactEnabled: Bool
  var teamRatingEnabled: Bool

  var posteriorWeight: Double
  var autoExcludeMinROI: Double
  var autoExcludeMinBets: Int
  var stopLossCapStreak: Int
  var stopLossPauseStreak: Int

  var updatedAt: Date

  init(id: String = "current") {
    self.id = id
    self.autoExcludeEnabled = true
    self.posteriorEnabled = true
    self.stopLossEnabled = true
    self.correlationEnabled = true
    self.playerImpactEnabled = true
    self.teamRatingEnabled = true

    self.posteriorWeight = 0.15
    self.autoExcludeMinROI = -0.05
    self.autoExcludeMinBets = 20
    self.stopLossCapStreak = 4
    self.stopLossPauseStreak = 7

    self.updatedAt = Date()
  }
}

@Model final class TuningEvent {
  @Attribute(.unique) var id: String
  var createdAt: Date
  var kind: String
  var target: String
  var beforeValue: String
  var afterValue: String
  var note: String
  var rolledBack: Bool

  init(id: String = UUID().uuidString, createdAt: Date = Date(),
       kind: String, target: String,
       beforeValue: String, afterValue: String,
       note: String = "", rolledBack: Bool = false) {
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
    self.target = target
    self.beforeValue = beforeValue
    self.afterValue = afterValue
    self.note = note
    self.rolledBack = rolledBack
  }
}

struct AutoDecision: Identifiable, Hashable {
  var id: String
  var title: String
  var summary: String
  var detail: String
  var enabled: Bool
  var flagKey: String
}

@MainActor
enum TuningService {
  static func fetchOrCreate(in context: ModelContext) -> TuningConfig {
    let descriptor = FetchDescriptor<TuningConfig>()
    if let existing = try? context.fetch(descriptor).first { return existing }
    let cfg = TuningConfig()
    context.insert(cfg)
    try? context.save()
    return cfg
  }

  static func log(context: ModelContext, kind: String, target: String,
                  before: String, after: String, note: String = "") {
    let e = TuningEvent(kind: kind, target: target,
                        beforeValue: before, afterValue: after, note: note)
    context.insert(e)
    try? context.save()
  }

  static func recentEvents(context: ModelContext, limit: Int = 30) -> [TuningEvent] {
    var d = FetchDescriptor<TuningEvent>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    d.fetchLimit = limit
    return (try? context.fetch(d)) ?? []
  }

  static func rollbackLastThreshold(in context: ModelContext) -> TuningEvent? {
    let d = FetchDescriptor<TuningEvent>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    guard let events = try? context.fetch(d) else { return nil }
    guard let last = events.first(where: {
      ($0.kind == "threshold" || $0.kind == "toggle") && !$0.rolledBack
    }) else { return nil }

    let cfg = fetchOrCreate(in: context)
    switch last.target {
    case "posteriorWeight":
      cfg.posteriorWeight = Double(last.beforeValue) ?? cfg.posteriorWeight
    case "autoExcludeMinROI":
      cfg.autoExcludeMinROI = Double(last.beforeValue) ?? cfg.autoExcludeMinROI
    case "autoExcludeMinBets":
      cfg.autoExcludeMinBets = Int(last.beforeValue) ?? cfg.autoExcludeMinBets
    case "stopLossCapStreak":
      cfg.stopLossCapStreak = Int(last.beforeValue) ?? cfg.stopLossCapStreak
    case "stopLossPauseStreak":
      cfg.stopLossPauseStreak = Int(last.beforeValue) ?? cfg.stopLossPauseStreak
    case "autoExcludeEnabled":
      cfg.autoExcludeEnabled = Bool(last.beforeValue) ?? cfg.autoExcludeEnabled
    case "posteriorEnabled":
      cfg.posteriorEnabled = Bool(last.beforeValue) ?? cfg.posteriorEnabled
    case "stopLossEnabled":
      cfg.stopLossEnabled = Bool(last.beforeValue) ?? cfg.stopLossEnabled
    case "correlationEnabled":
      cfg.correlationEnabled = Bool(last.beforeValue) ?? cfg.correlationEnabled
    case "playerImpactEnabled":
      cfg.playerImpactEnabled = Bool(last.beforeValue) ?? cfg.playerImpactEnabled
    case "teamRatingEnabled":
      cfg.teamRatingEnabled = Bool(last.beforeValue) ?? cfg.teamRatingEnabled
    default: break
    }
    cfg.updatedAt = Date()
    last.rolledBack = true
    try? context.save()
    return last
  }

  static func decisions(config: TuningConfig,
                        snapshot: BacktestSnapshot?,
                        journal: [JournalEntry],
                        corr: CorrelationMatrix) -> [AutoDecision] {
    var out: [AutoDecision] = []

    let rules = snapshot.map {
      AutoExclude.rules(from: $0,
                        minROI: config.autoExcludeMinROI,
                        minBets: config.autoExcludeMinBets)
    } ?? []
    let activeRules = rules.filter { $0.excluded }.count
    out.append(AutoDecision(
      id: "autoexclude", title: "Auto-Exclude",
      summary: config.autoExcludeEnabled ? "\(activeRules) активных правил" : "выключено",
      detail: String(format: "Порог: ROI < %.1f%% при n ≥ %d",
                     config.autoExcludeMinROI * 100, config.autoExcludeMinBets),
      enabled: config.autoExcludeEnabled, flagKey: "autoExcludeEnabled"))

    let buckets = snapshot?.decodedPosteriorBuckets() ?? []
    let usable = buckets.filter { $0.n >= 20 }.count
    out.append(AutoDecision(
      id: "posterior", title: "Bayesian posterior",
      summary: config.posteriorEnabled ? "\(usable) бакетов (n≥20)" : "выключено",
      detail: String(format: "p_adj = (1 − %.2f)·p + %.2f·p_post",
                     config.posteriorWeight, config.posteriorWeight),
      enabled: config.posteriorEnabled, flagKey: "posteriorEnabled"))

    let streak = VolatilityStop.evaluate(journal,
      capThreshold: config.stopLossCapStreak,
      pauseThreshold: config.stopLossPauseStreak)
    out.append(AutoDecision(
      id: "stoploss", title: "Volatility stop",
      summary: config.stopLossEnabled
        ? "\(streak.streak) проигрышей · \(streak.state.label)"
        : "выключено",
      detail: "Cap ≥ \(config.stopLossCapStreak) → 5%; Pause ≥ \(config.stopLossPauseStreak)",
      enabled: config.stopLossEnabled, flagKey: "stopLossEnabled"))

    out.append(AutoDecision(
      id: "correlation", title: "Correlation matrix",
      summary: config.correlationEnabled
        ? "\(corr.marketPairsN.count + corr.leaguePairsN.count) пар (n≥20)"
        : "выключено",
      detail: "Эмпирические φ-коэффициенты из журнала; fallback — структурные",
      enabled: config.correlationEnabled, flagKey: "correlationEnabled"))

    out.append(AutoDecision(
      id: "playerimpact", title: "Player impact",
      summary: config.playerImpactEnabled ? "ждём составы от API" : "выключено",
      detail: "λ × 0.88…1.00 в зависимости от отсутствия топ-8",
      enabled: config.playerImpactEnabled, flagKey: "playerImpactEnabled"))

    out.append(AutoDecision(
      id: "teamrating", title: "Team rating (Elo)",
      summary: config.teamRatingEnabled ? "активно (≥ 3 матчей на команду)" : "выключено",
      detail: "Старт 1500, HFA 60, K=32→20; влияет на λ через glickoAdjust",
      enabled: config.teamRatingEnabled, flagKey: "teamRatingEnabled"))

    return out
  }
}

// MARK: - Volatility stop

enum VolatilityState: Equatable {
  case normal
  case cap(Double)
  case pause

  var label: String {
    switch self {
    case .normal: return "NORMAL"
    case .cap(let v): return String(format: "CAP %.1f%%", v * 100)
    case .pause: return "PAUSE"
    }
  }
  var isPause: Bool { if case .pause = self { return true }; return false }
  var capValue: Double? { if case .cap(let v) = self { return v }; return nil }
}

enum VolatilityStop {
  static let defaultCapThreshold = 4
  static let defaultPauseThreshold = 7
  static let defaultCapValue = 0.05

  static func evaluate(_ journal: [JournalEntry],
                       capThreshold: Int = defaultCapThreshold,
                       pauseThreshold: Int = defaultPauseThreshold,
                       capValue: Double = defaultCapValue)
    -> (streak: Int, state: VolatilityState) {
    let sorted = journal
      .filter { $0.status == "CLOSED" }
      .sorted { $0.createdAt > $1.createdAt }
    var streak = 0
    for e in sorted {
      guard let r = e.result else { continue }
      if r == "VOID" || r == "PUSH" { continue }
      if r == "LOSS" { streak += 1; continue }
      break
    }
    if streak >= pauseThreshold { return (streak, .pause) }
    if streak >= capThreshold { return (streak, .cap(capValue)) }
    return (streak, .normal)
  }
}

// MARK: - Team rating service

@MainActor
enum TeamRatingService {
  static let initialRating = 1500.0
  static let homeAdvantage = 60.0
  static let kBase = 32.0
  static let kDecayAfter = 30
  static let kMin = 20.0
  static let minMatchesForUse = 3

  static func expectedHome(home: Double, away: Double) -> Double {
    let diff = (home + homeAdvantage) - away
    return 1.0 / (1.0 + pow(10.0, -diff / 400.0))
  }

  static func kFactor(matches: Int) -> Double {
    if matches >= kDecayAfter { return kMin }
    let t = Double(matches) / Double(kDecayAfter)
    return kBase + (kMin - kBase) * t
  }

  @discardableResult
  static func update(context: ModelContext,
                     homeTeamID: String, homeName: String,
                     awayTeamID: String, awayName: String,
                     homeGoals: Double, awayGoals: Double)
    -> (deltaHome: Double, deltaAway: Double)? {
    guard !homeTeamID.isEmpty, !awayTeamID.isEmpty,
          homeTeamID != awayTeamID else { return nil }

    let h = fetchOrCreate(context, teamID: homeTeamID, name: homeName)
    let a = fetchOrCreate(context, teamID: awayTeamID, name: awayName)

    let expectedHome = expectedHome(home: h.rating, away: a.rating)
    let outcomeHome: Double
    if homeGoals > awayGoals { outcomeHome = 1.0 }
    else if homeGoals == awayGoals { outcomeHome = 0.5 }
    else { outcomeHome = 0.0 }
    let outcomeAway = 1.0 - outcomeHome

    let deltaH = kFactor(matches: h.matches) * (outcomeHome - expectedHome)
    let deltaA = kFactor(matches: a.matches) * (outcomeAway - (1 - expectedHome))

    h.rating += deltaH; h.matches += 1; h.lastDelta = deltaH; h.updatedAt = Date()
    a.rating += deltaA; a.matches += 1; a.lastDelta = deltaA; a.updatedAt = Date()

    try? context.save()
    return (deltaH, deltaA)
  }

  static func fetchOrCreate(_ context: ModelContext,
                            teamID: String, name: String) -> TeamRating {
    let d = FetchDescriptor<TeamRating>(predicate: #Predicate { $0.teamID == teamID })
    if let existing = try? context.fetch(d).first {
      if !name.isEmpty, existing.name != name { existing.name = name }
      return existing
    }
    let r = TeamRating(teamID: teamID, name: name)
    context.insert(r)
    return r
  }

  static func usableRating(for teamID: String, context: ModelContext) -> Double? {
    let d = FetchDescriptor<TeamRating>(predicate: #Predicate { $0.teamID == teamID })
    guard let r = try? context.fetch(d).first,
          r.matches >= minMatchesForUse else { return nil }
    return r.rating
  }
}

// MARK: - Correlation matrix

struct CorrelationMatrix: Codable, Hashable {
  var marketPairs: [String: Double]
  var leaguePairs: [String: Double]
  var marketPairsN: [String: Int]
  var leaguePairsN: [String: Int]
  var totalPairs: Int
  var lastUpdated: Date

  static let empty = CorrelationMatrix(
    marketPairs: [:], leaguePairs: [:],
    marketPairsN: [:], leaguePairsN: [:],
    totalPairs: 0, lastUpdated: Date.distantPast)
}

enum CorrelationBuilder {
  static let minPairs = 20

  static func build(from journal: [JournalEntry]) -> CorrelationMatrix {
    let closed = journal.filter {
      $0.status == "CLOSED" && ($0.result == "WIN" || $0.result == "LOSS")
    }
    guard closed.count >= minPairs else { return .empty }

    let cal = Calendar(identifier: .gregorian)
    let byDay = Dictionary(grouping: closed) { cal.startOfDay(for: $0.createdAt) }

    var marketSum: [String: (both: Double, a: Double, b: Double, n: Int)] = [:]
    var leagueSum: [String: (both: Double, a: Double, b: Double, n: Int)] = [:]
    var totalPairs = 0

    for (_, entries) in byDay where entries.count >= 2 {
      for i in 0..<entries.count {
        for j in (i+1)..<entries.count {
          let ea = entries[i]; let eb = entries[j]
          if ea.gameID == eb.gameID { continue }
          let aW = ea.result == "WIN" ? 1.0 : 0.0
          let bW = eb.result == "WIN" ? 1.0 : 0.0

          let mk = [ea.market, eb.market].sorted().joined(separator: "|")
          var m = marketSum[mk] ?? (0, 0, 0, 0)
          m.both += aW * bW; m.a += aW; m.b += bW; m.n += 1
          marketSum[mk] = m

          let lk = [ea.league, eb.league].sorted().joined(separator: "|")
          var l = leagueSum[lk] ?? (0, 0, 0, 0)
          l.both += aW * bW; l.a += aW; l.b += bW; l.n += 1
          leagueSum[lk] = l

          totalPairs += 1
        }
      }
    }

    func toCorr(_ s: [String: (both: Double, a: Double, b: Double, n: Int)])
      -> ([String: Double], [String: Int]) {
      var corr: [String: Double] = [:]
      var ns: [String: Int] = [:]
      for (k, v) in s where v.n >= minPairs {
        let n = Double(v.n)
        let pAB = v.both / n
        let pA = v.a / n
        let pB = v.b / n
        let denom = sqrt(pA * (1 - pA) * pB * (1 - pB))
        let phi = denom > 1e-9 ? (pAB - pA * pB) / denom : 0
        corr[k] = max(-1, min(1, phi))
        ns[k] = v.n
      }
      return (corr, ns)
    }

    let (mc, mn) = toCorr(marketSum)
    let (lc, ln) = toCorr(leagueSum)

    return CorrelationMatrix(
      marketPairs: mc, leaguePairs: lc,
      marketPairsN: mn, leaguePairsN: ln,
      totalPairs: totalPairs, lastUpdated: Date())
  }
}

// MARK: - Journal

@Model final class JournalEntry {
  @Attribute(.unique) var id: String
  var gameID: String
  var home: String
  var away: String
  var league: String
  var market: String
  var selection: String
  var line: Double?
  var odds: Double
  var probability: Double
  var ev: Double
  var robustEV: Double
  var qcs: Double
  var dcs: Double
  var classification: String
  var stake: Double
  var status: String
  var createdAt: Date
  var result: String?
  var closingOdds: Double?
  var clv: Double?
  var profit: Double?

  var openingOdds: Double?
  var movement: Double?

  var stakeMoney: Double?

  init(signal: BetSignal, status: String = "OPEN") {
    id = signal.id
    gameID = signal.gameID
    home = signal.home
    away = signal.away
    league = signal.league
    market = signal.market
    selection = signal.selection
    line = signal.line
    odds = signal.odds
    probability = signal.probability
    ev = signal.ev
    robustEV = signal.robustEV
    qcs = signal.qcs
    dcs = signal.dcs
    classification = signal.classification
    stake = signal.stake
    self.status = status
    createdAt = signal.timestamp
    result = nil
    closingOdds = nil
    clv = nil
    profit = nil
    openingOdds = signal.odds
    movement = nil
    stakeMoney = signal.stakeMoney
  }
}

@Model final class CalibrationSample {
  @Attribute(.unique) var id: String
  var predicted: Double
  var actual: Double
  var market: String
  var createdAt: Date
  init(id: String, predicted: Double, actual: Double, market: String,
       createdAt: Date = Date()) {
    self.id = id
    self.predicted = predicted
    self.actual = actual
    self.market = market
    self.createdAt = createdAt
  }
}

// MARK: - BacktestRun (legacy)

@Model final class BacktestRun {
  @Attribute(.unique) var id: String
  var createdAt: Date
  var matches: Int
  var bets: Int
  var wins: Int
  var losses: Int
  var pushes: Int
  var profit: Double
  var staked: Double
  var roi: Double
  var yieldPct: Double
  var hitRate: Double
  var maxDrawdown: Double
  var maxLosingStreak: Int
  var sharpe: Double
  var brier: Double
  var logLoss: Double
  var avgCLV: Double

  init(id: String = UUID().uuidString, createdAt: Date = Date(),
       matches: Int, bets: Int, wins: Int, losses: Int, pushes: Int,
       profit: Double, staked: Double, roi: Double, yieldPct: Double,
       hitRate: Double, maxDrawdown: Double, maxLosingStreak: Int,
       sharpe: Double, brier: Double, logLoss: Double, avgCLV: Double) {
    self.id = id
    self.createdAt = createdAt
    self.matches = matches
    self.bets = bets
    self.wins = wins
    self.losses = losses
    self.pushes = pushes
    self.profit = profit
    self.staked = staked
    self.roi = roi
    self.yieldPct = yieldPct
    self.hitRate = hitRate
    self.maxDrawdown = maxDrawdown
    self.maxLosingStreak = maxLosingStreak
    self.sharpe = sharpe
    self.brier = brier
    self.logLoss = logLoss
    self.avgCLV = avgCLV
  }
}

// MARK: - Backtest snapshot

struct StoredSegmentStats: Codable, Hashable {
  var bets: Int
  var wins: Int
  var losses: Int
  var pushes: Int
  var profit: Double
  var staked: Double
  var roi: Double
  var yieldPct: Double
  var hitRate: Double
  var avgOdds: Double

  init() {
    bets = 0; wins = 0; losses = 0; pushes = 0
    profit = 0; staked = 0; roi = 0; yieldPct = 0
    hitRate = 0; avgOdds = 0
  }

  init(bets: Int, wins: Int, losses: Int, pushes: Int,
       profit: Double, staked: Double, avgOdds: Double) {
    self.bets = bets
    self.wins = wins
    self.losses = losses
    self.pushes = pushes
    self.profit = profit
    self.staked = staked
    self.roi = staked > 0 ? profit / staked : 0
    self.yieldPct = self.roi
    let dec = wins + losses
    self.hitRate = dec > 0 ? Double(wins) / Double(dec) : 0
    self.avgOdds = avgOdds
  }
}

struct PosteriorBucket: Codable, Hashable, Identifiable {
  var id: String { "\(probabilityLow)-\(probabilityHigh)" }
  var probabilityLow: Double
  var probabilityHigh: Double
  var n: Int
  var factHitRate: Double
}

struct AutoExcludeRule: Codable, Hashable, Identifiable {
  var id: String { "\(league)|\(market)" }
  var league: String
  var market: String
  var bets: Int
  var roi: Double
  var excluded: Bool
}

// MARK: - Model comparison (Волна E, E5)

struct ModelComparison: Codable, Hashable, Identifiable {
  var id: String { name }
  var name: String
  var matches: Int
  var brier: Double
  var logLoss: Double
  var avgHomeP: Double
  var avgDrawP: Double
  var avgAwayP: Double
}

@Model final class BacktestSnapshot {
  @Attribute(.unique) var id: String
  var version: Int
  var builtAt: Date?
  var fromDate: Date?
  var toDate: Date?
  var totalMatches: Int
  var totalBets: Int
  var buildProgress: Double
  var buildStatus: String
  var lastError: String?

  var perLeagueJSON: Data?
  var perMarketJSON: Data?
  var perLeagueMarketJSON: Data?
  var evBucketsJSON: Data?
  var oddsBucketsJSON: Data?
  var classificationJSON: Data?
  var posteriorJSON: Data?
  var modelComparisonJSON: Data?

  var avgROI: Double
  var avgCLV: Double
  var brier: Double
  var logLoss: Double
  var sharpe: Double
  var sortino: Double
  var profitFactor: Double

  init(id: String = "current") {
    self.id = id
    self.version = 1
    self.builtAt = nil
    self.fromDate = nil
    self.toDate = nil
    self.totalMatches = 0
    self.totalBets = 0
    self.buildProgress = 0
    self.buildStatus = "idle"
    self.lastError = nil
    self.perLeagueJSON = nil
    self.perMarketJSON = nil
    self.perLeagueMarketJSON = nil
    self.evBucketsJSON = nil
    self.oddsBucketsJSON = nil
    self.classificationJSON = nil
    self.posteriorJSON = nil
    self.modelComparisonJSON = nil
    self.avgROI = 0
    self.avgCLV = 0
    self.brier = 0
    self.logLoss = 0
    self.sharpe = 0
    self.sortino = 0
    self.profitFactor = 0
  }
}

extension BacktestSnapshot {
  func decodedLeagueStats() -> [String: StoredSegmentStats] {
    guard let d = perLeagueJSON else { return [:] }
    return (try? JSONDecoder().decode([String: StoredSegmentStats].self, from: d)) ?? [:]
  }
  func decodedMarketStats() -> [String: StoredSegmentStats] {
    guard let d = perMarketJSON else { return [:] }
    return (try? JSONDecoder().decode([String: StoredSegmentStats].self, from: d)) ?? [:]
  }
  func decodedLeagueMarketStats() -> [String: StoredSegmentStats] {
    guard let d = perLeagueMarketJSON else { return [:] }
    return (try? JSONDecoder().decode([String: StoredSegmentStats].self, from: d)) ?? [:]
  }
  func decodedEVBuckets() -> [String: StoredSegmentStats] {
    guard let d = evBucketsJSON else { return [:] }
    return (try? JSONDecoder().decode([String: StoredSegmentStats].self, from: d)) ?? [:]
  }
  func decodedOddsBuckets() -> [String: StoredSegmentStats] {
    guard let d = oddsBucketsJSON else { return [:] }
    return (try? JSONDecoder().decode([String: StoredSegmentStats].self, from: d)) ?? [:]
  }
  func decodedClassification() -> [String: StoredSegmentStats] {
    guard let d = classificationJSON else { return [:] }
    return (try? JSONDecoder().decode([String: StoredSegmentStats].self, from: d)) ?? [:]
  }
  func decodedPosteriorBuckets() -> [PosteriorBucket] {
    guard let d = posteriorJSON else { return [] }
    return (try? JSONDecoder().decode([PosteriorBucket].self, from: d)) ?? []
  }
  func decodedModelComparison() -> [ModelComparison] {
    guard let d = modelComparisonJSON else { return [] }
    return (try? JSONDecoder().decode([ModelComparison].self, from: d)) ?? []
  }
}

// MARK: - Auto-Exclude

enum AutoExclude {
  static let defaultMinBets = 20
  static let defaultMinROI = -0.05

  static func rules(from snapshot: BacktestSnapshot?,
                    minROI: Double = defaultMinROI,
                    minBets: Int = defaultMinBets) -> [AutoExcludeRule] {
    guard let snapshot else { return [] }
    let stats = snapshot.decodedLeagueMarketStats()
    return stats.map { (key, s) in
      let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
      let lg = parts.first ?? key
      let mk = parts.count > 1 ? parts[1] : ""
      let ex = s.bets >= minBets && s.roi < minROI
      return AutoExcludeRule(league: lg, market: mk,
                             bets: s.bets, roi: s.roi, excluded: ex)
    }.sorted { $0.roi < $1.roi }
  }

  static func isExcluded(league: String, market: String,
                         rules: [AutoExcludeRule]) -> Bool {
    rules.contains { r in
      guard r.excluded else { return false }
      guard market.caseInsensitiveCompare(r.market) == .orderedSame else { return false }
      let a = league.lowercased(); let b = r.league.lowercased()
      return a == b || a.contains(b) || b.contains(a)
    }
  }
}

struct AppStats {
  var bets = 0; var wins = 0; var losses = 0; var pushes = 0
  var profit = 0.0; var staked = 0.0
}

// MARK: - JournalMetrics & Metrics

struct JournalMetrics {
  var totalEntries = 0
  var closedEntries = 0
  var wins = 0
  var losses = 0
  var pushes = 0
  var voids = 0
  var profit = 0.0
  var staked = 0.0
  var avgCLV = 0.0
  var clvCount = 0
  var brier = 0.0
  var logLoss = 0.0
  var calibration: [CalibrationBucket] = []

  var roi: Double { staked > 0 ? profit / staked : 0 }
  var yieldPct: Double { roi }
  var hitRate: Double { wins + losses > 0 ? Double(wins) / Double(wins + losses) : 0 }
  var pending: Int { totalEntries - closedEntries }
}

struct CalibrationBucket: Identifiable {
  let id: String
  let midpoint: Double
  let predicted: Double
  let actual: Double
  let count: Int
}

struct EquityPoint: Identifiable, Hashable {
  let id: String
  let date: Date
  let cumulativeProfit: Double
  let cumulativeStaked: Double
  let bets: Int
}

enum Metrics {
  static func compute(_ entries: [JournalEntry]) -> JournalMetrics {
    var m = JournalMetrics()
    m.totalEntries = entries.count
    let closed = entries.filter { $0.status == "CLOSED" }
    m.closedEntries = closed.count

    var brierSum = 0.0
    var logLossSum = 0.0
    var brierCount = 0
    var clvSum = 0.0
    var clvCount = 0

    var bucketPredicted: [Int: Double] = [:]
    var bucketActual: [Int: Double] = [:]
    var bucketCount: [Int: Int] = [:]

    for e in closed {
      m.staked += e.stake
      if let p = e.profit { m.profit += p }
      switch e.result {
      case "WIN": m.wins += 1
      case "LOSS": m.losses += 1
      case "PUSH": m.pushes += 1
      case "VOID": m.voids += 1
      default: break
      }
      if let clv = e.clv { clvSum += clv; clvCount += 1 }
      if e.result == "WIN" || e.result == "LOSS" {
        let actual = e.result == "WIN" ? 1.0 : 0.0
        let p = e.probability
        brierSum += (p - actual) * (p - actual)
        let eps = 1e-9
        let clamped = min(1 - eps, max(eps, p))
        let ll = actual == 1 ? -log(clamped) : -log(1 - clamped)
        logLossSum += ll
        brierCount += 1
        let bucket = min(9, max(0, Int(p * 10.0)))
        bucketPredicted[bucket, default: 0] += p
        bucketActual[bucket, default: 0] += actual
        bucketCount[bucket, default: 0] += 1
      }
    }

    if clvCount > 0 { m.avgCLV = clvSum / Double(clvCount) }
    if brierCount > 0 {
      m.brier = brierSum / Double(brierCount)
      m.logLoss = logLossSum / Double(brierCount)
    }

    var buckets: [CalibrationBucket] = []
    for i in 0..<10 {
      guard let n = bucketCount[i], n > 0 else { continue }
      let avgPred = (bucketPredicted[i] ?? 0) / Double(n)
      let actual = (bucketActual[i] ?? 0) / Double(n)
      buckets.append(CalibrationBucket(id: "b\(i)",
        midpoint: Double(i) / 10.0 + 0.05,
        predicted: avgPred, actual: actual, count: n))
    }
    m.calibration = buckets
    return m
  }

  static func calibrationError(_ m: JournalMetrics) -> Double {
    guard !m.calibration.isEmpty else { return 0 }
    var weightedSum = 0.0
    var totalN = 0
    for b in m.calibration {
      weightedSum += abs(b.predicted - b.actual) * Double(b.count)
      totalN += b.count
    }
    return totalN > 0 ? weightedSum / Double(totalN) : 0
  }

  static func equityCurve(_ entries: [JournalEntry],
                          bankroll: Double? = nil) -> [EquityPoint] {
    let closed = entries
      .filter { $0.status == "CLOSED" && $0.profit != nil }
      .sorted { $0.createdAt < $1.createdAt }
    guard !closed.isEmpty else { return [] }

    var curve: [EquityPoint] = []
    var cumProfit = 0.0
    var cumStaked = 0.0
    let mult = bankroll ?? 1.0
    for (i, e) in closed.enumerated() {
      cumProfit += (e.profit ?? 0) * mult
      cumStaked += e.stake * mult
      curve.append(EquityPoint(id: "eq\(i)_\(e.id)", date: e.createdAt,
        cumulativeProfit: cumProfit, cumulativeStaked: cumStaked, bets: i + 1))
    }
    return curve
  }
}

// MARK: - JournalService

enum JournalService {
  @MainActor
  static func settleOpenEntries(context: ModelContext,
                                client: SStatsClient)
    async -> (closed: Int, failed: Int) {
    let descriptor = FetchDescriptor<JournalEntry>()
    guard let all = try? context.fetch(descriptor) else { return (0, 0) }
    let open = all.filter { $0.status == "OPEN" }
    var closed = 0
    var failed = 0

    for entry in open {
      guard let info = try? await client.gameInfo(entry.gameID) else {
        failed += 1; continue
      }
      guard let data = info.object?["data"]?.object,
            let game = data["game"]?.object,
            let hFT = number(game, ["homeFTResult", "homeResult"]),
            let aFT = number(game, ["awayFTResult", "awayResult"])
      else { continue }

      let result = evaluateResult(entry: entry, home: hFT, away: aFT)
      entry.result = result
      entry.profit = computeProfit(result: result, odds: entry.odds, stake: entry.stake)

      if let closingOdds = extractClosingOdds(data: data, entry: entry),
         closingOdds > 1 {
        entry.closingOdds = closingOdds
        entry.clv = entry.odds / closingOdds - 1
        if let openOdds = entry.openingOdds, openOdds > 1 {
          entry.movement = openOdds / closingOdds - 1
        }
      }

      entry.status = "CLOSED"
      closed += 1

      let ids = extractTeamIDs(from: game)
      if let hID = ids.home, let aID = ids.away {
        TeamRatingService.update(context: context,
          homeTeamID: hID, homeName: entry.home,
          awayTeamID: aID, awayName: entry.away,
          homeGoals: hFT, awayGoals: aFT)
      }

      try? await Task.sleep(for: .milliseconds(120))
    }

    try? context.save()
    return (closed, failed)
  }

  private static func evaluateResult(entry: JournalEntry,
                                     home: Double, away: Double) -> String {
    let sel = entry.selection.lowercased()
    if entry.market == "1X2" {
      let win: Bool
      if sel.contains("home") || sel == "1" { win = home > away }
      else if sel.contains("draw") || sel == "x" { win = home == away }
      else { win = away > home }
      return win ? "WIN" : "LOSS"
    }
    if entry.market == "GOALS" {
      guard let line = entry.line else { return "VOID" }
      let total = home + away
      let isOver = sel.contains("over") || sel.hasPrefix("o")
      if abs(line.rounded() - line) < 0.001, Double(Int(line)) == total {
        return "PUSH"
      }
      let hit = isOver ? total > line : total < line
      return hit ? "WIN" : "LOSS"
    }
    return "VOID"
  }

  private static func computeProfit(result: String, odds: Double, stake: Double) -> Double {
    switch result {
    case "WIN": return stake * (odds - 1)
    case "LOSS": return -stake
    case "PUSH": return 0
    default: return 0
    }
  }

  private static func extractClosingOdds(data: [String: JSONValue],
                                         entry: JournalEntry) -> Double? {
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
              let value = number(p, ["value", "odds", "price"]), value > 1
        else { continue }
        if let line = targetLine {
          if !containsLine(selName, line: line) { continue }
        }
        if targetMarket == "1X2" {
          if !selName.contains(targetSelection) { continue }
        } else {
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

  private static func extractTeamIDs(from game: [String: JSONValue])
    -> (home: String?, away: String?) {
    func extract(_ side: String) -> String? {
      if let s = game[side + "TeamId"]?.string, !s.isEmpty { return s }
      if let s = game[side + "TeamID"]?.string, !s.isEmpty { return s }
      if let n = game[side + "TeamId"]?.number { return String(Int(n)) }
      if let t = game[side + "Team"]?.object {
        if let s = t["id"]?.string, !s.isEmpty { return s }
        if let n = t["id"]?.number { return String(Int(n)) }
      }
      return nil
    }
    return (extract("home"), extract("away"))
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
    for f in formats { if s.contains(f) { return true } }
    if abs(line.rounded() - line) < 0.001 {
      if s.contains("\(Int(line))") { return true }
    }
    return false
  }

  private static func number(_ o: [String: JSONValue], _ keys: [String]) -> Double? {
    for k in keys { if let n = o[k]?.number { return n } }
    return nil
  }
}

// MARK: - AppDependencies

@MainActor
final class AppDependencies {
  static let shared = AppDependencies()
  var container: ModelContainer?
  private init() {}
}

// MARK: - BacktestService

@MainActor
final class BacktestService {
  static let shared = BacktestService()
  private init() {}

  static let yearsBack = 2
  static let monthsPerYear = 12
  static let oddsFetchCap = 500
  static let gamesPerRequest = 2000

  private var isBuilding = false

  func buildFullBase(
    progress: @MainActor @escaping (Double, String) -> Void
  ) async -> Bool {
    if isBuilding { progress(0, "Уже выполняется"); return false }
    isBuilding = true
    defer { isBuilding = false }

    guard let container = AppDependencies.shared.container else {
      progress(0, "Нет контейнера"); return false
    }
    let context = ModelContext(container)
    let snapshot = Self.fetchOrCreate(in: context)

    let settings = AppSettings()
    let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      snapshot.buildStatus = "failed"
      snapshot.lastError = "API key не задан"
      try? context.save()
      progress(0, "API key не задан")
      return false
    }

    snapshot.buildStatus = "building"
    snapshot.buildProgress = 0
    snapshot.lastError = nil
    snapshot.builtAt = nil
    snapshot.fromDate = nil
    snapshot.toDate = nil
    snapshot.totalMatches = 0
    snapshot.totalBets = 0
    try? context.save()

    let client = SStatsClient(settings: settings)
    let engine = QuantEngine()
    let backtester = WalkForwardBacktester()
    let cal = Calendar(identifier: .gregorian)

    let toDate = Date()
    guard let fromDate = cal.date(byAdding: .year, value: -Self.yearsBack, to: toDate) else {
      snapshot.buildStatus = "failed"
      snapshot.lastError = "Не могу построить дату"
      try? context.save()
      return false
    }

    let totalMonths = Self.yearsBack * Self.monthsPerYear
    var allMatches: [Match] = []
    var allHistories: [String: [TeamRecord]] = [:]
    var seenIDs = Set<String>()
    var cursor = fromDate
    var monthIndex = 0
    var lastSaved = Date()

    while cursor < toDate {
      guard let nextMonth = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
      let periodEnd = min(nextMonth, toDate)
      let monthProgress = Double(monthIndex) / Double(totalMonths) * 0.70
      progress(monthProgress, "Сбор \(monthIndex + 1)/\(totalMonths)")

      do {
        let json = try await client.listGamesRange(
          from: cursor, to: periodEnd, limit: Self.gamesPerRequest)
        let monthMatches = engine.matches(from: json)
          .filter { !Self.isExcluded($0) }
          .filter { Self.isInPool($0.league) }
          .filter { $0.homeFT != nil && $0.awayFT != nil }
          .filter { m in
            if seenIDs.contains(m.id) { return false }
            seenIDs.insert(m.id)
            return true
          }
        allMatches.append(contentsOf: monthMatches)
        let records = engine.allRecords(from: json)
        for (k, v) in records { allHistories[k, default: []].append(contentsOf: v) }
      } catch {
        print("[BT] month \(monthIndex) failed: \(error.localizedDescription)")
      }

      cursor = nextMonth
      monthIndex += 1
      if Date().timeIntervalSince(lastSaved) > 25 {
        snapshot.buildProgress = monthProgress
        try? context.save()
        lastSaved = Date()
      }
    }

    for (k, v) in allHistories {
      allHistories[k] = v.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    progress(0.70, "Матчей собрано: \(allMatches.count). Дотягиваю odds…")

    var prepared: [Match] = allMatches.filter { ($0.oddsJSON?.array?.isEmpty == false) }
    let needOdds = allMatches.filter { ($0.oddsJSON?.array?.isEmpty != false) }
    let cap = min(needOdds.count, Self.oddsFetchCap)

    for (i, m) in needOdds.prefix(cap).enumerated() {
      var mm = m
      if let nid = mm.numericID {
        if let o = try? await client.odds(numericID: nid) {
          mm.oddsJSON = o.object?["data"]
        }
        if i % 20 == 0 {
          let p = 0.70 + (Double(i) / Double(max(cap, 1))) * 0.15
          progress(p, "Odds \(i + 1)/\(cap)")
        }
        try? await Task.sleep(for: .milliseconds(400))
      }
      if mm.oddsJSON?.array?.isEmpty == false { prepared.append(mm) }
    }

    guard !prepared.isEmpty else {
      snapshot.buildStatus = "failed"
      snapshot.lastError = "Нет матчей с odds"
      try? context.save()
      progress(0, "Нет матчей с odds")
      return false
    }

    progress(0.85, "Walk-forward на \(prepared.count) матчах…")
    let report = backtester.run(matches: prepared, histories: allHistories)

    progress(0.90, "Сравнение моделей (E5)…")
    let comparisons = MultiModelBacktester().run(
      matches: prepared, histories: allHistories)

    progress(0.95, "Сохраняю снапшот…")

    snapshot.builtAt = Date()
    snapshot.fromDate = fromDate
    snapshot.toDate = toDate
    snapshot.totalMatches = report.matches
    snapshot.totalBets = report.bets
    snapshot.avgROI = report.roi
    snapshot.avgCLV = report.avgCLV
    snapshot.brier = report.brier
    snapshot.logLoss = report.logLoss
    snapshot.sharpe = report.sharpe
    snapshot.sortino = report.sortino
    snapshot.profitFactor = report.profitFactor

    let encoder = JSONEncoder()
    snapshot.perLeagueJSON = try? encoder.encode(
      report.perLeague.mapValues { Self.toStored($0) })
    snapshot.perMarketJSON = try? encoder.encode(
      report.perMarket.mapValues { Self.toStored($0) })
    snapshot.evBucketsJSON = try? encoder.encode(
      report.byEVBucket.mapValues { Self.toStored($0) })
    snapshot.oddsBucketsJSON = try? encoder.encode(
      report.byOddsBand.mapValues { Self.toStored($0) })
    snapshot.classificationJSON = try? encoder.encode(
      report.byClassification.mapValues { Self.toStored($0) })
    snapshot.posteriorJSON = try? encoder.encode(
      Self.buildPosteriorBuckets(from: report.betRecords))
    snapshot.modelComparisonJSON = try? encoder.encode(comparisons)

    snapshot.buildStatus = "ready"
    snapshot.buildProgress = 1.0
    snapshot.lastError = nil
    try? context.save()

    progress(1.0, "Готово: \(report.matches) матчей, \(report.bets) ставок")
    return true
  }

  func updateIncremental() async -> Bool {
    guard !isBuilding else { return false }
    isBuilding = true
    defer { isBuilding = false }

    guard let container = AppDependencies.shared.container else { return false }
    let context = ModelContext(container)
    let snapshot = Self.fetchOrCreate(in: context)

    guard snapshot.buildStatus == "ready", let lastTo = snapshot.toDate else {
      print("[BT] updateIncremental: снапшот ещё не готов")
      return false
    }

    let settings = AppSettings()
    let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return false }

    let client = SStatsClient(settings: settings)
    let engine = QuantEngine()
    let backtester = WalkForwardBacktester()

    let fromDate = lastTo
    let toDate = Date()

    do {
      let json = try await client.listGamesRange(
        from: fromDate, to: toDate, limit: Self.gamesPerRequest)

      let newMatches = engine.matches(from: json)
        .filter { !Self.isExcluded($0) }
        .filter { Self.isInPool($0.league) }
        .filter { $0.homeFT != nil && $0.awayFT != nil }

      var prepared: [Match] = []
      for m in newMatches {
        var mm = m
        if mm.oddsJSON?.array?.isEmpty != false, let nid = mm.numericID {
          if let o = try? await client.odds(numericID: nid) {
            mm.oddsJSON = o.object?["data"]
          }
          try? await Task.sleep(for: .milliseconds(400))
        }
        if mm.oddsJSON?.array?.isEmpty == false { prepared.append(mm) }
      }

      guard !prepared.isEmpty else {
        print("[BT] updateIncremental: нет новых матчей с odds")
        snapshot.toDate = toDate
        try? context.save()
        return true
      }

      let records = engine.allRecords(from: json)
      var sortedRecords = records
      for (k, v) in sortedRecords {
        sortedRecords[k] = v.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
      }

      let delta = backtester.run(matches: prepared, histories: sortedRecords)
      let encoder = JSONEncoder()

      let oldLeagues = snapshot.decodedLeagueStats()
      let oldMarkets = snapshot.decodedMarketStats()
      let oldEV = snapshot.decodedEVBuckets()
      let oldOdds = snapshot.decodedOddsBuckets()
      let oldClass = snapshot.decodedClassification()

      let newLeagues = Self.mergeSegmentDict(
        oldLeagues, delta.perLeague.mapValues { Self.toStored($0) })
      let newMarkets = Self.mergeSegmentDict(
        oldMarkets, delta.perMarket.mapValues { Self.toStored($0) })
      let newEV = Self.mergeSegmentDict(
        oldEV, delta.byEVBucket.mapValues { Self.toStored($0) })
      let newOdds = Self.mergeSegmentDict(
        oldOdds, delta.byOddsBand.mapValues { Self.toStored($0) })
      let newClass = Self.mergeSegmentDict(
        oldClass, delta.byClassification.mapValues { Self.toStored($0) })

      snapshot.perLeagueJSON = try? encoder.encode(newLeagues)
      snapshot.perMarketJSON = try? encoder.encode(newMarkets)
      snapshot.evBucketsJSON = try? encoder.encode(newEV)
      snapshot.oddsBucketsJSON = try? encoder.encode(newOdds)
      snapshot.classificationJSON = try? encoder.encode(newClass)

      let oldPosterior = snapshot.decodedPosteriorBuckets()
      let newPosterior = Self.mergePosterior(
        old: oldPosterior,
        delta: Self.buildPosteriorBuckets(from: delta.betRecords))
      snapshot.posteriorJSON = try? encoder.encode(newPosterior)

      snapshot.totalMatches += delta.matches
      snapshot.totalBets += delta.bets
      snapshot.toDate = toDate
      snapshot.builtAt = Date()
      try? context.save()

      print("[BT] updateIncremental: +\(delta.bets) ставок, +\(delta.matches) матчей")
      return true
    } catch {
      print("[BT] updateIncremental failed: \(error.localizedDescription)")
      return false
    }
  }

  static func fetchOrCreate(in context: ModelContext) -> BacktestSnapshot {
    let d = FetchDescriptor<BacktestSnapshot>()
    if let existing = try? context.fetch(d).first { return existing }
    let snap = BacktestSnapshot()
    context.insert(snap)
    try? context.save()
    return snap
  }

  static func toStored(_ s: SegmentStats) -> StoredSegmentStats {
    StoredSegmentStats(bets: s.bets, wins: s.wins, losses: s.losses, pushes: s.pushes,
                       profit: s.profit, staked: s.staked, avgOdds: s.avgOdds)
  }

  static func mergeSegmentDict(
    _ old: [String: StoredSegmentStats],
    _ delta: [String: StoredSegmentStats]
  ) -> [String: StoredSegmentStats] {
    var result = old
    for (k, v) in delta {
      if let existing = result[k] { result[k] = merge(existing, v) }
      else { result[k] = v }
    }
    return result
  }

  static func merge(_ a: StoredSegmentStats, _ b: StoredSegmentStats) -> StoredSegmentStats {
    let newBets = a.bets + b.bets
    let newWins = a.wins + b.wins
    let newLosses = a.losses + b.losses
    let newPushes = a.pushes + b.pushes
    let newProfit = a.profit + b.profit
    let newStaked = a.staked + b.staked
    let oddsSum = a.avgOdds * Double(a.bets) + b.avgOdds * Double(b.bets)
    let newAvgOdds = newBets > 0 ? oddsSum / Double(newBets) : 0
    return StoredSegmentStats(bets: newBets, wins: newWins, losses: newLosses,
      pushes: newPushes, profit: newProfit, staked: newStaked, avgOdds: newAvgOdds)
  }

  static func buildPosteriorBuckets(from bets: [BetRecord]) -> [PosteriorBucket] {
    var buckets: [PosteriorBucket] = []
    for i in 0..<10 {
      let lo = Double(i) / 10.0
      let hi = Double(i + 1) / 10.0
      let inBucket = bets.filter { b in
        let idx = min(9, max(0, Int(b.probability * 10.0)))
        return idx == i
      }
      let n = inBucket.count
      let hitRate = n > 0 ? inBucket.reduce(0.0) { $0 + $1.actual } / Double(n) : 0
      buckets.append(PosteriorBucket(probabilityLow: lo, probabilityHigh: hi,
        n: n, factHitRate: hitRate))
    }
    return buckets
  }

  static func mergePosterior(old: [PosteriorBucket],
                             delta: [PosteriorBucket]) -> [PosteriorBucket] {
    var out: [PosteriorBucket] = []
    for i in 0..<max(old.count, delta.count) {
      let o = i < old.count ? old[i] : PosteriorBucket(
        probabilityLow: Double(i) / 10.0,
        probabilityHigh: Double(i + 1) / 10.0, n: 0, factHitRate: 0)
      let d = i < delta.count ? delta[i] : PosteriorBucket(
        probabilityLow: Double(i) / 10.0,
        probabilityHigh: Double(i + 1) / 10.0, n: 0, factHitRate: 0)
      let newN = o.n + d.n
      let weightedSum = o.factHitRate * Double(o.n) + d.factHitRate * Double(d.n)
      let newHit = newN > 0 ? weightedSum / Double(newN) : 0
      out.append(PosteriorBucket(probabilityLow: o.probabilityLow,
        probabilityHigh: o.probabilityHigh, n: newN, factHitRate: newHit))
    }
    return out
  }

  private static func isExcluded(_ m: Match) -> Bool {
    let x = "\(m.league) \(m.home) \(m.away)".lowercased()
    let bad = ["friendly", "women", "женщ", "u19 women", "u20 women"]
    return bad.contains(where: x.contains)
  }

  private static func isInPool(_ league: String) -> Bool {
    LeaguePool.pool.contains { lg in league.localizedCaseInsensitiveContains(lg.name) }
  }
}

// MARK: - ScanCoordinator

@MainActor
final class ScanCoordinator {
  static let shared = ScanCoordinator()
  private var isScanning = false
  private init() {}

  struct ScanSummary {
    var signals: [BetSignal] = []
    var scannedMatches = 0
    var skippedExcluded = 0
    var notes: [String] = []
    var finishedAt: Date?
    var success: Bool = false
    var lossStreak: Int = 0
    var volatilityLabel: String = "NORMAL"
    var correlationPairs: Int = 0
    var lineupsFound: Int = 0
    var tuningNote: String? = nil
  }

  func scan(settings: AppSettings? = nil,
            selectedLeague: String = "Все") async -> ScanSummary {
    if isScanning { return ScanSummary(notes: ["Уже выполняется"]) }
    isScanning = true
    defer { isScanning = false }

    var summary = ScanSummary()

    let resolvedSettings: AppSettings = settings ?? AppSettings()
    let key = resolvedSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      summary.notes.append("API key не задан")
      return summary
    }

    let container = AppDependencies.shared.container
    let journalContext = container.map { ModelContext($0) }
    let ratingContext = container.map { ModelContext($0) }

    let tuning: TuningConfig = {
      guard let ctx = journalContext else { return TuningConfig() }
      return TuningService.fetchOrCreate(in: ctx)
    }()

    let corrMatrix: CorrelationMatrix = {
      guard let ctx = journalContext else { return .empty }
      let d = FetchDescriptor<JournalEntry>()
      guard let entries = try? ctx.fetch(d) else { return .empty }
      return CorrelationBuilder.build(from: entries)
    }()
    summary.correlationPairs = corrMatrix.marketPairsN.count + corrMatrix.leaguePairsN.count

    let streak: (streak: Int, state: VolatilityState) = {
      guard let ctx = journalContext else { return (0, .normal) }
      let d = FetchDescriptor<JournalEntry>()
      guard let entries = try? ctx.fetch(d) else { return (0, .normal) }
      return VolatilityStop.evaluate(entries,
        capThreshold: tuning.stopLossCapStreak,
        pauseThreshold: tuning.stopLossPauseStreak)
    }()
    summary.lossStreak = streak.streak
    summary.volatilityLabel = tuning.stopLossEnabled ? streak.state.label : "OFF"

    if !tuning.stopLossEnabled { summary.notes.append("Self-Tuning: stop-loss отключён") }
    else if streak.streak > 0 { summary.notes.append("LossStreak: \(streak.streak) · \(streak.state.label)") }
    if !tuning.autoExcludeEnabled { summary.notes.append("Self-Tuning: Auto-Exclude отключён") }
    if !tuning.posteriorEnabled { summary.notes.append("Self-Tuning: posterior отключён") }
    if !tuning.correlationEnabled { summary.notes.append("Self-Tuning: correlation отключён") }
    if !tuning.playerImpactEnabled { summary.notes.append("Self-Tuning: player impact отключён") }
    if !tuning.teamRatingEnabled { summary.notes.append("Self-Tuning: TeamRating отключён") }

    do {
      let client = SStatsClient(settings: resolvedSettings)
      let engine = QuantEngine()

      var all = engine.matches(from: try await client.listToday())
        .filter { !Self.isExcluded($0) }
      summary.skippedExcluded = all.count

      if selectedLeague != "Все" {
        all = all.filter { $0.league.localizedCaseInsensitiveContains(selectedLeague) }
      }
      let matches = all.prefix(resolvedSettings.scanMatches)

      let posteriorBuckets: [PosteriorBucket] = tuning.posteriorEnabled
        ? Self.loadPosteriorBuckets() : []
      let usableBuckets = posteriorBuckets.filter { $0.n >= 20 }.count
      if usableBuckets > 0 { summary.notes.append("Posterior: \(usableBuckets) надёжных бакетов") }

      let excludedRules: [AutoExcludeRule] = tuning.autoExcludeEnabled
        ? Self.loadExcludedRules(minROI: tuning.autoExcludeMinROI, minBets: tuning.autoExcludeMinBets)
        : []
      let excludedCount = excludedRules.filter { $0.excluded }.count

      let stopState: VolatilityState = tuning.stopLossEnabled ? streak.state : .normal

      var signalsOut: [BetSignal] = []
      var count = 0
      var lineupsFound = 0
      for match in matches {
        guard let h = match.homeID, let a = match.awayID else { continue }
        count += 1
        let hs = await client.fetchTeamHistory(teamID: h, count: resolvedSettings.historyMatches)
        let awayRecords = await client.fetchTeamHistory(teamID: a, count: resolvedSettings.historyMatches)
        guard let info = try? await client.gameInfo(match.id) else { continue }
        var oddsFromInfo = info.object?["data"]?.object?["odds"] ?? match.oddsJSON ?? .array([])
        if oddsFromInfo.array?.isEmpty != false, let nid = match.numericID {
          if let o = try? await client.odds(numericID: nid) {
            oddsFromInfo = o.object?["data"] ?? oddsFromInfo
          }
        }
        let glicko = try? await client.glicko(match.id)

        let ratings: (Double?, Double?) = {
          guard tuning.teamRatingEnabled, let ctx = ratingContext else { return (nil, nil) }
          return (TeamRatingService.usableRating(for: h, context: ctx),
                  TeamRatingService.usableRating(for: a, context: ctx))
        }()

        let lineups: (home: [String], away: [String])? = {
          guard tuning.playerImpactEnabled else { return nil }
          return Self.parseUpcomingLineups(from: info)
        }()
        if lineups != nil { lineupsFound += 1 }

        var s = engine.signals(
          match: match, info: info, oddsJSON: oddsFromInfo,
          homeHistory: hs, awayHistory: awayRecords, glicko: glicko,
          posteriorBuckets: posteriorBuckets,
          posteriorWeight: tuning.posteriorWeight,
          teamRatings: (home: ratings.0, away: ratings.1),
          upcomingLineups: lineups)

        // Волна D (D2): sharp money из LiveMonitor.
        s = s.map { sig in
          var x = sig
          let liveKey = "\(x.market)|\(x.selection.lowercased())|\(x.line.map { String($0) } ?? "")"
          if let cur = LiveMonitor.shared.snapshots[x.gameID],
             let prev = LiveMonitor.shared.previousSnapshotForDebug(matchID: x.gameID),
             let curAvg = cur.avg(forKey: liveKey),
             let prevAvg = prev.avg(forKey: liveKey),
             prevAvg > 1 {
            let delta = (curAvg - prevAvg) / prevAvg
            x.liveMovement = delta
            let moving = cur.booksMoving(forKey: liveKey, vs: prev, threshold: 0.01)
            if moving.count >= 3 && abs(delta) > 0.02 {
              x.sharpMoney = true
              x.sharpMovement = delta
            }
          }
          return x
        }
        signalsOut.append(contentsOf: s)
      }
      summary.lineupsFound = lineupsFound
      if lineupsFound > 0 { summary.notes.append("Lineups: \(lineupsFound) матчей с составом") }

      let filtered = signalsOut.filter { s in
        !AutoExclude.isExcluded(league: s.league, market: s.market, rules: excludedRules)
      }
      let removed = signalsOut.count - filtered.count
      if removed > 0 {
        summary.notes.append("Auto-Exclude: убрано \(removed) из \(signalsOut.count) (правил: \(excludedCount))")
      } else if excludedCount > 0 {
        summary.notes.append("Auto-Exclude: правил \(excludedCount), попаданий 0")
      }

      if summary.correlationPairs > 0 && tuning.correlationEnabled {
        summary.notes.append("Correlation: \(summary.correlationPairs) пар из журнала")
      }

      summary.scannedMatches = count
      summary.signals = engine.portfolio(filtered,
        excludedRules: excludedRules,
        stopLoss: stopState,
        correlationMatrix: tuning.correlationEnabled ? corrMatrix : nil,
        bankroll: resolvedSettings.effectiveBankroll)
      summary.finishedAt = Date()
      summary.success = true

      if resolvedSettings.notifyBets && !summary.signals.isEmpty {
        await NotificationService.notify(signals: summary.signals)
      }
    } catch {
      summary.notes.append("Ошибка: \(error.localizedDescription)")
    }

    return summary
  }

  func scanInBackground() async -> Bool {
    let result = await scan(settings: nil)
    return result.success
  }

  private static func loadExcludedRules(minROI: Double, minBets: Int) -> [AutoExcludeRule] {
    guard let container = AppDependencies.shared.container else { return [] }
    let context = ModelContext(container)
    let snap = BacktestService.fetchOrCreate(in: context)
    return AutoExclude.rules(from: snap, minROI: minROI, minBets: minBets)
  }

  private static func loadPosteriorBuckets() -> [PosteriorBucket] {
    guard let container = AppDependencies.shared.container else { return [] }
    let context = ModelContext(container)
    let snap = BacktestService.fetchOrCreate(in: context)
    return snap.decodedPosteriorBuckets()
  }

  private static func parseUpcomingLineups(from info: JSONValue)
    -> (home: [String], away: [String])? {
    let data = info.object?["data"]?.object ?? info.object ?? [:]

    if let obj = data["lineups"]?.object {
      let h = extractIDs(obj["home"]?.array ?? obj["homeTeam"]?.array ?? [])
      let a = extractIDs(obj["away"]?.array ?? obj["awayTeam"]?.array ?? [])
      if !h.isEmpty || !a.isEmpty { return (h, a) }
    }

    if let arr = data["lineups"]?.array, arr.count >= 2 {
      let hTeamID = data["homeTeamId"]?.string ?? data["homeTeam"]?.object?["id"]?.string
      var h: [String] = []
      var a: [String] = []
      for item in arr {
        guard let obj = item.object else { continue }
        let teamID = obj["teamId"]?.string ?? obj["team"]?.string
        let players = extractIDs(obj["players"]?.array ?? obj["lineup"]?.array ?? [])
        if let t = teamID, let hID = hTeamID, t == hID { h = players }
        else if let t = teamID, let hID = hTeamID, t != hID { a = players }
        else if h.isEmpty { h = players } else { a = players }
      }
      if !h.isEmpty || !a.isEmpty { return (h, a) }
    }

    let hArr = data["homeLineup"]?.array ?? data["homePlayers"]?.array ?? data["homeSquad"]?.array
    let aArr = data["awayLineup"]?.array ?? data["awayPlayers"]?.array ?? data["awaySquad"]?.array
    if hArr != nil || aArr != nil {
      let h = extractIDs(hArr ?? [])
      let a = extractIDs(aArr ?? [])
      if !h.isEmpty || !a.isEmpty { return (h, a) }
    }
    return nil
  }

  private static func extractIDs(_ arr: [JSONValue]) -> [String] {
    var out: [String] = []
    for v in arr {
      guard let o = v.object else { continue }
      if let id = o["id"]?.string, !id.isEmpty { out.append(id); continue }
      if let n = o["id"]?.number { out.append(String(Int(n))); continue }
      if let pid = o["playerId"]?.string, !pid.isEmpty { out.append(pid); continue }
      if let name = o["name"]?.string, !name.isEmpty { out.append(name); continue }
    }
    return out
  }

  private static func isExcluded(_ m: Match) -> Bool {
    let x = "\(m.league) \(m.home) \(m.away)".lowercased()
    let bad = ["friendly", "women", "женщ", "u19 women", "u20 women"]
    return bad.contains(where: x.contains)
  }
}

// MARK: - Odds format + Theme

enum OddsFormat: String, CaseIterable, Identifiable {
  case eu, us, uk
  var id: String { rawValue }
  var label: String {
    switch self {
    case .eu: return "EU"; case .us: return "US"; case .uk: return "UK"
    }
  }
  var hint: String {
    switch self {
    case .eu: return "Десятичные · 2.10"
    case .us: return "Американские · +110 / −150"
    case .uk: return "Дробные · 11/10"
    }
  }
}

enum AppColorScheme: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
  var label: String {
    switch self {
    case .system: return "Система"
    case .light: return "Светлая"
    case .dark: return "Тёмная"
    }
  }
  var toColorScheme: SwiftUI.ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

enum OddsFormatter {
  static func format(_ value: Double, as format: OddsFormat) -> String {
    guard value > 1.0 else { return "—" }
    switch format {
    case .eu: return String(format: "%.2f", value)
    case .us:
      if value >= 2.0 { return String(format: "+%d", Int(round((value - 1) * 100))) }
      else { return String(format: "−%d", Int(round(100 / (value - 1)))) }
    case .uk:
      let frac = fractional(value)
      return "\(frac.0)/\(frac.1)"
    }
  }

  private static func fractional(_ value: Double) -> (Int, Int) {
    let net = value - 1.0
    guard net > 0 else { return (0, 1) }
    var bestNum = 1; var bestDen = 1
    var bestErr = Double.greatestFiniteMagnitude
    for den in 1...20 {
      let num = Int(round(net * Double(den)))
      if num < 1 { continue }
      let approx = Double(num) / Double(den)
      let err = abs(approx - net)
      if err < bestErr { bestErr = err; bestNum = num; bestDen = den }
    }
    return (bestNum, bestDen)
  }
}

// MARK: - Notification name

extension Notification.Name {
  static let openSignal = Notification.Name("com.syndicatequant.openSignal")
}

struct SignalIDWrapper: Identifiable {
  let id: String
}

// MARK: - Live odds monitor

struct OddsSnapshot: Hashable {
  let gameID: String
  let numericID: Int?
  let takenAt: Date
  let byKey: [String: [String: Double]]

  func avg(forKey k: String) -> Double? {
    guard let map = byKey[k], !map.isEmpty else { return nil }
    let values = Array(map.values)
    return values.reduce(0, +) / Double(values.count)
  }

  func median(forKey k: String) -> Double? {
    guard let map = byKey[k], !map.isEmpty else { return nil }
    return QuantMath.median(Array(map.values))
  }

  func booksMoving(forKey k: String, vs previous: OddsSnapshot, threshold: Double)
    -> (count: Int, direction: Int, avgDelta: Double) {
    guard let cur = byKey[k], let prev = previous.byKey[k] else { return (0, 0, 0) }
    var upCount = 0; var downCount = 0
    var deltaSum = 0.0; var n = 0
    for (book, c) in cur {
      guard let p = prev[book], p > 1, c > 1 else { continue }
      let d = (c - p) / p
      if d > threshold { upCount += 1 } else if d < -threshold { downCount += 1 }
      deltaSum += d; n += 1
    }
    if upCount > downCount { return (upCount, +1, n > 0 ? deltaSum / Double(n) : 0) }
    else if downCount > upCount { return (downCount, -1, n > 0 ? deltaSum / Double(n) : 0) }
    return (0, 0, 0)
  }
}

struct LineMovement: Identifiable, Hashable {
  var id: String { key }
  let key: String
  let market: String
  let selection: String
  let line: Double?
  let previousAvg: Double
  let currentAvg: Double
  let delta: Double
  let booksAgreeing: Int
  let isSharp: Bool

  var direction: String { delta > 0 ? "▲" : (delta < 0 ? "▼" : "·") }
}

@MainActor
final class LiveMonitor: ObservableObject {
  static let shared = LiveMonitor()

  @Published private(set) var snapshots: [String: OddsSnapshot] = [:]
  private var previous: [String: OddsSnapshot] = [:]
  @Published private(set) var movements: [LineMovement] = []
  @Published private(set) var isRunning: Bool = false
  @Published private(set) var lastTick: Date?
  @Published private(set) var lastError: String?

  private var observed: [String: Int?] = [:]
  private var task: Task<Void, Never>?

  private init() {}

  func observe(gameID: String, numericID: Int?) { observed[gameID] = numericID }

  func clearObserved() {
    observed.removeAll(); snapshots.removeAll()
    previous.removeAll(); movements.removeAll()
  }

  func previousSnapshotForDebug(matchID: String) -> OddsSnapshot? {
    return previous[matchID]
  }

  func start(settings: AppSettings) {
    guard settings.liveMonitorEnabled else { return }
    guard !isRunning else { return }
    isRunning = true
    lastError = nil
    let interval = max(30, min(300, settings.liveMonitorIntervalSec))

    task = Task { [weak self] in
      await self?.tick(settings: settings)
      while !Task.isCancelled {
        let ns = UInt64(interval) * 1_000_000_000
        try? await Task.sleep(nanoseconds: ns)
        if Task.isCancelled { break }
        await self?.tick(settings: settings)
      }
    }
  }

  func stop() { task?.cancel(); task = nil; isRunning = false }

  private func tick(settings: AppSettings) async {
    let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { lastError = "API key не задан"; return }

    let client = SStatsClient(settings: settings)
    var newSnapshots: [String: OddsSnapshot] = [:]
    var newMovements: [LineMovement] = []

    for (gameID, numericID) in observed {
      guard let nid = numericID else { continue }
      var json: JSONValue?
      if let live = try? await client.oddsLive(numericID: nid) { json = live }
      if json == nil { json = try? await client.odds(numericID: nid) }
      guard let raw = json else { continue }

      let parsed = Self.parseOddsByBook(raw)
      guard !parsed.isEmpty else { continue }

      let snap = OddsSnapshot(gameID: gameID, numericID: nid,
                              takenAt: Date(), byKey: parsed)

      if let prev = previous[gameID] {
        for (k, _) in parsed {
          let parts = k.split(separator: "|").map(String.init)
          let market = parts.first ?? ""
          let selection = parts.count > 1 ? parts[1] : ""
          let line: Double? = parts.count > 2 ? Double(parts[2]) : nil

          guard let prevAvg = prev.avg(forKey: k),
                let curAvg = snap.avg(forKey: k),
                prevAvg > 1, curAvg > 1 else { continue }

          let delta = (curAvg - prevAvg) / prevAvg
          let moving = snap.booksMoving(forKey: k, vs: prev, threshold: 0.01)
          let isSharp = moving.count >= 3 && abs(delta) > 0.02

          newMovements.append(LineMovement(
            key: k, market: market, selection: selection, line: line,
            previousAvg: prevAvg, currentAvg: curAvg,
            delta: delta, booksAgreeing: moving.count, isSharp: isSharp))
        }
      }

      previous[gameID] = snap
      newSnapshots[gameID] = snap
    }

    self.snapshots = newSnapshots
    self.movements = newMovements.sorted { abs($0.delta) > abs($1.delta) }
    self.lastTick = Date()
    if newSnapshots.isEmpty {
      self.lastError = observed.isEmpty ? "Нет активных матчей" : "Не удалось получить котировки"
    } else { self.lastError = nil }
  }

  static func parseOddsByBook(_ json: JSONValue) -> [String: [String: Double]] {
    var out: [String: [String: Double]] = [:]
    let items: [JSONValue] = {
      if let arr = json.array { return arr }
      if let dataArr = json.object?["data"]?.array { return dataArr }
      return json.allObjects().map { .object($0) }
    }()

    for mv in items {
      guard let m = mv.object else { continue }
      let marketName = (m["marketName"]?.string ?? m["market"]?.string ?? m["market_name"]?.string ?? "").lowercased()
      guard let prices = m["odds"]?.array else { continue }
      for pv in prices {
        guard let p = pv.object else { continue }
        guard let value = numberFrom(p, ["value", "odds", "price"]),
              value > 1, value < 1000 else { continue }
        let selName = (p["name"]?.string ?? p["selection"]?.string ?? p["outcome"]?.string ?? "")
        let market = normalizeLiveMarket(marketName + " " + selName)
        guard !market.isEmpty else { continue }
        let line = extractLineFrom(selName) ?? extractLineFrom(marketName)
        let book = (p["bookmaker"]?.string ?? p["bookmakerName"]?.string
          ?? p["bookie"]?.string ?? p["bk"]?.string
          ?? m["bookmaker"]?.string ?? m["bookmakerName"]?.string ?? "sstats").lowercased()

        let key = "\(market)|\(selName.lowercased())|\(line.map { String($0) } ?? "")"
        var byBook = out[key] ?? [:]
        if let existing = byBook[book] { byBook[book] = max(existing, value) }
        else { byBook[book] = value }
        out[key] = byBook
      }
    }
    return out
  }

  private static func normalizeLiveMarket(_ x: String) -> String {
    let s = x.lowercased()
    if s.contains("corner") { return "CORNERS" }
    if s.contains("card") || s.contains("yellow") { return "CARDS" }
    if s.contains("goal") || s.contains("total")
        || s.contains("over") || s.contains("under") { return "GOALS" }
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if s.contains("1x2") || s.contains("winner") || s.contains("home")
        || trimmed == "1" || trimmed == "x" || trimmed == "2" { return "1X2" }
    return ""
  }

  private static func extractLineFrom(_ s: String) -> Double? {
    let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)")
    if let m = regex?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let r = Range(m.range(at: 1), in: s) { return Double(s[r]) }
    return nil
  }

  private static func numberFrom(_ o: [String: JSONValue], _ keys: [String]) -> Double? {
    for k in keys { if let n = o[k]?.number { return n } }
    return nil
  }
}