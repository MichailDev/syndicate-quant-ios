import Charts
import SwiftData
import SwiftUI

struct RootView: View {
  @EnvironmentObject var settings: AppSettings
  @Environment(\.modelContext) private var context
  @Query(sort: \JournalEntry.createdAt, order: .reverse) private var journal: [JournalEntry]
  @Query private var snapshots: [BacktestSnapshot]
  @Query(sort: \TeamRating.rating, order: .reverse) private var teamRatings: [TeamRating]

  @State private var signals: [BetSignal] = []
  @State private var status = "Готов"
  @State private var busy = false
  @State private var lastRefresh: Date?
  @State private var diagnostics: [String] = []
  @State private var selectedLeague: String = "Все"

  @State private var apiReachable: String = "—"
  @State private var apiKeyState: String = "—"
  @State private var lastSettleStatus: String = "—"

  @State private var btProgressText = ""

  private var currentSnapshot: BacktestSnapshot? { snapshots.first }

  private var correlationMatrix: CorrelationMatrix {
    CorrelationBuilder.build(from: journal)
  }

  var body: some View {
    TabView {
      NavigationStack { forecast }
        .tabItem { Label("Прогноз", systemImage: "sparkles") }
      NavigationStack { journalView }
        .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
      NavigationStack { autoView }
        .tabItem { Label("Авто", systemImage: "gearshape.2") }
      NavigationStack { diagnosticsView }
        .tabItem { Label("Контроль", systemImage: "checkmark.shield") }
      NavigationStack { settingsView }
        .tabItem { Label("Настройки", systemImage: "gearshape") }
    }
    .tint(.blue)
    .task {
      _ = BacktestService.fetchOrCreate(in: context)
      await refresh()
    }
  }

  // MARK: - Прогноз

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

