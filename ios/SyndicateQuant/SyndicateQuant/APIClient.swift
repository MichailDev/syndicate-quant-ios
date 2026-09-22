import Foundation

final class SStatsClient {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    @MainActor
    init(settings: AppSettings) {
        self.baseURL = settings.baseURL
        self.apiKey = settings.apiKey
        self.session = URLSession(configuration: .ephemeral)
    }

    func listToday() async throws -> JSONValue {
        try await get("/Ls/List", query: [
            "Date": Self.dateString(Date()),
            "TimeZone": "3",
            "Upcoming": "true"
        ])
    }

    func listTeam(_ teamID: String, limit: Int = 25) async throws -> JSONValue {
        try await get("/Ls/List", query: [
            "Team": teamID,
            "Upcoming": "false",
            "Limit": String(limit)
        ])
    }

    func gameInfo(_ id: String) async throws -> JSONValue {
        try await get("/Ls/GameInfo", query: ["id": id])
    }

    func odds(_ id: String) async throws -> JSONValue {
        try await get("/Odds/\(id)", query: [:])
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
                .prefix(count)
                .map { $0 }
        } catch {
            return []
        }
    }

    private func matches(from json: JSONValue) -> [Match] {
        QuantEngine().matches(from: json)
    }

    private func recordsFromList(_ json: JSONValue, targetID: String) -> [TeamRecord] {
        var out: [TeamRecord] = []
        for o in json.allObjects() {
            let homeID = teamID(o, "home")
            let awayID = teamID(o, "away")
            guard homeID == targetID || awayID == targetID else { continue }

            let home = homeID == targetID
            let pref = home ? "home" : "away"
            let opp  = home ? "away" : "home"
            let stats = o["statistics"]?.object ?? o

            let rec = TeamRecord(
                id: string(o, ["id", "gameId", "game_id", "eventId", "flashId"]) ?? UUID().uuidString,
                date: date(o),
                gf: number(o, [pref + "FTResult", pref + "Score", pref + "Goals"]),
                ga: number(o, [opp + "FTResult", opp + "Score", opp + "Goals"]),
                corners: number(stats, ["cornerKicks" + (home ? "Home" : "Away"), pref + "Corners", "corners"]),
                oppCorners: number(stats, ["cornerKicks" + (home ? "Away" : "Home"), opp + "Corners"]),
                cards: number(stats, ["yellowCards" + (home ? "Home" : "Away"), pref + "Cards", "cards"]),
                oppCards: number(stats, ["yellowCards" + (home ? "Away" : "Home"), opp + "Cards"]),
                fouls: number(stats, ["fouls" + (home ? "Home" : "Away"), pref + "Fouls", "fouls"]),
                oppFouls: number(stats, ["fouls" + (home ? "Away" : "Home"), opp + "Fouls"]),
                shots: number(stats, ["totalShots" + (home ? "Home" : "Away"), "shots"]),
                sot: number(stats, ["shotsOnGoal" + (home ? "Home" : "Away"), "sot"]),
                possession: number(stats, ["ballPossession" + (home ? "Home" : "Away"), "possession"]),
                xg: number(stats, ["expectedGoals" + (home ? "Home" : "Away"), "xg"]),
                oppXg: number(stats, ["expectedGoals" + (home ? "Away" : "Home"), "opp_xg"]),
                referee: string(o, ["refereeName", "referee"]),
                players: []
            )
            if rec.gf != nil || rec.ga != nil { out.append(rec) }
        }
        return out
    }

    private func teamID(_ o: [String: JSONValue], _ side: String) -> String? {
        if let x = o[side + "Team"]?.object {
            return string(x, ["id", "teamId", "team_id", "flashId"])
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
            if let t = Double(s) {
                return Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t)
            }
        }
        return nil
    }

    private func get(_ path: String, query: [String: String], attempt: Int = 0) async throws -> JSONValue {
        guard var c = URLComponents(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "apikey", value: apiKey))
        c.queryItems = items

        guard let url = c.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 45

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            if http.statusCode == 429 {
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                    return try await get(path, query: query, attempt: attempt + 1)
                }
                throw APIError.rateLimited
            }

            guard (200..<300).contains(http.statusCode) else {
                throw APIError.server("SStats HTTP \(http.statusCode)")
            }

            return try JSONValue(data: data)
        } catch {
            if attempt < 2 && !(error is APIError) {
                try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
                return try await get(path, query: query, attempt: attempt + 1)
            }
            throw error
        }
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 3 * 3600)
        return f.string(from: date)
    }
}

enum APIError: LocalizedError {
    case invalidURL, invalidResponse, rateLimited, missingAPIKey, server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:        return "Некорректный URL"
        case .invalidResponse:   return "Некорректный ответ SStats"
        case .rateLimited:       return "SStats: превышен лимит запросов"
        case .missingAPIKey:     return "Укажи SStats API key в настройках"
        case .server(let s):     return s
        }
    }
}

enum JSONValue: Codable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var o = [String: JSONValue]()
            for k in c.allKeys {
                o[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
            }
            self = .object(o)
            return
        }
        if var c = try? decoder.unkeyedContainer() {
            var a = [JSONValue]()
            while !c.isAtEnd {
                a.append(try c.decode(JSONValue.self))
            }
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
        case .array(let v):  try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    var string: String? { if case .string(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array:  [JSONValue]? { if case .array(let v)  = self { return v }; return nil }
    var bool:   Bool? { if case .bool(let v)   = self { return v }; return nil }

    func allObjects() -> [[String: JSONValue]] {
        var out = [[String: JSONValue]]()
        if let o = object {
            out.append(o)
            for v in o.values { out += v.allObjects() }
        }
        if let a = array {
            for v in a { out += v.allObjects() }
        }
        return out
    }

    func firstNumber(keys: Set<String>) -> Double? {
        if let o = object {
            for (k, v) in o {
                if keys.contains(k.lowercased()), let n = v.number { return n }
                if let n = v.firstNumber(keys: keys) { return n }
            }
        }
        if let a = array {
            for v in a { if let n = v.firstNumber(keys: keys) { return n } }
        }
        return nil
    }
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    let intValue: Int? = nil
    init?(intValue: Int) { return nil }
}
