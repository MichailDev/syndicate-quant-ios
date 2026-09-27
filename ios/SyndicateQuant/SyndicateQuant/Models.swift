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

// MARK: - Signal thresholds

struct SignalThresholds: Hashable {
  var goalsMinEV: Double
  var goalsMinRobustEV: Double
  var goalsMinQCS: Double
  var goalsMinMSS: Double
  var goalsMaxUncertainty: Double
  var goalsMinSample: Int
  var goalsMaxStake: Double

  var cornersEnabled: Bool
  var cornersMinEV: Double
  var cornersMinRobustEV: Double
  var cornersMinQCS: Double
  var cornersMinMSS: Double
  var cornersMaxUncertainty: Double
  var cornersMinSample: Int
  var cornersMaxStake: Double

  var cardsEnabled: Bool
  var cardsMinEV: Double
  var cardsMinRobustEV: Double
  var cardsMinQCS: Double
  var cardsMinMSS: Double
  var cardsMaxUncertainty: Double
  var cardsMinSample: Int
  var cardsMaxStake: Double

  var blockedByOOS: Set<String> = []

  static let `default` = SignalThresholds(
    goalsMinEV: 0.03, goalsMinRobustEV: 0.0,
    goalsMinQCS: 78, goalsMinMSS: 0, goalsMaxUncertainty: 0.25,
    goalsMinSample: 6, goalsMaxStake: 0.025,
    cornersEnabled: true,
    cornersMinEV: 0.03, cornersMinRobustEV: 0.0,
    cornersMinQCS: 70, cornersMinMSS: 30, cornersMaxUncertainty: 0.22,
    cornersMinSample: 5, cornersMaxStake: 0.02,
    cardsEnabled: true,
    cardsMinEV: 0.03, cardsMinRobustEV: 0.0,
    cardsMinQCS: 70, cardsMinMSS: 30, cardsMaxUncertainty: 0.22,
    cardsMinSample: 5, cardsMaxStake: 0.02)

  static func from(_ cfg: TuningConfig) -> SignalThresholds {
    SignalThresholds(
      goalsMinEV: 0.03,
      goalsMinRobustEV: cfg.goalsMinRobustEV,
      goalsMinQCS: 78, goalsMinMSS: 0,
      goalsMaxUncertainty: cfg.goalsMaxUncertainty,
      goalsMinSample: cfg.goalsMinSample,
      goalsMaxStake: 0.025,
      cornersEnabled: cfg.cornersEnabled,
      cornersMinEV: cfg.cornersMinEV,
      cornersMinRobustEV: cfg.cornersMinRobustEV,
      cornersMinQCS: cfg.cornersMinQCS,
      cornersMinMSS: cfg.cornersMinMSS,
      cornersMaxUncertainty: cfg.cornersMaxUncertainty,
      cornersMinSample: cfg.cornersMinSample,
      cornersMaxStake: cfg.cornersMaxStake,
      cardsEnabled: cfg.cardsEnabled,
      cardsMinEV: cfg.cardsMinEV,
      cardsMinRobustEV: cfg.cardsMinRobustEV,
      cardsMinQCS: cfg.cardsMinQCS,
      cardsMinMSS: cfg.cardsMinMSS,
      cardsMaxUncertainty: cfg.cardsMaxUncertainty,
      cardsMinSample: cfg.cardsMinSample,
      cardsMaxStake: cfg.cardsMaxStake)
  }
}

// MARK: - Corner / Card weights

struct CornerWeights: Hashable {
  var recentOwn: Double
  var recentOpp: Double
  var leagueAvg: Double
  var xgFactor: Double
  var possession: Double
  var h2h: Double

  static let `default` = CornerWeights(
    recentOwn: 0.35, recentOpp: 0.25,
    leagueAvg: 0.15, xgFactor: 0.10,
    possession: 0.05, h2h: 0.10)

  static func from(_ cfg: TuningConfig) -> CornerWeights {
    CornerWeights(
      recentOwn: cfg.cornersWeightRecentOwn,
      recentOpp: cfg.cornersWeightRecentOpp,
      leagueAvg: cfg.cornersWeightLeague,
      xgFactor: cfg.cornersWeightXG,
      possession: cfg.cornersWeightPossession,
      h2h: cfg.cornersWeightH2H)
  }
}

struct CardWeights: Hashable {
  var recentOwn: Double
  var recentOpp: Double
  var leagueAvg: Double
  var fouls: Double
  var referee: Double
  var h2h: Double

  static let `default` = CardWeights(
    recentOwn: 0.30, recentOpp: 0.20,
    leagueAvg: 0.15, fouls: 0.10,
    referee: 0.20, h2h: 0.05)

