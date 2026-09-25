import Charts
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
      NavigationStack { autoView }
        .tabItem { Label("Авто", systemImage: "gearshape.2") }
      NavigationStack { diagnosticsView }
        .tabItem { Label("Контроль", systemImage: "checkmark.shield") }
      NavigationStack { settingsView }
        .tabItem { Label("Настройки", systemImage: "gearshape") }
    }
    .tint(.blue)
    .task { await refresh() }
  }

  // MARK: - Прогноз (A5: NavigationLink → SignalDetailView)

  private var forecast: some View {
    List {
      Section {
        HStack {
          Text(status).font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
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
          NavigationLink {
            SignalDetailView(signal: s)
              .onAppear { autoJournal(s) }
          } label: {
            SignalCard(signal: s)
          }
        }
      }

      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .contentMargins(.top, 4, for: .scrollContent)
    .navigationTitle("SYNDICATE QUANT")
    .navigationBarTitleDisplayMode(.large)
    .refreshable { await refresh() }
  }

  /// Первое открытие карточки сигнала → запись в журнал.
  private func autoJournal(_ s: BetSignal) {
    if !journal.contains(where: { $0.id == s.id }) {
      context.insert(JournalEntry(signal: s))
      try? context.save()
    }
  }

  // MARK: - Журнал (A2: Equity chart, A3: movement)

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
        equitySection
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

  @ViewBuilder
  private var equitySection: some View {
    let curve = Metrics.equityCurve(journal)
    Section("Equity curve") {
      if curve.count < 2 {
        Text("Нужно минимум 2 закрытые записи")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Chart {
          ForEach(curve) { p in
            AreaMark(
              x: .value("Дата", p.date),
              y: .value("P/L", p.cumulativeProfit)
            )
            .foregroundStyle(.blue.opacity(0.15))
            LineMark(
              x: .value("Дата", p.date),
              y: .value("P/L", p.cumulativeProfit)
            )
            .foregroundStyle(.blue)
          }
        }
        .frame(height: 180)
        HStack {
          Text("Точек: \(curve.count)")
          Spacer()
          if let last = curve.last {
            Text(String(format: "Итог: %+.3f", last.cumulativeProfit))
              .foregroundStyle(last.cumulativeProfit >= 0 ? .green : .red)
          }
        }
        .font(.caption)
      }
    }
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
        if let mv = e.movement {
          Text("Δ \(String(format: "%+.2f%%", mv * 100))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(mv > 0 ? .green : .red)
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

  // MARK: - Backtest (A7: ROI heatmap лиг)

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
      leagueHeatmapSection
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

  @ViewBuilder
  private var leagueHeatmapSection: some View {
    let cells = leagueROICells
    Section("Лиги — ROI heatmap") {
      if cells.isEmpty {
        Text("Закрытых записей журнала пока нет")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("ROI по закрытым записям журнала, сгруппированным по лиге.")
          .font(.caption2).foregroundStyle(.secondary)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
          spacing: 8
        ) {
          ForEach(cells) { c in
            VStack(spacing: 3) {
              Text(c.league)
                .font(.caption2).lineLimit(2)
                .multilineTextAlignment(.center)
              Text(String(format: "%+.1f%%", c.roi * 100))
                .font(.caption.monospacedDigit().bold())
              Text("n=\(c.bets)")
                .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .padding(6)
            .background(c.color.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  private var leagueROICells: [LeagueROICell] {
    let closed = journal.filter { $0.status == "CLOSED" }
    let grouped = Dictionary(grouping: closed, by: { $0.league })
    return grouped.map { (lg, entries) in
      let stake = entries.reduce(0.0) { $0 + $1.stake }
      let profit = entries.reduce(0.0) { $0 + ($1.profit ?? 0) }
      let roi = stake > 0 ? profit / stake : 0
      return LeagueROICell(id: lg, league: lg, bets: entries.count, roi: roi)
    }.sorted { $0.bets > $1.bets }
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

  // MARK: - Авто (A8: заглушка под Волну G)

  private var autoView: some View {
    List {
      Section {
        Text("Волна G — Backtest Service")
          .font(.headline)
        Text("Приложение само собирает базу за 2 года × 8 лиг и обновляет её по воскресеньям в фоне. Результаты используются для авто-отключения «мёртвых» комбинаций (лига+рынок) и корректировки порогов.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("В работе (Волна G)") {
        Label("BacktestSnapshot @Model", systemImage: "cylinder")
        Label("buildFullBase (2 года, прогресс, возобновление)", systemImage: "arrow.down.circle")
        Label("updateIncremental (докачка за неделю)", systemImage: "arrow.triangle.2.circlepath")
        Label("BGProcessingTask по воскресеньям", systemImage: "moon.zzz")
        Label("Замена Backtest на Авто", systemImage: "arrow.left.arrow.right")
        Label("Auto-Exclude при ROI < −5% (n≥20)", systemImage: "xmark.octagon")
        Label("Posterior buckets (fact hit rate)", systemImage: "chart.bar.xaxis")
      }

      Section("Дальше") {
        Label("Волна B — Model Ensemble, Elo/Glicko, Bayesian posterior", systemImage: "function")
        Label("Волна F — Self-Tuning UI", systemImage: "slider.horizontal.3")
        Label("Волна C — UX и визуализация", systemImage: "paintbrush")
        Label("Волна D — Live odds, Sharp money, voting", systemImage: "bolt")
      }

      Section("Статус") {
        LabeledContent("Снапшот", value: "не собран")
        LabeledContent("Последнее обновление", value: "—")
      }

      Section("Принцип") {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET")
          .font(.subheadline).bold()
      }

      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Авто")
    .navigationBarTitleDisplayMode(.large)
  }

  // MARK: - Контроль (A4: LeagueBaselines)

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
      Section("Sample / Consensus") {
        let m = Metrics.compute(journal)
        LabeledContent("Closed entries", value: "\(m.closedEntries)")
        LabeledContent("Calibration err", value: String(format: "%.3f", Metrics.calibrationError(m)))
        LabeledContent("Avg CLV", value: String(format: "%+.2f%%", m.avgCLV * 100))
        LabeledContent("Brier", value: String(format: "%.3f", m.brier))
      }
      Section("Пул лиг") {
        ForEach(LeaguePool.pool, id: \.id) { lg in
          Text("\(lg.id) · \(lg.name)").font(.subheadline)
        }
      }
      Section("League baselines (prior)") {
        Text("Структурные приоритеты. sampleSize=0 → prior, не измеренные данные. Волна G заменит на фактические.")
          .font(.caption2).foregroundStyle(.secondary)
        ForEach(LeagueBaselines.all) { b in
          VStack(alignment: .leading, spacing: 4) {
            Text(b.name).font(.subheadline).bold()
            HStack(spacing: 12) {
              miniBlock("λH", String(format: "%.2f", b.homeLambda))
              miniBlock("λA", String(format: "%.2f", b.awayLambda))
              miniBlock("Adv", String(format: "%.2f", b.homeAdvantage))
              miniBlock("ρ", String(format: "%+.2f", b.rho))
            }
          }
          .padding(.vertical, 2)
        }
      }
      Section("Принципы") {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET").font(.subheadline).bold()
        Text("Quarter Kelly · max 2% · S BET до 2.5%")
          .font(.caption).foregroundStyle(.secondary)
        Text("Portfolio cap 10% bankroll в день")
          .font(.caption).foregroundStyle(.secondary)
        Text("Background refresh: BGAppRefreshTask, интервал ≥ 30 мин")
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

    let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    apiKeyState = key.isEmpty ? "пусто" : "задан (\(key.count) симв.)"
    guard !key.isEmpty else {
      apiReachable = "пропущено (нет ключа)"
      return
    }

    let client = SStatsClient(settings: settings)
    do {
      _ = try await client.listToday()
      apiReachable = "OK"
    } catch {
      apiReachable = "FAIL: \(error.localizedDescription)"
    }

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
        Text("iOS сама решает, когда запускать фон (обычно ≥30 мин).")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Section("Параметры модели") {
        Stepper("История: \(settings.historyMatches) матчей",
                value: $settings.historyMatches, in: 6...20)
        Stepper("Матчей в сканере: \(settings.scanMatches)",
                value: $settings.scanMatches, in: 5...30)
      }
      Section("Уведомления") {
        Toggle("Уведомлять при S/A BET", isOn: $settings.notifyBets)
        Button {
          NotificationService.resetDedupe()
        } label: {
          Label("Сбросить дубликаты", systemImage: "arrow.counterclockwise")
        }
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
    status = "Сканирую…"

    let summary = await ScanCoordinator.shared.scan(
      settings: settings, selectedLeague: selectedLeague)

    signals = summary.signals
    lastRefresh = summary.finishedAt
    if summary.success {
      status = "Обновлено · \(signals.count) сигналов"
    } else {
      status = summary.notes.first ?? "Ошибка"
    }
    for n in summary.notes { diagnostics.append(n) }
    diagnostics.append("scanned=\(summary.scannedMatches)")
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

  // MARK: - Backtest (без изменений)

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
      let report = WalkForwardBacktester().run(
        matches: prepared, histories: histories)

      context.insert(
        BacktestRun(
          matches: report.matches, bets: report.bets,
          wins: report.wins, losses: report.losses, pushes: report.pushes,
          profit: report.profit, staked: report.staked, roi: report.roi,
          yieldPct: report.yieldPct, hitRate: report.hitRate,
          maxDrawdown: report.maxDrawdown,
          maxLosingStreak: report.maxLosingStreak,
          sharpe: report.sharpe, brier: report.brier,
          logLoss: report.logLoss, avgCLV: report.avgCLV))
      try? context.save()

      log("--- Итог ---")
      log("Matches: \(report.matches)")
      log("Bets: \(report.bets)")
      log("W/L/P: \(report.wins)/\(report.losses)/\(report.pushes)")
      log("Hit: \(String(format: "%.1f%%", report.hitRate * 100))")
      log("ROI: \(String(format: "%+.2f%%", report.roi * 100))")
      log("Yield: \(String(format: "%+.2f%%", report.yieldPct * 100))")
      log("Profit: \(String(format: "%+.3f", report.profit))")
      log("Avg odds: \(String(format: "%.2f", report.avgOdds))")
      log("Expectancy: \(String(format: "%+.3f", report.expectancy))")

      log("--- Риск ---")
      log("Max DD: \(String(format: "%.3f", report.maxDrawdown))")
      log("Max loss streak: \(report.maxLosingStreak)")
      log("Sharpe: \(String(format: "%.2f", report.sharpe))")
      log("Sortino: \(String(format: "%.2f", report.sortino))")
      log("Profit Factor: \(String(format: "%.2f", report.profitFactor))")

      log("--- Качество прогноза ---")
      log("Brier: \(String(format: "%.3f", report.brier))")
      log("LogLoss: \(String(format: "%.3f", report.logLoss))")
      log("Avg CLV: \(String(format: "%+.2f%%", report.avgCLV * 100))")

      logSection("EV buckets", log: log, dict: report.byEVBucket)
      logSection("Classification", log: log, dict: report.byClassification)
      logSection("Odds bands", log: log, dict: report.byOddsBand)

      log("--- Лиги ---")
      let topLeagues = report.perLeague
        .sorted(by: { $0.value.bets > $1.value.bets })
        .prefix(5)
      for (lg, s) in topLeagues {
        log("\(lg): \(s.bets)b, ROI \(String(format: "%+.1f%%", s.roi * 100)), hit \(String(format: "%.0f%%", s.hitRate * 100))")
      }

      log("--- Рынки ---")
      for (mk, s) in report.perMarket.sorted(by: { $0.value.bets > $1.value.bets }) {
        log("\(mk): \(s.bets)b, ROI \(String(format: "%+.1f%%", s.roi * 100))")
      }

      log("--- По неделям ---")
      let weeksSorted = report.byWeek.sorted(by: { $0.key < $1.key })
      for (wk, s) in weeksSorted {
        log("\(wk): \(s.bets)b, ROI \(String(format: "%+.1f%%", s.roi * 100))")
      }
    } catch {
      log("ERROR: \(error.localizedDescription)")
    }
  }

  private func logSection(
    _ title: String,
    log: (String) -> Void,
    dict: [String: SegmentStats]
  ) {
    guard !dict.isEmpty else { return }
    log("--- \(title) ---")
    for (k, s) in dict.sorted(by: { $0.value.bets > $1.value.bets }) {
      log("\(k): \(s.bets)b, ROI \(String(format: "%+.1f%%", s.roi * 100)), hit \(String(format: "%.0f%%", s.hitRate * 100))")
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

// MARK: - LeagueROICell (для heatmap)

struct LeagueROICell: Identifiable {
  let id: String
  let league: String
  let bets: Int
  let roi: Double

  var color: Color {
    if bets < 5 { return .gray }
    if roi >= 0.10 { return .green }
    if roi >= 0.02 { return Color.green.opacity(0.7) }
    if roi > -0.02 { return .yellow }
    if roi > -0.10 { return .orange }
    return .red
  }
}

// MARK: - SignalCard

struct SignalCard: View {
  let signal: BetSignal

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text("\(signal.home) — \(signal.away)").font(.headline)
          .fixedSize(horizontal: false, vertical: true)
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

// MARK: - SignalDetailView (Волна A, A5)

struct SignalDetailView: View {
  let signal: BetSignal

  var body: some View {
    List {
      Section("Матч") {
        LabeledContent("Хозяева", value: signal.home)
        LabeledContent("Гости", value: signal.away)
        LabeledContent("Лига", value: signal.league)
        LabeledContent("Рынок", value: signal.market)
        LabeledContent("Выбор", value: selectionLine)
      }

      Section("Классификация") {
        HStack {
          Text("Класс").font(.subheadline)
          Spacer()
          Text(signal.classification)
            .font(.subheadline.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(classColor.opacity(0.22))
            .clipShape(Capsule())
        }
        LabeledContent("Модель", value: signal.model)
        LabeledContent("Букмекеров", value: "\(signal.bookmakers)")
        if signal.priceAnomaly {
          Label("Аномальная цена (flag)", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange).font(.caption)
        }
      }

      Section("Цена и вероятность") {
        LabeledContent("Odds", value: String(format: "%.3f", signal.odds))
        LabeledContent("Fair odds",
                       value: String(format: "%.3f", signal.fairOdds))
        LabeledContent("P (модель)",
                       value: String(format: "%.2f%%", signal.probability * 100))
        LabeledContent("P (рынок)",
                       value: String(format: "%.2f%%", signal.marketProbability * 100))
        LabeledContent("EV",
                       value: String(format: "%+.2f%%", signal.ev * 100))
        LabeledContent("Robust EV",
                       value: String(format: "%+.2f%%", signal.robustEV * 100))
      }

      Section("Интервал неопределённости") {
        HStack {
          intervalBlock("P10",
                        String(format: "%.1f%%", signal.probabilityLow * 100))
          intervalBlock("P50",
                        String(format: "%.1f%%", signal.probability * 100))
          intervalBlock("P90",
                        String(format: "%.1f%%", signal.probabilityHigh * 100))
        }
        LabeledContent("Uncertainty",
                       value: String(format: "%.3f", signal.uncertainty))
        LabeledContent("Band", value: signal.uncertaintyBand)
        LabeledContent("Market MAD",
                       value: String(format: "%.2f", signal.marketMAD))
      }

      Section("Компоненты QCS") {
        Text("QCS = 0.30·MES + 0.20·DCS + 0.20·MS + 0.15·TS + 0.15·RS")
          .font(.caption2).foregroundStyle(.secondary)
        scoreRow("DCS", signal.dcs, w: "0.20")
        scoreRow("MS",  signal.ms,  w: "0.20")
        scoreRow("MES", signal.mes, w: "0.30")
        scoreRow("TS",  signal.ts,  w: "0.15")
        scoreRow("RS",  signal.rs,  w: "0.15")
        HStack {
          Text("QCS").font(.subheadline.bold())
          Spacer()
          Text(String(format: "%.1f", signal.qcs))
            .font(.subheadline.monospacedDigit().bold())
        }
      }

      Section("Sample") {
        LabeledContent("Класс", value: signal.sampleClass)
        LabeledContent("Матчей хозяев", value: "\(signal.homeSample)")
        LabeledContent("Матчей гостей", value: "\(signal.awaySample)")
      }

      Section("Kelly / Stake") {
        LabeledContent("Full Kelly",
                       value: String(format: "%.2f%%", signal.kellyFraction * 100))
        LabeledContent("Quarter Kelly",
                       value: String(format: "%.2f%%", signal.quarterKelly * 100))
        LabeledContent("Stake cap",
                       value: String(format: "%.2f%%", signal.stakeCap * 100))
        HStack {
          Text("Stake").font(.subheadline.bold())
          Spacer()
          Text(String(format: "%.3f%%", signal.stake * 100))
            .font(.subheadline.monospacedDigit().bold())
        }
      }

      if signal.portfolioCorrelation > 0 {
        Section("Портфель") {
          LabeledContent("Макс. корреляция",
                         value: String(format: "%.2f", signal.portfolioCorrelation))
          LabeledContent("Причина", value: signal.correlationReason)
        }
      }

      Section("Идентификаторы") {
        LabeledContent("Game ID", value: signal.gameID)
        LabeledContent("Signal ID", value: signal.id)
        LabeledContent("Timestamp",
                       value: signal.timestamp.formatted(date: .abbreviated, time: .standard))
      }

      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Разбор сигнала")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var selectionLine: String {
    if let line = signal.line {
      return "\(signal.selection) \(line)"
    }
    return signal.selection
  }

  private var classColor: Color {
    switch signal.classification {
    case "S BET": return .green
    case "A BET": return .blue
    case "B LEAN": return .yellow
    case "C WATCH": return .orange
    default: return .gray
    }
  }

  private func intervalBlock(_ label: String, _ value: String) -> some View {
    VStack(spacing: 2) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.subheadline.monospacedDigit())
    }.frame(maxWidth: .infinity)
  }

  private func scoreRow(_ name: String, _ value: Double, w: String) -> some View {
    HStack {
      Text(name).font(.subheadline)
      Text("· w=\(w)").font(.caption2).foregroundStyle(.secondary)
      Spacer()
      Text(String(format: "%.1f", value))
        .font(.subheadline.monospacedDigit())
    }
  }
}