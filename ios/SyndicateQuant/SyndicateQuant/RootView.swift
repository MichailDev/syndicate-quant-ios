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
  @State private var selectedLeague: String = "Все"

  // Для вкладки Контроль
  @State private var apiReachable: String = "—"
  @State private var apiKeyState: String = "—"
  @State private var lastSettleStatus: String = "—"

  var body: some View {
    TabView {
      NavigationStack { forecast }
        .tabItem { Label("Прогноз", systemImage: "sparkles") }
      NavigationStack { journalView }
        .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
      NavigationStack { backtestView }
        .tabItem { Label("Backtest", systemImage: "chart.xyaxis.line") }
      NavigationStack { diagnosticsView }
        .tabItem { Label("Контроль", systemImage: "checkmark.shield") }
      NavigationStack { settingsView }
        .tabItem { Label("Настройки", systemImage: "gearshape") }
    }
    .tint(.blue)
    .task { await refresh() }
  }

  // MARK: - Прогноз

  private var forecast: some View {
    List {
      Section {
        HStack {
          Text(status).font(.subheadline)
          Spacer(minLength: 8)
          if busy { ProgressView().scaleEffect(0.9) }
        }
        Picker("Лига", selection: $selectedLeague) {
          Text("Все").tag("Все")
          ForEach(LeaguePool.pool, id: \.name) { lg in
            Text(lg.name).tag(lg.name)
          }
        }
        .pickerStyle(.menu)
        Button {
          Task { await refresh() }
        } label: {
          Label("Обновить", systemImage: "arrow.clockwise")
        }
        .disabled(busy)
      }

      if signals.isEmpty {
        Section {
          ContentUnavailableView(
            "Нет подтверждённых ставок", systemImage: "checkmark.shield",
            description: Text("NO DATA → NO NUMBER → NO EDGE → NO BET"))
        }
      }

      ForEach(signals) { s in
        Section {
          SignalCard(signal: s)
            .contentShape(Rectangle())
            .onTapGesture {
              if !journal.contains(where: { $0.id == s.id }) {
                context.insert(JournalEntry(signal: s))
                try? context.save()
              }
            }
        }
      }

      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("SYNDICATE QUANT")
    .navigationBarTitleDisplayMode(.large)
    .refreshable { await refresh() }
  }

  // MARK: - Журнал

  private var journalView: some View {
    List {
      Section {
        Button {
          Task { await settleJournal() }
        } label: {
          Label("Обновить результаты", systemImage: "checkmark.circle")
        }
        .disabled(busy)
        Text(lastSettleStatus)
          .font(.caption).foregroundStyle(.secondary)
      }

      if journal.isEmpty {
        Section {
          ContentUnavailableView("Журнал пуст", systemImage: "tray")
        }
      } else {
        Section("Статистика") { journalStatsView() }
        Section("Калибровка") { calibrationView() }
        Section("Записи") {
          ForEach(journal) { e in
            journalRow(e)
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                  context.delete(e); try? context.save()
                } label: {
                  Label("Удалить", systemImage: "trash")
                }
              }
          }
        }
      }
      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Журнал")
    .navigationBarTitleDisplayMode(.large)
  }

  private func journalStatsView() -> some View {
    let m = Metrics.compute(journal)
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        statBlock("Всего", "\(m.totalEntries)")
        statBlock("Closed", "\(m.closedEntries)")
        statBlock("Pending", "\(m.pending)")
      }
      HStack {
        statBlock("W/L/P", "\(m.wins)/\(m.losses)/\(m.pushes)")
        statBlock("Hit", String(format: "%.1f%%", m.hitRate * 100))
        statBlock("ROI", String(format: "%+.2f%%", m.roi * 100))
      }
      HStack {
        statBlock("CLV ср.", String(format: "%+.2f%%", m.avgCLV * 100))
        statBlock("Brier", String(format: "%.3f", m.brier))
        statBlock("LogLoss", String(format: "%.3f", m.logLoss))
      }
    }
    .padding(.vertical, 2)
  }

  private func calibrationView() -> some View {
    let m = Metrics.compute(journal)
    if m.calibration.isEmpty {
      return AnyView(Text("Недостаточно закрытых записей для калибровки")
        .font(.caption).foregroundStyle(.secondary))
    }
    return AnyView(
      VStack(alignment: .leading, spacing: 4) {
        ForEach(m.calibration) { b in
          HStack {
            Text(String(format: "P=%.0f%%", b.midpoint * 100))
              .font(.caption.monospacedDigit())
              .frame(width: 60, alignment: .leading)
            Text(String(format: "act %.0f%%", b.actual * 100))
              .font(.caption.monospacedDigit())
              .foregroundStyle(abs(b.predicted - b.actual) < 0.08 ? .green : .orange)
            Spacer()
            Text("n=\(b.count)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Text("CalErr: \(String(format: "%.3f", Metrics.calibrationError(m)))")
          .font(.caption).foregroundStyle(.secondary)
      }
    )
  }

  private func journalRow(_ e: JournalEntry) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("\(e.home) — \(e.away)").font(.headline)
        Spacer()
        Text(e.classification).font(.caption.bold())
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(.thinMaterial).clipShape(Capsule())
      }
      Text("\(e.league) · \(e.market) · \(e.selection)\(e.line.map { " \($0)" } ?? "")")
        .font(.subheadline).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        miniBlock("Odds", String(format: "%.2f", e.odds))
        miniBlock("P", String(format: "%.0f%%", e.probability * 100))
        miniBlock("EV", String(format: "%+.1f%%", e.ev * 100))
        miniBlock("QCS", String(format: "%.0f", e.qcs))
        miniBlock("Stake", String(format: "%.2f%%", e.stake * 100))
      }
      HStack(spacing: 12) {
        statusBadge(e.status)
        if let r = e.result { resultBadge(r) }
        if let clv = e.clv {
          Text("CLV \(String(format: "%+.2f%%", clv * 100))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(clv > 0 ? .green : .red)
        }
        if let p = e.profit {
          Text("P/L \(String(format: "%+.3f", p))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(p >= 0 ? .green : .red)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func statusBadge(_ status: String) -> some View {
    Text(status)
      .font(.caption2.bold())
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(status == "CLOSED" ? Color.gray.opacity(0.3) : Color.blue.opacity(0.25))
      .clipShape(Capsule())
  }

  private func resultBadge(_ r: String) -> some View {
    let color: Color
    switch r {
    case "WIN": color = .green
    case "LOSS": color = .red
    case "PUSH": color = .orange
    default: color = .gray
    }
    return Text(r)
      .font(.caption2.bold())
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(color.opacity(0.25))
      .clipShape(Capsule())
  }

  private func statBlock(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.subheadline.monospacedDigit())
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func miniBlock(_ n: String, _ v: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(n).font(.caption2).foregroundStyle(.secondary)
      Text(v).font(.caption.monospacedDigit())
    }
  }

  // MARK: - Backtest

  private var backtestView: some View {
    List {
      Section("Walk-forward") {
        Text("Локальный backtest использует только данные, доступные ДО даты каждого матча.")
          .font(.caption).foregroundStyle(.secondary)
        Text(backtestStatus)
          .font(.caption.monospaced())
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        Button {
          Task { await runBacktest() }
        } label: {
          Label("Запустить на 45 днях", systemImage: "play.fill")
        }
        .disabled(busy)
      }
      if !backtests.isEmpty {
        Section("История") {
          ForEach(backtests) { b in
            backtestRow(b)
          }
        }
      }
      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Backtest")
    .navigationBarTitleDisplayMode(.large)
  }

  private func backtestRow(_ b: BacktestRun) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(b.createdAt.formatted(date: .abbreviated, time: .shortened))
        .font(.headline)
      Text("Matches \(b.matches) · Bets \(b.bets) · W/L/P \(b.wins)/\(b.losses)/\(b.pushes)")
        .font(.subheadline)
      Text("ROI \(b.roi * 100, specifier: "%+.2f")% · Yield \(b.yieldPct * 100, specifier: "%+.2f")% · Hit \(b.hitRate * 100, specifier: "%.1f")%")
        .font(.caption)
      Text("DD \(b.maxDrawdown, specifier: "%.3f") · Sharpe \(b.sharpe, specifier: "%.2f") · Brier \(b.brier, specifier: "%.3f") · LL \(b.logLoss, specifier: "%.3f")")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(.vertical, 2)
  }

  // MARK: - Контроль

  private var diagnosticsView: some View {
    List {
      Section("API") {
        LabeledContent("Base URL", value: settings.baseURL)
        LabeledContent("API key", value: settings.apiKey.isEmpty
          ? "не задан" : "\(settings.apiKey.count) симв.")
        LabeledContent("Engine", value: settings.engineVersion)
      }
      Section("Проверки") {
        Button {
          Task { await runChecks() }
        } label: {
          Label("Запустить проверки", systemImage: "checkmark.shield")
        }
        .disabled(busy)
        LabeledContent("API reachable", value: apiReachable)
        LabeledContent("API key", value: apiKeyState)
        LabeledContent("Settle", value: lastSettleStatus)
        if let lr = lastRefresh {
          LabeledContent(
            "Last refresh",
            value: lr.formatted(date: .omitted, time: .shortened))
        }
      }
      Section("Data freshness") {
        Text("Свежесть данных матча обновляется раз в сутки (SStats).")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Sample / Consensus") {
        let m = Metrics.compute(journal)
        LabeledContent("Closed entries", value: "\(m.closedEntries)")
        LabeledContent("Calibration err", value: String(format: "%.3f", Metrics.calibrationError(m)))
        LabeledContent("Avg CLV", value: String(format: "%+.2f%%", m.avgCLV * 100))
        LabeledContent("Brier", value: String(format: "%.3f", m.brier))
      }
      Section("Market / Referee / Lineup") {
        Text("Referee и Lineup доступны через /Ls/GameInfo и /Games/{id}. Проверки включаются автоматически при анализе матча.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Пул лиг") {
        ForEach(LeaguePool.pool, id: \.id) { lg in
          Text("\(lg.id) · \(lg.name)").font(.subheadline)
        }
      }
      Section("Принципы") {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET").font(.subheadline).bold()
        Text("Quarter Kelly · max 2% · S BET до 2.5%")
          .font(.caption).foregroundStyle(.secondary)
        Text("Portfolio cap 10% bankroll в день")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !diagnostics.isEmpty {
        Section("Последний запуск") {
          ForEach(diagnostics, id: \.self) { d in
            Text(d).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Контроль")
    .navigationBarTitleDisplayMode(.large)
  }

  private func runChecks() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }

    // API key
    let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    apiKeyState = key.isEmpty ? "пусто" : "задан (\(key.count) симв.)"
    guard !key.isEmpty else {
      apiReachable = "пропущено (нет ключа)"
      return
    }

    // API reachable
    let client = SStatsClient(settings: settings)
    do {
      _ = try await client.listToday()
      apiReachable = "OK"
    } catch {
      apiReachable = "FAIL: \(error.localizedDescription)"
    }

    // Settle
    let result = await JournalService.settleOpenEntries(
      context: context, client: client)
    lastSettleStatus = "закрыто \(result.closed), ошибок \(result.failed)"
  }

  // MARK: - Настройки

  private var settingsView: some View {
    Form {
      Section("SStats API") {
        SecureField("API key", text: $settings.apiKey)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Text("Ключ хранится в Keychain и не попадает в репозиторий.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Автообновление") {
        Toggle("Фоновое обновление", isOn: $settings.autoRefresh)
        Stepper("Интервал: \(settings.refreshMinutes) мин",
                value: $settings.refreshMinutes, in: 15...120, step: 15)
      }
      Section("Параметры модели") {
        Stepper("История: \(settings.historyMatches) матчей",
                value: $settings.historyMatches, in: 6...20)
        Stepper("Матчей в сканере: \(settings.scanMatches)",
                value: $settings.scanMatches, in: 5...30)
      }
      Section("Принцип") {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET").bold()
      }
      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .navigationTitle("Настройки")
    .navigationBarTitleDisplayMode(.large)
  }

  // MARK: - Refresh

  private func refresh() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    diagnostics = []
    do {
      guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw APIError.missingAPIKey }
      status = "Получаю сегодняшние матчи…"
      let client = SStatsClient(settings: settings)
      let engine = QuantEngine()
      var all = engine.matches(from: try await client.listToday())
        .filter { !isExcluded($0) }
      if selectedLeague != "Все" {
        all = all.filter {
          $0.league.localizedCaseInsensitiveContains(selectedLeague)
        }
      }
      let matches = all.prefix(settings.scanMatches)

      var signalsOut: [BetSignal] = []
      for match in matches {
        guard let h = match.homeID, let a = match.awayID else { continue }
        status = "Анализ \(match.home) — \(match.away)…"
        let hs = await client.fetchTeamHistory(
          teamID: h, count: settings.historyMatches)
        let awayRecords = await client.fetchTeamHistory(
          teamID: a, count: settings.historyMatches)
        let info = try await client.gameInfo(match.id)
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
        diagnostics.append(
          "\(match.id) hist=\(hs.count)/\(awayRecords.count) sig=\(s.count)")
      }
      signals = engine.portfolio(signalsOut)
      lastRefresh = Date()
      status = "Обновлено · \(signals.count) сигналов"
      if settings.notifyBets && !signals.isEmpty {
        await NotificationService.notify(signals: signals)
      }
    } catch {
      status = error.localizedDescription
      diagnostics.append("ERROR: \(error.localizedDescription)")
    }
  }

  // MARK: - Settle Journal

  private func settleJournal() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }

    guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      lastSettleStatus = "API key не задан"
      return
    }

    let client = SStatsClient(settings: settings)
    lastSettleStatus = "Обновляю…"
    let result = await JournalService.settleOpenEntries(
      context: context, client: client)
    lastSettleStatus = "Закрыто \(result.closed), ошибок \(result.failed)"
  }

  // MARK: - Backtest

  private func runBacktest() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }

    var lines: [String] = []
    func log(_ s: String) {
      lines.append(s)
      backtestStatus = lines.joined(separator: "\n")
      print("[BT] \(s)")
    }

    do {
      guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw APIError.missingAPIKey }
      let client = SStatsClient(settings: settings)
      let engine = QuantEngine()

      let toDate = Date()
      let fromDate = Calendar.current.date(byAdding: .day, value: -45, to: toDate) ?? toDate
      log("1) /Games/list \(Self.fmt(fromDate))…\(Self.fmt(toDate))")

      var json: JSONValue
      do {
        json = try await client.listGamesRange(from: fromDate, to: toDate, limit: 1000)
      } catch {
        log("1) /Games/list упал (\(error.localizedDescription)), беру /Ls/List…")
        json = try await client.listRange(from: fromDate, to: toDate, limit: 1000)
      }

      var matches = engine.matches(from: json).filter { !isExcluded($0) }
      log("1) Матчей: \(matches.count)")

      if selectedLeague != "Все" {
        matches = matches.filter {
          $0.league.localizedCaseInsensitiveContains(selectedLeague)
        }
        log("1) После фильтра: \(matches.count)")
      }

      matches = matches.filter { $0.homeFT != nil && $0.awayFT != nil }
      log("1) С FT: \(matches.count)")

      let inline = matches.filter { ($0.oddsJSON?.array?.isEmpty == false) }
      log("1) С odds: \(inline.count)")

      let needFetch = matches.filter { ($0.oddsJSON?.array?.isEmpty != false) }
      let cap = min(needFetch.count, 80)
      log("2) /Odds для \(cap) матчей…")
      var prepared: [Match] = inline
      for (i, m) in needFetch.prefix(cap).enumerated() {
        var mm = m
        if let nid = mm.numericID {
          if i % 10 == 0 { log("2) \(i + 1)/\(cap)…") }
          if let o = try? await client.odds(numericID: nid) {
            mm.oddsJSON = o.object?["data"]
          }
          try? await Task.sleep(for: .milliseconds(700))
        }
        if mm.oddsJSON?.array?.isEmpty == false { prepared.append(mm) }
      }
      log("2) С odds итого: \(prepared.count)")

      guard !prepared.isEmpty else {
        log("Стоп: нет odds")
        return
      }

      let histories = engine.allRecords(from: json)
      log("3) Команд: \(histories.count)")

      log("4) Walk-forward…")
      let result = WalkForwardBacktester().run(matches: prepared, histories: histories)

      context.insert(
        BacktestRun(
          matches: result.matches, bets: result.bets,
          wins: result.wins, losses: result.losses, pushes: result.pushes,
          profit: result.profit, staked: result.staked, roi: result.roi,
          yieldPct: result.yieldPct, hitRate: result.hitRate,
          maxDrawdown: result.maxDrawdown,
          maxLosingStreak: result.maxLosingStreak,
          sharpe: result.sharpe, brier: result.brier,
          logLoss: result.logLoss, avgCLV: result.avgCLV))
      try? context.save()

      log("--- Итог ---")
      log("Matches: \(result.matches)")
      log("Bets: \(result.bets)")
      log("W/L/P: \(result.wins)/\(result.losses)/\(result.pushes)")
      log("ROI: \(String(format: "%+.2f%%", result.roi * 100))")
      log("Yield: \(String(format: "%+.2f%%", result.yieldPct * 100))")
      log("Hit: \(String(format: "%.1f%%", result.hitRate * 100))")
      log("DD: \(String(format: "%.3f", result.maxDrawdown))")
      log("Sharpe: \(String(format: "%.2f", result.sharpe))")
      log("Brier: \(String(format: "%.3f", result.brier))")
      log("LogLoss: \(String(format: "%.3f", result.logLoss))")
      if !result.perLeague.isEmpty {
        log("--- Лиги ---")
        for (lg, s) in result.perLeague
          .sorted(by: { $0.value.bets > $1.value.bets }).prefix(5) {
          log("\(lg): \(s.bets)b, \(String(format: "%+.1f%%", s.roi * 100))")
        }
      }
      if !result.perMarket.isEmpty {
        log("--- Рынки ---")
        for (mk, s) in result.perMarket
          .sorted(by: { $0.value.bets > $1.value.bets }) {
          log("\(mk): \(s.bets)b, \(String(format: "%+.1f%%", s.roi * 100))")
        }
      }
    } catch {
      log("ERROR: \(error.localizedDescription)")
    }
  }

  private static func fmt(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(secondsFromGMT: 3 * 3600)
    return f.string(from: d)
  }

  private func isExcluded(_ m: Match) -> Bool {
    let x = "\(m.league) \(m.home) \(m.away)".lowercased()
    let bad = ["friendly", "women", "женщ", "u19 women", "u20 women"]
    return bad.contains(where: x.contains)
  }
}

