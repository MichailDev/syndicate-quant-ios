import Foundation
import SwiftData

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
}

struct Quote: Codable, Hashable {
  let market: String
  let selection: String
  let line: Double?
  let odds: Double
  let bookmaker: String
}

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
  let qcs: Double
  let dcs: Double
  let model: String
  let timestamp: Date
  let classification: String
  let stake: Double
  let priceAnomaly: Bool
  let bookmakers: Int
  var portfolioCorrelation: Double
  var marketProbability: Double = 0.0
  var marketMAD: Double = 0.0
  var probabilityLow: Double = 0.0
  var probabilityHigh: Double = 1.0
  var uncertainty: Double = 1.0
  var modelAgreement: Double = 0.0
}

@Model final class JournalEntry {
  @Attribute(.unique) var id: String
  var gameID: String
  var home: String
  var away: String
  var league: String
  var market: String
  var selection: String
  var odds: Double
  var probability: Double
  var ev: Double
  var qcs: Double
  var status: String
  var createdAt: Date
  var result: String?

  init(signal: BetSignal, status: String = "OPEN") {
    id = signal.id
    gameID = signal.gameID
    home = signal.home
    away = signal.away
    league = signal.league
    market = signal.market
    selection = signal.selection
    odds = signal.odds
    probability = signal.probability
    ev = signal.ev
    qcs = signal.qcs
    self.status = status
    createdAt = signal.timestamp
    result = nil
  }
}

@Model final class CalibrationSample {
  @Attribute(.unique) var id: String
  var predicted: Double
  var actual: Double
  var market: String
  var createdAt: Date
  init(id: String, predicted: Double, actual: Double, market: String, createdAt: Date = Date()) {
    self.id = id
    self.predicted = predicted
    self.actual = actual
    self.market = market
    self.createdAt = createdAt
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
  var maxDrawdown: Double
  var maxLosingStreak: Int
  init(
    id: String = UUID().uuidString, createdAt: Date = Date(), matches: Int, bets: Int, wins: Int,
    losses: Int, pushes: Int, profit: Double, staked: Double, roi: Double, maxDrawdown: Double,
    maxLosingStreak: Int
  ) {
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
    self.maxDrawdown = maxDrawdown
    self.maxLosingStreak = maxLosingStreak
  }
}

struct AppStats {
  var bets = 0
  var wins = 0
  var losses = 0
  var pushes = 0
  var profit = 0.0
  var staked = 0.0
}