import Foundation
import SwiftData

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
  ]
  static func id(for name: String) -> Int? { pool.first(where: { $0.name == name })?.id }
  static func name(for id: Int) -> String? { pool.first(where: { $0.id == id })?.name }
}

// MARK: - League baselines (Волна A, A4)
//
// ВАЖНО: это структурные ПРИОРЫ, а не измеренные данные.
// sampleSize = 0 означает "prior", а не "n наблюдений".
// В Волне G значения будут заменены на фактические, собранные из 2-летней базы.

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
  let stake: Double
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

  // Волна A, A3 — движение линии.
  // Опциональные поля → миграция SwiftData не требуется.
  var openingOdds: Double?   // цена в момент постановки в журнал
  var movement: Double?      // openingOdds / closingOdds - 1

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

// MARK: - BacktestRun

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

  init(
    id: String = UUID().uuidString, createdAt: Date = Date(),
    matches: Int, bets: Int, wins: Int, losses: Int, pushes: Int,
    profit: Double, staked: Double, roi: Double, yieldPct: Double,
    hitRate: Double, maxDrawdown: Double, maxLosingStreak: Int,
    sharpe: Double, brier: Double, logLoss: Double, avgCLV: Double
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

struct AppStats {
  var bets = 0
  var wins = 0
  var losses = 0
  var pushes = 0
  var profit = 0.0
  var staked = 0.0
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
  var hitRate: Double {
    wins + losses > 0 ? Double(wins) / Double(wins + losses) : 0
  }
  var pending: Int { totalEntries - closedEntries }
}

struct CalibrationBucket: Identifiable {
  let id: String
  let midpoint: Double
  let predicted: Double
  let actual: Double
  let count: Int
}

// Волна A, A2 — точка equity curve.
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

      if let clv = e.clv {
        clvSum += clv
        clvCount += 1
      }

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
      buckets.append(CalibrationBucket(
        id: "b\(i)",
        midpoint: Double(i) / 10.0 + 0.05,
        predicted: avgPred,
        actual: actual,
        count: n))
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

  /// Волна A, A2 — equity curve по закрытым записям, отсортированным по времени.
  static func equityCurve(_ entries: [JournalEntry]) -> [EquityPoint] {
    let closed = entries
      .filter { $0.status == "CLOSED" && $0.profit != nil }
      .sorted { $0.createdAt < $1.createdAt }
    guard !closed.isEmpty else { return [] }

    var curve: [EquityPoint] = []
    var cumProfit = 0.0
    var cumStaked = 0.0
    for (i, e) in closed.enumerated() {
      cumProfit += e.profit ?? 0
      cumStaked += e.stake
      curve.append(EquityPoint(
        id: "eq\(i)_\(e.id)",
        date: e.createdAt,
        cumulativeProfit: cumProfit,
        cumulativeStaked: cumStaked,
        bets: i + 1))
    }
    return curve
  }
}

// MARK: - JournalService

enum JournalService {
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
        continue
      }

      let result = evaluateResult(entry: entry, home: hFT, away: aFT)
      entry.result = result
      entry.profit = computeProfit(
        result: result, odds: entry.odds, stake: entry.stake)

      if let closingOdds = extractClosingOdds(data: data, entry: entry),
         closingOdds > 1 {
        entry.closingOdds = closingOdds
        entry.clv = entry.odds / closingOdds - 1
        // A3: movement — движение линии от открытия к закрытию.
        if let openOdds = entry.openingOdds, openOdds > 1 {
          entry.movement = openOdds / closingOdds - 1
        }
      }

      entry.status = "CLOSED"
      closed += 1

      try? await Task.sleep(for: .milliseconds(120))
    }

    try? context.save()
    return (closed, failed)
  }

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
      if abs(line.rounded() - line) < 0.001,
         Double(Int(line)) == total {
        return "PUSH"
      }
      let hit = isOver ? total > line : total < line
      return hit ? "WIN" : "LOSS"
    }
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

// MARK: - AppDependencies (Волна A, A9)
// Общий ModelContainer, доступный и из UI, и из фоновых задач.

@MainActor
final class AppDependencies {
  static let shared = AppDependencies()
  var container: ModelContainer?
  private init() {}
}

// MARK: - ScanCoordinator
// Общий сервис сканирования, доступный и из UI, и из BGAppRefreshTask.

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
  }

  func scan(
    settings: AppSettings? = nil,
    selectedLeague: String = "Все"
  ) async -> ScanSummary {
    if isScanning {
      return ScanSummary(notes: ["Уже выполняется"])
    }
    isScanning = true
    defer { isScanning = false }

    var summary = ScanSummary()

    let resolvedSettings: AppSettings = settings ?? AppSettings()
    let key = resolvedSettings.apiKey
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      summary.notes.append("API key не задан")
      return summary
    }

    do {
      let client = SStatsClient(settings: resolvedSettings)
      let engine = QuantEngine()

      var all = engine.matches(from: try await client.listToday())
        .filter { !Self.isExcluded($0) }
      summary.skippedExcluded = all.count

      if selectedLeague != "Все" {
        all = all.filter {
          $0.league.localizedCaseInsensitiveContains(selectedLeague)
        }
      }
      let matches = all.prefix(resolvedSettings.scanMatches)

      var signalsOut: [BetSignal] = []
      var count = 0
      for match in matches {
        guard let h = match.homeID, let a = match.awayID else { continue }
        count += 1
        let hs = await client.fetchTeamHistory(
          teamID: h, count: resolvedSettings.historyMatches)
        let awayRecords = await client.fetchTeamHistory(
          teamID: a, count: resolvedSettings.historyMatches)
        guard let info = try? await client.gameInfo(match.id) else { continue }
        var oddsFromInfo = info.object?["data"]?.object?["odds"]
          ?? match.oddsJSON ?? .array([])
        if oddsFromInfo.array?.isEmpty != false, let nid = match.numericID {
          if let o = try? await client.odds(numericID: nid) {
            oddsFromInfo = o.object?["data"] ?? oddsFromInfo
          }
        }
        let glicko = try? await client.glicko(match.id)
        let s = engine.signals(
          match: match, info: info, oddsJSON: oddsFromInfo,
          homeHistory: hs, awayHistory: awayRecords, glicko: glicko)
        signalsOut.append(contentsOf: s)
      }

      summary.scannedMatches = count
      summary.signals = engine.portfolio(signalsOut)
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

  private static func isExcluded(_ m: Match) -> Bool {
    let x = "\(m.league) \(m.home) \(m.away)".lowercased()
    let bad = ["friendly", "women", "женщ", "u19 women", "u20 women"]
    return bad.contains(where: x.contains)
  }
}