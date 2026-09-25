import Foundation
import Network

// MARK: - Response Cache

actor ResponseCache {
  static let shared = ResponseCache()

  private struct Entry {
    let json: JSONValue
    let expiresAt: Date
  }

  private struct Envelope: Codable {
    let payload: Data
    let expiresAt: Date
  }

  private var memory: [String: Entry] = [:]
  private let fm = FileManager.default
  private let dir: URL

  private init() {
    let base = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let d = base.appendingPathComponent("SStatsCache", isDirectory: true)
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    self.dir = d
    try? purgeExpiredOnDisk()
  }

  func get(key: String) -> JSONValue? {
    if let e = memory[key], e.expiresAt > Date() {
      return e.json
    }
    let url = fileURL(for: key)
    guard let data = try? Data(contentsOf: url),
          let env = try? JSONDecoder().decode(Envelope.self, from: data),
          env.expiresAt > Date()
    else {
      try? fm.removeItem(at: url)
      return nil
    }
    guard let json = try? JSONValue(data: env.payload) else { return nil }
    memory[key] = Entry(json: json, expiresAt: env.expiresAt)
    return json
  }

  func set(key: String, json: JSONValue, ttl: TimeInterval) {
    let expiresAt = Date().addingTimeInterval(ttl)
    memory[key] = Entry(json: json, expiresAt: expiresAt)
    do {
      let payload = try JSONEncoder().encode(json)
      let env = Envelope(payload: payload, expiresAt: expiresAt)
      let data = try JSONEncoder().encode(env)
      let url = fileURL(for: key)
      try data.write(to: url, options: .atomic)
    } catch {}
  }

  func clearAll() {
    memory.removeAll()
    try? fm.removeItem(at: dir)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  private func fileURL(for key: String) -> URL {
    dir.appendingPathComponent(ResponseCache.fnv1a(key) + ".json")
  }

  private func purgeExpiredOnDisk() throws {
    let files = (try? fm.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: nil)) ?? []
    for f in files {
      guard let data = try? Data(contentsOf: f),
            let env = try? JSONDecoder().decode(Envelope.self, from: data)
      else {
        try? fm.removeItem(at: f)
        continue
      }
      if env.expiresAt <= Date() {
        try? fm.removeItem(at: f)
      }
    }
  }

  private static func fnv1a(_ s: String) -> String {
    var h: UInt64 = 1469598103934665603
    for b in s.utf8 {
      h ^= UInt64(b)
      h &*= 1099511628211
    }
    return String(h, radix: 16)
  }
}

// MARK: - Rate Limiter

actor RateLimiter {
  static let shared = RateLimiter()

  private var lastRequest = Date.distantPast
  private var minInterval: TimeInterval = 0.20

  func acquire() async {
    let now = Date()
    let elapsed = now.timeIntervalSince(lastRequest)
    if elapsed < minInterval {
      let wait = minInterval - elapsed
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
    lastRequest = Date()
  }

  func register429(retryAfter: TimeInterval?) {
    let cooldown = retryAfter ?? 5.0
    minInterval = min(2.0, max(minInterval, cooldown / 10.0))
    lastRequest = Date().addingTimeInterval(cooldown)
    print("[RateLimit] 429; minInterval=\(minInterval)s cooldown=\(cooldown)s")
  }

  func onSuccess() {
    minInterval = max(0.20, minInterval * 0.95)
  }
}

// MARK: - Request Coalescer

actor RequestCoalescer {
  static let shared = RequestCoalescer()

  private var inFlight: [String: Task<JSONValue, Error>] = [:]

  func coalesce(
    key: String,
    operation: @escaping @Sendable () async throws -> JSONValue
  ) async throws -> JSONValue {
    if let existing = inFlight[key] {
      return try await existing.value
    }
    let task = Task { try await operation() }
    inFlight[key] = task
    do {
      let value = try await task.value
      inFlight[key] = nil
      return value
    } catch {
      inFlight[key] = nil
      throw error
    }
  }
}

// MARK: - Network Monitor

final class NetworkMonitor: @unchecked Sendable {
  static let shared = NetworkMonitor()

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.syndicatequant.netmon")

  private let lock = NSLock()
  private var _isOnline = true

  var isOnline: Bool {
    lock.lock(); defer { lock.unlock() }
    return _isOnline
  }

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.lock.lock()
      self._isOnline = (path.status == .satisfied)
      self.lock.unlock()
    }
    monitor.start(queue: queue)
  }
}

// MARK: - SStatsClient

final class SStatsClient {
  private let baseURL: String
  private let apiKey: String
  private let session: URLSession

