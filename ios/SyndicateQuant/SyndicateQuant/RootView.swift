import SwiftData
import SwiftUI

struct RootView: View {
  @EnvironmentObject var settings: AppSettings
  @Environment(\.modelContext) private var context
  @Query(sort: \JournalEntry.createdAt, order: .reverse) private var journal: [JournalEntry]
  @Query(sort: \BacktestRun.createdAt, order: .reverse) private var backtests: [BacktestRun]
  @State private var signals: [BetSignal] = []
  @State private var status = "Готов"
  @State private var busy = false
  @State private var lastRefresh: Date?
  @State private var diagnostics: [String] = []
  @State private var backtestStatus = "Не запускался"

  var body: some View {
    TabView {
      NavigationStack { forecast }.tabItem { Label("Прогноз", systemImage: "sparkles") }
      NavigationStack { journalView }.tabItem {
        Label("Журнал", systemImage: "list.bullet.rectangle")
      }
      NavigationStack { backtestView }.tabItem {
        Label("Backtest", systemImage: "chart.xyaxis.line")
      }
      NavigationStack { diagnosticsView }.tabItem {
        Label("Контроль", systemImage: "checkmark.shield")
      }
      NavigationStack { settingsView }.tabItem { Label("Настройки", systemImage: "gearshape") }
    }.task { await refresh() }
  }

  private var forecast: some View {
    List {
      Section {
        HStack {
          Text(status)
          Spacer()
          if busy { ProgressView() }
        }
        Button {
          Task { await refresh() }
        } label: {
          Label("Обновить", systemImage: "arrow.clockwise")
        }.disabled(busy)
      }
      if signals.isEmpty {
        ContentUnavailableView(
          "Нет подтверждённых ставок", systemImage: "checkmark.shield",
          description: Text("NO DATA → NO NUMBER → NO EDGE → NO BET"))
      }
      ForEach(signals) { s in
        SignalCard(signal: s).contentShape(Rectangle()).onTapGesture {
          if !journal.contains(where: { $0.id == s.id }) {
            context.insert(JournalEntry(signal: s))
            try? context.save()
          }
        }
      }
    }.navigationTitle("SYNDICATE QUANT").refreshable { await refresh() }
  }

  private var journalView: some View {
    List {
      if journal.isEmpty {
        ContentUnavailableView("Журнал пуст", systemImage: "tray")
      } else {
        ForEach(journal) { e in
          VStack(alignment: .leading, spacing: 4) {
            Text("\(e.home) — \(e.away)").font(.headline)
            Text(
              "\(e.market) · \(e.selection) · \(e.odds,specifier:"%.2f") · EV \(e.ev*100,specifier:"%+.1f")%"
            ).font(.subheadline)
            Text("\(e.status) · QCS \(e.qcs,specifier:"%.0f")").font(.caption).foregroundStyle(
              .secondary)
          }
        }.onDelete {
          for i in $0 { context.delete(journal[i]) }
          try? context.save()
        }
      }
    }.navigationTitle("Журнал")
  }