  static func from(_ cfg: TuningConfig) -> CardWeights {
    CardWeights(
      recentOwn: cfg.cardsWeightRecentOwn,
      recentOpp: cfg.cardsWeightRecentOpp,
      leagueAvg: cfg.cardsWeightLeague,
      fouls: cfg.cardsWeightFouls,
      referee: cfg.cardsWeightReferee,
      h2h: cfg.cardsWeightH2H)
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
  var status: Int? = nil

  var homeCorners: Int? = nil
  var awayCorners: Int? = nil
  var homeYellows: Int? = nil
  var awayYellows: Int? = nil
  var homeReds: Int? = nil
  var awayReds: Int? = nil
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

  var oddsSource: String? = nil
  var startTime: Date? = nil
  var mss: Double? = nil
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

// MARK: - Historical market cache

@Model final class HistoricalMarketCache {
  @Attribute(.unique) var gameID: String
  var numericID: Int
  var start: Date?
  var league: String
  var homeID: String?
  var awayID: String?
  var home: String
  var away: String
  var oddsJSON: Data?
  var enriched: Bool
  var hasCorners: Bool
  var hasCards: Bool
  var failedAttempts: Int
  var lastError: String?
  var updatedAt: Date

  init(gameID: String, numericID: Int, start: Date?, league: String,
       homeID: String?, awayID: String?, home: String, away: String) {
    self.gameID = gameID
    self.numericID = numericID
    self.start = start
    self.league = league
    self.homeID = homeID
    self.awayID = awayID
    self.home = home
    self.away = away
    self.oddsJSON = nil
    self.enriched = false
    self.hasCorners = false
    self.hasCards = false
    self.failedAttempts = 0
    self.lastError = nil
    self.updatedAt = Date()
  }
}

@MainActor
enum HistoricalMarketCacheService {
  @discardableResult
  static func upsert(from match: Match, in context: ModelContext) -> HistoricalMarketCache? {
    guard let nid = match.numericID else { return nil }
    let gid = match.id
    let d = FetchDescriptor<HistoricalMarketCache>(
      predicate: #Predicate { $0.gameID == gid })
    if let existing = try? context.fetch(d).first {
      existing.numericID = nid
      existing.start = match.start
      existing.league = match.league
      existing.homeID = match.homeID
      existing.awayID = match.awayID
      existing.home = match.home
      existing.away = match.away
      existing.updatedAt = Date()
      return existing
    }
    let row = HistoricalMarketCache(
      gameID: match.id, numericID: nid, start: match.start,
      league: match.league, homeID: match.homeID, awayID: match.awayID,
      home: match.home, away: match.away)
    context.insert(row)
    return row
  }

  static func markEnriched(gameID: String, oddsData: Data,
                           hasCorners: Bool, hasCards: Bool,
                           in context: ModelContext) {
    let gid = gameID
    let d = FetchDescriptor<HistoricalMarketCache>(
      predicate: #Predicate { $0.gameID == gid })
    guard let row = try? context.fetch(d).first else { return }
    row.oddsJSON = oddsData
    row.hasCorners = hasCorners
    row.hasCards = hasCards
    row.enriched = hasCorners || hasCards
    row.failedAttempts = 0
    row.lastError = nil
    row.updatedAt = Date()
  }

  static func markFailed(gameID: String, error: String, in context: ModelContext) {
    let gid = gameID
    let d = FetchDescriptor<HistoricalMarketCache>(
      predicate: #Predicate { $0.gameID == gid })
    guard let row = try? context.fetch(d).first else { return }
    row.failedAttempts += 1
    row.lastError = error
    row.updatedAt = Date()
  }

  static func progress(in context: ModelContext) -> (enriched: Int, total: Int) {
    let all = (try? context.fetch(FetchDescriptor<HistoricalMarketCache>())) ?? []
    let enriched = all.reduce(0) { $0 + ($1.enriched ? 1 : 0) }
    return (enriched, all.count)
  }

  static func candidates(limit: Int, in context: ModelContext) -> [HistoricalMarketCache] {
    let all = (try? context.fetch(FetchDescriptor<HistoricalMarketCache>())) ?? []
    let filtered = all
      .filter { !$0.enriched && $0.failedAttempts < 3 }
      .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    return Array(filtered.prefix(limit))
  }
}

// MARK: - Pre-match line snapshot

@Model final class LineSnapshot {
  @Attribute(.unique) var id: String
  var gameID: String
  var numericID: Int?
  var market: String
  var selection: String
  var line: Double?
  var startTime: Date?
  var league: String
  var home: String
  var away: String
  var takenAt: Date
  var minutesToStart: Int
  var bucketMinutes: Int
  var avgOdds: Double
  var bestOdds: Double
  var worstOdds: Double
  var booksCount: Int
  var bookmakerJSON: Data?

  init(id: String, gameID: String, numericID: Int?,
       market: String, selection: String, line: Double?,
       startTime: Date?, league: String, home: String, away: String,
       takenAt: Date, minutesToStart: Int, bucketMinutes: Int,
       avgOdds: Double, bestOdds: Double, worstOdds: Double,
       booksCount: Int, bookmakerJSON: Data?) {
    self.id = id
    self.gameID = gameID
    self.numericID = numericID
    self.market = market
    self.selection = selection
    self.line = line
    self.startTime = startTime
    self.league = league
    self.home = home
    self.away = away
    self.takenAt = takenAt
    self.minutesToStart = minutesToStart
    self.bucketMinutes = bucketMinutes
    self.avgOdds = avgOdds
    self.bestOdds = bestOdds
    self.worstOdds = worstOdds
    self.booksCount = booksCount
    self.bookmakerJSON = bookmakerJSON
  }
}

@MainActor
enum LineSnapshotService {
  static func bucket(minutesToStart: Int, maxWindow: Int = 60) -> Int? {
    if minutesToStart <= 0 { return nil }
    if minutesToStart > maxWindow { return nil }
    if minutesToStart > 30 { return 60 }
    if minutesToStart > 15 { return 30 }
    if minutesToStart > 5  { return 15 }
    return 5
  }

  @discardableResult
  static func save(gameID: String, numericID: Int?,
                   market: String, selection: String, line: Double?,
                   startTime: Date?, league: String, home: String, away: String,
                   bucketMinutes: Int, minutesToStart: Int,
                   byBook: [String: Double],
                   in context: ModelContext) -> Bool {
    let sid = "\(gameID)|\(market)|\(selection.lowercased())|\(line.map { String($0) } ?? "na")|\(bucketMinutes)"
    let d = FetchDescriptor<LineSnapshot>(predicate: #Predicate { $0.id == sid })
    if let _ = try? context.fetch(d).first { return false }

    let values = Array(byBook.values)
    guard !values.isEmpty else { return false }
    let avg = values.reduce(0, +) / Double(values.count)
    let best = values.max() ?? avg
    let worst = values.min() ?? avg

    let bookJSON: Data? = {
      let dict = Dictionary(uniqueKeysWithValues: byBook.map { ($0.key, $0.value) })
      return try? JSONEncoder().encode(dict)
    }()

    let snap = LineSnapshot(
      id: sid, gameID: gameID, numericID: numericID,
      market: market, selection: selection, line: line,
      startTime: startTime, league: league, home: home, away: away,
      takenAt: Date(), minutesToStart: minutesToStart, bucketMinutes: bucketMinutes,
      avgOdds: avg, bestOdds: best, worstOdds: worst,
      booksCount: values.count, bookmakerJSON: bookJSON)
    context.insert(snap)
    return true
  }

  static func history(gameID: String, market: String, selection: String,
                      line: Double?, in context: ModelContext) -> [LineSnapshot] {
    let gid = gameID
    let d = FetchDescriptor<LineSnapshot>(
      predicate: #Predicate { $0.gameID == gid })
    let all = (try? context.fetch(d)) ?? []
    let selLower = selection.lowercased()
    return all
      .filter { $0.market == market && $0.selection.lowercased() == selLower }
      .filter { s in
        if let l = line { return s.line == l }
        return s.line == nil
      }
      .sorted { $0.takenAt < $1.takenAt }
  }

  static func totalCount(in context: ModelContext) -> Int {
    (try? context.fetch(FetchDescriptor<LineSnapshot>()))?.count ?? 0
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

  var cornersEnabled: Bool = true
  var cardsEnabled: Bool = true
  var cornersMinEV: Double = 0.03
  var cardsMinEV: Double = 0.03
  var cornersMinQCS: Double = 70
  var cardsMinQCS: Double = 70
  var cornersMaxStake: Double = 0.02
  var cardsMaxStake: Double = 0.02
  var cornersMinSample: Int = 5
  var cardsMinSample: Int = 5

  var goalsMinRobustEV: Double = 0.0
  var goalsMinSample: Int = 6
  var goalsMaxUncertainty: Double = 0.25

  var cornersMinRobustEV: Double = 0.0
  var cornersMinMSS: Double = 30
  var cornersMaxUncertainty: Double = 0.22

  var cardsMinRobustEV: Double = 0.0
  var cardsMinMSS: Double = 30
  var cardsMaxUncertainty: Double = 0.22

  var oosGateEnabled: Bool = false
  var oosMinBets: Int = 100
  var oosWindowDays: Int = 90
  var goalsOOSMinROI: Double = -0.03
  var cornersOOSMinROI: Double = -0.03
  var cardsOOSMinROI: Double = -0.03

  var cornersWeightRecentOwn: Double = 0.35
  var cornersWeightRecentOpp: Double = 0.25
  var cornersWeightLeague: Double = 0.15
  var cornersWeightXG: Double = 0.10
  var cornersWeightPossession: Double = 0.05
  var cornersWeightH2H: Double = 0.10

  var cardsWeightRecentOwn: Double = 0.30
  var cardsWeightRecentOpp: Double = 0.20
  var cardsWeightLeague: Double = 0.15
  var cardsWeightFouls: Double = 0.10
  var cardsWeightReferee: Double = 0.20
  var cardsWeightH2H: Double = 0.05

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
    self.id = id; self.createdAt = createdAt
    self.kind = kind; self.target = target
    self.beforeValue = beforeValue; self.afterValue = afterValue
    self.note = note; self.rolledBack = rolledBack
  }
}

struct AutoDecision: Identifiable, Hashable {
  var id: String; var title: String; var summary: String
  var detail: String; var enabled: Bool; var flagKey: String
}

@MainActor
enum TuningService {
  static func fetchOrCreate(in context: ModelContext) -> TuningConfig {
    let d = FetchDescriptor<TuningConfig>()
    if let existing = try? context.fetch(d).first { return existing }
    let cfg = TuningConfig()
    context.insert(cfg); try? context.save()
    return cfg
  }

  static func log(context: ModelContext, kind: String, target: String,
                  before: String, after: String, note: String = "") {
    let e = TuningEvent(kind: kind, target: target,
                        beforeValue: before, afterValue: after, note: note)
    context.insert(e); try? context.save()
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
    case "cornersEnabled":
      cfg.cornersEnabled = Bool(last.beforeValue) ?? cfg.cornersEnabled
    case "cardsEnabled":
      cfg.cardsEnabled = Bool(last.beforeValue) ?? cfg.cardsEnabled
    case "cornersMinEV":
      cfg.cornersMinEV = Double(last.beforeValue) ?? cfg.cornersMinEV
    case "cardsMinEV":
      cfg.cardsMinEV = Double(last.beforeValue) ?? cfg.cardsMinEV
    case "cornersMinQCS":
      cfg.cornersMinQCS = Double(last.beforeValue) ?? cfg.cornersMinQCS
    case "cardsMinQCS":
      cfg.cardsMinQCS = Double(last.beforeValue) ?? cfg.cardsMinQCS
    case "cornersMaxStake":
      cfg.cornersMaxStake = Double(last.beforeValue) ?? cfg.cornersMaxStake
    case "cardsMaxStake":
      cfg.cardsMaxStake = Double(last.beforeValue) ?? cfg.cardsMaxStake
    case "cornersMinSample":
      cfg.cornersMinSample = Int(last.beforeValue) ?? cfg.cornersMinSample
    case "cardsMinSample":
      cfg.cardsMinSample = Int(last.beforeValue) ?? cfg.cardsMinSample
    case "goalsMinRobustEV":
      cfg.goalsMinRobustEV = Double(last.beforeValue) ?? cfg.goalsMinRobustEV
    case "goalsMinSample":
      cfg.goalsMinSample = Int(last.beforeValue) ?? cfg.goalsMinSample
    case "goalsMaxUncertainty":
      cfg.goalsMaxUncertainty = Double(last.beforeValue) ?? cfg.goalsMaxUncertainty
    case "cornersMinRobustEV":
      cfg.cornersMinRobustEV = Double(last.beforeValue) ?? cfg.cornersMinRobustEV
    case "cornersMinMSS":
      cfg.cornersMinMSS = Double(last.beforeValue) ?? cfg.cornersMinMSS
    case "cornersMaxUncertainty":
      cfg.cornersMaxUncertainty = Double(last.beforeValue) ?? cfg.cornersMaxUncertainty
    case "cardsMinRobustEV":
      cfg.cardsMinRobustEV = Double(last.beforeValue) ?? cfg.cardsMinRobustEV
    case "cardsMinMSS":
      cfg.cardsMinMSS = Double(last.beforeValue) ?? cfg.cardsMinMSS
    case "cardsMaxUncertainty":
      cfg.cardsMaxUncertainty = Double(last.beforeValue) ?? cfg.cardsMaxUncertainty
    case "oosGateEnabled":
      cfg.oosGateEnabled = Bool(last.beforeValue) ?? cfg.oosGateEnabled
    case "oosMinBets":
      cfg.oosMinBets = Int(last.beforeValue) ?? cfg.oosMinBets
    case "oosWindowDays":
      cfg.oosWindowDays = Int(last.beforeValue) ?? cfg.oosWindowDays
    case "goalsOOSMinROI":
      cfg.goalsOOSMinROI = Double(last.beforeValue) ?? cfg.goalsOOSMinROI
    case "cornersOOSMinROI":
      cfg.cornersOOSMinROI = Double(last.beforeValue) ?? cfg.cornersOOSMinROI
    case "cardsOOSMinROI":
      cfg.cardsOOSMinROI = Double(last.beforeValue) ?? cfg.cardsOOSMinROI
    case "cornersWeightRecentOwn":
      cfg.cornersWeightRecentOwn = Double(last.beforeValue) ?? cfg.cornersWeightRecentOwn
    case "cornersWeightRecentOpp":
      cfg.cornersWeightRecentOpp = Double(last.beforeValue) ?? cfg.cornersWeightRecentOpp
    case "cornersWeightLeague":
      cfg.cornersWeightLeague = Double(last.beforeValue) ?? cfg.cornersWeightLeague
    case "cornersWeightXG":
      cfg.cornersWeightXG = Double(last.beforeValue) ?? cfg.cornersWeightXG
    case "cornersWeightPossession":
      cfg.cornersWeightPossession = Double(last.beforeValue) ?? cfg.cornersWeightPossession
    case "cornersWeightH2H":
      cfg.cornersWeightH2H = Double(last.beforeValue) ?? cfg.cornersWeightH2H
    case "cardsWeightRecentOwn":
      cfg.cardsWeightRecentOwn = Double(last.beforeValue) ?? cfg.cardsWeightRecentOwn
    case "cardsWeightRecentOpp":
      cfg.cardsWeightRecentOpp = Double(last.beforeValue) ?? cfg.cardsWeightRecentOpp
    case "cardsWeightLeague":
      cfg.cardsWeightLeague = Double(last.beforeValue) ?? cfg.cardsWeightLeague
    case "cardsWeightFouls":
      cfg.cardsWeightFouls = Double(last.beforeValue) ?? cfg.cardsWeightFouls
    case "cardsWeightReferee":
      cfg.cardsWeightReferee = Double(last.beforeValue) ?? cfg.cardsWeightReferee
    case "cardsWeightH2H":
      cfg.cardsWeightH2H = Double(last.beforeValue) ?? cfg.cardsWeightH2H
    default: break
    }
    cfg.updatedAt = Date()
    last.rolledBack = true
    try? context.save()
    return last
  }

  static func decisions(config: TuningConfig, snapshot: BacktestSnapshot?,
                        journal: [JournalEntry], corr: CorrelationMatrix) -> [AutoDecision] {
    var out: [AutoDecision] = []
    let rules = snapshot.map {
      AutoExclude.rules(from: $0, minROI: config.autoExcludeMinROI,
                        minBets: config.autoExcludeMinBets)
    } ?? []
    let activeRules = rules.filter { $0.excluded }.count
    out.append(AutoDecision(id: "autoexclude", title: "Auto-Exclude",
      summary: config.autoExcludeEnabled ? "\(activeRules) активных правил" : "выключено",
      detail: String(format: "Порог: ROI < %.1f%% при n ≥ %d",
                     config.autoExcludeMinROI * 100, config.autoExcludeMinBets),
      enabled: config.autoExcludeEnabled, flagKey: "autoExcludeEnabled"))

    let buckets = snapshot?.decodedPosteriorBuckets() ?? []
    let usable = buckets.filter { $0.n >= 20 }.count
    out.append(AutoDecision(id: "posterior", title: "Bayesian posterior",
      summary: config.posteriorEnabled ? "\(usable) бакетов (n≥20)" : "выключено",
      detail: String(format: "p_adj = (1 − %.2f)·p + %.2f·p_post",
                     config.posteriorWeight, config.posteriorWeight),
      enabled: config.posteriorEnabled, flagKey: "posteriorEnabled"))

    let streak = VolatilityStop.evaluate(journal,
      capThreshold: config.stopLossCapStreak,
      pauseThreshold: config.stopLossPauseStreak)
    out.append(AutoDecision(id: "stoploss", title: "Volatility stop",
      summary: config.stopLossEnabled
        ? "\(streak.streak) проигрышей · \(streak.state.label)" : "выключено",
      detail: "Cap ≥ \(config.stopLossCapStreak) → 5%; Pause ≥ \(config.stopLossPauseStreak)",
      enabled: config.stopLossEnabled, flagKey: "stopLossEnabled"))

    out.append(AutoDecision(id: "correlation", title: "Correlation matrix",
      summary: config.correlationEnabled
        ? "\(corr.marketPairsN.count + corr.leaguePairsN.count) пар (n≥20)" : "выключено",
      detail: "Эмпирические φ-коэффициенты из журнала; fallback — структурные",
      enabled: config.correlationEnabled, flagKey: "correlationEnabled"))

    out.append(AutoDecision(id: "playerimpact", title: "Player impact",
      summary: config.playerImpactEnabled ? "ждём составы от API" : "выключено",
      detail: "λ × 0.88…1.00 в зависимости от отсутствия топ-8",
      enabled: config.playerImpactEnabled, flagKey: "playerImpactEnabled"))

    out.append(AutoDecision(id: "teamrating", title: "Team rating (Elo)",
      summary: config.teamRatingEnabled ? "активно (≥ 3 матчей на команду)" : "выключено",
      detail: "Старт 1500, HFA 60, K=32→20; влияет на λ через glickoAdjust",
      enabled: config.teamRatingEnabled, flagKey: "teamRatingEnabled"))

    let oosReport = OOSBuilder.build(from: journal, windowDays: config.oosWindowDays)
    let blocked = OOSBuilder.blockedMarkets(report: oosReport, cfg: config)
    let oosSummary: String = {
      if !config.oosGateEnabled { return "выключено" }
      if blocked.isEmpty { return "активно · блокировок нет" }
      return "активно · блок: \(blocked.sorted().joined(separator: ", "))"
    }()
    out.append(AutoDecision(id: "oos", title: "OOS-валидация",
      summary: oosSummary,
      detail: String(format: "Окно %d дней · n≥%d · порог ROI −%.1f%%",
                     config.oosWindowDays, config.oosMinBets,
                     abs(config.goalsOOSMinROI) * 100),
      enabled: config.oosGateEnabled, flagKey: "oosGateEnabled"))

    out.append(AutoDecision(id: "corners", title: "Рынок CORNERS",
      summary: config.cornersEnabled
        ? String(format: "EV ≥ %.1f%%, robEV ≥ %.1f%%, QCS ≥ %.0f, MSS ≥ %.0f, sample ≥ %d, unc ≤ %.2f",
                 config.cornersMinEV * 100, config.cornersMinRobustEV * 100,
                 config.cornersMinQCS, config.cornersMinMSS,
                 config.cornersMinSample, config.cornersMaxUncertainty)
        : "выключен",
      detail: String(format: "Pinnacle. Вес λ: own %.2f/opp %.2f · xG %.2f · H2H %.2f · poss %.2f",
                     config.cornersWeightRecentOwn, config.cornersWeightRecentOpp,
                     config.cornersWeightXG, config.cornersWeightH2H,
                     config.cornersWeightPossession),
      enabled: config.cornersEnabled, flagKey: "cornersEnabled"))

    out.append(AutoDecision(id: "cards", title: "Рынок CARDS",
      summary: config.cardsEnabled
        ? String(format: "EV ≥ %.1f%%, robEV ≥ %.1f%%, QCS ≥ %.0f, MSS ≥ %.0f, sample ≥ %d, unc ≤ %.2f",
                 config.cardsMinEV * 100, config.cardsMinRobustEV * 100,
                 config.cardsMinQCS, config.cardsMinMSS,
                 config.cardsMinSample, config.cardsMaxUncertainty)
        : "выключен",
      detail: String(format: "Best available. Вес λ: fouls %.2f, ref %.2f, H2H %.2f",
                     config.cardsWeightFouls, config.cardsWeightReferee,
                     config.cardsWeightH2H),
      enabled: config.cardsEnabled, flagKey: "cardsEnabled"))

    return out
  }
}

// MARK: - OOS validation

struct MarketOOSReport: Codable, Hashable {
  var market: String
  var bets: Int
  var wins: Int
  var losses: Int
  var pushes: Int
  var staked: Double
  var profit: Double
  var roi: Double
  var hitRate: Double
}

struct OOSValidationReport: Codable, Hashable {
  var generatedAt: Date
  var totalEntries: Int
  var windowDays: Int
  var windowStart: Date?
  var byMarket: [String: MarketOOSReport]

  static let empty = OOSValidationReport(
    generatedAt: .distantPast, totalEntries: 0,
    windowDays: 0, windowStart: nil, byMarket: [:])

  func report(for market: String) -> MarketOOSReport? { byMarket[market] }
}

enum OOSBuilder {
  static func build(from journal: [JournalEntry],
                    windowDays: Int = 90) -> OOSValidationReport {
    let cutoff = Date().addingTimeInterval(-Double(max(1, windowDays)) * 86400)
    let closed = journal.filter {
      $0.status == "CLOSED"
        && $0.createdAt >= cutoff
        && ($0.result == "WIN" || $0.result == "LOSS" || $0.result == "PUSH")
    }
    guard !closed.isEmpty else {
      return OOSValidationReport(generatedAt: Date(), totalEntries: 0,
                                 windowDays: windowDays, windowStart: nil, byMarket: [:])
    }

    var byMarket: [String: MarketOOSReport] = [:]
    let grouped = Dictionary(grouping: closed, by: { $0.market })
    for (mk, list) in grouped {
      var wins = 0, losses = 0, pushes = 0
      var staked = 0.0, profit = 0.0
      for e in list {
        staked += e.stake
        if let p = e.profit { profit += p }
        switch e.result {
        case "WIN": wins += 1
        case "LOSS": losses += 1
        case "PUSH": pushes += 1
        default: break
        }
      }
      let roi = staked > 0 ? profit / staked : 0
      let dec = wins + losses
      let hitRate = dec > 0 ? Double(wins) / Double(dec) : 0
      byMarket[mk] = MarketOOSReport(
        market: mk, bets: list.count, wins: wins, losses: losses, pushes: pushes,
        staked: staked, profit: profit, roi: roi, hitRate: hitRate)
    }
    return OOSValidationReport(
      generatedAt: Date(),
      totalEntries: closed.count,
      windowDays: windowDays,
      windowStart: closed.map { $0.createdAt }.min(),
      byMarket: byMarket)
  }

  static func blockedMarkets(report: OOSValidationReport,
                             cfg: TuningConfig) -> Set<String> {
    guard cfg.oosGateEnabled else { return [] }
    var out: Set<String> = []
    for (mk, r) in report.byMarket where r.bets >= cfg.oosMinBets {
      let threshold: Double
      switch mk {
      case "CORNERS": threshold = cfg.cornersOOSMinROI
      case "CARDS":   threshold = cfg.cardsOOSMinROI
      default:        threshold = cfg.goalsOOSMinROI
      }
      if r.roi < threshold { out.insert(mk) }
    }
    return out
  }
}

// MARK: - Volatility stop

enum VolatilityState: Equatable {
  case normal, cap(Double), pause
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

// MARK: - Correlation

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
      var corr: [String: Double] = [:]; var ns: [String: Int] = [:]
      for (k, v) in s where v.n >= minPairs {
        let n = Double(v.n)
        let pAB = v.both / n; let pA = v.a / n; let pB = v.b / n
        let denom = sqrt(pA * (1 - pA) * pB * (1 - pB))
        let phi = denom > 1e-9 ? (pAB - pA * pB) / denom : 0
        corr[k] = max(-1, min(1, phi)); ns[k] = v.n
      }
      return (corr, ns)
    }

    let (mc, mn) = toCorr(marketSum)
    let (lc, ln) = toCorr(leagueSum)

    return CorrelationMatrix(marketPairs: mc, leaguePairs: lc,
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
  var matchStart: Date?

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
    matchStart = signal.startTime
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
    self.id = id; self.predicted = predicted; self.actual = actual
    self.market = market; self.createdAt = createdAt
  }
}

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
    self.id = id; self.createdAt = createdAt
    self.matches = matches; self.bets = bets
    self.wins = wins; self.losses = losses; self.pushes = pushes
    self.profit = profit; self.staked = staked; self.roi = roi
    self.yieldPct = yieldPct; self.hitRate = hitRate
    self.maxDrawdown = maxDrawdown; self.maxLosingStreak = maxLosingStreak
    self.sharpe = sharpe; self.brier = brier
    self.logLoss = logLoss; self.avgCLV = avgCLV
  }
}

struct StoredSegmentStats: Codable, Hashable {
  var bets: Int; var wins: Int; var losses: Int; var pushes: Int
  var profit: Double; var staked: Double
  var roi: Double; var yieldPct: Double; var hitRate: Double; var avgOdds: Double

  init() {
    bets = 0; wins = 0; losses = 0; pushes = 0
    profit = 0; staked = 0; roi = 0; yieldPct = 0; hitRate = 0; avgOdds = 0
  }
  init(bets: Int, wins: Int, losses: Int, pushes: Int,
       profit: Double, staked: Double, avgOdds: Double) {
    self.bets = bets; self.wins = wins; self.losses = losses; self.pushes = pushes
    self.profit = profit; self.staked = staked
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

// MARK: - Walk-forward delta

struct WalkForwardDelta: Codable, Hashable {
  var matches: Int
  var bets: Int
  var wins: Int
  var losses: Int
  var pushes: Int
  var roi: Double
  var sharpe: Double
  var sortino: Double
  var profitFactor: Double
  var brier: Double
  var logLoss: Double
  var avgCLV: Double
  var hitRate: Double
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

  var enrichmentProgress: Int = 0
  var enrichmentTotal: Int = 0

  var posteriorCornersJSON: Data?
  var posteriorCardsJSON: Data?

  var buildCursorTimestamp: Double = 0
  var buildMatchesCount: Int = 0

  var buildJobID: String? = nil
  var historicalCacheCount: Int = 0

  var oosValidationJSON: Data? = nil

  var trainReportJSON: Data? = nil
  var validationReportJSON: Data? = nil
  var holdoutReportJSON: Data? = nil
  var walkForwardMode: String = "off"

  init(id: String = "current") {
    self.id = id; self.version = 1
    self.builtAt = nil; self.fromDate = nil; self.toDate = nil
    self.totalMatches = 0; self.totalBets = 0
    self.buildProgress = 0; self.buildStatus = "idle"; self.lastError = nil
    self.perLeagueJSON = nil; self.perMarketJSON = nil
    self.perLeagueMarketJSON = nil; self.evBucketsJSON = nil
    self.oddsBucketsJSON = nil; self.classificationJSON = nil
    self.posteriorJSON = nil; self.modelComparisonJSON = nil
    self.posteriorCornersJSON = nil; self.posteriorCardsJSON = nil
    self.avgROI = 0; self.avgCLV = 0; self.brier = 0; self.logLoss = 0
    self.sharpe = 0; self.sortino = 0; self.profitFactor = 0
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
  func decodedPosteriorCornersBuckets() -> [PosteriorBucket] {
    guard let d = posteriorCornersJSON else { return [] }
    return (try? JSONDecoder().decode([PosteriorBucket].self, from: d)) ?? []
  }
  func decodedPosteriorCardsBuckets() -> [PosteriorBucket] {
    guard let d = posteriorCardsJSON else { return [] }
    return (try? JSONDecoder().decode([PosteriorBucket].self, from: d)) ?? []
  }
  func decodedModelComparison() -> [ModelComparison] {
    guard let d = modelComparisonJSON else { return [] }
    return (try? JSONDecoder().decode([ModelComparison].self, from: d)) ?? []
  }
  func decodedOOSReport() -> OOSValidationReport {
    guard let d = oosValidationJSON else { return .empty }
    return (try? JSONDecoder().decode(OOSValidationReport.self, from: d)) ?? .empty
  }
  func decodedTrainReport() -> WalkForwardDelta? {
    guard let d = trainReportJSON else { return nil }
    return try? JSONDecoder().decode(WalkForwardDelta.self, from: d)
  }
  func decodedValidationReport() -> WalkForwardDelta? {
    guard let d = validationReportJSON else { return nil }
    return try? JSONDecoder().decode(WalkForwardDelta.self, from: d)
  }
  func decodedHoldoutReport() -> WalkForwardDelta? {
    guard let d = holdoutReportJSON else { return nil }
    return try? JSONDecoder().decode(WalkForwardDelta.self, from: d)
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

// MARK: - Metrics

struct JournalMetrics {
  var totalEntries = 0; var closedEntries = 0
  var wins = 0; var losses = 0; var pushes = 0; var voids = 0
  var profit = 0.0; var staked = 0.0
  var avgCLV = 0.0; var clvCount = 0
  var brier = 0.0; var logLoss = 0.0
  var calibration: [CalibrationBucket] = []

  var roi: Double { staked > 0 ? profit / staked : 0 }
  var yieldPct: Double { roi }
  var hitRate: Double {
    wins + losses > 0 ? Double(wins) / Double(wins + losses) : 0
  }
  var pending: Int { totalEntries - closedEntries }
}

struct CalibrationBucket: Identifiable {
  let id: String; let midpoint: Double
  let predicted: Double; let actual: Double; let count: Int
}

struct MarketCLV: Codable, Hashable {
  var count: Int
  var avgCLV: Double
  var positiveRate: Double
}

struct CLVReport {
  var totalWithCLV: Int
  var positiveCount: Int
  var neutralCount: Int
  var negativeCount: Int
  var avgCLV: Double
  var medianCLV: Double
  var byMarket: [String: MarketCLV]
  var pnlPositive: Double
  var pnlNegative: Double
  var positiveRate: Double
  var verdict: String
  var note: String
}

enum MarketRegime: String {
  case normal          = "NORMAL"
  case highVolatility  = "HIGH VOL"
  case lowLiquidity    = "LOW LIQ"
  case lineDislocation = "DISLOCATION"
  case unknown         = "UNKNOWN"

  var label: String { rawValue }
}

struct MarketRegimeReport {
  var regime: MarketRegime
  var avgBooksPerMarket: Double
  var avgSpreadPct: Double
  var sharpMovements: Int
  var totalMovements: Int
  var note: String
}

struct EquityPoint: Identifiable, Hashable {
  let id: String; let date: Date
  let cumulativeProfit: Double; let cumulativeStaked: Double
  let bets: Int
}

struct BollingerPoint: Identifiable, Hashable {
  var id: String
  let date: Date
  let index: Int
  let value: Double
  let ma: Double?
  let upper: Double?
  let lower: Double?
  let isBreakout: Bool
}

struct BollingerRisk {
  enum State: String {
    case normal = "NORMAL"
    case expanding = "EXPANDING"
    case high = "HIGH"
    case risk = "RISK"
  }

  struct Report {
    var state: State
    var width: Double?
    var avgWidth: Double?
    var widthRatio: Double
    var recentBreakouts: Int
    var breakoutRate: Double
    var window: Int
    var note: String
  }

  static func evaluate(_ bands: [BollingerPoint], window: Int = 20) -> Report {
    guard bands.count >= window + 2 else {
      return Report(state: .normal, width: nil, avgWidth: nil,
                    widthRatio: 1, recentBreakouts: 0, breakoutRate: 0,
                    window: window,
                    note: "Недостаточно данных (\(bands.count)/\(window + 2))")
    }

    var widths: [Double] = []
    widths.reserveCapacity(bands.count)
    for p in bands {
      if let u = p.upper, let l = p.lower, u >= l { widths.append(u - l) }
    }
    guard widths.count >= window else {
      return Report(state: .normal, width: nil, avgWidth: nil,
                    widthRatio: 1, recentBreakouts: 0, breakoutRate: 0,
                    window: window, note: "Нет полос")
    }

    let recent = Array(widths.suffix(window))
    let currentWidth = recent.last ?? 0
    let avgWidth = recent.reduce(0, +) / Double(recent.count)
    let widthRatio = avgWidth > 0 ? currentWidth / avgWidth : 1

    let tail = Array(bands.suffix(window))
    let breakouts = tail.filter { $0.isBreakout }.count
    let breakoutRate = Double(breakouts) / Double(max(tail.count, 1))

    let state: State
    let note: String
    if widthRatio > 1.5 && breakoutRate > 0.25 {
      state = .risk
      note = "Высокая волатильность P/L и частые выходы за полосу"
    } else if widthRatio > 1.5 {
      state = .high
      note = "Полосы расширяются — волатильность P/L растёт"
    } else if breakoutRate > 0.25 {
      state = .expanding
      note = "Частые выходы за полосу при стабильной ширине"
    } else {
      state = .normal
      note = "Штатный режим волатильности"
    }
    return Report(state: state,
                  width: currentWidth, avgWidth: avgWidth,
                  widthRatio: widthRatio,
                  recentBreakouts: breakouts, breakoutRate: breakoutRate,
                  window: window, note: note)
  }
}

enum Metrics {
  static func compute(_ entries: [JournalEntry]) -> JournalMetrics {
    var m = JournalMetrics()
    m.totalEntries = entries.count
    let closed = entries.filter { $0.status == "CLOSED" }
    m.closedEntries = closed.count

    var brierSum = 0.0; var logLossSum = 0.0; var brierCount = 0
    var clvSum = 0.0; var clvCount = 0
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
    var weightedSum = 0.0; var totalN = 0
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
    var cumProfit = 0.0; var cumStaked = 0.0
    let mult = bankroll ?? 1.0
    for (i, e) in closed.enumerated() {
      cumProfit += (e.profit ?? 0) * mult
      cumStaked += e.stake * mult
      curve.append(EquityPoint(id: "eq\(i)_\(e.id)", date: e.createdAt,
        cumulativeProfit: cumProfit, cumulativeStaked: cumStaked, bets: i + 1))
    }
    return curve
  }

  static func bollingerBands(
    _ curve: [EquityPoint],
    window: Int = 20,
    sigmaMultiplier: Double = 2.0
  ) -> [BollingerPoint] {
    guard curve.count >= window else { return [] }
    var out: [BollingerPoint] = []
    out.reserveCapacity(curve.count)
    for i in 0..<curve.count {
      let p = curve[i]
      if i < window - 1 {
        out.append(BollingerPoint(
          id: p.id, date: p.date, index: i,
          value: p.cumulativeProfit,
          ma: nil, upper: nil, lower: nil, isBreakout: false))
        continue
      }
      let slice = curve[(i - window + 1)...i].map { $0.cumulativeProfit }
      let mean = slice.reduce(0, +) / Double(slice.count)
      let variance = slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(slice.count)
      let sd = sqrt(variance)
      let upper = mean + sigmaMultiplier * sd
      let lower = mean - sigmaMultiplier * sd
      let value = p.cumulativeProfit
      let breakout = value > upper || value < lower
      out.append(BollingerPoint(
        id: p.id, date: p.date, index: i,
        value: value, ma: mean, upper: upper, lower: lower,
        isBreakout: breakout))
    }
    return out
  }

  static func clvReport(_ entries: [JournalEntry]) -> CLVReport {
    let closed = entries.filter { $0.status == "CLOSED" && $0.clv != nil }
    guard !closed.isEmpty else {
      return CLVReport(
        totalWithCLV: 0, positiveCount: 0, neutralCount: 0, negativeCount: 0,
        avgCLV: 0, medianCLV: 0, byMarket: [:],
        pnlPositive: 0, pnlNegative: 0, positiveRate: 0,
        verdict: "NO DATA",
        note: "Нет закрытых записей с CLV")
    }
    let clvs = closed.compactMap { $0.clv }
    let avg = clvs.reduce(0, +) / Double(clvs.count)
    let median = QuantMath.median(clvs) ?? 0

    let pos = closed.filter { ($0.clv ?? 0) > 0.005 }
    let neg = closed.filter { ($0.clv ?? 0) < -0.005 }
    let neu = closed.count - pos.count - neg.count

    var byMarket: [String: MarketCLV] = [:]
    let grouped = Dictionary(grouping: closed, by: { $0.market })
    for (mk, list) in grouped {
      let vals = list.compactMap { $0.clv }
      guard !vals.isEmpty else { continue }
      let a = vals.reduce(0, +) / Double(vals.count)
      let p = Double(list.filter { ($0.clv ?? 0) > 0.005 }.count) / Double(list.count)
      byMarket[mk] = MarketCLV(count: list.count, avgCLV: a, positiveRate: p)
    }

    let pnlPos = pos.compactMap { $0.profit }.reduce(0, +)
    let pnlNeg = neg.compactMap { $0.profit }.reduce(0, +)
    let rate = Double(pos.count) / Double(closed.count)

    let verdict: String
    let note: String
    if avg > 0.015 && rate > 0.55 {
      verdict = "STRONG"
      note = "Сигналы системно берут цену лучше закрытия — edge до рынка подтверждён"
    } else if avg > 0.005 && rate > 0.45 {
      verdict = "OK"
      note = "Средний CLV положительный, доля плюсовых ставок приемлемая"
    } else if avg > -0.005 && rate > 0.35 {
      verdict = "WEAK"
      note = "CLV около нуля — преимущество слабое, следите за выборкой"
    } else if avg < -0.01 {
      verdict = "NEGATIVE"
      note = "Цена систематически хуже закрытия — edge под вопросом"
    } else {
      verdict = "MIXED"
      note = "CLV асимметричный — нестабильная картина"
    }
    return CLVReport(
      totalWithCLV: closed.count,
      positiveCount: pos.count, neutralCount: neu, negativeCount: neg.count,
      avgCLV: avg, medianCLV: median, byMarket: byMarket,
      pnlPositive: pnlPos, pnlNegative: pnlNeg,
      positiveRate: rate, verdict: verdict, note: note)
  }

  // [W3c] OOS wrapper для UI.
  static func oosFromJournal(_ entries: [JournalEntry],
                             windowDays: Int = 90) -> OOSValidationReport {
    OOSBuilder.build(from: entries, windowDays: windowDays)
  }
}

// MARK: - JournalService

enum JournalService {
  @MainActor
  static func settleOpenEntries(context: ModelContext, client: SStatsClient)
    async -> (closed: Int, failed: Int) {
    let descriptor = FetchDescriptor<JournalEntry>()
    guard let all = try? context.fetch(descriptor) else { return (0, 0) }
    let open = all.filter { $0.status == "OPEN" }
    var closed = 0; var failed = 0

    for entry in open {
      guard let info = try? await client.gameInfo(entry.gameID) else {
        failed += 1; continue
      }
      let data = info.object?["data"]?.object ?? info.object ?? [:]
      let game = data["game"]?.object ?? data
      let stats = data["statistics"]?.object ?? game["statistics"]?.object ?? [:]

      guard let result = resolveResult(entry: entry, game: game, stats: stats)
      else { continue }

      entry.result = result
      entry.profit = computeProfit(result: result, odds: entry.odds, stake: entry.stake)

      if entry.market == "CORNERS" || entry.market == "CARDS" {
        if let nid = Int(entry.gameID),
           let books = try? await client.fullOdds(gameId: nid),
           let closing = findClosingInBookmakers(entry: entry, books: books),
           closing > 1 {
          entry.closingOdds = closing
          entry.clv = entry.odds / closing - 1
          if let openOdds = entry.openingOdds, openOdds > 1 {
            entry.movement = openOdds / closing - 1
          }
        }
      } else {
        if let closingOdds = extractClosingOdds(data: data, entry: entry),
           closingOdds > 1 {
          entry.closingOdds = closingOdds
          entry.clv = entry.odds / closingOdds - 1
          if let openOdds = entry.openingOdds, openOdds > 1 {
            entry.movement = openOdds / closingOdds - 1
          }
        }
      }

      entry.status = "CLOSED"
      closed += 1

      if entry.market == "1X2" || entry.market == "GOALS" {
        if let hFT = number(game, ["homeFTResult", "homeResult"]),
           let aFT = number(game, ["awayFTResult", "awayResult"]) {
          let ids = extractTeamIDs(from: game)
          if let hID = ids.home, let aID = ids.away {
            TeamRatingService.update(context: context,
              homeTeamID: hID, homeName: entry.home,
              awayTeamID: aID, awayName: entry.away,
              homeGoals: hFT, awayGoals: aFT)
          }
        }
      }
      try? await Task.sleep(for: .milliseconds(300))
    }
    try? context.save()
    return (closed, failed)
  }

  private static func resolveResult(entry: JournalEntry,
                                    game: [String: JSONValue],
                                    stats: [String: JSONValue]) -> String? {
    switch entry.market {
    case "1X2", "GOALS":
      guard let h = number(game, ["homeFTResult", "homeResult"]),
            let a = number(game, ["awayFTResult", "awayResult"]) else { return nil }
      return evaluateResult(entry: entry, home: h, away: a)
    case "CORNERS":
      guard let hc = number(stats, ["cornerKicksHome"]),
            let ac = number(stats, ["cornerKicksAway"]) else { return nil }
      return evaluateResult(entry: entry, home: hc, away: ac)
    case "CARDS":
      guard let hy = number(stats, ["yellowCardsHome"]),
            let ay = number(stats, ["yellowCardsAway"]) else { return nil }
      let hr = number(stats, ["redCardsHome"]) ?? 0
      let ar = number(stats, ["redCardsAway"]) ?? 0
      return evaluateResult(entry: entry, home: hy + hr, away: ay + ar)
    default:
      return nil
    }
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
    if entry.market == "GOALS" || entry.market == "CORNERS" || entry.market == "CARDS" {
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
      let marketId = m["marketId"]?.number.map { Int($0) }
      let marketName = (m["marketName"]?.string ?? "").lowercased()
      let normalized = normalizeMarketByIDAndName(marketId, marketName)
      guard normalized == targetMarket else { continue }
      guard let prices = m["odds"]?.array else { continue }

      for pv in prices {
        guard let p = pv.object,
              let selName = p["name"]?.string?.lowercased(),
              let value = number(p, ["value", "odds", "price"]),
              value > 1
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

  private static func findClosingInBookmakers(entry: JournalEntry,
                                              books: [BookmakerOdds]) -> Double? {
    let marketId: Int
    switch entry.market {
    case "CORNERS": marketId = MarketID.totalCorners
    case "CARDS":   marketId = MarketID.totalCards
    default: return nil
    }
    return SStatsClient.bestPrice(marketId: marketId,
                                  selection: entry.selection,
                                  line: entry.line,
                                  across: books)?.value
  }

  private static func normalizeMarketByIDAndName(_ id: Int?, _ name: String) -> String {
    if let id {
      switch id {
      case MarketID.matchWinner:    return "1X2"
      case MarketID.goals,
           MarketID.goalsHome,
           MarketID.goalsAway:      return "GOALS"
      case MarketID.totalCorners:   return "CORNERS"
      case MarketID.totalCards:     return "CARDS"
      default:                      return ""
      }
    }
    let n = name.lowercased()
    if n.contains("corner") { return "CORNERS" }
    if n.contains("card") || n.contains("yellow") { return "CARDS" }
    if n.contains("goal") || n.contains("total")
        || n.contains("over") || n.contains("under") { return "GOALS" }
    if n.contains("1x2") || n.contains("winner") { return "1X2" }
    return ""
  }

  private static func extractTeamIDs(from game: [String: JSONValue])
    -> (home: String?, away: String?) {
    func extract(_ side: String) -> String? {
      if let t = game[side + "Team"]?.object {
        if let n = t["id"]?.number { return String(Int(n)) }
        if let s = t["id"]?.string, !s.isEmpty { return s }
      }
      if let s = game[side + "TeamId"]?.string, !s.isEmpty { return s }
      if let n = game[side + "TeamId"]?.number { return String(Int(n)) }
      return nil
    }
    return (extract("home"), extract("away"))
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
  static let gamesPerRequest = 1000
  static let maxPagesPerMonth = 20
  static let oddsFetchCap = 1500
  static let cornersCardsFetchCap = 300

  private var isBuilding = false

  struct Checkpoint: Codable {
    var jobID: String?
    var fromDate: Double
    var toDate: Double
    var cursor: Double
    var matches: [Match]
    var histories: [String: [TeamRecord]]
    var matchesCount: Int?
    var historiesCount: Int?
  }

  static var checkpointURL: URL {
    let fm = FileManager.default
    let docs = (try? fm.url(for: .documentDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return docs.appendingPathComponent("build_checkpoint.json")
  }

  static func hasCheckpoint() -> Bool {
    FileManager.default.fileExists(atPath: checkpointURL.path)
  }

  static func loadCheckpoint() -> Checkpoint? {
    guard let data = try? Data(contentsOf: checkpointURL),
          let cp = try? JSONDecoder().decode(Checkpoint.self, from: data)
    else { return nil }
    return cp
  }

  static func saveCheckpoint(jobID: String,
                             cursor: Date, fromDate: Date, toDate: Date,
                             matches: [Match],
                             histories: [String: [TeamRecord]]) {
    let cp = Checkpoint(
      jobID: jobID,
      fromDate: fromDate.timeIntervalSince1970,
      toDate: toDate.timeIntervalSince1970,
      cursor: cursor.timeIntervalSince1970,
      matches: matches,
      histories: histories,
      matchesCount: matches.count,
      historiesCount: histories.count)
    if let data = try? JSONEncoder().encode(cp) {
      try? data.write(to: checkpointURL, options: .atomic)
    }
  }

  static func clearCheckpoint() {
    try? FileManager.default.removeItem(at: checkpointURL)
  }

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

    var cursor: Date = fromDate
    var allMatches: [Match] = []
    var allHistories: [String: [TeamRecord]] = [:]
    var resumed = false
    var jobID: String = snapshot.buildJobID ?? UUID().uuidString

    // ── Resume
    if snapshot.buildStatus == "building",
       let cp = Self.loadCheckpoint(),
       let cpJobID = cp.jobID,
       cpJobID == jobID {
      cursor = Date(timeIntervalSince1970: cp.cursor)
      allMatches = cp.matches
      allHistories = cp.histories
      resumed = true
      snapshot.buildMatchesCount = allMatches.count
      snapshot.buildCursorTimestamp = cp.cursor
      try? context.save()
      progress(0, "Продолжаю сбор с \(Self.shortDay(cursor)) · матчей: \(allMatches.count)")
    } else {
      Self.clearCheckpoint()
    }

    if !resumed {
      Self.clearCheckpoint()
      jobID = UUID().uuidString
      snapshot.buildStatus = "building"
      snapshot.buildProgress = 0
      snapshot.lastError = nil
      snapshot.builtAt = nil
      snapshot.fromDate = fromDate
      snapshot.toDate = toDate
      snapshot.totalMatches = 0
      snapshot.totalBets = 0
      snapshot.enrichmentProgress = 0
      snapshot.enrichmentTotal = 0
      snapshot.buildCursorTimestamp = fromDate.timeIntervalSince1970
      snapshot.buildMatchesCount = 0
      snapshot.buildJobID = jobID
      try? context.save()
    }

    var seenIDs = Set(allMatches.map { $0.id })
    var monthIndex = max(0, cal.dateComponents([.month], from: fromDate, to: cursor).month ?? 0)
    let totalMonths = Self.yearsBack * Self.monthsPerYear

    // ── Фаза 1: сбор матчей по месяцам
    while cursor < toDate {
      guard let nextMonth = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
      let periodEnd = min(nextMonth, toDate)
      let monthProgress = Double(monthIndex) / Double(totalMonths) * 0.55
      progress(monthProgress,
               "Сбор \(monthIndex + 1)/\(totalMonths) · матчей: \(allMatches.count)")

      var monthItems: [JSONValue] = []
      var pageOffset = 0
      var pageCount = 0

      while pageCount < Self.maxPagesPerMonth {
        do {
          let r = try await client.listGamesRange(
            from: cursor, to: periodEnd,
            limit: Self.gamesPerRequest, offset: pageOffset)
          let items = r.object?["data"]?.array ?? []
          if items.isEmpty { break }
          monthItems.append(contentsOf: items)
          pageOffset += Self.gamesPerRequest
          pageCount += 1
          if items.count < Self.gamesPerRequest { break }
          try? await Task.sleep(for: .milliseconds(700))
        } catch {
          print("[BT] month \(monthIndex) page \(pageCount) error: \(error.localizedDescription)")
          break
        }
      }

      if !monthItems.isEmpty {
        let json = JSONValue.object(["data": .array(monthItems)])
        let monthMatches = engine.matches(from: json)
          .filter { !Self.isExcluded($0) }
          .filter { Self.isInPool($0.league) }
          .filter { $0.homeFT != nil && $0.awayFT != nil }
          .filter { m in
            if seenIDs.contains(m.id) { return false }
            seenIDs.insert(m.id); return true
          }
        allMatches.append(contentsOf: monthMatches)
        let records = engine.allRecords(from: json)
        for (k, v) in records { allHistories[k, default: []].append(contentsOf: v) }
      }

      cursor = nextMonth
      monthIndex += 1

      Self.saveCheckpoint(jobID: jobID,
                          cursor: cursor, fromDate: fromDate, toDate: toDate,
                          matches: allMatches, histories: allHistories)
      snapshot.buildCursorTimestamp = cursor.timeIntervalSince1970
      snapshot.buildMatchesCount = allMatches.count
      snapshot.buildProgress = monthProgress
      try? context.save()
    }

    for (k, v) in allHistories {
      allHistories[k] = v.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    // ── Сидируем кэш
    for m in allMatches {
      _ = HistoricalMarketCacheService.upsert(from: m, in: context)
    }
    try? context.save()
    let cacheSeed = HistoricalMarketCacheService.progress(in: context)
    snapshot.historicalCacheCount = cacheSeed.total
    snapshot.enrichmentTotal = cacheSeed.total
    snapshot.enrichmentProgress = cacheSeed.enriched
    try? context.save()

    // ── Фаза 2: Odds+stats (resume-safe)
    progress(0.55, "Матчей собрано: \(allMatches.count). Дотягиваю odds и statistics…")

    var allMatchesMut = allMatches
    let needOddsIdx: [Int] = allMatchesMut.enumerated()
      .filter { $0.element.oddsJSON?.array?.isEmpty != false }
      .map { $0.offset }
    let cap = min(needOddsIdx.count, Self.oddsFetchCap)

    for (i, idx) in needOddsIdx.prefix(cap).enumerated() {
      var mm = allMatchesMut[idx]
      if let nid = mm.numericID {
        if let o = try? await client.odds(numericID: nid) {
          let data = o.object?["data"]?.object ?? o.object ?? [:]
          let game = data["game"]?.object ?? data
          let stats = data["statistics"]?.object ?? game["statistics"]?.object ?? [:]
          mm.oddsJSON = game["odds"] ?? data["odds"]
          Self.fillCornersCards(into: &mm, from: stats)
          Self.replaceHistoryRecords(&allHistories, engine: engine,
                                     payload: o, match: mm)
        }
        allMatchesMut[idx] = mm
      }
      if i % 20 == 0 {
        let p = 0.55 + (Double(i) / Double(max(cap, 1))) * 0.10
        progress(p, "Odds+stats \(i + 1)/\(cap)")
        // Чекпоинт каждые 20 матчей
        Self.saveCheckpoint(jobID: jobID,
                            cursor: cursor, fromDate: fromDate, toDate: toDate,
                            matches: allMatchesMut, histories: allHistories)
      }
      try? await Task.sleep(for: .milliseconds(400))
    }
    // Финальный чекпоинт фазы 2
    Self.saveCheckpoint(jobID: jobID,
                        cursor: cursor, fromDate: fromDate, toDate: toDate,
                        matches: allMatchesMut, histories: allHistories)

    // ── Фаза 3: Corners/Cards (resume-safe через HistoricalMarketCache)
    let needCC: [Int] = allMatchesMut.enumerated().compactMap { (idx, m) -> Int? in
      guard let nid = m.numericID else { return nil }
      let gid = m.id
      let d = FetchDescriptor<HistoricalMarketCache>(
        predicate: #Predicate { $0.gameID == gid })
      guard let row = try? context.fetch(d).first else { return idx }
      if row.enriched { return nil }
      if row.failedAttempts >= 3 { return nil }
      return idx
    }.sorted { a, b in
      let sa = allMatchesMut[a].start ?? .distantPast
      let sb = allMatchesMut[b].start ?? .distantPast
      return sa > sb
    }
    let ccCount = min(needCC.count, Self.cornersCardsFetchCap)

    progress(0.65, "Дотягиваю углы/ЖК (\(ccCount) матчей)…")

    for (i, idx) in needCC.prefix(ccCount).enumerated() {
      var mm = allMatchesMut[idx]
      guard let nid = mm.numericID else { continue }
      if let books = try? await client.fullOdds(gameId: nid), !books.isEmpty {
        let extra = Self.oddsJSONFromBookmakers(books)
        if !extra.isEmpty {
          var merged: [JSONValue] = mm.oddsJSON?.array ?? []
          merged.append(contentsOf: extra)
          mm.oddsJSON = .array(merged)
          allMatchesMut[idx] = mm

          if let encoded = try? JSONEncoder().encode(extra) {
            let hasC = extra.contains { $0.object?["marketId"]?.number == Double(MarketID.totalCorners) }
            let hasK = extra.contains { $0.object?["marketId"]?.number == Double(MarketID.totalCards) }
            if hasC || hasK {
              HistoricalMarketCacheService.markEnriched(
                gameID: mm.id, oddsData: encoded,
                hasCorners: hasC, hasCards: hasK, in: context)
            } else {
              HistoricalMarketCacheService.markFailed(
                gameID: mm.id, error: "Нет market 45/80 в /Odds", in: context)
            }
          }
        }
      }
      if i % 25 == 0 {
        let p = 0.65 + (Double(i) / Double(max(ccCount, 1))) * 0.15
        progress(p, "Corners/Cards \(i + 1)/\(ccCount)")
        // Чекпоинт каждые 25 матчей
        try? context.save()
        Self.saveCheckpoint(jobID: jobID,
                            cursor: cursor, fromDate: fromDate, toDate: toDate,
                            matches: allMatchesMut, histories: allHistories)
      }
      try? await Task.sleep(for: .milliseconds(400))
    }

    try? context.save()
    Self.saveCheckpoint(jobID: jobID,
                        cursor: cursor, fromDate: fromDate, toDate: toDate,
                        matches: allMatchesMut, histories: allHistories)

    let cacheAfter = HistoricalMarketCacheService.progress(in: context)
    snapshot.historicalCacheCount = cacheAfter.total
    snapshot.enrichmentTotal = cacheAfter.total
    snapshot.enrichmentProgress = cacheAfter.enriched
    try? context.save()

    // Собираем prepared для walk-forward
    var prepared: [Match] = allMatchesMut.filter { ($0.oddsJSON?.array?.isEmpty == false) }
    prepared.sort { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }

    guard !prepared.isEmpty else {
      snapshot.buildStatus = "failed"
      snapshot.lastError = "Нет матчей с odds (матчей: \(allMatchesMut.count), историй: \(allHistories.count))"
      try? context.save()
      progress(0, "Нет матчей с odds (собрано: \(allMatchesMut.count))")
      return false
    }

    // ── Walk-forward
    let totalPrepared = prepared.count
    let trainEnd = max(1, Int(Double(totalPrepared) * 0.60))
    let valEnd = max(trainEnd + 1, Int(Double(totalPrepared) * 0.80))

    let trainMatches = Array(prepared[0..<trainEnd])
    let valMatches = Array(prepared[trainEnd..<min(valEnd, totalPrepared)])
    let holdoutMatches = Array(prepared[min(valEnd, totalPrepared)..<totalPrepared])

    progress(0.83, "Walk-forward train \(trainMatches.count) / val \(valMatches.count) / holdout \(holdoutMatches.count)…")
    let trainReport = backtester.run(matches: trainMatches, histories: allHistories)
    let valReport = backtester.run(matches: valMatches, histories: allHistories)
    let holdoutReport = backtester.run(matches: holdoutMatches, histories: allHistories)
    let report = backtester.run(matches: trainMatches + valMatches, histories: allHistories)

    progress(0.90, "Сравнение моделей (E5)…")
    let comparisons = MultiModelBacktester().run(
      matches: trainMatches + valMatches, histories: allHistories)

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

    snapshot.enrichmentTotal = prepared.count
    snapshot.enrichmentProgress = min(prepared.count, ccCount)

    let encoder = JSONEncoder()
    snapshot.trainReportJSON = try? encoder.encode(Self.walkForwardDelta(trainReport))
    snapshot.validationReportJSON = try? encoder.encode(Self.walkForwardDelta(valReport))
    snapshot.holdoutReportJSON = try? encoder.encode(Self.walkForwardDelta(holdoutReport))
    snapshot.walkForwardMode = "602020"

    snapshot.perLeagueJSON = try? encoder.encode(
      report.perLeague.mapValues { Self.toStored($0) })
    snapshot.perMarketJSON = try? encoder.encode(
      report.perMarket.mapValues { Self.toStored($0) })
    snapshot.perLeagueMarketJSON = try? encoder.encode(
      Self.leagueMarketSegment(report: report, matches: prepared))
    snapshot.evBucketsJSON = try? encoder.encode(
      report.byEVBucket.mapValues { Self.toStored($0) })
    snapshot.oddsBucketsJSON = try? encoder.encode(
      report.byOddsBand.mapValues { Self.toStored($0) })
    snapshot.classificationJSON = try? encoder.encode(
      report.byClassification.mapValues { Self.toStored($0) })
    snapshot.posteriorJSON = try? encoder.encode(
      Self.buildPosteriorBuckets(from: report.betRecords))
    snapshot.posteriorCornersJSON = try? encoder.encode(
      Self.buildPosteriorBuckets(from: report.betRecords.filter {
        $0.market == "CORNERS"
      }))
    snapshot.posteriorCardsJSON = try? encoder.encode(
      Self.buildPosteriorBuckets(from: report.betRecords.filter {
        $0.market == "CARDS"
      }))
    snapshot.modelComparisonJSON = try? encoder.encode(comparisons)

    let journalDescriptor = FetchDescriptor<JournalEntry>()
    let journal = (try? context.fetch(journalDescriptor)) ?? []
    let cfg = TuningService.fetchOrCreate(in: context)
    let oosReport = OOSBuilder.build(from: journal, windowDays: cfg.oosWindowDays)
    snapshot.oosValidationJSON = try? encoder.encode(oosReport)

    snapshot.buildStatus = "ready"
    snapshot.buildProgress = 1.0
    snapshot.lastError = nil
    snapshot.buildCursorTimestamp = 0
    snapshot.buildMatchesCount = 0
    snapshot.buildJobID = nil
    try? context.save()

    Self.clearCheckpoint()

    progress(1.0, "Готово: \(report.matches) матчей, \(report.bets) ставок")
    return true
  }

    // [W3b] Train 60% / Validation 20% / Holdout 20%.
    let totalPrepared = prepared.count
    let trainEnd = max(1, Int(Double(totalPrepared) * 0.60))
    let valEnd = max(trainEnd + 1, Int(Double(totalPrepared) * 0.80))

    let trainMatches = Array(prepared[0..<trainEnd])
    let valMatches = Array(prepared[trainEnd..<min(valEnd, totalPrepared)])
    let holdoutMatches = Array(prepared[min(valEnd, totalPrepared)..<totalPrepared])

    progress(0.83, "Walk-forward train \(trainMatches.count) / val \(valMatches.count) / holdout \(holdoutMatches.count)…")
    let trainReport = backtester.run(matches: trainMatches, histories: allHistories)
    let valReport = backtester.run(matches: valMatches, histories: allHistories)
    let holdoutReport = backtester.run(matches: holdoutMatches, histories: allHistories)

    // Для summary и posterior — только train + val.
    let report = backtester.run(matches: trainMatches + valMatches, histories: allHistories)

    progress(0.90, "Сравнение моделей (E5)…")
    let comparisons = MultiModelBacktester().run(
      matches: trainMatches + valMatches, histories: allHistories)

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

    snapshot.enrichmentTotal = prepared.count
    snapshot.enrichmentProgress = min(prepared.count, ccCount)

    let encoder = JSONEncoder()

    snapshot.trainReportJSON = try? encoder.encode(Self.walkForwardDelta(trainReport))
    snapshot.validationReportJSON = try? encoder.encode(Self.walkForwardDelta(valReport))
    snapshot.holdoutReportJSON = try? encoder.encode(Self.walkForwardDelta(holdoutReport))
    snapshot.walkForwardMode = "602020"

    snapshot.perLeagueJSON = try? encoder.encode(
      report.perLeague.mapValues { Self.toStored($0) })
    snapshot.perMarketJSON = try? encoder.encode(
      report.perMarket.mapValues { Self.toStored($0) })
    snapshot.perLeagueMarketJSON = try? encoder.encode(
      Self.leagueMarketSegment(report: report, matches: prepared))
    snapshot.evBucketsJSON = try? encoder.encode(
      report.byEVBucket.mapValues { Self.toStored($0) })
    snapshot.oddsBucketsJSON = try? encoder.encode(
      report.byOddsBand.mapValues { Self.toStored($0) })
    snapshot.classificationJSON = try? encoder.encode(
      report.byClassification.mapValues { Self.toStored($0) })
    snapshot.posteriorJSON = try? encoder.encode(
      Self.buildPosteriorBuckets(from: report.betRecords))
    snapshot.posteriorCornersJSON = try? encoder.encode(
      Self.buildPosteriorBuckets(from: report.betRecords.filter {
        $0.market == "CORNERS"
      }))
    snapshot.posteriorCardsJSON = try? encoder.encode(
      Self.buildPosteriorBuckets(from: report.betRecords.filter {
        $0.market == "CARDS"
      }))
    snapshot.modelComparisonJSON = try? encoder.encode(comparisons)

    // OOS-отчёт по журналу.
    let journalDescriptor = FetchDescriptor<JournalEntry>()
    let journal = (try? context.fetch(journalDescriptor)) ?? []
    let cfg = TuningService.fetchOrCreate(in: context)
    let oosReport = OOSBuilder.build(from: journal, windowDays: cfg.oosWindowDays)
    snapshot.oosValidationJSON = try? encoder.encode(oosReport)

    snapshot.buildStatus = "ready"
    snapshot.buildProgress = 1.0
    snapshot.lastError = nil
    snapshot.buildCursorTimestamp = 0
    snapshot.buildMatchesCount = 0
    snapshot.buildJobID = nil
    try? context.save()

    Self.clearCheckpoint()

    progress(1.0, "Готово: \(report.matches) матчей, \(report.bets) ставок")
    return true
  }

  func continueEnrichmentInBackground(
    chunkSize: Int = 30,
    progress: @MainActor @escaping (Int, Int, String) -> Void = { _,_,_ in }
  ) async {
    guard let container = AppDependencies.shared.container else { return }
    let context = ModelContext(container)
    let snapshot = Self.fetchOrCreate(in: context)

    let settings = AppSettings()
    let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }

    let client = SStatsClient(settings: settings)

    let (enrichedBefore, total) = HistoricalMarketCacheService.progress(in: context)
    snapshot.enrichmentProgress = enrichedBefore
    snapshot.enrichmentTotal = total
    snapshot.historicalCacheCount = total
    try? context.save()

    guard total > 0 else {
      progress(0, 0, "Кэш пуст — сначала соберите базу (Авто → Собрать базу)")
      return
    }
    if enrichedBefore >= total {
      progress(total, total, "Все \(total) матчей обогащены")
      return
    }

    let candidates = HistoricalMarketCacheService.candidates(limit: chunkSize, in: context)
    guard !candidates.isEmpty else {
      progress(enrichedBefore, total, "Нет кандидатов (failedAttempts ≥ 3?)")
      return
    }

    var newlyEnriched = 0
    for (i, row) in candidates.enumerated() {
      do {
        let books = try await client.fullOdds(gameId: row.numericID)
        if books.isEmpty {
          HistoricalMarketCacheService.markFailed(
            gameID: row.gameID, error: "Пустой ответ /Odds", in: context)
          continue
        }
        let markets = Self.oddsJSONFromBookmakers(books)
        if markets.isEmpty {
          HistoricalMarketCacheService.markFailed(
            gameID: row.gameID, error: "Нет market 45/80", in: context)
          continue
        }
        let data = try JSONEncoder().encode(markets)
        let hasC = markets.contains { $0.object?["marketId"]?.number == Double(MarketID.totalCorners) }
        let hasK = markets.contains { $0.object?["marketId"]?.number == Double(MarketID.totalCards) }
        HistoricalMarketCacheService.markEnriched(
          gameID: row.gameID, oddsData: data,
          hasCorners: hasC, hasCards: hasK, in: context)
        newlyEnriched += 1
      } catch {
        HistoricalMarketCacheService.markFailed(
          gameID: row.gameID, error: error.localizedDescription, in: context)
      }
      try? context.save()

      if i % 5 == 0 {
        let (e, t) = HistoricalMarketCacheService.progress(in: context)
        progress(e, t, "Обогащено \(e)/\(t)")
      }
      try? await Task.sleep(for: .milliseconds(400))
    }

    let (finalE, finalT) = HistoricalMarketCacheService.progress(in: context)
    snapshot.enrichmentProgress = finalE
    snapshot.enrichmentTotal = finalT
    snapshot.historicalCacheCount = finalT
    snapshot.builtAt = Date()
    try? context.save()

    progress(finalE, finalT,
             "Обогащено \(finalE)/\(finalT) (+\(newlyEnriched) за проход)")
  }

  private static func fillCornersCards(into mm: inout Match,
                                       from stats: [String: JSONValue]) {
    if let v = stats["cornerKicksHome"]?.number { mm.homeCorners = Int(v) }
    if let v = stats["cornerKicksAway"]?.number { mm.awayCorners = Int(v) }
    if let v = stats["yellowCardsHome"]?.number { mm.homeYellows = Int(v) }
    if let v = stats["yellowCardsAway"]?.number { mm.awayYellows = Int(v) }
    if let v = stats["redCardsHome"]?.number { mm.homeReds = Int(v) }
    if let v = stats["redCardsAway"]?.number { mm.awayReds = Int(v) }
  }

  private static func replaceHistoryRecords(
    _ history: inout [String: [TeamRecord]],
    engine: QuantEngine,
    payload: JSONValue,
    match: Match
  ) {
    if let hID = match.homeID,
       let rec = engine.teamRecord(from: payload, targetID: hID) {
      var arr = history[hID] ?? []
      if let i = arr.firstIndex(where: { $0.id == rec.id }) { arr[i] = rec }
      else { arr.append(rec) }
      history[hID] = arr
    }
    if let aID = match.awayID,
       let rec = engine.teamRecord(from: payload, targetID: aID) {
      var arr = history[aID] ?? []
      if let i = arr.firstIndex(where: { $0.id == rec.id }) { arr[i] = rec }
      else { arr.append(rec) }
      history[aID] = arr
    }
  }

  static func oddsJSONFromBookmakers(_ books: [BookmakerOdds]) -> [JSONValue] {
    var out: [JSONValue] = []

    if let pin = books.first(where: { $0.bookmakerId == SStatsClient.pinnacleBookmakerId }),
       let market = pin.odds.first(where: { $0.marketId == MarketID.totalCorners }) {
      var prices: [JSONValue] = []
      for p in market.odds {
        prices.append(.object([
          "name": .string(p.name),
          "value": .number(p.value),
        ]))
      }
      out.append(.object([
        "marketId": .number(Double(MarketID.totalCorners)),
        "marketName": .string(market.marketName ?? "Corners Over Under"),
        "odds": .array(prices),
      ]))
    }

    var best: [String: (name: String, line: Double?, value: Double)] = [:]
    for b in books {
      guard let market = b.odds.first(where: { $0.marketId == MarketID.totalCards })
      else { continue }
      for p in market.odds {
        let line = OddsQuery.extractLine(from: p.name)
        let k = "\(p.name.lowercased())|\(line.map { String($0) } ?? "")"
        if let cur = best[k], cur.value >= p.value { continue }
        best[k] = (p.name, line, p.value)
      }
    }
    if !best.isEmpty {
      var prices: [JSONValue] = []
      for (_, v) in best {
        prices.append(.object([
          "name": .string(v.name),
          "value": .number(v.value),
        ]))
      }
      out.append(.object([
        "marketId": .number(Double(MarketID.totalCards)),
        "marketName": .string("Cards Over/Under"),
        "odds": .array(prices),
      ]))
    }

    return out
  }

  private static func leagueMarketSegment(
    report: WalkForwardReport,
    matches: [Match]
  ) -> [String: StoredSegmentStats] {
    var out: [String: StoredSegmentStats] = [:]
    for (key, s) in report.perLeagueMarket {
      out[key] = toStored(s)
    }
    return out
  }

  static func walkForwardDelta(_ r: WalkForwardReport) -> WalkForwardDelta {
    WalkForwardDelta(
      matches: r.matches, bets: r.bets,
      wins: r.wins, losses: r.losses, pushes: r.pushes,
      roi: r.roi, sharpe: r.sharpe, sortino: r.sortino,
      profitFactor: r.profitFactor,
      brier: r.brier, logLoss: r.logLoss, avgCLV: r.avgCLV,
      hitRate: r.hitRate)
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

    var monthItems: [JSONValue] = []
    var pageOffset = 0
    var pageCount = 0
    while pageCount < Self.maxPagesPerMonth {
      do {
        let r = try await client.listGamesRange(
          from: fromDate, to: toDate,
          limit: Self.gamesPerRequest, offset: pageOffset)
        let items = r.object?["data"]?.array ?? []
        if items.isEmpty { break }
        monthItems.append(contentsOf: items)
        pageOffset += Self.gamesPerRequest
        pageCount += 1
        if items.count < Self.gamesPerRequest { break }
        try? await Task.sleep(for: .milliseconds(700))
      } catch { break }
    }

    guard !monthItems.isEmpty else {
      snapshot.toDate = toDate
      try? context.save()
      return true
    }

    let json = JSONValue.object(["data": .array(monthItems)])
    let newMatches = engine.matches(from: json)
      .filter { !Self.isExcluded($0) }
      .filter { Self.isInPool($0.league) }
      .filter { $0.homeFT != nil && $0.awayFT != nil }

    var prepared: [Match] = []
    for m in newMatches {
      var mm = m
      if let nid = mm.numericID,
         let o = try? await client.odds(numericID: nid) {
        let data = o.object?["data"]?.object ?? o.object ?? [:]
        let game = data["game"]?.object ?? data
        let stats = data["statistics"]?.object ?? game["statistics"]?.object ?? [:]
        mm.oddsJSON = game["odds"] ?? data["odds"]
        Self.fillCornersCards(into: &mm, from: stats)
        try? await Task.sleep(for: .milliseconds(400))
      }
      if mm.oddsJSON?.array?.isEmpty == false { prepared.append(mm) }
    }

    guard !prepared.isEmpty else {
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

    let newLeagues = Self.mergeSegmentDict(
      snapshot.decodedLeagueStats(), delta.perLeague.mapValues { Self.toStored($0) })
    let newMarkets = Self.mergeSegmentDict(
      snapshot.decodedMarketStats(), delta.perMarket.mapValues { Self.toStored($0) })
    let newLeagueMarket = Self.mergeSegmentDict(
      snapshot.decodedLeagueMarketStats(),
      delta.perLeagueMarket.mapValues { Self.toStored($0) })
    let newEV = Self.mergeSegmentDict(
      snapshot.decodedEVBuckets(), delta.byEVBucket.mapValues { Self.toStored($0) })
    let newOdds = Self.mergeSegmentDict(
      snapshot.decodedOddsBuckets(), delta.byOddsBand.mapValues { Self.toStored($0) })
    let newClass = Self.mergeSegmentDict(
      snapshot.decodedClassification(), delta.byClassification.mapValues { Self.toStored($0) })

    snapshot.perLeagueJSON = try? encoder.encode(newLeagues)
    snapshot.perMarketJSON = try? encoder.encode(newMarkets)
    snapshot.perLeagueMarketJSON = try? encoder.encode(newLeagueMarket)
    snapshot.evBucketsJSON = try? encoder.encode(newEV)
    snapshot.oddsBucketsJSON = try? encoder.encode(newOdds)
    snapshot.classificationJSON = try? encoder.encode(newClass)

    let oldPosterior = snapshot.decodedPosteriorBuckets()
    let newPosterior = Self.mergePosterior(
      old: oldPosterior,
      delta: Self.buildPosteriorBuckets(from: delta.betRecords))
    snapshot.posteriorJSON = try? encoder.encode(newPosterior)

    let oldCornersP = snapshot.decodedPosteriorCornersBuckets()
    let newCornersP = Self.mergePosterior(
      old: oldCornersP,
      delta: Self.buildPosteriorBuckets(from: delta.betRecords.filter {
        $0.market == "CORNERS"
      }))
    snapshot.posteriorCornersJSON = try? encoder.encode(newCornersP)

    let oldCardsP = snapshot.decodedPosteriorCardsBuckets()
    let newCardsP = Self.mergePosterior(
      old: oldCardsP,
      delta: Self.buildPosteriorBuckets(from: delta.betRecords.filter {
        $0.market == "CARDS"
      }))
    snapshot.posteriorCardsJSON = try? encoder.encode(newCardsP)

    let journalDescriptor = FetchDescriptor<JournalEntry>()
    let journal = (try? context.fetch(journalDescriptor)) ?? []
    let cfg = TuningService.fetchOrCreate(in: context)
    let oosReport = OOSBuilder.build(from: journal, windowDays: cfg.oosWindowDays)
    snapshot.oosValidationJSON = try? encoder.encode(oosReport)

    snapshot.totalMatches += delta.matches
    snapshot.totalBets += delta.bets
    snapshot.toDate = toDate
    snapshot.builtAt = Date()
    try? context.save()

    return true
  }

  static func fetchOrCreate(in context: ModelContext) -> BacktestSnapshot {
    let d = FetchDescriptor<BacktestSnapshot>()
    if let existing = try? context.fetch(d).first { return existing }
    let snap = BacktestSnapshot()
    context.insert(snap); try? context.save()
    return snap
  }

  static func toStored(_ s: SegmentStats) -> StoredSegmentStats {
    StoredSegmentStats(bets: s.bets, wins: s.wins, losses: s.losses,
                       pushes: s.pushes, profit: s.profit, staked: s.staked,
                       avgOdds: s.avgOdds)
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
    let nb = a.bets + b.bets
    let nw = a.wins + b.wins
    let nl = a.losses + b.losses
    let np = a.pushes + b.pushes
    let npr = a.profit + b.profit
    let ns = a.staked + b.staked
    let oddsSum = a.avgOdds * Double(a.bets) + b.avgOdds * Double(b.bets)
    let navg = nb > 0 ? oddsSum / Double(nb) : 0
    return StoredSegmentStats(bets: nb, wins: nw, losses: nl, pushes: np,
                              profit: npr, staked: ns, avgOdds: navg)
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
        probabilityLow: Double(i) / 10.0, probabilityHigh: Double(i + 1) / 10.0,
        n: 0, factHitRate: 0)
      let d = i < delta.count ? delta[i] : PosteriorBucket(
        probabilityLow: Double(i) / 10.0, probabilityHigh: Double(i + 1) / 10.0,
        n: 0, factHitRate: 0)
      let nN = o.n + d.n
      let ws = o.factHitRate * Double(o.n) + d.factHitRate * Double(d.n)
      let nh = nN > 0 ? ws / Double(nN) : 0
      out.append(PosteriorBucket(probabilityLow: o.probabilityLow,
                                 probabilityHigh: o.probabilityHigh,
                                 n: nN, factHitRate: nh))
    }
    return out
  }

  private static func isExcluded(_ m: Match) -> Bool {
    let x = "\(m.league) \(m.home) \(m.away)".lowercased()
    let bad = ["friendly", "women", "женщ", "u19 women", "u20 women"]
    return bad.contains(where: x.contains)
  }

  private static func isInPool(_ league: String) -> Bool {
    LeaguePool.pool.contains { lg in
      league.localizedCaseInsensitiveContains(lg.name)
    }
  }

  private static func shortDay(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
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
    var cornersSignals: Int = 0
    var cardsSignals: Int = 0
    var liveDropped: Int = 0
    var h2hFetched: Int = 0
    var oosBlocked: [String] = []
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

    var thresholds = SignalThresholds.from(tuning)
    let journalEntries: [JournalEntry] = {
      guard let ctx = journalContext else { return [] }
      let d = FetchDescriptor<JournalEntry>()
      return (try? ctx.fetch(d)) ?? []
    }()

    if tuning.oosGateEnabled {
      let oosReport = OOSBuilder.build(from: journalEntries,
                                       windowDays: tuning.oosWindowDays)
      let blocked = OOSBuilder.blockedMarkets(report: oosReport, cfg: tuning)
      thresholds.blockedByOOS = blocked
      summary.oosBlocked = Array(blocked).sorted()
      if !blocked.isEmpty {
        summary.notes.append("OOS-блок: \(summary.oosBlocked.joined(separator: ", "))")
      }
      if let container = container {
        let snapCtx = ModelContext(container)
        let snap = BacktestService.fetchOrCreate(in: snapCtx)
        snap.oosValidationJSON = try? JSONEncoder().encode(oosReport)
        try? snapCtx.save()
      }
    }

    let cornerWeights = CornerWeights.from(tuning)
    let cardWeights = CardWeights.from(tuning)

    let corrMatrix: CorrelationMatrix = {
      CorrelationBuilder.build(from: journalEntries)
    }()
    summary.correlationPairs = corrMatrix.marketPairsN.count + corrMatrix.leaguePairsN.count

    let streak: (streak: Int, state: VolatilityState) = {
      VolatilityStop.evaluate(journalEntries,
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
    if !thresholds.cornersEnabled { summary.notes.append("Self-Tuning: рынок CORNERS выключен") }
    if !thresholds.cardsEnabled { summary.notes.append("Self-Tuning: рынок CARDS выключен") }

    do {
      let client = SStatsClient(settings: resolvedSettings)
      let engine = QuantEngine()

      let base = engine.matches(from: try await client.listToday())
        .filter { !Self.isExcluded($0) }

      var all = base.filter { m in
        guard let st = m.status else { return true }
        return st == 2
      }
      summary.liveDropped = base.count - all.count
      summary.skippedExcluded = all.count
      summary.notes.append("Всего матчей сегодня: \(base.count)")
      if summary.liveDropped > 0 {
        summary.notes.append("Отсеяно начавшихся/завершённых: \(summary.liveDropped)")
      }

      if selectedLeague != "Все" {
        all = all.filter { $0.league.localizedCaseInsensitiveContains(selectedLeague) }
      }
      let matches = all.prefix(resolvedSettings.scanMatches)
      summary.notes.append("К обработке: \(matches.count)")

      let posteriorBuckets: [PosteriorBucket] = tuning.posteriorEnabled
        ? Self.loadPosteriorBuckets() : []
      let posteriorCornersBuckets: [PosteriorBucket] = tuning.posteriorEnabled
        ? Self.loadPosteriorCornersBuckets() : []
      let posteriorCardsBuckets: [PosteriorBucket] = tuning.posteriorEnabled
        ? Self.loadPosteriorCardsBuckets() : []

      let usableBuckets = posteriorBuckets.filter { $0.n >= 20 }.count
      if usableBuckets > 0 { summary.notes.append("Posterior: \(usableBuckets) надёжных бакетов") }
      let usableCorners = posteriorCornersBuckets.filter { $0.n >= 20 }.count
      let usableCards = posteriorCardsBuckets.filter { $0.n >= 20 }.count
      if usableCorners > 0 || usableCards > 0 {
        summary.notes.append("Posterior CORNERS/CARDS: \(usableCorners)/\(usableCards) надёжных")
      }

      let excludedRules: [AutoExcludeRule] = tuning.autoExcludeEnabled
        ? Self.loadExcludedRules(minROI: tuning.autoExcludeMinROI,
                                 minBets: tuning.autoExcludeMinBets) : []
      let stopState: VolatilityState = tuning.stopLossEnabled ? streak.state : .normal

      var signalsOut: [BetSignal] = []
      var count = 0
      var lineupsFound = 0
      var cornersCount = 0
      var cardsCount = 0
      var h2hFetched = 0

      for match in matches {
        guard let h = match.homeID, let a = match.awayID else { continue }
        count += 1
        let hs = await client.fetchTeamHistory(
          teamID: h, count: resolvedSettings.historyMatches)
        let awayRecords = await client.fetchTeamHistory(
          teamID: a, count: resolvedSettings.historyMatches)
        guard let info = try? await client.gameInfo(match.id) else { continue }

        let data = info.object?["data"]?.object ?? info.object ?? [:]
        let game = data["game"]?.object ?? data
        let oddsFromInfo = game["odds"] ?? data["odds"]
          ?? match.oddsJSON ?? .array([])

        var fullBooks: [BookmakerOdds] = []
        if let nid = match.numericID {
          fullBooks = (try? await client.fullOdds(gameId: nid)) ?? []
        }

        var h2hRecords: [TeamRecord] = []
        let hasCornersOrCards = fullBooks.contains { book in
          book.odds.contains { m in
            m.marketId == MarketID.totalCorners || m.marketId == MarketID.totalCards
          }
        }
        if hasCornersOrCards && (thresholds.cornersEnabled || thresholds.cardsEnabled) {
          h2hRecords = await client.fetchH2H(
            homeID: h, awayID: a,
            homeName: match.home, awayName: match.away,
            count: 3)
          if !h2hRecords.isEmpty { h2hFetched += 1 }
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
          fullOdds: fullBooks,
          homeHistory: hs, awayHistory: awayRecords, glicko: glicko,
          h2hRecords: h2hRecords,
          posteriorBuckets: posteriorBuckets,
          posteriorBucketsByMarket: [
            "CORNERS": posteriorCornersBuckets,
            "CARDS": posteriorCardsBuckets
          ],
          posteriorWeight: tuning.posteriorWeight,
          teamRatings: (home: ratings.0, away: ratings.1),
          upcomingLineups: lineups,
          thresholds: thresholds,
          cornerWeights: cornerWeights,
          cardWeights: cardWeights)

        for sig in s {
          if sig.market == "CORNERS" { cornersCount += 1 }
          if sig.market == "CARDS"   { cardsCount += 1 }
        }

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
      summary.h2hFetched = h2hFetched
      if lineupsFound > 0 { summary.notes.append("Lineups: \(lineupsFound)") }
      if h2hFetched > 0 { summary.notes.append("H2H загружено: \(h2hFetched)") }
      summary.cornersSignals = cornersCount
      summary.cardsSignals = cardsCount

      let filtered = signalsOut.filter { s in
        !AutoExclude.isExcluded(league: s.league, market: s.market, rules: excludedRules)
      }
      let removed = signalsOut.count - filtered.count
      if removed > 0 {
        summary.notes.append("Auto-Exclude: убрано \(removed) из \(signalsOut.count)")
      }

      summary.scannedMatches = count
      summary.signals = engine.portfolio(filtered,
        excludedRules: excludedRules,
        stopLoss: stopState,
        correlationMatrix: tuning.correlationEnabled ? corrMatrix : nil,
        bankroll: resolvedSettings.effectiveBankroll,
        thresholds: thresholds)
      summary.finishedAt = Date()
      summary.success = true

      let cornersInPort = summary.signals.filter { $0.market == "CORNERS" }.count
      let cardsInPort = summary.signals.filter { $0.market == "CARDS" }.count
      summary.notes.append("Сырых сигналов: \(signalsOut.count), в портфель: \(summary.signals.count)")
      summary.notes.append("Углы: \(cornersCount) сырых, \(cornersInPort) в портфель · ЖК: \(cardsCount) сырых, \(cardsInPort) в портфель")

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

  private static func loadPosteriorCornersBuckets() -> [PosteriorBucket] {
    guard let container = AppDependencies.shared.container else { return [] }
    let context = ModelContext(container)
    let snap = BacktestService.fetchOrCreate(in: context)
    return snap.decodedPosteriorCornersBuckets()
  }

  private static func loadPosteriorCardsBuckets() -> [PosteriorBucket] {
    guard let container = AppDependencies.shared.container else { return [] }
    let context = ModelContext(container)
    let snap = BacktestService.fetchOrCreate(in: context)
    return snap.decodedPosteriorCardsBuckets()
  }

  private static func parseUpcomingLineups(from info: JSONValue)
    -> (home: [String], away: [String])? {
    let data = info.object?["data"]?.object ?? info.object ?? [:]
    if let obj = data["lineups"]?.object {
      let h = extractIDs(obj["home"]?.array ?? [])
      let a = extractIDs(obj["away"]?.array ?? [])
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
    switch self { case .eu: return "EU"; case .us: return "US"; case .uk: return "UK" }
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
    switch self { case .system: return "Система"; case .light: return "Светлая"; case .dark: return "Тёмная" }
  }
  var toColorScheme: SwiftUI.ColorScheme? {
    switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
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

extension Notification.Name {
  static let openSignal = Notification.Name("com.syndicatequant.openSignal")
}

struct SignalIDWrapper: Identifiable { let id: String }

// MARK: - Live monitor

struct OddsSnapshot: Hashable {
  let gameID: String; let numericID: Int?; let takenAt: Date
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
    var up = 0; var down = 0; var deltaSum = 0.0; var n = 0
    for (book, c) in cur {
      guard let p = prev[book], p > 1, c > 1 else { continue }
      let d = (c - p) / p
      if d > threshold { up += 1 } else if d < -threshold { down += 1 }
      deltaSum += d; n += 1
    }
    if up > down { return (up, +1, n > 0 ? deltaSum / Double(n) : 0) }
    else if down > up { return (down, -1, n > 0 ? deltaSum / Double(n) : 0) }
    return (0, 0, 0)
  }
}

struct LineMovement: Identifiable, Hashable {
  var id: String { key }
  let key: String; let market: String; let selection: String; let line: Double?
  let previousAvg: Double; let currentAvg: Double; let delta: Double
  let booksAgreeing: Int; let isSharp: Bool
  var direction: String { delta > 0 ? "▲" : (delta < 0 ? "▼" : "·") }
}

struct ObservedGame {
  var numericID: Int?
  var startTime: Date?
  var league: String
  var home: String
  var away: String
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
  @Published private(set) var preMatchSnapshotsSaved: Int = 0

  private var observed: [String: ObservedGame] = [:]
  private var task: Task<Void, Never>?
  private var cycleCounter: Int = 0
  private var cachedContext: ModelContext?

  private let fullOddsEveryNCycles = 5

  private init() {}

  func observe(gameID: String, numericID: Int?,
               startTime: Date? = nil,
               league: String = "",
               home: String = "",
               away: String = "") {
    observed[gameID] = ObservedGame(
      numericID: numericID, startTime: startTime,
      league: league, home: home, away: away)
  }

  func clearObserved() {
    observed.removeAll(); snapshots.removeAll()
    previous.removeAll(); movements.removeAll()
    preMatchSnapshotsSaved = 0
    cycleCounter = 0
  }

  func previousSnapshotForDebug(matchID: String) -> OddsSnapshot? { return previous[matchID] }

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

    cycleCounter += 1
    let doFullFetch = (cycleCounter % fullOddsEveryNCycles == 0)
    let now = Date()

    for (gameID, obs) in observed {
      guard let nid = obs.numericID else { continue }

      let parsed: [String: [String: Double]]
      if doFullFetch {
        guard let books = try? await client.fullOdds(gameId: nid),
              !books.isEmpty else { continue }
        parsed = Self.parseFullBooksToDict(books)
      } else {
        guard let raw = try? await client.odds(numericID: nid) else { continue }
        parsed = Self.parseOddsByBook(raw)
      }
      guard !parsed.isEmpty else { continue }

      let snap = OddsSnapshot(gameID: gameID, numericID: nid,
                              takenAt: now, byKey: parsed)

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

      if settings.preMatchHistoryEnabled,
         let startTime = obs.startTime,
         startTime > now {
        let minutes = Int(startTime.timeIntervalSince(now) / 60.0)
        if let bucket = LineSnapshotService.bucket(
            minutesToStart: minutes,
            maxWindow: settings.preMatchCaptureWindowMin),
           let ctx = persistContext() {
          for (k, byBook) in parsed {
            let parts = k.split(separator: "|").map(String.init)
            guard parts.count >= 2 else { continue }
            let market = parts[0]
            let selection = parts[1]
            let line: Double? = parts.count > 2 ? Double(parts[2]) : nil
            let didSave = LineSnapshotService.save(
              gameID: gameID, numericID: nid,
              market: market, selection: selection, line: line,
              startTime: startTime, league: obs.league,
              home: obs.home, away: obs.away,
              bucketMinutes: bucket, minutesToStart: minutes,
              byBook: byBook, in: ctx)
            if didSave { preMatchSnapshotsSaved += 1 }
          }
          try? ctx.save()
        }
      }

      previous[gameID] = snap
      newSnapshots[gameID] = snap
    }

    self.snapshots = newSnapshots
    self.movements = newMovements.sorted { abs($0.delta) > abs($1.delta) }
    self.lastTick = Date()
    self.lastError = newSnapshots.isEmpty
      ? (observed.isEmpty ? "Нет активных матчей" : "Не удалось получить котировки") : nil
  }

  private func persistContext() -> ModelContext? {
    if let c = cachedContext { return c }
    guard let container = AppDependencies.shared.container else { return nil }
    let c = ModelContext(container)
    cachedContext = c
    return c
  }

  static func parseFullBooksToDict(_ books: [BookmakerOdds]) -> [String: [String: Double]] {
    var out: [String: [String: Double]] = [:]
    for b in books {
      for m in b.odds {
        let market: String
        switch m.marketId {
        case MarketID.goals, MarketID.goalsHome, MarketID.goalsAway:
          market = "GOALS"
        case MarketID.totalCorners:
          market = "CORNERS"
        case MarketID.totalCards:
          market = "CARDS"
        default:
          continue
        }
        for p in m.odds {
          let line = OddsQuery.extractLine(from: p.name)
          let key = "\(market)|\(p.name.lowercased())|\(line.map { String($0) } ?? "")"
          var byBook = out[key] ?? [:]
          let bidStr = String(b.bookmakerId)
          byBook[bidStr] = max(byBook[bidStr] ?? 0, p.value)
          out[key] = byBook
        }
      }
    }
    return out
  }

  static func parseOddsByBook(_ json: JSONValue) -> [String: [String: Double]] {
    var out: [String: [String: Double]] = [:]
    let data = json.object?["data"]?.object ?? json.object ?? [:]
    let game = data["game"]?.object ?? data
    let items: [JSONValue] = {
      if let arr = game["odds"]?.array { return arr }
      if let arr = data["odds"]?.array { return arr }
      if let arr = json.array { return arr }
      return []
    }()

    for mv in items {
      guard let m = mv.object else { continue }
      let marketId = m["marketId"]?.number.map { Int($0) }
      let marketName = (m["marketName"]?.string ?? "").lowercased()
      guard let prices = m["odds"]?.array else { continue }
      for pv in prices {
        guard let p = pv.object else { continue }
        guard let value = numberFrom(p, ["value", "odds", "price"]),
              value > 1, value < 1000 else { continue }
        let selName = (p["name"]?.string ?? "")
        let market = normalizeLiveMarket(marketId, marketName, selName)
        guard !market.isEmpty else { continue }
        let line = extractLineFrom(selName) ?? extractLineFrom(marketName)
        let book = "sstats"
        let key = "\(market)|\(selName.lowercased())|\(line.map { String($0) } ?? "")"
        var byBook = out[key] ?? [:]
        byBook[book] = max(byBook[book] ?? 0, value)
        out[key] = byBook
      }
    }
    return out
  }

  private static func normalizeLiveMarket(_ id: Int?, _ name: String, _ sel: String) -> String {
    if let id {
      switch id {
      case MarketID.matchWinner: return "1X2"
      case MarketID.goals,
           MarketID.goalsHome,
           MarketID.goalsAway: return "GOALS"
      case MarketID.totalCorners: return "CORNERS"
      case MarketID.totalCards: return "CARDS"
      default: break
      }
    }
    let s = (name + " " + sel).lowercased()
    if s.contains("corner") { return "CORNERS" }
    if s.contains("card") || s.contains("yellow") { return "CARDS" }
    if s.contains("goal") || s.contains("total")
        || s.contains("over") || s.contains("under") { return "GOALS" }
    if s.contains("1x2") || s.contains("winner")
        || s.contains("home") || s.contains("draw") || s.contains("away") { return "1X2" }
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

  static func classifyRegime(snapshots: [String: OddsSnapshot],
                             movements: [LineMovement]) -> MarketRegimeReport {
    guard !snapshots.isEmpty else {
      return MarketRegimeReport(
        regime: .unknown, avgBooksPerMarket: 0, avgSpreadPct: 0,
        sharpMovements: 0, totalMovements: 0,
        note: "Нет активных котировок — запустите live-монитор")
    }

    var spreads: [Double] = []
    var bookCounts: [Int] = []
    for snap in snapshots.values {
      for (_, byBook) in snap.byKey {
        bookCounts.append(byBook.count)
        if byBook.count >= 2 {
          let vals = Array(byBook.values)
          let mn = vals.min() ?? 1
          let mx = vals.max() ?? 1
          if mn > 1 { spreads.append((mx - mn) / mn) }
        }
      }
    }
    let avgSpread = spreads.isEmpty ? 0 : spreads.reduce(0, +) / Double(spreads.count)
    let avgBooks = bookCounts.isEmpty
      ? 0 : Double(bookCounts.reduce(0, +)) / Double(bookCounts.count)

    let total = movements.count
    let sharp = movements.filter { $0.isSharp }.count
    let bigMovers = movements.filter { abs($0.delta) > 0.02 }.count

    let regime: MarketRegime
    let note: String
    if total == 0 {
      regime = .normal
      note = "Движений пока нет — базовый цикл"
    } else if sharp >= 3 && total >= 3 {
      regime = .lineDislocation
      note = "\(sharp) sharp-движений на \(total) — резкий переезд линий в 3+ книгах"
    } else if avgBooks > 0 && avgBooks < 4 {
      regime = .lowLiquidity
      note = String(format: "Средне %.1f книг/рынок — тонкий рынок, котировки менее надёжны", avgBooks)
    } else if bigMovers >= 5 || avgSpread > 0.10 {
      regime = .highVolatility
      note = String(format: "%d крупных движений, средний спред %.1f%% — рынок волатильный",
                    bigMovers, avgSpread * 100)
    } else {
      regime = .normal
      note = "Штатный режим рынка"
    }
    return MarketRegimeReport(
      regime: regime,
      avgBooksPerMarket: avgBooks,
      avgSpreadPct: avgSpread,
      sharpMovements: sharp,
      totalMovements: total,
      note: note)
  }
}