  @MainActor
  init(settings: AppSettings) {
    self.baseURL = settings.baseURL
    self.apiKey = settings.apiKey
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 25
    cfg.timeoutIntervalForResource = 40
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.waitsForConnectivity = false
    cfg.httpAdditionalHeaders = [
      "Accept": "application/json",
      "User-Agent": "SyndicateQuant-iOS/5.3.0 (iPhone; iOS)",
      "Accept-Language": "en-US,en;q=0.9",
    ]
    self.session = URLSession(configuration: cfg)
  }

  // MARK: - Public API

  func listToday() async throws -> JSONValue {
    try await get(
      "/Ls/List",
      query: ["Date": Self.dateString(Date()), "TimeZone": "3", "Upcoming": "true"])
  }

  func listOn(date: Date, upcoming: Bool = false) async throws -> JSONValue {
    try await get(
      "/Ls/List",
      query: [
        "Date": Self.dateString(date),
        "TimeZone": "3",
        "Upcoming": upcoming ? "true" : "false",
      ])
  }

  func listGamesRange(from: Date, to: Date, limit: Int = 1000) async throws -> JSONValue {
    try await get(
      "/Games/list",
      query: [
        "From": Self.dateString(from),
        "To": Self.dateString(to),
        "Ended": "true",
        "Limit": String(limit),
        "TimeZone": "3",
      ])
  }

  func listRange(from: Date, to: Date, limit: Int = 1000) async throws -> JSONValue {
    try await get(
      "/Ls/List",
      query: [
        "From": Self.dateString(from),
        "To": Self.dateString(to),
        "Ended": "true",
        "Limit": String(limit),
        "TimeZone": "3",
      ])
  }

  func listTeam(_ teamID: String, limit: Int = 25) async throws -> JSONValue {
    try await get(
      "/Ls/List",
      query: ["Team": teamID, "Ended": "true", "Limit": String(limit), "Order": "-1"])
  }

  func gameInfo(_ id: String) async throws -> JSONValue {
    try await get("/Ls/GameInfo", query: ["id": id])
  }

  func odds(numericID: Int) async throws -> JSONValue {
    try await get("/Odds/\(numericID)", query: [:])
  }

  func glicko(_ id: String) async throws -> JSONValue {
    try await get("/Games/glicko/\(id)", query: [:])
  }

  func fetchTeamHistory(teamID: String, count: Int = 15) async -> [TeamRecord] {
    do {
      let list = try await listTeam(teamID, limit: max(count * 2, 25))
      var rows = recordsFromList(list, targetID: teamID)
      if rows.count < min(6, count) {
        let ids = matches(from: list).prefix(count).map { $0.id }
        for id in ids {
          if let r = try? await gameInfo(id),
             let x = QuantEngine().teamRecord(from: r, targetID: teamID) {
            rows.append(x)
          }
        }
      }
      var unique = [String: TeamRecord]()
      for r in rows { unique[r.id] = r }
      return Array(unique.values)
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        .prefix(count).map { $0 }
    } catch { return [] }
  }

  // MARK: - Cache policy

  private static func ttl(for path: String) -> TimeInterval {
    if path.hasPrefix("/Ls/List") { return 15 * 60 }
    if path.hasPrefix("/Games/list") { return 6 * 3600 }
    if path.hasPrefix("/Ls/Team") { return 3600 }
    if path.hasPrefix("/Ls/GameInfo") { return 30 * 60 }
    if path.hasPrefix("/Odds/") { return 5 * 60 }
    if path.hasPrefix("/Games/glicko") { return 6 * 3600 }
    return 5 * 60
  }