// MARK: - SignalCard

struct SignalCard: View {
  let signal: BetSignal

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text("\(signal.home) — \(signal.away)").font(.headline)
        Spacer(minLength: 8)
        Text(signal.classification).font(.caption.bold())
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(classificationColor(signal.classification).opacity(0.25))
          .clipShape(Capsule())
      }
      Text(marketLine)
        .font(.subheadline).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 14) {
        metric("Odds", signal.odds, "%.2f")
        metric("P", signal.probability * 100, "%.1f%%")
        metric("EV", signal.ev * 100, "%+.1f%%")
        metric("Rob.", signal.robustEV * 100, "%+.1f%%")
        metric("QCS", signal.qcs, "%.0f")
        metric("Stake", signal.stake * 100, "%.2f%%")
      }
      HStack(spacing: 10) {
        Text("DCS \(String(format: "%.0f", signal.dcs))")
        Text("MS \(String(format: "%.0f", signal.ms))")
        Text("Sample \(signal.sampleClass)")
        Text("\(signal.bookmakers)b")
      }
      .font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
  }

  private var marketLine: String {
    let linePart: String
    if let line = signal.line {
      linePart = " \(line)"
    } else {
      linePart = ""
    }
    return "\(signal.league) · \(signal.market) · \(signal.selection)\(linePart)"
  }

  private func classificationColor(_ c: String) -> Color {
    switch c {
    case "S BET": return .green
    case "A BET": return .blue
    case "B LEAN": return .yellow
    case "C WATCH": return .orange
    default: return .gray
    }
  }

  private func metric(_ n: String, _ v: Double, _ f: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(n).font(.caption2).foregroundStyle(.secondary)
      Text(String(format: f, v)).font(.caption.monospacedDigit())
    }
  }
}