  private var backtestView: some View {
    List {
      Section("Walk-forward") {
        Text(
          "Локальный backtest использует только уже полученные данные SStats. Никаких будущих матчей в истории модели не используется."
        ).font(.caption).foregroundStyle(.secondary)
        Text(backtestStatus).font(.caption.monospaced())
        Button("Запустить на последнем наборе") { Task { await runBacktest() } }.disabled(busy)
      }
      ForEach(backtests) { b in
        VStack(alignment: .leading) {
          Text(b.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
          Text("Matches \(b.matches) · Bets \(b.bets) · W/L/P \(b.wins)/\(b.losses)/\(b.pushes)")
          Text(
            "ROI \(b.roi*100,specifier:"%+.2f")% · Profit \(b.profit,specifier:"%+.3f") · DD \(b.maxDrawdown,specifier:"%.3f")"
          ).font(.caption)
        }
      }
    }.navigationTitle("Backtest")
  }

  private var diagnosticsView: some View {
    List {
      Section("Engine") {
        Text(settings.engineVersion)
        Text("Dixon–Coles")
        Text("Poisson / Negative Binomial")
        Text("Monte Carlo")
        Text("Glicko adjustment")
        Text("Bottom-Up Player Assembly / ExpMin")
        Text("Referee profile")
        Text("Market consensus / MAD guard")
        Text("Sharp bookmaker guard")
        Text("DCS / QCS / Robust EV / Kelly")
        Text("Portfolio correlation")
        Text("Calibration / Brier / reliability diagnostics")
        Text("P10 / P50 / P90 probability uncertainty")
        Text("Market probability / MAD dispersion")
        Text("Model-vs-market conflict guard")
        Text("Replacement-level player impact")
        Text("Bayesian referee shrinkage")
        Text("Walk-forward / CLV audit layer")
      }
      Section("Последний запуск") {
        ForEach(diagnostics, id: \.self) { Text($0).font(.caption.monospaced()) }
      }
    }.navigationTitle("Контроль")
  }

  private var settingsView: some View {
    Form {
      Section("SStats API") {
        SecureField("API key", text: $settings.apiKey)
        Text("Ключ хранится в Keychain. Он используется только для запросов к api.sstats.net.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Автообновление") {
        Toggle("Фоновое обновление", isOn: $settings.autoRefresh)
        Stepper(
          "Интервал: \(settings.refreshMinutes) мин", value: $settings.refreshMinutes, in: 15...120,
          step: 15)
      }
      Section("Параметры модели") {
        Stepper(
          "История: \(settings.historyMatches) матчей", value: $settings.historyMatches, in: 6...20)
        Stepper(
          "Матчей в сканере: \(settings.scanMatches)", value: $settings.scanMatches, in: 5...30)
      }
      Section("Принцип") {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET").bold()
        Text("Приложение не использует AI/ML API, Telegram или Windows-сервер.").font(.caption)
      }
    }.navigationTitle("Настройки")
  }

  private func refresh() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    diagnostics = []
    do {
      guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw APIError.missingAPIKey
      }
      status = "Получаю сегодняшние матчи…"
      let client = SStatsClient(settings: settings)
      let matches = QuantEngine().matches(from: try await client.listToday()).filter {
        !isExcluded($0)
      }.prefix(settings.scanMatches)
      var all: [BetSignal] = []
      for match in matches {
        guard let h = match.homeID, let a = match.awayID else { continue }
        status = "Анализ \(match.home) — \(match.away)…"
        let hs = await client.fetchTeamHistory(teamID: h, count: settings.historyMatches)
        let awayRecords = await client.fetchTeamHistory(teamID: a, count: settings.historyMatches)
        let info = try await client.gameInfo(match.id)
        let odds = try await client.odds(match.id)
        let glicko = try? await client.glicko(match.id)
        let s = QuantEngine().signals(
          match: match, info: info, oddsJSON: odds, homeHistory: hs, awayHistory: awayRecords,
          glicko: glicko)
        all.append(contentsOf: s)
        diagnostics.append(
          "\(match.id) history=\(hs.count)/\(awayRecords.count) signals=\(s.count)")
      }
      signals = QuantEngine().portfolio(all)
      lastRefresh = Date()
      status =
        "Обновлено \(lastRefresh!.formatted(date:.omitted,time:.shortened)) · \(signals.count) сигналов"
      if settings.notifyBets && !signals.isEmpty {
        await NotificationService.notify(signals: signals)
      }
    } catch {
      status = error.localizedDescription
      diagnostics.append("ERROR: \(error.localizedDescription)")
    }
  }