  private static func makeCacheKey(path: String, query: [String: String]) -> String {
    let q = query
      .filter { $0.key.lowercased() != "apikey" }
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "&")
    return path + "?" + q
  }

  // MARK: - Networking core

  private func get(
    _ path: String, query: [String: String], attempt: Int = 0
  ) async throws -> JSONValue {
    let cacheKey = Self.makeCacheKey(path: path, query: query)

    if let cached = await ResponseCache.shared.get(key: cacheKey) {
      return cached
    }

    if !NetworkMonitor.shared.isOnline {
      throw APIError.server("Нет соединения с интернетом")
    }

    let baseURL = self.baseURL
    let apiKey = self.apiKey
    let session = self.session
    let ttlValue = Self.ttl(for: path)

    return try await RequestCoalescer.shared.coalesce(key: cacheKey) {
      await RateLimiter.shared.acquire()

      let json = try await Self.performGet(
        path: path, query: query, attempt: attempt,
        baseURL: baseURL, apiKey: apiKey, session: session)

      await ResponseCache.shared.set(key: cacheKey, json: json, ttl: ttlValue)
      return json
    }
  }

  private static func performGet(
    path: String, query: [String: String], attempt: Int,
    baseURL: String, apiKey: String, session: URLSession
  ) async throws -> JSONValue {
    guard var c = URLComponents(string: baseURL + path) else {
      throw APIError.invalidURL
    }
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "apikey", value: apiKey))
    c.queryItems = items
    guard let url = c.url else { throw APIError.invalidURL }

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 25

    do {
      let (data, response) = try await session.data(for: req)
      guard let http = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      if http.statusCode == 429 {
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
          .flatMap { TimeInterval($0) }
        await RateLimiter.shared.register429(retryAfter: retryAfter)

        if attempt < 3 {
          let wait = retryAfter ?? min(30, 1.0 * pow(2, Double(attempt)))
          try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
          return try await performGet(
            path: path, query: query, attempt: attempt + 1,
            baseURL: baseURL, apiKey: apiKey, session: session)
        }
        throw APIError.rateLimited
      }

      guard (200..<300).contains(http.statusCode) else {
        throw APIError.server("SStats HTTP \(http.statusCode)")
      }

      await RateLimiter.shared.onSuccess()
      return try JSONValue(data: data)
    } catch let urlErr as URLError {
      print("[SStats] URLError code=\(urlErr.code.rawValue) url=\(url.absoluteString)")
      let retriable: Set<URLError.Code> = [
        .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
      ]
      if retriable.contains(urlErr.code) && attempt < 2 {
        try? await Task.sleep(nanoseconds: UInt64(500 * (attempt + 1)) * 1_000_000)
        return try await performGet(
          path: path, query: query, attempt: attempt + 1,
          baseURL: baseURL, apiKey: apiKey, session: session)
      }
      throw APIError.server("Сеть: \(urlErr.code.rawValue) — \(urlErr.localizedDescription)")
    } catch {
      print("[SStats] Error: \(error) url=\(url.absoluteString)")
      throw error
    }
  }

  // MARK: - Helpers

  private func matches(from json: JSONValue) -> [Match] {
    QuantEngine().matches(from: json)
  }

  private func recordsFromList(_ json: JSONValue, targetID: String) -> [TeamRecord] {
    var out: [TeamRecord] = []
    let items: [JSONValue] =
      json.object?["data"]?.array ?? json.allObjects().map { .object($0) }
    for item in items {
      guard let o = item.object else { continue }
      let homeID = teamID(o, "home")
      let awayID = teamID(o, "away")
      guard homeID == targetID || awayID == targetID else { continue }
      let home = homeID == targetID
      let pref = home ? "home" : "away"
      let opp = home ? "away" : "home"
      let stats = o["statistics"]?.object ?? o
      let rec = TeamRecord(
        id: string(o, ["id", "gameId", "game_id", "eventId", "flashId"]) ?? UUID().uuidString,
        date: date(o),
        gf: number(o, [pref + "FTResult", pref + "Result", pref + "Score", pref + "Goals"]),
        ga: number(o, [opp + "FTResult", opp + "Result", opp + "Score", opp + "Goals"]),
        corners: number(stats, ["cornerKicks" + (home ? "Home" : "Away"),
                                pref + "Corners", "corners"]),
        oppCorners: number(stats, ["cornerKicks" + (home ? "Away" : "Home"), opp + "Corners"]),
        cards: number(stats, ["yellowCards" + (home ? "Home" : "Away"),
                              pref + "Cards", "cards"]),
        oppCards: number(stats, ["yellowCards" + (home ? "Away" : "Home"), opp + "Cards"]),
        fouls: number(stats, ["fouls" + (home ? "Home" : "Away"), pref + "Fouls", "fouls"]),
        oppFouls: number(stats, ["fouls" + (home ? "Away" : "Home"), opp + "Fouls"]),
        shots: number(stats, ["totalShots" + (home ? "Home" : "Away"), "shots"]),
        sot: number(stats, ["shotsOnGoal" + (home ? "Home" : "Away"), "sot"]),
        possession: number(stats, ["ballPossession" + (home ? "Home" : "Away"), "possession"]),
        xg: number(stats, ["expectedGoals" + (home ? "Home" : "Away"), "xg"]),
        oppXg: number(stats, ["expectedGoals" + (home ? "Away" : "Home"), "opp_xg"]),
        referee: string(o, ["refereeName", "referee"]),
        isHome: home,
        players: parsePlayers(o: o, stats: stats, side: pref))
      if rec.gf != nil || rec.ga != nil { out.append(rec) }
    }
    return out
  }

  /// B6: попытка достать построчный список игроков команды из матча.
  /// Пробует несколько ключей и структур, если ничего не находит — возвращает [].
  private func parsePlayers(
    o: [String: JSONValue], stats: [String: JSONValue], side: String
  ) -> [PlayerRow] {
    let candidates: [JSONValue?] = [
      o[side + "Players"], o[side + "Lineup"],
      o["players_" + side], o["lineup_" + side],
      o["players"], o["lineups"],
      stats[side + "Players"], stats["players"],
    ]
    for v in candidates {
      guard let arr = v?.array, !arr.isEmpty else { continue }
      let rows = arr.compactMap { parsePlayer($0, side: side) }
      if !rows.isEmpty { return rows }
    }
    return []
  }

  private func parsePlayer(_ v: JSONValue, side: String) -> PlayerRow? {
    guard let o = v.object else { return nil }
    // Если у объекта есть поле side/team, отфильтруем несоответствующие.
    if let team = string(o, ["side", "team", "teamSide"])?.lowercased() {
      if team.contains("home") && side == "away" { return nil }
      if team.contains("away") && side == "home" { return nil }
    }
    let id = string(o, ["id", "playerId", "player_id", "uid", "flashId"]) ?? ""
    let name = string(o, ["name", "playerName", "shortName"]) ?? ""
    guard !id.isEmpty || !name.isEmpty else { return nil }
    let resolvedID = id.isEmpty ? name : id
    return PlayerRow(
      id: resolvedID,
      name: name,
      minutes: number(o, ["minutes", "min", "played", "minutesPlayed"]) ?? 0,
      xg: number(o, ["xg", "expectedGoals", "xG"]) ?? 0,
      xa: number(o, ["xa", "expectedAssists", "xA"]) ?? 0,
      goals: number(o, ["goals", "g", "scored"]) ?? 0,
      assists: number(o, ["assists", "a"]) ?? 0,
      shots: number(o, ["shots", "totalShots", "shotsTotal"]) ?? 0,
      sot: number(o, ["sot", "shotsOnGoal", "shotsOnTarget"]) ?? 0,
      starts: Int(number(o, ["starts", "isStarter", "started"]) ?? 0)
    )
  }

  private func teamID(_ o: [String: JSONValue], _ side: String) -> String? {
    if let x = o[side + "Team"]?.object {
      return string(x, ["id", "teamId", "team_id", "flashId", "uid"])
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

  private func date(_ o: [String: JSONValue]) -> Date? {
    if let s = string(o, ["date", "dateUtc", "startTime", "datetime"]) {
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

  private static func dateString(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(secondsFromGMT: 3 * 3600)
    return f.string(from: date)
  }
}

// MARK: - APIError

enum APIError: LocalizedError {
  case invalidURL, invalidResponse, rateLimited, missingAPIKey
  case server(String)
  var errorDescription: String? {
    switch self {
    case .invalidURL: return "Некорректный URL"
    case .invalidResponse: return "Некорректный ответ SStats"
    case .rateLimited: return "SStats: превышен лимит запросов"
    case .missingAPIKey: return "Укажи SStats API key в настройках"
    case .server(let s): return s
    }
  }
}

// MARK: - JSONValue

enum JSONValue: Codable, Hashable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  init(data: Data) throws { self = try JSONDecoder().decode(JSONValue.self, from: data) }
  init(from decoder: Decoder) throws {
    if let c = try? decoder.container(keyedBy: AnyCodingKey.self) {
      var o = [String: JSONValue]()
      for k in c.allKeys { o[k.stringValue] = try c.decode(JSONValue.self, forKey: k) }
      self = .object(o)
      return
    }
    if var c = try? decoder.unkeyedContainer() {
      var a = [JSONValue]()
      while !c.isAtEnd { a.append(try c.decode(JSONValue.self)) }
      self = .array(a)
      return
    }
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else {
      self = .string(try c.decode(String.self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  var number: Double? {
    if case .number(let v) = self { return v }
    return nil
  }
  var object: [String: JSONValue]? {
    if case .object(let v) = self { return v }
    return nil
  }
  var array: [JSONValue]? {
    if case .array(let v) = self { return v }
    return nil
  }
  var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  func allObjects() -> [[String: JSONValue]] {
    var out = [[String: JSONValue]]()
    if let o = object {
      out.append(o)
      for v in o.values { out += v.allObjects() }
    }
    if let a = array { for v in a { out += v.allObjects() } }
    return out
  }
  func firstNumber(keys: Set<String>) -> Double? {
    if let o = object {
      for (k, v) in o {
        if keys.contains(k.lowercased()), let n = v.number { return n }
        if let n = v.firstNumber(keys: keys) { return n }
      }
    }
    if let a = array { for v in a { if let n = v.firstNumber(keys: keys) { return n } } }
    return nil
  }
}

struct AnyCodingKey: CodingKey {
  let stringValue: String
  init?(stringValue: String) { self.stringValue = stringValue }
  let intValue: Int? = nil
  init?(intValue: Int) { return nil }
}