  private func autoJournal(_ s: BetSignal) {
    if !journal.contains(where: { $0.id == s.id }) {
      context.insert(JournalEntry(signal: s))
      try? context.save()
    }
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

  // MARK: - Авто

  private var autoView: some View {
    List {
      Section {
        Text("Backtest Service").font(.headline)
        Text("Auto-Exclude, posterior (B2), TeamRating (B3), корреляция (B4), stop-loss (B5) и player impact (B6) — всё это опирается на данные отсюда и из журнала.")
          .font(.caption).foregroundStyle(.secondary)
      }

      volatilitySection
      correlationSection
      playerImpactSection

      if let snap = currentSnapshot {
        Section("Статус") {
          LabeledContent("Состояние", value: snap.buildStatus)
          ProgressView(value: snap.buildProgress)
          LabeledContent("Прогресс",
                         value: String(format: "%.1f%%", snap.buildProgress * 100))
          if let f = snap.fromDate, let t = snap.toDate {
            LabeledContent("Период",
                           value: "\(Self.shortDate(f)) – \(Self.shortDate(t))")
          }
          if let b = snap.builtAt {
            LabeledContent("Собран",
                           value: b.formatted(date: .abbreviated, time: .shortened))
          }
          LabeledContent("Матчей", value: "\(snap.totalMatches)")
          LabeledContent("Ставок", value: "\(snap.totalBets)")
          if snap.totalBets > 0 {
            LabeledContent("avgROI",
                           value: String(format: "%+.2f%%", snap.avgROI * 100))
            LabeledContent("Sharpe",
                           value: String(format: "%.2f", snap.sharpe))
            LabeledContent("Sortino",
                           value: String(format: "%.2f", snap.sortino))
            LabeledContent("Profit Factor",
                           value: String(format: "%.2f", snap.profitFactor))
            LabeledContent("Brier",
                           value: String(format: "%.3f", snap.brier))
            LabeledContent("avgCLV",
                           value: String(format: "%+.2f%%", snap.avgCLV * 100))
          }
          if let err = snap.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
          }
        }
      }

      Section("Действия") {
        Button {
          Task { await runFullBuild() }
        } label: {
          Label("Собрать базу (2 года × 8 лиг)",
                systemImage: "arrow.down.circle")
        }
        .disabled(busy || currentSnapshot?.buildStatus == "building")

        Button {
          Task { await runIncremental() }
        } label: {
          Label("Докачать за неделю",
                systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(busy || currentSnapshot?.buildStatus != "ready")

        if !btProgressText.isEmpty {
          Text(btProgressText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }

      if let snap = currentSnapshot {
        autoExcludeSection(snap)
        posteriorSection(snap)
        leagueSection(snap)
        marketSection(snap)
        evSection(snap)
        oddsSection(snap)
        classSection(snap)
      }

      teamRatingsSection

      Section("Задачи Волны B") {
        Label("B1 Model Ensemble (DC+BIV+NB)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Label("B2 Bayesian posterior", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Label("B3 Elo team strength", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Label("B4 Correlation matrix", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Label("B5 Volatility stop-loss", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Label("B6 Player impact в λ", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
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

  @ViewBuilder
  private var volatilitySection: some View {
    let ev = VolatilityStop.evaluate(journal)
    Section("Volatility stop (B5)") {
      LabeledContent("Текущая серия", value: "\(ev.streak)")
      LabeledContent("Состояние", value: ev.state.label)
      switch ev.state {
      case .normal:
        Text("Работаем в штатном режиме.")
          .font(.caption).foregroundStyle(.secondary)
      case .cap(let v):
        Text("После \(VolatilityStop.capThreshold) проигрышей подряд — стейк ограничен \(Int(v * 100))%.")
          .font(.caption).foregroundStyle(.orange)
      case .pause:
        Text("После \(VolatilityStop.pauseThreshold) проигрышей подряд — новые ставки не создаются.")
          .font(.caption).foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private var correlationSection: some View {
    let m = correlationMatrix
    Section("Correlation matrix (B4)") {
      if m.totalPairs == 0 {
        Text("Нужно ≥ 20 пар закрытых записей в одном дне для эмпирики. Пока используются структурные значения.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        LabeledContent("Пар в журнале", value: "\(m.totalPairs)")
        LabeledContent("Market-пар (n≥20)", value: "\(m.marketPairsN.count)")
        LabeledContent("League-пар (n≥20)", value: "\(m.leaguePairsN.count)")
        if !m.marketPairs.isEmpty {
          Text("Сильнейшие market-связи:").font(.caption2).foregroundStyle(.secondary)
          let topM = m.marketPairs
            .filter { abs($0.value) > 0.001 }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(5)
          ForEach(Array(topM), id: \.key) { (k, v) in
            HStack {
              Text(k).font(.caption.monospacedDigit())
              Spacer()
              Text(String(format: "%+.2f", v))
                .font(.caption.monospacedDigit())
                .foregroundStyle(v > 0 ? .green : .red)
              if let n = m.marketPairsN[k] {
                Text("n=\(n)")
                  .font(.caption2).foregroundStyle(.secondary)
                  .frame(width: 52, alignment: .trailing)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var playerImpactSection: some View {
    Section("Player impact (B6)") {
      Text("Применяется, когда в gameInfo есть состав (lineups) и у команды ≥ 6 игроков в истории. Отсутствие топ-8 → −5…−12% к λ.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Статус: ожидание данных от API. Ключи, которые пробуются: lineups, homeLineup/awayLineup, homePlayers/awayPlayers.")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var teamRatingsSection: some View {
    let top = Array(teamRatings.prefix(20))
    if !top.isEmpty {
      Section("Team ratings (B3)") {
        Text("Elo, старт 1500, HFA 60, K=32→20. Применяются после 3 матчей.")
          .font(.caption2).foregroundStyle(.secondary)
        ForEach(top) { r in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(r.name.isEmpty ? r.teamID : r.name).font(.subheadline)
              Text("n=\(r.matches)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.0f", r.rating))
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.primary)
            if r.lastDelta != 0 {
              Text(String(format: "%+.0f", r.lastDelta))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(r.lastDelta > 0 ? .green : .red)
                .frame(width: 44, alignment: .trailing)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func autoExcludeSection(_ snap: BacktestSnapshot) -> some View {
    let rules = AutoExclude.rules(from: snap)
    let excluded = rules.filter { $0.excluded }
    Section("Auto-Exclude (ROI < −5%, n≥20)") {
      if rules.isEmpty {
        Text("Нет данных по лига+рынок (соберите базу)")
          .font(.caption).foregroundStyle(.secondary)
      } else if excluded.isEmpty {
        Text("Пока не исключено ни одной комбинации")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("\(excluded.count) комбинаций будут отфильтрованы в сканере")
          .font(.caption2).foregroundStyle(.secondary)
        ForEach(excluded) { r in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("\(r.league) · \(r.market)").font(.subheadline)
              Text("n=\(r.bets)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%+.1f%%", r.roi * 100))
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.red)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func posteriorSection(_ snap: BacktestSnapshot) -> some View {
    let buckets = snap.decodedPosteriorBuckets()
    let nonEmpty = buckets.filter { $0.n > 0 }
    let usable = nonEmpty.filter { $0.n >= 20 }.count
    Section("Posterior buckets (B2)") {
      if nonEmpty.isEmpty {
        Text("Нет данных (соберите базу)")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Применяются бакеты с n ≥ 20. Сейчас: \(usable) из \(nonEmpty.count)")
          .font(.caption2).foregroundStyle(.secondary)
        ForEach(nonEmpty) { b in
          HStack {
            Text(String(format: "P %.0f–%.0f%%",
                        b.probabilityLow * 100, b.probabilityHigh * 100))
              .font(.caption.monospacedDigit())
            Spacer()
            Text(String(format: "act %.0f%%", b.factHitRate * 100))
              .font(.caption.monospacedDigit())
              .foregroundStyle(b.n >= 20 ? .primary : .secondary)
            Text("n=\(b.n)")
              .font(.caption2).foregroundStyle(.secondary)
              .frame(width: 52, alignment: .trailing)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func leagueSection(_ snap: BacktestSnapshot) -> some View {
    let stats = snap.decodedLeagueStats()
    if !stats.isEmpty {
      Section("Лиги (ROI)") {
        ForEach(stats.keys.sorted(), id: \.self) { lg in
          if let s = stats[lg] { segmentRow(name: lg, s: s) }
        }
      }
    }
  }

  @ViewBuilder
  private func marketSection(_ snap: BacktestSnapshot) -> some View {
    let stats = snap.decodedMarketStats()
    if !stats.isEmpty {
      Section("Рынки (ROI)") {
        ForEach(stats.keys.sorted(), id: \.self) { mk in
          if let s = stats[mk] { segmentRow(name: mk, s: s) }
        }
      }
    }
  }

  @ViewBuilder
  private func evSection(_ snap: BacktestSnapshot) -> some View {
    let stats = snap.decodedEVBuckets()
    if !stats.isEmpty {
      Section("EV buckets") {
        ForEach(stats.keys.sorted(), id: \.self) { k in
          if let s = stats[k] { segmentRow(name: k, s: s) }
        }
      }
    }
  }

  @ViewBuilder
  private func oddsSection(_ snap: BacktestSnapshot) -> some View {
    let stats = snap.decodedOddsBuckets()
    if !stats.isEmpty {
      Section("Odds bands") {
        ForEach(stats.keys.sorted(), id: \.self) { k in
          if let s = stats[k] { segmentRow(name: k, s: s) }
        }
      }
    }
  }

  @ViewBuilder
  private func classSection(_ snap: BacktestSnapshot) -> some View {
    let stats = snap.decodedClassification()
    if !stats.isEmpty {
      Section("Классы") {
        ForEach(stats.keys.sorted(), id: \.self) { k in
          if let s = stats[k] { segmentRow(name: k, s: s) }
        }
      }
    }
  }

  private func segmentRow(name: String, s: StoredSegmentStats) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.subheadline)
        Text("n=\(s.bets) · hit \(String(format: "%.0f%%", s.hitRate * 100))")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      Text(String(format: "%+.1f%%", s.roi * 100))
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(s.roi >= 0 ? .green : .red)
    }
  }

  private static func shortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }

  private func runFullBuild() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }

    btProgressText = "Запуск…"
    let ok = await BacktestService.shared.buildFullBase { progress, msg in
      btProgressText = String(format: "%.0f%% · %@", progress * 100, msg)
    }
    btProgressText = ok ? "Готово" : "Ошибка/прервано"
    try? context.save()
  }

  private func runIncremental() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }

    btProgressText = "Докачка…"
    let ok = await BacktestService.shared.updateIncremental()
    btProgressText = ok ? "Докачка завершена" : "Докачка не выполнена"
    try? context.save()
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
      Section("Sample / Consensus") {
        let m = Metrics.compute(journal)
        LabeledContent("Closed entries", value: "\(m.closedEntries)")
        LabeledContent("Calibration err", value: String(format: "%.3f", Metrics.calibrationError(m)))
        LabeledContent("Avg CLV", value: String(format: "%+.2f%%", m.avgCLV * 100))
        LabeledContent("Brier", value: String(format: "%.3f", m.brier))
      }
      Section("Team ratings (B3)") {
        LabeledContent("Всего команд", value: "\(teamRatings.count)")
        let usable = teamRatings.filter { $0.matches >= TeamRatingService.minMatchesForUse }.count
        LabeledContent("С ≥ 3 матчами", value: "\(usable)")
      }
      Section("Volatility stop (B5)") {
        let ev = VolatilityStop.evaluate(journal)
        LabeledContent("Текущая серия", value: "\(ev.streak)")
        LabeledContent("Состояние", value: ev.state.label)
      }
      Section("Correlation (B4)") {
        let m = correlationMatrix
        LabeledContent("Пар в журнале", value: "\(m.totalPairs)")
        LabeledContent("Market-пар (n≥20)", value: "\(m.marketPairsN.count)")
        LabeledContent("League-пар (n≥20)", value: "\(m.leaguePairsN.count)")
      }
      Section("Backtest snapshot") {
        if let snap = currentSnapshot {
          LabeledContent("Status", value: snap.buildStatus)
          LabeledContent("Progress",
                         value: String(format: "%.1f%%", snap.buildProgress * 100))
          LabeledContent("Matches", value: "\(snap.totalMatches)")
          LabeledContent("Bets", value: "\(snap.totalBets)")
          if snap.totalBets > 0 {
            LabeledContent("avgROI",
                           value: String(format: "%+.2f%%", snap.avgROI * 100))
            LabeledContent("Sharpe",
                           value: String(format: "%.2f", snap.sharpe))
          }
          let rules = AutoExclude.rules(from: snap)
          let excludedCount = rules.filter { $0.excluded }.count
          LabeledContent("Auto-Exclude (активных)",
                         value: "\(excludedCount)")
          let buckets = snap.decodedPosteriorBuckets()
          let usableBuckets = buckets.filter { $0.n >= 20 }.count
          LabeledContent("Posterior (n≥20)",
                         value: "\(usableBuckets)")
          if let err = snap.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
          }
        } else {
          Text("Снапшот ещё не создан")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Пул лиг") {
        ForEach(LeaguePool.pool, id: \.id) { lg in
          Text("\(lg.id) · \(lg.name)").font(.subheadline)
        }
      }
      Section("League baselines (prior)") {
        Text("Структурные приоритеты. sampleSize=0 → prior, не измеренные данные.")
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
        Text("Ensemble DC+BIV+NB · posterior 0.15 при n≥20")
          .font(.caption).foregroundStyle(.secondary)
        Text("Stop-loss: ≥4 LOSS → CAP 5%, ≥7 → PAUSE")
          .font(.caption).foregroundStyle(.secondary)
        Text("Empirical correlation (n≥20) · player impact (if lineups)")
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
    diagnostics.append("corrPairs=\(summary.correlationPairs)")
    diagnostics.append("lineups=\(summary.lineupsFound)")
  }

  // MARK: - Settle

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
        if signal.posteriorWeight != nil { Text("PST").foregroundStyle(.purple) }
        if signal.stopApplied != nil { Text("STOP").foregroundStyle(.red) }
        if signal.playerImpactHome != nil || signal.playerImpactAway != nil {
          Text("PLR").foregroundStyle(.orange)
        }
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

// MARK: - SignalDetailView

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
        LabeledContent("P (финальная)",
                       value: String(format: "%.2f%%", signal.probability * 100))
        if let raw = signal.probabilityRaw, raw != signal.probability {
          LabeledContent("P (модель)",
                         value: String(format: "%.2f%%", raw * 100))
        }
        LabeledContent("P (рынок)",
                       value: String(format: "%.2f%%", signal.marketProbability * 100))
        LabeledContent("EV",
                       value: String(format: "%+.2f%%", signal.ev * 100))
        LabeledContent("Robust EV",
                       value: String(format: "%+.2f%%", signal.robustEV * 100))
      }

      if let w = signal.posteriorWeight {
        Section("Posterior correction (B2)") {
          Text("p_adj = (1 − w)·p_model + w·p_posterior")
            .font(.caption2).foregroundStyle(.secondary)
          LabeledContent("Вес w", value: String(format: "%.2f", w))
          if let src = signal.posteriorSource {
            LabeledContent("Бакет", value: src)
          }
          if let raw = signal.probabilityRaw {
            LabeledContent("p_model",
                           value: String(format: "%.2f%%", raw * 100))
            LabeledContent("p_adj",
                           value: String(format: "%.2f%%", signal.probability * 100))
            let delta = (signal.probability - raw) * 100
            LabeledContent("Δ", value: String(format: "%+.2f п.п.", delta))
          }
        }
      }

      if signal.stopApplied != nil {
        Section("Stop-loss (B5)") {
          if let reason = signal.stopApplied {
            LabeledContent("Применено", value: reason)
          }
          if let before = signal.stakeBeforeStop {
            LabeledContent("Стейк был",
                           value: String(format: "%.3f%%", before * 100))
            LabeledContent("Стейк стал",
                           value: String(format: "%.3f%%", signal.stake * 100))
          }
          Text("Серия проигрышей ≥4 → ограничение стейка до 5%. ≥7 → пауза.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }

      if signal.playerImpactHome != nil || signal.playerImpactAway != nil {
        Section("Player impact (B6)") {
          if let hi = signal.playerImpactHome {
            LabeledContent("Дом. λ-множитель",
                           value: String(format: "%.2f", hi))
          }
          if let ai = signal.playerImpactAway {
            LabeledContent("Гост. λ-множитель",
                           value: String(format: "%.2f", ai))
          }
          Text("Сравнение ожидаемого состава с типичным топ-8 команды.")
            .font(.caption2).foregroundStyle(.secondary)
        }
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