  // MARK: - ДИАГНОСТИЧЕСКИЙ RUNBACKTEST
  // Ничего не считает. Показывает пошагово, где теряются данные SStats.
  private func runBacktest() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }

    var lines: [String] = []
    func add(_ s: String) {
      lines.append(s)
      backtestStatus = lines.joined(separator: "\n")
      print("[BT] \(s)")
    }

    do {
      guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw APIError.missingAPIKey
      }
      let client = SStatsClient(settings: settings)
      let engine = QuantEngine()

      // ШАГ 1. Today
      add("1) apiKey length: \(settings.apiKey.count)")
      add("1) baseURL: \(settings.baseURL)")

      let todayJSON = try await client.listToday()
      let rawObjects = todayJSON.allObjects()
      add("1) raw objects: \(rawObjects.count)")

      let todayMatches = engine.matches(from: todayJSON)
      add("1) parsed matches: \(todayMatches.count)")

      if let firstRaw = rawObjects.first {
        let preview = firstRaw.keys.sorted().prefix(15).joined(separator: ",")
        add("1) first object keys: \(preview)")
      }

      // ШАГ 2. Проверяем homeID/awayID
      let withIDs = todayMatches.filter { $0.homeID != nil && $0.awayID != nil }
      add("2) matches with homeID+awayID: \(withIDs.count)/\(todayMatches.count)")

      // ШАГ 3. Для первых 3 матчей — GameInfo и Odds
      for (i, m) in withIDs.prefix(3).enumerated() {
        add("3.\(i+1)) \(m.home) vs \(m.away) id=\(m.id)")
        if let info = try? await client.gameInfo(m.id) {
          let keys = (info.object?.keys ?? []).sorted().prefix(10).joined(separator: ",")
          add("   info keys: \(keys)")
          let h = info.firstNumber(keys: ["homeftresult", "homescore", "homegoals"])
          let a = info.firstNumber(keys: ["awayftresult", "awayscore", "awaygoals"])
          add("   info FT: \(h.map { String($0) } ?? "nil") - \(a.map { String($0) } ?? "nil")")
        } else {
          add("   info: FAILED")
        }
        if let odd = try? await client.odds(m.id) {
          let cnt = odd.allObjects().count
          add("   odds objects: \(cnt)")
        } else {
          add("   odds: FAILED")
        }
        if let h = m.homeID {
          let hist = await client.fetchTeamHistory(teamID: h, count: 10)
          add("   home history: \(hist.count)")
        }
        try? await Task.sleep(for: .milliseconds(150))
      }

      // ШАГ 4. Если матчей на сегодня нет — пробуем listTeam
      if withIDs.isEmpty {
        add("4) матчей на сегодня нет — тестирую listTeam…")
        if let teamJSON = try? await client.listTeam("1", limit: 10) {
          let objs = teamJSON.allObjects()
          add("4) listTeam('1') objects: \(objs.count)")
          if let first = objs.first {
            let keys = first.keys.sorted().prefix(15).joined(separator: ",")
            add("4) first team match keys: \(keys)")
          }
          let matches = engine.matches(from: teamJSON)
          add("4) listTeam parsed matches: \(matches.count)")
        } else {
          add("4) listTeam: FAILED")
        }
      }

      add("--- конец диагностики ---")
    } catch {
      add("ERROR: \(error.localizedDescription)")
    }
  }

  private func isExcluded(_ m: Match) -> Bool {
    let x = "\(m.league) \(m.home) \(m.away)".lowercased()
    let bad = ["friendly", "women", "женщ", "u19 women", "u20 women"]
    return bad.contains(where: x.contains)
  }
}

struct SignalCard: View {
  let signal: BetSignal
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("\(signal.home) — \(signal.away)").font(.headline)
        Spacer()
        Text(signal.classification).font(.caption.bold()).padding(5).background(.thinMaterial)
          .clipShape(Capsule())
      }
      Text(
        "\(signal.league) · \(signal.market) · \(signal.selection)\(signal.line.map { " \($0)" } ?? "")"
      ).foregroundStyle(.secondary)
      HStack {
        metric("Odds", signal.odds, "%.2f")
        metric("P", signal.probability * 100, "%.1f%%")
        metric("EV", signal.ev * 100, "%+.1f%%")
        metric("Robust", signal.robustEV * 100, "%+.1f%%")
        metric("QCS", signal.qcs, "%.0f")
      }
      Text("\(signal.model) · DCS \(signal.dcs,specifier:"%.0f") · \(signal.bookmakers) books")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(.vertical, 5)
  }
  private func metric(_ n: String, _ v: Double, _ f: String) -> some View {
    VStack(alignment: .leading) {
      Text(n).font(.caption2).foregroundStyle(.secondary)
      Text(String(format: f, v)).font(.subheadline.monospacedDigit())
    }
  }
}