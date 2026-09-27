import Charts
import SwiftData
import SwiftUI

private let matchStartFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "dd.MM · HH:mm"
  f.timeZone = .current
  return f
}()

private func formatMatchStart(_ date: Date?) -> String? {
  guard let date else { return nil }
  return matchStartFormatter.string(from: date)
}

private func formatMatchStartLong(_ date: Date?) -> String? {
  guard let date else { return nil }
  let f = DateFormatter()
  f.dateStyle = .medium
  f.timeStyle = .short
  f.timeZone = .current
  return f.string(from: date)
}

struct RootView: View {
  @EnvironmentObject var settings: AppSettings
  @ObservedObject private var liveMonitor = LiveMonitor.shared
  @Environment(\.modelContext) private var context
  @Query(sort: \JournalEntry.createdAt, order: .reverse) private var journal: [JournalEntry]
  @Query private var snapshots: [BacktestSnapshot]
  @Query(sort: \TeamRating.rating, order: .reverse) private var teamRatings: [TeamRating]
  @Query private var tuningConfigs: [TuningConfig]
  @Query(sort: \TuningEvent.createdAt, order: .reverse) private var tuningEvents: [TuningEvent]

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
  @State private var selectedTab: Int = 0
  @State private var pendingSignalID: String?
  @State private var selfTestResults: [QuantMathSelfTest.Check] = []

  private var currentSnapshot: BacktestSnapshot? { snapshots.first }
  private var tuningConfig: TuningConfig? { tuningConfigs.first }
  private var correlationMatrix: CorrelationMatrix {
    CorrelationBuilder.build(from: journal)
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack { forecast }
        .tabItem { Label("Прогноз", systemImage: "sparkles") }.tag(0)
      NavigationStack { journalView }
        .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }.tag(1)
      NavigationStack { autoView }
        .tabItem { Label("Авто", systemImage: "gearshape.2") }.tag(2)
      NavigationStack { diagnosticsView }
        .tabItem { Label("Контроль", systemImage: "checkmark.shield") }.tag(3)
      NavigationStack { settingsView }
        .tabItem { Label("Настройки", systemImage: "gearshape") }.tag(4)
    }
    .tint(.blue)
    .preferredColorScheme(settings.colorScheme.toColorScheme)
    .task {
      _ = BacktestService.fetchOrCreate(in: context)
      _ = TuningService.fetchOrCreate(in: context)
      await refresh()
      if currentSnapshot?.buildStatus == "building",
         BacktestService.hasCheckpoint() {
        await runFullBuild()
      }
    }
    .onChange(of: settings.liveMonitorEnabled) { _, enabled in
      if enabled { liveMonitor.start(settings: settings) }
      else { liveMonitor.stop() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openSignal)) { note in
      if let id = note.userInfo?["signalID"] as? String {
        pendingSignalID = id
        selectedTab = 1
      }
    }
    .sheet(item: Binding<SignalIDWrapper?>(
      get: { pendingSignalID.map(SignalIDWrapper.init) },
      set: { pendingSignalID = $0?.id }
    )) { wrapper in
      NavigationStack {
        if let entry = journal.first(where: { $0.id == wrapper.id }) {
          JournalEntryDetailView(entry: entry)
        } else {
          ContentUnavailableView("Запись не найдена",
            systemImage: "magnifyingglass",
            description: Text("Возможно, сигнал был удалён из журнала."))
        }
      }
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
          ForEach(LeaguePool.pool, id: \.name) { lg in Text(lg.name).tag(lg.name) }
        }
        .pickerStyle(.menu)
        Button { Task { await refresh() } } label: {
          Label("Обновить", systemImage: "arrow.clockwise")
        }
        .disabled(busy)
      } footer: {
        Text("Скан проверяет матчи выбранной лиги по 3 рынкам: тоталы голов, углы Pinnacle, карточки best available. Сигналы автоматически уходят в Журнал при открытии карточки.")
      }

      if signals.isEmpty {
        Section {
          ContentUnavailableView("Нет подтверждённых ставок",
            systemImage: "checkmark.shield",
            description: Text("NO DATA → NO NUMBER → NO EDGE → NO BET"))
        }
      }

      ForEach(signals) { s in
        Section {
          NavigationLink {
            SignalDetailView(signal: s).onAppear { autoJournal(s) }
          } label: {
            SignalCard(signal: s, oddsFormat: settings.oddsFormat)
          }
        }
      }

      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .contentMargins(.top, 4, for: .scrollContent)
    .navigationTitle("OVERBET")
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
        Button { Task { await settleJournal() } } label: {
          Label("Обновить результаты", systemImage: "checkmark.circle")
        }
        .disabled(busy)
        Text(lastSettleStatus).font(.caption).foregroundStyle(.secondary)
      } header: {
        Text("Settlement")
      } footer: {
        Text("Запрашивает /Games/{id} по каждой открытой записи, определяет WIN/LOSS/PUSH, считает профит и CLV (Closing Line Value — насколько ваш коэффициент лучше закрывающего).")
      }

      if journal.isEmpty {
        Section { ContentUnavailableView("Журнал пуст", systemImage: "tray") }
      } else {
        Section("Статистика") { journalStatsView() }
        clvFirstSection
        equitySection
        Section("Калибровка") { calibrationView() }
        Section("Записи") {
          ForEach(journal) { e in
            NavigationLink { JournalEntryDetailView(entry: e) } label: { journalRow(e) }
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                  context.delete(e); try? context.save()
                } label: { Label("Удалить", systemImage: "trash") }
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

  // MARK: - CLV-first

  @ViewBuilder
  private var clvFirstSection: some View {
    let rep = Metrics.clvReport(journal)
    Section {
      HStack {
        Text("Вердикт").font(.subheadline)
        Spacer()
        Text(rep.verdict).font(.subheadline.bold())
          .foregroundStyle(clvVerdictColor(rep.verdict))
      }
      Text(rep.note).font(.caption).foregroundStyle(.secondary)

      if rep.totalWithCLV == 0 {
        Text("Пока нет записей с CLV. Запустите settle после тура.")
          .font(.caption2).foregroundStyle(.secondary)
      } else {
        HStack(spacing: 14) {
          miniBlock("+CLV", "\(rep.positiveCount)")
          miniBlock("±0", "\(rep.neutralCount)")
          miniBlock("−CLV", "\(rep.negativeCount)")
          miniBlock("Доля +", String(format: "%.0f%%", rep.positiveRate * 100))
        }
        HStack(spacing: 14) {
          miniBlock("avg CLV", String(format: "%+.2f%%", rep.avgCLV * 100))
          miniBlock("median", String(format: "%+.2f%%", rep.medianCLV * 100))
          miniBlock("P/L +CLV", String(format: "%+.3f", rep.pnlPositive))
            .foregroundStyle(rep.pnlPositive >= 0 ? .green : .red)
          miniBlock("P/L −CLV", String(format: "%+.3f", rep.pnlNegative))
            .foregroundStyle(rep.pnlNegative >= 0 ? .green : .red)
        }
        if !rep.byMarket.isEmpty {
          Text("По рынкам:").font(.caption2).foregroundStyle(.secondary)
          ForEach(rep.byMarket.keys.sorted(), id: \.self) { mk in
            if let m = rep.byMarket[mk] {
              HStack {
                Text(mk).font(.caption.monospacedDigit())
                Spacer()
                Text(String(format: "n=%d · +%.0f%% · avg %+.2f%%",
                            m.count, m.positiveRate * 100, m.avgCLV * 100))
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(m.avgCLV > 0 ? .green : .red)
              }
            }
          }
        }
        Text("Порог «+CLV» = +0.5%, «−CLV» = −0.5%.")
          .font(.caption2).foregroundStyle(.tertiary)
      }
    } header: {
      Text("CLV-first")
    } footer: {
      Text("CLV-first — отдельно измеряем, берут ли сигналы систематически лучшую цену, чем закрытие. STRONG/OK = edge до рынка подтверждён. NEGATIVE = цена хуже закрытия, стратегия под вопросом.")
    }
  }

  private func clvVerdictColor(_ v: String) -> Color {
    switch v {
    case "STRONG":   return .green
    case "OK":       return .blue
    case "WEAK":     return .yellow
    case "MIXED":    return .orange
    case "NEGATIVE": return .red
    default:         return .gray
    }
  }

  @ViewBuilder
  private var equitySection: some View {
    let curve = Metrics.equityCurve(journal, bankroll: settings.effectiveBankroll)
    let bands = Metrics.bollingerBands(curve, window: 20, sigmaMultiplier: 2.0)
    let breakouts = bands.filter { $0.isBreakout }
    let lastBand = bands.last

    Section {
      if curve.count < 2 {
        Text("Нужно минимум 2 закрытые записи")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Chart {
          ForEach(bands) { p in
            if let u = p.upper {
              LineMark(x: .value("Дата", p.date), y: .value("Upper", u))
                .foregroundStyle(.gray.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let l = p.lower {
              LineMark(x: .value("Дата", p.date), y: .value("Lower", l))
                .foregroundStyle(.gray.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let m = p.ma {
              LineMark(x: .value("Дата", p.date), y: .value("MA", m))
                .foregroundStyle(.purple.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1))
            }
          }
          ForEach(curve) { p in
            AreaMark(x: .value("Дата", p.date),
                     y: .value("P/L", p.cumulativeProfit))
              .foregroundStyle(.blue.opacity(0.15))
            LineMark(x: .value("Дата", p.date),
                     y: .value("P/L", p.cumulativeProfit))
              .foregroundStyle(.blue)
          }
          ForEach(breakouts) { p in
            PointMark(x: .value("Дата", p.date),
                      y: .value("P/L", p.value))
              .foregroundStyle(p.value > (p.upper ?? .infinity) ? .green : .red)
              .symbolSize(55)
          }
        }
        .frame(height: 200)

        HStack {
          Text("Точек: \(curve.count)")
          Spacer()
          if let last = curve.last {
            if settings.useMoneyStakes {
              Text(String(format: "Итог: %+.0f", last.cumulativeProfit))
                .foregroundStyle(last.cumulativeProfit >= 0 ? .green : .red)
            } else {
              Text(String(format: "Итог: %+.3f", last.cumulativeProfit))
                .foregroundStyle(last.cumulativeProfit >= 0 ? .green : .red)
            }
          }
        }
        .font(.caption)

        if let lb = lastBand, let ma = lb.ma, let u = lb.upper, let l = lb.lower {
          HStack(spacing: 14) {
            miniBlock("MA(20)", String(format: "%+.3f", ma))
            miniBlock("Upper", String(format: "%+.3f", u))
            miniBlock("Lower", String(format: "%+.3f", l))
            miniBlock("Breakouts", "\(breakouts.count)")
          }
          .padding(.vertical, 2)

          let risk = BollingerRisk.evaluate(bands, window: 20)
          HStack(spacing: 8) {
            Text("Risk").font(.caption2).foregroundStyle(.secondary)
            Text(risk.state.rawValue).font(.caption.bold())
              .foregroundStyle(bollingerRiskColor(risk.state))
            Spacer()
            if let w = risk.width, let aw = risk.avgWidth {
              Text(String(format: "w %.3f / avg %.3f", w, aw))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(String(format: "BO %d/%d",
                        risk.recentBreakouts, risk.window))
              .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          }
          Text(risk.note).font(.caption2).foregroundStyle(.tertiary)
        } else {
          Text("Полосы Боллинджера появятся после 20 закрытых записей.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Equity curve")
    } footer: {
      Text("Накопленный P/L. Синяя — факт. Фиолетовая MA(20) — скользящее среднее. Серые пунктиры — MA ± 2σ (полосы Боллинджера). Точки — breakout. BollingerRisk — диагностика волатильности P/L (не влияет на размер стейка).")
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
              .font(.caption.monospacedDigit()).frame(width: 60, alignment: .leading)
            Text(String(format: "act %.0f%%", b.actual * 100))
              .font(.caption.monospacedDigit())
              .foregroundStyle(abs(b.predicted - b.actual) < 0.08 ? .green : .orange)
            Spacer()
            Text("n=\(b.count)").font(.caption2).foregroundStyle(.secondary)
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
      if let s = formatMatchStart(e.matchStart) {
        HStack(spacing: 4) {
          Image(systemName: "clock")
          Text(s)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      Text("\(e.league) · \(e.market) · \(e.selection)\(e.line.map { " \($0)" } ?? "")")
        .font(.subheadline).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        miniBlock("Odds", OddsFormatter.format(e.odds, as: settings.oddsFormat))
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
          let label: String = {
            if let sm = e.stakeMoney, e.stake > 0 {
              let money = p / e.stake * sm
              return String(format: "P/L %+.0f", money)
            }
            return String(format: "P/L %+.3f", p)
          }()
          Text(label)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(p >= 0 ? .green : .red)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func statusBadge(_ status: String) -> some View {
    Text(status).font(.caption2.bold())
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
    return Text(r).font(.caption2.bold())
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(color.opacity(0.25)).clipShape(Capsule())
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

  private func bollingerRiskColor(_ s: BollingerRisk.State) -> Color {
    switch s {
    case .normal:    return .green
    case .expanding: return .yellow
    case .high:      return .orange
    case .risk:      return .red
    }
  }

  private func marketRegimeColor(_ r: MarketRegime) -> Color {
    switch r {
    case .normal:          return .green
    case .highVolatility:  return .orange
    case .lowLiquidity:    return .yellow
    case .lineDislocation: return .red
    case .unknown:         return .gray
    }
  }

  private func oosMarketColor(_ roi: Double, threshold: Double) -> Color {
    if roi < threshold { return .red }
    if roi < 0 { return .orange }
    return .green
  }

  // MARK: - Авто

  private var autoView: some View {
    List {
      Section {
        Text("Backtest Service").font(.headline)
        Text("Все механизмы автотюнинга, обучения и диагностики. Здесь собирается база за 2 года, обогащаются котировки углов/ЖК, настраиваются пороги, и ведутся отчёты OOS + walk-forward.")
          .font(.caption).foregroundStyle(.secondary)
      }

      selfTuningLinkSection
      enrichmentSection
      liveMonitorSection
      leagueMarketHeatmapSection
      modelComparisonSection
      walkForwardSection
      oosValidationSection

      volatilitySection
      correlationSection
      playerImpactSection

      if let snap = currentSnapshot {
        Section {
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
            LabeledContent("avgROI", value: String(format: "%+.2f%%", snap.avgROI * 100))
            LabeledContent("Sharpe", value: String(format: "%.2f", snap.sharpe))
            LabeledContent("Sortino", value: String(format: "%.2f", snap.sortino))
            LabeledContent("Profit Factor", value: String(format: "%.2f", snap.profitFactor))
            LabeledContent("Brier", value: String(format: "%.3f", snap.brier))
            LabeledContent("avgCLV", value: String(format: "%+.2f%%", snap.avgCLV * 100))
          }
          if let err = snap.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
          }
        } header: {
          Text("Статус снапшота")
        } footer: {
          Text("Снапшот — агрегат по всей собранной базе: средний ROI, Sharpe, Sortino, Profit Factor, Brier, avgCLV. Обновляется после каждого пересбора или докачки.")
        }
      }

      Section {
        let snap = currentSnapshot
        let isResumable = (snap?.buildStatus == "building"
                           && (snap?.buildMatchesCount ?? 0) > 0)
        Button { Task { await runFullBuild() } } label: {
          if isResumable {
            Label("Продолжить сбор · \(snap?.buildMatchesCount ?? 0) матчей",
                  systemImage: "arrow.clockwise.circle")
          } else {
            Label("Собрать базу (2 года × 11 лиг)", systemImage: "arrow.down.circle")
          }
        }
        .disabled(busy)

        Button { Task { await runIncremental() } } label: {
          Label("Докачать за неделю", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(busy || currentSnapshot?.buildStatus != "ready")

        if !btProgressText.isEmpty {
          Text(btProgressText).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
      } header: {
        Text("Действия")
      } footer: {
        Text("Прогресс сборки сохраняется после каждого месяца в Documents/build_checkpoint.json — можно смело сворачивать и возвращаться. Докачка берёт только последние 7 дней.")
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

      Section {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET").font(.subheadline).bold()
      } header: {
        Text("Принцип")
      }

      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Авто")
    .navigationBarTitleDisplayMode(.large)
  }

  @ViewBuilder
  private var enrichmentSection: some View {
    if let snap = currentSnapshot, snap.enrichmentTotal > 0 {
      Section {
        let done = snap.enrichmentProgress
        let total = max(snap.enrichmentTotal, 1)
        let progress = Double(done) / Double(total)
        ProgressView(value: progress)
        HStack {
          Text("Обогащено")
          Spacer()
          Text("\(done) / \(total)")
            .font(.subheadline.monospacedDigit().bold())
            .foregroundStyle(done >= total ? .green : .primary)
        }
        if done >= total {
          Text("Все матчи обогащены углами и ЖК.")
            .font(.caption2).foregroundStyle(.secondary)
        } else {
          Button {
            Task { await runEnrichment() }
          } label: {
            Label("Продолжить обогащение (30 матчей)",
                  systemImage: "arrow.triangle.branch")
          }
          .disabled(busy)
        }
      } header: {
        Text("Обогащение котировок")
      } footer: {
        Text("Скачиваем /Odds/{id} для матчей, у которых ещё нет marketId 45 (углы Pinnacle) или 80 (карточки best). Успешные матчи сохраняются в HistoricalMarketCache — прогресс не теряется при перезапуске. Ночью BGTask добавляет ещё ~60 матчей при зарядке.")
      }
    }
  }

  @ViewBuilder
  private var modelComparisonSection: some View {
    let list = currentSnapshot?.decodedModelComparison() ?? []
    if !list.isEmpty {
      Section {
        ForEach(list) { c in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(c.name).font(.subheadline.bold())
              Spacer()
              Text("n=\(c.matches)").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
              miniBlock("Brier", String(format: "%.3f", c.brier))
              miniBlock("LogLoss", String(format: "%.3f", c.logLoss))
              miniBlock("P(H)", String(format: "%.2f", c.avgHomeP))
              miniBlock("P(D)", String(format: "%.2f", c.avgDrawP))
              miniBlock("P(A)", String(format: "%.2f", c.avgAwayP))
            }
          }
          .padding(.vertical, 2)
        }
      } header: {
        Text("Model comparison (E5)")
      } footer: {
        Text("DC — Dixon-Coles. BIV — Bivariate Poisson. NB — Negative Binomial. ENS — ансамбль. Brier и LogLoss ниже — модель точнее. P(H)/P(D)/P(A) — средние вероятности модели по выборке.")
      }
    }
  }

  // MARK: - W3b Walk-forward

  @ViewBuilder
  private var walkForwardSection: some View {
    if let snap = currentSnapshot,
       let train = snap.decodedTrainReport(),
       let val = snap.decodedValidationReport(),
       let holdout = snap.decodedHoldoutReport() {
      Section {
        wfBlock(title: "Train (60%)", color: .blue, delta: train)
        wfBlock(title: "Validation (20%)", color: .purple, delta: val)
        wfBlock(title: "Holdout (20%)", color: .orange, delta: holdout)
      } header: {
        Text("Walk-forward (W3b)")
      } footer: {
        Text("Train + Validation → в Self-Tuning (пороги, posterior, auto-exclude). Holdout не участвует в обучении — это независимая проверка. Если holdout сильно хуже train — модель переобучена.")
      }
    }
  }

  @ViewBuilder
  private func wfBlock(title: String, color: Color, delta: WalkForwardDelta) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.subheadline.bold()).foregroundStyle(color)
        Spacer()
        Text("n=\(delta.bets)").font(.caption2).foregroundStyle(.secondary)
      }
      HStack(spacing: 14) {
        miniBlock("ROI", String(format: "%+.1f%%", delta.roi * 100))
          .foregroundStyle(delta.roi >= 0 ? .green : .red)
        miniBlock("Sharpe", String(format: "%.2f", delta.sharpe))
        miniBlock("ProfitF", String(format: "%.2f", delta.profitFactor))
        miniBlock("Brier", String(format: "%.3f", delta.brier))
        miniBlock("avgCLV", String(format: "%+.2f%%", delta.avgCLV * 100))
          .foregroundStyle(delta.avgCLV >= 0 ? .green : .red)
      }
      HStack(spacing: 14) {
        miniBlock("Матчей", "\(delta.matches)")
        miniBlock("W/L/P", "\(delta.wins)/\(delta.losses)/\(delta.pushes)")
        miniBlock("Hit", String(format: "%.0f%%", delta.hitRate * 100))
      }
    }
    .padding(.vertical, 2)
  }

  // MARK: - W3a OOS-валидация

  @ViewBuilder
  private var oosValidationSection: some View {
    let cfg = tuningConfig
    let enabled = cfg?.oosGateEnabled ?? false
    let window = cfg?.oosWindowDays ?? 90
    let minBets = cfg?.oosMinBets ?? 100
    let report = Metrics.oosFromJournal(journal, windowDays: window)
    let blocked = cfg.map { OOSBuilder.blockedMarkets(report: report, cfg: $0) } ?? []

    Section {
      LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
      LabeledContent("Окно", value: "\(window) дней")
      LabeledContent("Min n", value: "\(minBets)")
      if blocked.isEmpty {
        Text("Блокировок нет").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Заблокировано: \(blocked.sorted().joined(separator: ", "))")
          .font(.caption).foregroundStyle(.red)
      }
      if report.byMarket.isEmpty {
        Text("Пока нет закрытых записей в окне.").font(.caption2).foregroundStyle(.secondary)
      } else {
        ForEach(report.byMarket.keys.sorted(), id: \.self) { mk in
          if let r = report.byMarket[mk] {
            HStack {
              Text(mk).font(.subheadline)
              Spacer()
              Text(String(format: "%+.1f%% · n=%d", r.roi * 100, r.bets))
                .font(.caption.monospacedDigit())
                .foregroundStyle(r.roi >= 0 ? .green : .red)
            }
          }
        }
      }
    } header: {
      Text("OOS-валидация журнала (W3a)")
    } footer: {
      Text("Out-of-sample по реальному журналу (не бэктест). Если за окно n ≥ Min и ROI < порога — рынок автоматически блокируется в сканере (X NO BET). Пороги задаются в Self-Tuning.")
    }
  }

  @ViewBuilder
  private var liveMonitorSection: some View {
    Section {
      HStack {
        Label("Live-монитор", systemImage: "dot.radiowaves.left.and.right")
          .font(.headline)
        Spacer()
        Text(liveMonitor.isRunning ? "● идёт" : "○ стоп")
          .font(.caption)
          .foregroundStyle(liveMonitor.isRunning ? .green : .secondary)
      }
      LabeledContent("Матчей под наблюдением", value: "\(liveMonitor.snapshots.count)")
      if let t = liveMonitor.lastTick {
        LabeledContent("Последний цикл",
                       value: t.formatted(date: .omitted, time: .standard))
      }
      if let err = liveMonitor.lastError {
        Text(err).font(.caption).foregroundStyle(.orange)
      }

      if liveMonitor.isRunning {
        Button(role: .destructive) { liveMonitor.stop() } label: {
          Label("Остановить", systemImage: "stop.circle")
        }
      } else {
        Button { liveMonitor.start(settings: settings) } label: {
          Label("Запустить", systemImage: "play.circle")
        }
        .disabled(!settings.liveMonitorEnabled || signals.isEmpty)
      }
      if settings.preMatchHistoryEnabled {
        LabeledContent("Pre-match snapshots",
                       value: "\(liveMonitor.preMatchSnapshotsSaved)")
      }
    } header: {
      Text("Live (D1)")
    } footer: {
      Text("Live-монитор опрашивает котировки активных матчей. Каждый 5-й цикл — полные котировки (голы + углы + ЖК). Остальные — только голы. Это экономит лимит SStats.")
    }

    let regime = LiveMonitor.classifyRegime(
      snapshots: liveMonitor.snapshots,
      movements: liveMonitor.movements)
    Section {
      HStack {
        Text("Состояние").font(.subheadline)
        Spacer()
        Text(regime.regime.label).font(.subheadline.bold())
          .foregroundStyle(marketRegimeColor(regime.regime))
      }
      Text(regime.note).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 14) {
        miniBlock("Книг/рынок", String(format: "%.1f", regime.avgBooksPerMarket))
        miniBlock("Спред", String(format: "%.1f%%", regime.avgSpreadPct * 100))
        miniBlock("Sharp", "\(regime.sharpMovements)")
        miniBlock("Движений", "\(regime.totalMovements)")
      }
    } header: {
      Text("Регим рынка (W2b)")
    } footer: {
      Text("NORMAL — штатный режим. HIGH VOL — широкие спреды. LOW LIQ — мало книг. DISLOCATION — резкий переезд линий в 3+ книгах. Диагностика, не влияет на размер стейка.")
    }

    if !liveMonitor.movements.isEmpty {
      Section {
        let top = liveMonitor.movements.prefix(5)
        ForEach(Array(top)) { m in
          HStack(alignment: .top, spacing: 8) {
            Text(m.direction).font(.body.bold())
              .foregroundStyle(m.delta < 0 ? .green : (m.delta > 0 ? .red : .secondary))
            VStack(alignment: .leading, spacing: 2) {
              Text("\(m.market) · \(m.selection)\(m.line.map { " \($0)" } ?? "")")
                .font(.caption).lineLimit(1)
              Text(String(format: "%.2f → %.2f · книг: %d",
                          m.previousAvg, m.currentAvg, m.booksAgreeing))
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if m.isSharp {
              Text("SHARP").font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.purple).clipShape(Capsule())
            }
            Text(String(format: "%+.1f%%", m.delta * 100))
              .font(.caption.monospacedDigit())
              .foregroundStyle(m.delta < 0 ? .green : .red)
          }
        }
      } header: {
        Text("Движения линии (D2)")
      } footer: {
        Text("Если ≥ 3 книги двигают цену в одну сторону > 2% — линия помечается SHARP (вероятен инсайд или smart money).")
      }
    }
  }

  @ViewBuilder
  private var selfTuningLinkSection: some View {
    Section {
      NavigationLink { SelfTuningView() } label: {
        HStack {
          Image(systemName: "slider.horizontal.3").foregroundStyle(.blue)
          VStack(alignment: .leading, spacing: 2) {
            Text("Self-Tuning панель").font(.headline)
            if let cfg = tuningConfig {
              Text("Активных: \(activeCount(cfg)) из 9 · порогов: 24 · весов: 12")
                .font(.caption).foregroundStyle(.secondary)
            } else {
              Text("Открыть настройки автотюнинга")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
        }
      }
    } footer: {
      Text("Все ручные пороги и тумблеры. Каждое изменение логируется с возможностью отката.")
    }
  }

  private func activeCount(_ cfg: TuningConfig) -> Int {
    var n = 0
    if cfg.autoExcludeEnabled { n += 1 }
    if cfg.posteriorEnabled { n += 1 }
    if cfg.stopLossEnabled { n += 1 }
    if cfg.correlationEnabled { n += 1 }
    if cfg.playerImpactEnabled { n += 1 }
    if cfg.teamRatingEnabled { n += 1 }
    if cfg.cornersEnabled { n += 1 }
    if cfg.cardsEnabled { n += 1 }
    if cfg.oosGateEnabled { n += 1 }
    return n
  }

  @ViewBuilder
  private var leagueMarketHeatmapSection: some View {
    let stats = currentSnapshot?.decodedLeagueMarketStats() ?? [:]
    if !stats.isEmpty {
      let leagues = LeaguePool.pool.map { $0.name }
      let markets = ["GOALS", "CARDS", "CORNERS"]
      Section {
        ScrollView(.horizontal, showsIndicators: false) {
          Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
              Text("").frame(width: 100, alignment: .leading)
              ForEach(markets, id: \.self) { mk in
                Text(mk).font(.caption2.bold()).frame(width: 66)
              }
            }
            ForEach(leagues, id: \.self) { lg in
              GridRow {
                Text(lg).font(.caption2).frame(width: 100, alignment: .leading).lineLimit(1)
                ForEach(markets, id: \.self) { mk in
                  let key = "\(lg)|\(mk)"
                  heatCell(stats[key])
                }
              }
            }
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("Лиги × Рынки (ROI)")
      } footer: {
        Text("Разбивка ROI по каждой лиге и рынку отдельно. Зелёный — плюс. Красный — минус. n = число ставок в ячейке.")
      }
    }
  }

  @ViewBuilder
  private func heatCell(_ s: StoredSegmentStats?) -> some View {
    if let s, s.bets > 0 {
      VStack(spacing: 1) {
        Text(String(format: "%+.0f%%", s.roi * 100))
          .font(.caption2.monospacedDigit().bold())
        Text("n=\(s.bets)").font(.caption2).opacity(0.7)
      }
      .frame(width: 66, height: 34)
      .background(heatColor(s.roi).opacity(0.28))
      .clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
      Text("—").font(.caption2).foregroundStyle(.secondary)
        .frame(width: 66, height: 34)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }

  private func heatColor(_ roi: Double) -> Color {
    if roi >= 0.10 { return .green }
    if roi >= 0.02 { return Color.green.opacity(0.75) }
    if roi > -0.02 { return .yellow }
    if roi > -0.10 { return .orange }
    return .red
  }

  @ViewBuilder
  private var volatilitySection: some View {
    let cap = tuningConfig?.stopLossCapStreak ?? VolatilityStop.defaultCapThreshold
    let pause = tuningConfig?.stopLossPauseStreak ?? VolatilityStop.defaultPauseThreshold
    let enabled = tuningConfig?.stopLossEnabled ?? true
    let ev = VolatilityStop.evaluate(journal, capThreshold: cap, pauseThreshold: pause)
    Section {
      LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
      LabeledContent("Текущая серия", value: "\(ev.streak)")
      LabeledContent("Состояние", value: enabled ? ev.state.label : "OFF")
      switch (enabled, ev.state) {
      case (false, _):
        Text("Stop-loss отключён в Self-Tuning.")
          .font(.caption).foregroundStyle(.secondary)
      case (true, .cap(let v)):
        Text("После \(cap) проигрышей подряд — стейк ограничен \(Int(v * 100))%.")
          .font(.caption).foregroundStyle(.orange)
      case (true, .pause):
        Text("После \(pause) проигрышей подряд — новые ставки не создаются.")
          .font(.caption).foregroundStyle(.red)
      default:
        Text("Работаем в штатном режиме.")
          .font(.caption).foregroundStyle(.secondary)
      }
    } header: {
      Text("Volatility stop (B5)")
    } footer: {
      Text("Автоматическая защита от длинных серий проигрышей. NORMAL — штатно. CAP — стейк урезан до 5%. PAUSE — новые ставки не создаются.")
    }
  }

  @ViewBuilder
  private var correlationSection: some View {
    let m = correlationMatrix
    let enabled = tuningConfig?.correlationEnabled ?? true
    Section {
      LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
      if m.totalPairs == 0 {
        Text("Нужно ≥ 20 пар закрытых записей в одном дне для эмпирики.")
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
                Text("n=\(n)").font(.caption2).foregroundStyle(.secondary)
                  .frame(width: 52, alignment: .trailing)
              }
            }
          }
        }
      }
    } header: {
      Text("Correlation matrix (B4)")
    } footer: {
      Text("φ-коэффициенты между рынками и лигами из журнала. Если две ставки в портфеле сильно коррелируют (≥ 0.65), вторая отсекается. Fallback — структурные значения.")
    }
  }

  @ViewBuilder
  private var playerImpactSection: some View {
    let enabled = tuningConfig?.playerImpactEnabled ?? true
    Section {
      LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
    } header: {
      Text("Player impact (B6)")
    } footer: {
      Text("Коррекция λ, если в gameInfo есть составы (lineups) и у команды ≥ 6 игроков в истории. Отсутствие 3–4 топ-8 → λ × 0.92…0.95. Отсутствие 5+ → λ × 0.88.")
    }
  }

  @ViewBuilder
  private var teamRatingsSection: some View {
    let top = Array(teamRatings.prefix(20))
    let enabled = tuningConfig?.teamRatingEnabled ?? true
    if !top.isEmpty || !enabled {
      Section {
        LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
        ForEach(top) { r in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(r.name.isEmpty ? r.teamID : r.name).font(.subheadline)
              Text("n=\(r.matches)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.0f", r.rating))
              .font(.subheadline.monospacedDigit())
            if r.lastDelta != 0 {
              Text(String(format: "%+.0f", r.lastDelta))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(r.lastDelta > 0 ? .green : .red)
                .frame(width: 44, alignment: .trailing)
            }
          }
        }
      } header: {
        Text("Team ratings (B3)")
      } footer: {
        Text("Elo, старт 1500, HFA 60, K=32→20. Применяются после ≥ 3 матчей. Влияют на λ через glickoAdjust (не более ±12%).")
      }
    }
  }

  @ViewBuilder
  private func autoExcludeSection(_ snap: BacktestSnapshot) -> some View {
    let cfg = tuningConfig
    let minROI = cfg?.autoExcludeMinROI ?? AutoExclude.defaultMinROI
    let minBets = cfg?.autoExcludeMinBets ?? AutoExclude.defaultMinBets
    let enabled = cfg?.autoExcludeEnabled ?? true
    let rules = AutoExclude.rules(from: snap, minROI: minROI, minBets: minBets)
    let excluded = rules.filter { $0.excluded }
    Section {
      LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
      LabeledContent("Порог",
                     value: String(format: "ROI < %.1f%%, n ≥ %d",
                                   minROI * 100, minBets))
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
              .font(.subheadline.monospacedDigit()).foregroundStyle(.red)
          }
        }
      }
    } header: {
      Text("Auto-Exclude")
    } footer: {
      Text("Комбинации лига+рынок с плохим ROI в бэктесте автоматически отсеиваются в сканере.")
    }
  }

  @ViewBuilder
  private func posteriorSection(_ snap: BacktestSnapshot) -> some View {
    let cfg = tuningConfig
    let enabled = cfg?.posteriorEnabled ?? true
    let w = cfg?.posteriorWeight ?? QuantEngine.defaultPosteriorWeight
    let buckets = snap.decodedPosteriorBuckets()
    let nonEmpty = buckets.filter { $0.n > 0 }
    let usable = nonEmpty.filter { $0.n >= 20 }.count
    Section {
      LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
      LabeledContent("Вес w", value: String(format: "%.2f", w))
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
            Text("n=\(b.n)").font(.caption2).foregroundStyle(.secondary)
              .frame(width: 52, alignment: .trailing)
          }
        }
      }
    } header: {
      Text("Posterior buckets (B2)")
    } footer: {
      Text("Байесовская коррекция вероятности: p_adj = (1-w)·p + w·p_post. p_post — исторически фактический hit rate для того же бакета вероятности. Применяется только для бакетов с n ≥ 20.")
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

  private func runEnrichment() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    btProgressText = "Обогащение…"
    await BacktestService.shared.continueEnrichmentInBackground(chunkSize: 30) { done, total, msg in
      btProgressText = String(format: "%d/%d · %@", done, total, msg)
    }
    btProgressText = "Обогащение завершено (порция)"
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
      Section {
        Button { Task { await runChecks() } } label: {
          Label("Запустить проверки", systemImage: "checkmark.shield")
        }
        .disabled(busy)
        LabeledContent("API reachable", value: apiReachable)
        LabeledContent("API key", value: apiKeyState)
        LabeledContent("Settle", value: lastSettleStatus)
        if let lr = lastRefresh {
          LabeledContent("Last refresh",
                         value: lr.formatted(date: .omitted, time: .shortened))
        }
      } header: {
        Text("Проверки")
      } footer: {
        Text("Проверяет доступность SStats, валидность ключа и запускает settlement открытых записей.")
      }
      Section {
        Button { selfTestResults = QuantMathSelfTest.runAll() } label: {
          Label("Запустить unit-тесты", systemImage: "checkmark.seal")
        }
        if !selfTestResults.isEmpty {
          let passed = selfTestResults.filter { $0.pass }.count
          let total = selfTestResults.count
          HStack {
            Text("Пройдено")
            Spacer()
            Text("\(passed)/\(total)")
              .font(.subheadline.bold())
              .foregroundStyle(passed == total ? .green : .orange)
          }
          ForEach(selfTestResults) { r in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: r.pass ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(r.pass ? .green : .red)
              VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.caption)
                Text(r.note).font(.caption2).foregroundStyle(.secondary)
              }
            }
          }
        } else {
          Text("Нажмите кнопку — 15 проверок QuantMath.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      } header: {
        Text("Self-tests (E4)")
      } footer: {
        Text("15 юнит-тестов QuantMath: медиана, EV, Kelly, DC/BIV, split линий, β-shrink, NB-PMF. Все должны быть зелёными. Известная косметика: median чётная использует верхнюю медиану.")
      }
      Section("Sample / Consensus") {
        let m = Metrics.compute(journal)
        LabeledContent("Closed entries", value: "\(m.closedEntries)")
        LabeledContent("Calibration err",
                       value: String(format: "%.3f", Metrics.calibrationError(m)))
        LabeledContent("Avg CLV", value: String(format: "%+.2f%%", m.avgCLV * 100))
        LabeledContent("Brier", value: String(format: "%.3f", m.brier))
      }
      Section("CLV-first (W2b)") {
        let rep = Metrics.clvReport(journal)
        LabeledContent("Вердикт", value: rep.verdict)
        LabeledContent("Записей с CLV", value: "\(rep.totalWithCLV)")
        LabeledContent("+CLV доля",
                       value: String(format: "%.0f%%", rep.positiveRate * 100))
        LabeledContent("avg CLV", value: String(format: "%+.2f%%", rep.avgCLV * 100))
        LabeledContent("median CLV",
                       value: String(format: "%+.2f%%", rep.medianCLV * 100))
      }
      Section {
        LabeledContent("Статус", value: settings.preMatchHistoryEnabled ? "вкл" : "выкл")
        LabeledContent("Окно", value: "\(settings.preMatchCaptureWindowMin) мин")
        LabeledContent("Снимков за сессию",
                       value: "\(liveMonitor.preMatchSnapshotsSaved)")
        let total = LineSnapshotService.totalCount(in: context)
        LabeledContent("Всего в БД", value: "\(total)")
      } header: {
        Text("Pre-match line history (W2b)")
      } footer: {
        Text("Снимки котировок за T-60/30/15/5 минут до старта. Позволяют измерить реальное движение линии и отличить настоящий edge от one-off аномалии цены.")
      }
      Section {
        let snap = currentSnapshot
        let train = snap?.decodedTrainReport()
        let val = snap?.decodedValidationReport()
        let holdout = snap?.decodedHoldoutReport()
        LabeledContent("Режим", value: snap?.walkForwardMode ?? "off")
        if let t = train {
          LabeledContent("Train ROI", value: String(format: "%+.2f%%", t.roi * 100))
          LabeledContent("Train n", value: "\(t.bets)")
        }
        if let v = val {
          LabeledContent("Val ROI", value: String(format: "%+.2f%%", v.roi * 100))
          LabeledContent("Val n", value: "\(v.bets)")
        }
        if let h = holdout {
          LabeledContent("Holdout ROI", value: String(format: "%+.2f%%", h.roi * 100))
          LabeledContent("Holdout n", value: "\(h.bets)")
        }
      } header: {
        Text("Walk-forward (W3b)")
      } footer: {
        Text("Self-Tuning обучается на Train+Validation. Holdout — независимая проверка. Сильное расхождение → модель переобучена.")
      }
      Section {
        let cfg = tuningConfig
        let report = Metrics.oosFromJournal(journal, windowDays: cfg?.oosWindowDays ?? 90)
        LabeledContent("Флаг", value: (cfg?.oosGateEnabled ?? false) ? "вкл" : "выкл")
        LabeledContent("Окно", value: "\(cfg?.oosWindowDays ?? 90) дней")
        LabeledContent("Записей в окне", value: "\(report.totalEntries)")
        let blocked = cfg.map { OOSBuilder.blockedMarkets(report: report, cfg: $0) } ?? []
        LabeledContent("Заблокировано", value: blocked.isEmpty ? "—" : blocked.sorted().joined(separator: ", "))
      } header: {
        Text("OOS-валидация (W3a)")
      } footer: {
        Text("OOS по реальному журналу. Если рынок системно убыточен за окно — блокируется в сканере до восстановления.")
      }
      Section {
        let snap = currentSnapshot
        let allSample = sampleBreakdown(signals)
        LabeledContent("FULL", value: "\(allSample.full)")
        LabeledContent("GOOD", value: "\(allSample.good)")
        LabeledContent("USABLE", value: "\(allSample.usable)")
        LabeledContent("INS", value: "\(allSample.ins)")
        LabeledContent("С SHARP", value: "\(signals.filter { $0.sharpMoney == true }.count)")
        LabeledContent("С posterior", value: "\(signals.filter { $0.posteriorWeight != nil }.count)")
        if snap != nil {
          let cached = snap?.historicalCacheCount ?? 0
          LabeledContent("Historical cache", value: "\(cached) матчей")
        }
      } header: {
        Text("Data Health (W3c)")
      } footer: {
        Text("Сводка качества входных данных по последнему скану. FULL/GOOD/USABLE/INS — размер рыночной выборки. Чем больше INS — тем менее надёжны сигналы.")
      }
      Section("Self-Tuning") {
        if let cfg = tuningConfig {
          LabeledContent("Активных механизмов", value: "\(activeCount(cfg)) из 9")
          LabeledContent("posteriorWeight",
                         value: String(format: "%.2f", cfg.posteriorWeight))
          LabeledContent("autoExcludeMinROI",
                         value: String(format: "%.1f%%", cfg.autoExcludeMinROI * 100))
          LabeledContent("autoExcludeMinBets", value: "\(cfg.autoExcludeMinBets)")
          LabeledContent("stopLossCap/Pause",
                         value: "\(cfg.stopLossCapStreak)/\(cfg.stopLossPauseStreak)")
          LabeledContent("CORNERS",
                         value: String(format: "EV ≥ %.1f%%, QCS ≥ %.0f, MSS ≥ %.0f, stake ≤ %.1f%%",
                                       cfg.cornersMinEV * 100, cfg.cornersMinQCS,
                                       cfg.cornersMinMSS, cfg.cornersMaxStake * 100))
          LabeledContent("CARDS",
                         value: String(format: "EV ≥ %.1f%%, QCS ≥ %.0f, MSS ≥ %.0f, stake ≤ %.1f%%",
                                       cfg.cardsMinEV * 100, cfg.cardsMinQCS,
                                       cfg.cardsMinMSS, cfg.cardsMaxStake * 100))
          LabeledContent("OOS gate",
                         value: cfg.oosGateEnabled ? "вкл · n≥\(cfg.oosMinBets)" : "выкл")
          LabeledContent("Событий в логе", value: "\(tuningEvents.count)")
        } else {
          Text("Конфиг не создан").font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Отображение") {
        LabeledContent("Odds format", value: settings.oddsFormat.label)
        LabeledContent("Тема", value: settings.colorScheme.label)
      }
      Section("Банк") {
        LabeledContent("Ставки в деньгах",
                       value: settings.useMoneyStakes ? "да" : "нет")
        LabeledContent("Размер банка",
                       value: String(format: "%.0f", settings.bankroll))
      }
      Section {
        LabeledContent("Статус", value: liveMonitor.isRunning ? "идёт" : "стоп")
        LabeledContent("Матчей", value: "\(liveMonitor.snapshots.count)")
        LabeledContent("Движений", value: "\(liveMonitor.movements.count)")
        let sharpCount = liveMonitor.movements.filter { $0.isSharp }.count
        LabeledContent("Sharp", value: "\(sharpCount)")
        if let t = liveMonitor.lastTick {
          LabeledContent("Last tick",
                         value: t.formatted(date: .omitted, time: .standard))
        }
        let regime = LiveMonitor.classifyRegime(
          snapshots: liveMonitor.snapshots,
          movements: liveMonitor.movements)
        LabeledContent("Регим рынка", value: regime.regime.label)
      } header: {
        Text("Live-монитор (D1)")
      }
      Section("Team ratings (B3)") {
        LabeledContent("Всего команд", value: "\(teamRatings.count)")
        let usable = teamRatings.filter { $0.matches >= TeamRatingService.minMatchesForUse }.count
        LabeledContent("С ≥ 3 матчами", value: "\(usable)")
      }
      Section("Correlation (B4)") {
        let m = correlationMatrix
        LabeledContent("Пар в журнале", value: "\(m.totalPairs)")
        LabeledContent("Market-пар (n≥20)", value: "\(m.marketPairsN.count)")
        LabeledContent("League-пар (n≥20)", value: "\(m.leaguePairsN.count)")
      }
      Section {
        if let snap = currentSnapshot {
          LabeledContent("Status", value: snap.buildStatus)
          LabeledContent("Progress",
                         value: String(format: "%.1f%%", snap.buildProgress * 100))
          LabeledContent("Matches", value: "\(snap.totalMatches)")
          LabeledContent("Bets", value: "\(snap.totalBets)")
          if snap.enrichmentTotal > 0 {
            LabeledContent("Enrichment",
                           value: "\(snap.enrichmentProgress)/\(snap.enrichmentTotal)")
          }
          if snap.historicalCacheCount > 0 {
            LabeledContent("Historical cache",
                           value: "\(snap.historicalCacheCount) матчей")
          }
          if snap.totalBets > 0 {
            LabeledContent("avgROI",
                           value: String(format: "%+.2f%%", snap.avgROI * 100))
            LabeledContent("Sharpe", value: String(format: "%.2f", snap.sharpe))
          }
          let rules = AutoExclude.rules(from: snap)
          let excludedCount = rules.filter { $0.excluded }.count
          LabeledContent("Auto-Exclude (активных)", value: "\(excludedCount)")
          let buckets = snap.decodedPosteriorBuckets()
          let usableBuckets = buckets.filter { $0.n >= 20 }.count
          LabeledContent("Posterior (n≥20)", value: "\(usableBuckets)")
          let comps = snap.decodedModelComparison()
          if !comps.isEmpty {
            LabeledContent("Model comparison (E5)", value: "\(comps.count) строк")
          }
          if let err = snap.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
          }
        } else {
          Text("Снапшот ещё не создан").font(.caption).foregroundStyle(.secondary)
        }
      } header: {
        Text("Backtest snapshot")
      }
      Section("Пул лиг") {
        ForEach(LeaguePool.pool, id: \.id) { lg in
          Text("\(lg.id) · \(lg.name)").font(.subheadline)
        }
      }
      Section {
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
      } header: {
        Text("League baselines (prior)")
      } footer: {
        Text("Структурные приоры λ для каждой лиги. sampleSize=0 → это prior, а не измеренные данные. Используются как fallback, когда истории мало.")
      }
      Section {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET").font(.subheadline).bold()
        Text("Quarter Kelly · max 2% · S BET до 2.5%")
          .font(.caption).foregroundStyle(.secondary)
        Text("Portfolio cap 10% bankroll в день")
          .font(.caption).foregroundStyle(.secondary)
      } header: {
        Text("Принципы")
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

  private func sampleBreakdown(_ sigs: [BetSignal]) -> (full: Int, good: Int, usable: Int, ins: Int) {
    var f = 0, g = 0, u = 0, i = 0
    for s in sigs {
      switch s.sampleClass {
      case "FULL": f += 1
      case "GOOD": g += 1
      case "USABLE": u += 1
      default: i += 1
      }
    }
    return (f, g, u, i)
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
      Section {
        SecureField("API key", text: $settings.apiKey)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      } header: {
        Text("SStats API")
      } footer: {
        Text("Ключ хранится в Keychain и не попадает в репозиторий.")
      }
      Section("Отображение") {
        Picker("Формат коэффициентов", selection: $settings.oddsFormatRaw) {
          ForEach(OddsFormat.allCases) { f in Text(f.label).tag(f.rawValue) }
        }
        Text(settings.oddsFormat.hint).font(.caption2).foregroundStyle(.secondary)
        Picker("Тема", selection: $settings.colorSchemeRaw) {
          ForEach(AppColorScheme.allCases) { s in Text(s.label).tag(s.rawValue) }
        }
      }
      Section {
        Toggle("Ставки в деньгах", isOn: $settings.useMoneyStakes)
        if settings.useMoneyStakes {
          HStack {
            Text("Размер банка")
            Spacer()
            TextField("0", value: $settings.bankroll, format: .number)
              .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
              .frame(width: 140).monospacedDigit()
          }
        }
      } header: {
        Text("Банк")
      } footer: {
        Text("Включённый режим показывает стейк в деньгах: 2% банка = 0.02 × размер банка.")
      }
      Section {
        Toggle("Следить за линией", isOn: $settings.liveMonitorEnabled)
        if settings.liveMonitorEnabled {
          Stepper("Интервал: \(settings.liveMonitorIntervalSec) сек",
                  value: $settings.liveMonitorIntervalSec, in: 30...300, step: 30)
        }
      } header: {
        Text("Live-монитор")
      } footer: {
        Text("Каждый 5-й цикл — полные котировки (углы+ЖК). Остальные — только голы.")
      }
      Section {
        Toggle("Сохранять движение линии до старта",
               isOn: $settings.preMatchHistoryEnabled)
        if settings.preMatchHistoryEnabled {
          Stepper("Окно снимков: \(settings.preMatchCaptureWindowMin) мин",
                  value: $settings.preMatchCaptureWindowMin,
                  in: 15...180, step: 15)
        }
      } header: {
        Text("Pre-match line history (W2b)")
      } footer: {
        Text("Снимки пишутся в 4 контрольных точках (T-60/30/15/5) пока активен Live-монитор.")
      }
      Section {
        Toggle("Фоновое обновление", isOn: $settings.autoRefresh)
        Stepper("Интервал: \(settings.refreshMinutes) мин",
                value: $settings.refreshMinutes, in: 15...120, step: 15)
      } header: {
        Text("Автообновление")
      } footer: {
        Text("iOS сама решает, когда запускать фон (обычно ≥ 30 мин).")
      }
      Section("Параметры модели") {
        Stepper("История: \(settings.historyMatches) матчей",
                value: $settings.historyMatches, in: 6...20)
        Stepper("Матчей в сканере: \(settings.scanMatches)",
                value: $settings.scanMatches, in: 5...30)
      }
      Section("Уведомления") {
        Toggle("Уведомлять при S/A BET", isOn: $settings.notifyBets)
        Button { NotificationService.resetDedupe() } label: {
          Label("Сбросить дубликаты", systemImage: "arrow.counterclockwise")
        }
      }
      Section {
        Text("NO DATA → NO NUMBER → NO EDGE → NO BET").bold()
      } header: {
        Text("Принцип")
      }
      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .navigationTitle("Настройки")
    .navigationBarTitleDisplayMode(.large)
  }

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

    liveMonitor.clearObserved()
    for s in signals {
      liveMonitor.observe(
        gameID: s.gameID,
        numericID: Int(s.gameID),
        startTime: s.startTime,
        league: s.league,
        home: s.home,
        away: s.away)
    }
    if settings.liveMonitorEnabled && !signals.isEmpty {
      liveMonitor.start(settings: settings)
    }

    if summary.success {
      status = "Обновлено · \(signals.count) сигналов"
    } else {
      status = summary.notes.first ?? "Ошибка"
    }
    for n in summary.notes { diagnostics.append(n) }
    diagnostics.append("scanned=\(summary.scannedMatches)")
    diagnostics.append("corrPairs=\(summary.correlationPairs)")
    diagnostics.append("lineups=\(summary.lineupsFound)")
    diagnostics.append("h2h=\(summary.h2hFetched)")
    if !summary.oosBlocked.isEmpty {
      diagnostics.append("oosBlocked=\(summary.oosBlocked.joined(separator: ","))")
    }
  }

  private func settleJournal() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { lastSettleStatus = "API key не задан"; return }
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
  let oddsFormat: OddsFormat
  @EnvironmentObject private var settings: AppSettings

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
      if let s = formatMatchStart(signal.startTime) {
        HStack(spacing: 4) {
          Image(systemName: "clock")
          Text(s)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      Text(marketLine).font(.subheadline).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 14) {
        metric("Odds", OddsFormatter.format(signal.odds, as: oddsFormat))
        metric("P", String(format: "%.1f%%", signal.probability * 100))
        metric("EV", String(format: "%+.1f%%", signal.ev * 100))
        metric("Rob.", String(format: "%+.1f%%", signal.robustEV * 100))
        metric("QCS", String(format: "%.0f", signal.qcs))
        stakeMetric
      }
      HStack(spacing: 10) {
        Text("DCS \(String(format: "%.0f", signal.dcs))")
        Text("MS \(String(format: "%.0f", signal.ms))")
        Text("Sample \(signal.sampleClass)")
        Text("\(signal.bookmakers)b")
        if let src = signal.oddsSource {
          Text(src).foregroundStyle(.blue)
        }
        if let mss = signal.mss, signal.market == "CORNERS" || signal.market == "CARDS" {
          Text("MSS \(String(format: "%.0f", mss))")
            .foregroundStyle(mss >= 70 ? .green : (mss >= 40 ? .primary : .orange))
        }
        if signal.posteriorWeight != nil { Text("PST").foregroundStyle(.purple) }
        if signal.stopApplied != nil { Text("STOP").foregroundStyle(.red) }
        if signal.playerImpactHome != nil || signal.playerImpactAway != nil {
          Text("PLR").foregroundStyle(.orange)
        }
        if signal.sharpMoney == true { Text("SHARP").foregroundStyle(.purple) }
        if let v = signal.modelVote {
          Text("VOTE \(v)/4")
            .foregroundStyle(v >= 3 ? .green : (v == 2 ? .orange : .red))
        }
      }
      .font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
  }

  private var marketLine: String {
    let linePart: String = signal.line.map { " \($0)" } ?? ""
    var base = "\(signal.league) · \(signal.market) · \(signal.selection)\(linePart)"
    if let src = signal.oddsSource {
      base += " · \(src)"
    }
    return base
  }

  @ViewBuilder
  private var stakeMetric: some View {
    if settings.useMoneyStakes, let money = signal.stakeMoney {
      VStack(alignment: .leading, spacing: 2) {
        Text("Stake").font(.caption2).foregroundStyle(.secondary)
        Text(String(format: "%.0f", money)).font(.caption.monospacedDigit())
      }
    } else {
      metric("Stake", String(format: "%.2f%%", signal.stake * 100))
    }
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

  private func metric(_ n: String, _ v: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(n).font(.caption2).foregroundStyle(.secondary)
      Text(v).font(.caption.monospacedDigit())
    }
  }
}

// MARK: - SignalDetailView

struct SignalDetailView: View {
  let signal: BetSignal
  @EnvironmentObject var settings: AppSettings
  @State private var homeHistory: [TeamRecord] = []
  @State private var awayHistory: [TeamRecord] = []
  @State private var previewLoading = false
  @State private var previewError: String? = nil

  var body: some View {
    List {
      Section("Матч") {
        LabeledContent("Хозяева", value: signal.home)
        LabeledContent("Гости", value: signal.away)
        LabeledContent("Лига", value: signal.league)
        if let s = formatMatchStartLong(signal.startTime) {
          LabeledContent("Начало", value: s)
        }
        LabeledContent("Рынок", value: signal.market)
        LabeledContent("Выбор", value: selectionLine)
      }

      matchPreviewSection

      // [W3c] Data Health
      Section {
        HStack {
          Text("Sample").font(.subheadline)
          Spacer()
          Text(signal.sampleClass).font(.subheadline.bold())
            .foregroundStyle(sampleColor(signal.sampleClass))
        }
        LabeledContent("Матчей хозяев", value: "\(signal.homeSample)")
        LabeledContent("Матчей гостей", value: "\(signal.awaySample)")
        LabeledContent("Букмекеров", value: "\(signal.bookmakers)")
        LabeledContent("DCS", value: String(format: "%.0f", signal.dcs))
        LabeledContent("MS", value: String(format: "%.0f", signal.ms))
        if let mss = signal.mss {
          LabeledContent("MSS", value: String(format: "%.0f", mss))
        }
        LabeledContent("Uncertainty",
                       value: String(format: "%.3f · %@", signal.uncertainty, signal.uncertaintyBand))
        LabeledContent("Market MAD", value: String(format: "%.2f", signal.marketMAD))
        if let src = signal.oddsSource {
          LabeledContent("Источник", value: src)
        }
        if signal.sharpMoney == true {
          LabeledContent("Sharp", value: "да")
        }
        if signal.posteriorWeight != nil {
          LabeledContent("Posterior", value: "применён")
        }
        if signal.playerImpactHome != nil || signal.playerImpactAway != nil {
          LabeledContent("Player impact", value: "применён")
        }
      } header: {
        Text("Data Health (W3c)")
      } footer: {
        Text("Качество входных данных конкретного сигнала. FULL/GOOD — надёжно. USABLE — приемлемо. INS — мало данных, сигнал менее устойчив.")
      }

      if let src = signal.oddsSource {
        Section {
          LabeledContent("Источник", value: src)
          if signal.market == "CORNERS" {
            Text("Edge считается против sharp-линии Pinnacle (bookmakerId=4).")
              .font(.caption2).foregroundStyle(.secondary)
          } else if signal.market == "CARDS" {
            Text("Edge считается против лучшей доступной котировки среди букмекеров.")
              .font(.caption2).foregroundStyle(.secondary)
          }
        } header: {
          Text("Источник котировки")
        }
      }

      if let mss = signal.mss,
         signal.market == "CORNERS" || signal.market == "CARDS" {
        Section {
          HStack {
            Text("MSS").font(.subheadline.bold())
            Spacer()
            Text(String(format: "%.0f", mss))
              .font(.subheadline.monospacedDigit().bold())
              .foregroundStyle(mss >= 70 ? .green : (mss >= 40 ? .primary : .orange))
          }
        } header: {
          Text("Market support (MSS)")
        } footer: {
          Text("Оценка согласованности котировок: чем выше — тем сильнее рынок подтверждает сигнал. Учитывает ширину спреда между книгами и согласие sharp-книг.")
        }
      }

      Section {
        HStack {
          Text("Класс").font(.subheadline)
          Spacer()
          Text(signal.classification)
            .font(.subheadline.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(classColor.opacity(0.22)).clipShape(Capsule())
        }
        LabeledContent("Модель", value: signal.model)
        LabeledContent("Букмекеров", value: "\(signal.bookmakers)")
        if signal.priceAnomaly {
          Label("Аномальная цена (flag)", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange).font(.caption)
        }
      } header: {
        Text("Классификация")
      } footer: {
        Text("S BET — лучший сигнал (EV ≥ 7%, QCS ≥ 85). A BET — хороший. B LEAN — edge есть. C WATCH — минимальный. X NO BET — не проходит фильтр.")
      }

      Section {
        LabeledContent("Odds", value: OddsFormatter.format(signal.odds, as: settings.oddsFormat))
        LabeledContent("Fair odds",
                       value: OddsFormatter.format(signal.fairOdds, as: settings.oddsFormat))
        LabeledContent("P (финальная)",
                       value: String(format: "%.2f%%", signal.probability * 100))
        if let raw = signal.probabilityRaw, raw != signal.probability {
          LabeledContent("P (модель)", value: String(format: "%.2f%%", raw * 100))
        }
        LabeledContent("P (рынок)",
                       value: String(format: "%.2f%%", signal.marketProbability * 100))
        LabeledContent("EV", value: String(format: "%+.2f%%", signal.ev * 100))
        LabeledContent("Robust EV", value: String(format: "%+.2f%%", signal.robustEV * 100))
      } header: {
        Text("Цена и вероятность")
      } footer: {
        Text("EV = p × odds − 1. Robust EV — то же, но с поправкой на неопределённость. Fair odds = 1/p.")
      }

      if let best = signal.bestOdds,
         let avg = signal.avgOdds,
         let worst = signal.worstOdds,
         let bestBook = signal.bestBook,
         let worstBook = signal.worstBook {
        Section("Odds comparison (D4)") {
          LabeledContent("Лучшая",
                         value: "\(OddsFormatter.format(best, as: settings.oddsFormat)) · \(bestBook)")
          LabeledContent("Средняя",
                         value: OddsFormatter.format(avg, as: settings.oddsFormat))
          LabeledContent("Худшая",
                         value: "\(OddsFormatter.format(worst, as: settings.oddsFormat)) · \(worstBook)")
          LabeledContent("Книг", value: "\(signal.bookmakers)")
        }
      }

      if let lm = signal.liveMovement {
        Section("Live movement (D1)") {
          LabeledContent("Средняя цена",
                         value: String(format: "%+.2f%%", lm * 100))
            .foregroundStyle(lm < 0 ? .green : .red)
          if signal.sharpMoney == true, let sm = signal.sharpMovement {
            HStack {
              Text("Sharp money")
              Spacer()
              Text(String(format: "да · %+.2f%%", sm * 100))
                .foregroundStyle(.purple).font(.subheadline.bold())
            }
          }
        }
      }

      if let vote = signal.modelVote {
        Section("Voting (D3)") {
          HStack {
            Text("Согласие моделей")
            Spacer()
            Text("\(vote)/4").font(.subheadline.bold())
              .foregroundStyle(vote >= 3 ? .green : (vote == 2 ? .orange : .red))
          }
        }
      }

      if let w = signal.posteriorWeight {
        Section("Posterior correction (B2)") {
          LabeledContent("Вес w", value: String(format: "%.2f", w))
          if let src = signal.posteriorSource {
            LabeledContent("Бакет", value: src)
          }
        }
      }

      if signal.stopApplied != nil {
        Section("Stop-loss (B5)") {
          if let reason = signal.stopApplied {
            LabeledContent("Применено", value: reason)
          }
          if let before = signal.stakeBeforeStop {
            LabeledContent("Стейк был", value: String(format: "%.3f%%", before * 100))
            LabeledContent("Стейк стал", value: String(format: "%.3f%%", signal.stake * 100))
          }
        }
      }

      if signal.playerImpactHome != nil || signal.playerImpactAway != nil {
        Section("Player impact (B6)") {
          if let hi = signal.playerImpactHome {
            LabeledContent("Дом. λ-множитель", value: String(format: "%.2f", hi))
          }
          if let ai = signal.playerImpactAway {
            LabeledContent("Гост. λ-множитель", value: String(format: "%.2f", ai))
          }
        }
      }

      Section {
        HStack {
          intervalBlock("P10", String(format: "%.1f%%", signal.probabilityLow * 100))
          intervalBlock("P50", String(format: "%.1f%%", signal.probability * 100))
          intervalBlock("P90", String(format: "%.1f%%", signal.probabilityHigh * 100))
        }
        LabeledContent("Uncertainty", value: String(format: "%.3f", signal.uncertainty))
        LabeledContent("Band", value: signal.uncertaintyBand)
        LabeledContent("Market MAD", value: String(format: "%.2f", signal.marketMAD))
      } header: {
        Text("Интервал неопределённости")
      } footer: {
        Text("P10/P50/P90 — вероятностный интервал. Узкий интервал = уверенная модель. Band влияет на размер стейка: LOW ×1.0, MED ×0.75, HIGH ×0.5.")
      }

      Section {
        Text("QCS = 0.30·MES + 0.20·DCS + 0.20·MS + 0.15·TS + 0.15·RS")
          .font(.caption2).foregroundStyle(.secondary)
        scoreRow("DCS", signal.dcs, w: "0.20")
        scoreRow("MS", signal.ms, w: "0.20")
        scoreRow("MES", signal.mes, w: "0.30")
        scoreRow("TS", signal.ts, w: "0.15")
        scoreRow("RS", signal.rs, w: "0.15")
        HStack {
          Text("QCS").font(.subheadline.bold())
          Spacer()
          Text(String(format: "%.1f", signal.qcs))
            .font(.subheadline.monospacedDigit().bold())
        }
      } header: {
        Text("Компоненты QCS")
      } footer: {
        Text("QCS — композитный скор качества сигнала (0–100). Порог для S BET — 85, для A BET — 78.")
      }

      Section("Sample") {
        LabeledContent("Класс", value: signal.sampleClass)
        LabeledContent("Матчей хозяев", value: "\(signal.homeSample)")
        LabeledContent("Матчей гостей", value: "\(signal.awaySample)")
      }

      Section {
        LabeledContent("Full Kelly",
                       value: String(format: "%.2f%%", signal.kellyFraction * 100))
        LabeledContent("Quarter Kelly",
                       value: String(format: "%.2f%%", signal.quarterKelly * 100))
        LabeledContent("Stake cap",
                       value: String(format: "%.2f%%", signal.stakeCap * 100))
        HStack {
          Text("Stake").font(.subheadline.bold())
          Spacer()
          if settings.useMoneyStakes, let money = signal.stakeMoney {
            Text(String(format: "%.0f", money))
              .font(.subheadline.monospacedDigit().bold())
          } else {
            Text(String(format: "%.3f%%", signal.stake * 100))
              .font(.subheadline.monospacedDigit().bold())
          }
        }
      } header: {
        Text("Kelly / Stake")
      } footer: {
        Text("Quarter Kelly — консервативный подход (25% от полной формулы Келли). Stake cap — верхняя граница по классу/рынку.")
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
    .task { await loadPreview() }
  }

  private func sampleColor(_ s: String) -> Color {
    switch s {
    case "FULL":   return .green
    case "GOOD":   return .blue
    case "USABLE": return .yellow
    default:       return .orange
    }
  }

  @ViewBuilder
  private var matchPreviewSection: some View {
    Section {
      if previewLoading && homeHistory.isEmpty && awayHistory.isEmpty {
        HStack {
          ProgressView().scaleEffect(0.8)
          Text("Загружаю последние 5 матчей…")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else if let err = previewError {
        Text(err).font(.caption).foregroundStyle(.secondary)
      } else {
        marketFormBlock(title: signal.home, records: homeHistory,
                        accent: .blue, market: signal.market)
        marketFormBlock(title: signal.away, records: awayHistory,
                        accent: .purple, market: signal.market)
        Text(marketHintLine)
          .font(.caption2).foregroundStyle(.tertiary)
      }
    } header: {
      Text("Форма (последние 5 матчей)")
    }
  }

  private var marketHintLine: String {
    switch signal.market {
    case "CORNERS":
      return "В бейдже — свои углы · углы соперника в каждом матче. avg справа — средний тотал за 5 матчей."
    case "CARDS":
      return "В бейдже — свои ЖК · ЖК соперника в каждом матче. avg справа — средний тотал за 5 матчей."
    default:
      return "Показан счёт каждого матча и результат (В/Н/П)."
    }
  }

  @ViewBuilder
  private func marketFormBlock(title: String, records: [TeamRecord],
                               accent: Color, market: String) -> some View {
    let last5 = Array(records.prefix(5))
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.subheadline.bold()).foregroundStyle(accent)
        Spacer()
        if !last5.isEmpty {
          Text(summaryFor(market: market, records: last5))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      if last5.isEmpty {
        Text("Нет данных").font(.caption2).foregroundStyle(.secondary)
      } else {
        HStack(spacing: 6) {
          ForEach(Array(last5.enumerated()), id: \.offset) { (_, r) in
            formBadge(r, market: market)
          }
          Spacer()
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func summaryFor(market: String, records: [TeamRecord]) -> String {
    switch market {
    case "CORNERS":
      let vals = records.compactMap { r -> Double? in
        guard let c = r.corners, let oc = r.oppCorners else { return nil }
        return c + oc
      }
      guard !vals.isEmpty else { return "avg —" }
      let avg = vals.reduce(0, +) / Double(vals.count)
      return String(format: "avg %.1f", avg)
    case "CARDS":
      let vals = records.compactMap { r -> Double? in
        guard let c = r.cardsPlusReds, let oc = r.oppCardsPlusReds else { return nil }
        return c + oc
      }
      guard !vals.isEmpty else { return "avg —" }
      let avg = vals.reduce(0, +) / Double(vals.count)
      return String(format: "avg %.1f", avg)
    default:
      var w = 0, d = 0, l = 0
      for r in records {
        guard let gf = r.gf, let ga = r.ga else { continue }
        if gf > ga { w += 1 } else if gf == ga { d += 1 } else { l += 1 }
      }
      return "\(w)В · \(d)Н · \(l)П"
    }
  }

  @ViewBuilder
  private func formBadge(_ r: TeamRecord, market: String) -> some View {
    switch market {
    case "CORNERS":
      let own = r.corners.map { String(format: "%.0f", $0) } ?? "—"
      let opp = r.oppCorners.map { String(format: "%.0f", $0) } ?? "—"
      VStack(spacing: 1) {
        Text("\(own)·\(opp)").font(.caption2.bold())
        Text("угл").font(.caption2).opacity(0.6)
        Text(r.isHome ? "Д" : "Г").font(.caption2).opacity(0.6)
      }
      .frame(width: 46, height: 46)
      .background(Color.blue.opacity(0.20))
      .clipShape(RoundedRectangle(cornerRadius: 6))

    case "CARDS":
      let own = r.cardsPlusReds.map { String(format: "%.0f", $0) } ?? "—"
      let opp = r.oppCardsPlusReds.map { String(format: "%.0f", $0) } ?? "—"
      VStack(spacing: 1) {
        Text("\(own)·\(opp)").font(.caption2.bold())
        Text("ЖК").font(.caption2).opacity(0.6)
        Text(r.isHome ? "Д" : "Г").font(.caption2).opacity(0.6)
      }
      .frame(width: 46, height: 46)
      .background(Color.orange.opacity(0.20))
      .clipShape(RoundedRectangle(cornerRadius: 6))

    default:
      let gf = r.gf ?? 0
      let ga = r.ga ?? 0
      let (resultChar, color): (String, Color) = {
        if gf > ga { return ("В", .green) }
        if gf == ga { return ("Н", .orange) }
        return ("П", .red)
      }()
      VStack(spacing: 1) {
        Text(resultChar).font(.caption2.bold())
        Text("\(Int(gf)):\(Int(ga))").font(.caption2.monospacedDigit())
        Text(r.isHome ? "Д" : "Г").font(.caption2).opacity(0.6)
      }
      .frame(width: 38, height: 46)
      .background(color.opacity(0.20))
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }

  private func loadPreview() async {
    if previewLoading { return }
    previewLoading = true
    previewError = nil
    defer { previewLoading = false }
    guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { previewError = "Нет API key"; return }

    let client = SStatsClient(settings: settings)
    do {
      let info = try await client.gameInfo(signal.gameID)
      guard let data = info.object?["data"]?.object,
            let game = data["game"]?.object
      else { previewError = "Нет данных матча"; return }

      func extractID(_ side: String) -> String? {
        if let s = game[side + "TeamId"]?.string, !s.isEmpty { return s }
        if let s = game[side + "TeamID"]?.string, !s.isEmpty { return s }
        if let n = game[side + "TeamId"]?.number { return String(Int(n)) }
        if let t = game[side + "Team"]?.object {
          if let s = t["id"]?.string, !s.isEmpty { return s }
          if let n = t["id"]?.number { return String(Int(n)) }
        }
        return nil
      }

      guard let hID = extractID("home"), let aID = extractID("away") else {
        previewError = "Не удалось определить команды"; return
      }

      async let hFetch = client.fetchTeamHistoryEnriched(teamID: hID, count: 5)
      async let aFetch = client.fetchTeamHistoryEnriched(teamID: aID, count: 5)
      let (h, a) = await (hFetch, aFetch)
      homeHistory = h; awayHistory = a
      if h.isEmpty && a.isEmpty {
        previewError = "Нет данных по последним матчам"
      }
    } catch {
      previewError = "Ошибка загрузки: \(error.localizedDescription)"
    }
  }

  private var selectionLine: String {
    if let line = signal.line { return "\(signal.selection) \(line)" }
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
      Text(String(format: "%.1f", value)).font(.subheadline.monospacedDigit())
    }
  }
}

// MARK: - JournalEntryDetailView

struct JournalEntryDetailView: View {
  let entry: JournalEntry
  @EnvironmentObject var settings: AppSettings

  var body: some View {
    List {
      Section("Матч") {
        LabeledContent("Хозяева", value: entry.home)
        LabeledContent("Гости", value: entry.away)
        LabeledContent("Лига", value: entry.league)
        if let s = formatMatchStartLong(entry.matchStart) {
          LabeledContent("Начало", value: s)
        }
        LabeledContent("Рынок", value: entry.market)
        LabeledContent("Выбор", value: selectionLine)
      }
      Section("Статус") {
        LabeledContent("Класс", value: entry.classification)
        LabeledContent("Статус", value: entry.status)
        if let r = entry.result { LabeledContent("Результат", value: r) }
        if let p = entry.profit {
          if let sm = entry.stakeMoney, entry.stake > 0 {
            let money = p / entry.stake * sm
            LabeledContent("P/L", value: String(format: "%+.0f", money))
              .foregroundStyle(p >= 0 ? .green : .red)
          } else {
            LabeledContent("P/L", value: String(format: "%+.3f", p))
              .foregroundStyle(p >= 0 ? .green : .red)
          }
        }
        if let clv = entry.clv {
          LabeledContent("CLV", value: String(format: "%+.2f%%", clv * 100))
            .foregroundStyle(clv > 0 ? .green : .red)
        }
        if let mv = entry.movement {
          LabeledContent("Движение линии", value: String(format: "%+.2f%%", mv * 100))
            .foregroundStyle(mv > 0 ? .green : .red)
        }
      }
      Section("Коэффициенты") {
        LabeledContent("Odds",
                       value: OddsFormatter.format(entry.odds, as: settings.oddsFormat))
        if let open = entry.openingOdds {
          LabeledContent("Открытие",
                         value: OddsFormatter.format(open, as: settings.oddsFormat))
        }
        if let close = entry.closingOdds {
          LabeledContent("Закрытие",
                         value: OddsFormatter.format(close, as: settings.oddsFormat))
        }
      }
      Section("Модель") {
        LabeledContent("P", value: String(format: "%.2f%%", entry.probability * 100))
        LabeledContent("EV", value: String(format: "%+.2f%%", entry.ev * 100))
        LabeledContent("Robust EV", value: String(format: "%+.2f%%", entry.robustEV * 100))
        LabeledContent("QCS", value: String(format: "%.1f", entry.qcs))
        LabeledContent("DCS", value: String(format: "%.1f", entry.dcs))
        LabeledContent("Stake", value: String(format: "%.3f%%", entry.stake * 100))
      }
      Section("Идентификаторы") {
        LabeledContent("Game ID", value: entry.gameID)
        LabeledContent("Signal ID", value: entry.id)
        LabeledContent("Создан",
                       value: entry.createdAt.formatted(date: .abbreviated, time: .standard))
      }
      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Разбор записи")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var selectionLine: String {
    if let line = entry.line { return "\(entry.selection) \(line)" }
    return entry.selection
  }
}

// MARK: - SelfTuningView

struct SelfTuningView: View {
  @Environment(\.modelContext) private var context
  @Query private var configs: [TuningConfig]
  @Query(sort: \TuningEvent.createdAt, order: .reverse) private var events: [TuningEvent]
  @Query(sort: \JournalEntry.createdAt, order: .reverse) private var journal: [JournalEntry]
  @Query private var snapshots: [BacktestSnapshot]

  @State private var rollbackMessage: String? = nil

  private var config: TuningConfig? { configs.first }
  private var snapshot: BacktestSnapshot? { snapshots.first }

  private var correlationMatrix: CorrelationMatrix {
    CorrelationBuilder.build(from: journal)
  }

  var body: some View {
    List {
      if let cfg = config {
        decisionsSection(cfg)
        marketsSection(cfg)
        thresholdsSection(cfg)
        marketThresholdsSection(cfg)
        oosThresholdsSection(cfg)
        cornersWeightsSection(cfg)
        cardsWeightsSection(cfg)
        eventsSection
        resetSection
      } else {
        Section {
          Text("Конфиг не создан. Перезапустите приложение.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section { Color.clear.frame(height: 56).listRowBackground(Color.clear) }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Self-Tuning")
    .navigationBarTitleDisplayMode(.large)
    .onAppear {
      if configs.isEmpty { _ = TuningService.fetchOrCreate(in: context) }
    }
  }

  @ViewBuilder
  private func decisionsSection(_ cfg: TuningConfig) -> some View {
    let decisions = TuningService.decisions(config: cfg, snapshot: snapshot,
                                            journal: journal, corr: correlationMatrix)
    Section {
      ForEach(decisions) { d in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(d.title).font(.subheadline.bold())
            Spacer()
            Toggle("", isOn: Binding(
              get: { d.enabled },
              set: { newValue in setFlag(d.flagKey, value: newValue, in: cfg) }
            ))
            .labelsHidden()
          }
          Text(d.summary).font(.caption).foregroundStyle(.secondary)
          Text(d.detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
      }
    } header: {
      Text("Активные механизмы")
    } footer: {
      Text("Отключённый механизм не применяется при следующем скане.")
    }
  }

  @ViewBuilder
  private func marketsSection(_ cfg: TuningConfig) -> some View {
    Section {
      Toggle(isOn: Binding(
        get: { cfg.cornersEnabled },
        set: { v in setFlag("cornersEnabled", value: v, in: cfg) }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Рынок CORNERS").font(.subheadline)
          Text("Углы. Edge vs Pinnacle (sharp).")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      Toggle(isOn: Binding(
        get: { cfg.cardsEnabled },
        set: { v in setFlag("cardsEnabled", value: v, in: cfg) }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Рынок CARDS").font(.subheadline)
          Text("ЖК + красные. Edge vs best available.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Рынки")
    } footer: {
      Text("Выключенный рынок не генерирует сигналы — ни в скане, ни в portfolio.")
    }
  }

  private func setFlag(_ key: String, value: Bool, in cfg: TuningConfig) {
    let before = currentFlagValue(key, cfg)
    switch key {
    case "autoExcludeEnabled": cfg.autoExcludeEnabled = value
    case "posteriorEnabled": cfg.posteriorEnabled = value
    case "stopLossEnabled": cfg.stopLossEnabled = value
    case "correlationEnabled": cfg.correlationEnabled = value
    case "playerImpactEnabled": cfg.playerImpactEnabled = value
    case "teamRatingEnabled": cfg.teamRatingEnabled = value
    case "cornersEnabled": cfg.cornersEnabled = value
    case "cardsEnabled": cfg.cardsEnabled = value
    case "oosGateEnabled": cfg.oosGateEnabled = value
    default: return
    }
    cfg.updatedAt = Date()
    TuningService.log(context: context, kind: "toggle", target: key,
                      before: before ? "on" : "off",
                      after: value ? "on" : "off",
                      note: "Переключение флага")
  }

  private func currentFlagValue(_ key: String, _ cfg: TuningConfig) -> Bool {
    switch key {
    case "autoExcludeEnabled": return cfg.autoExcludeEnabled
    case "posteriorEnabled": return cfg.posteriorEnabled
    case "stopLossEnabled": return cfg.stopLossEnabled
    case "correlationEnabled": return cfg.correlationEnabled
    case "playerImpactEnabled": return cfg.playerImpactEnabled
    case "teamRatingEnabled": return cfg.teamRatingEnabled
    case "cornersEnabled": return cfg.cornersEnabled
    case "cardsEnabled": return cfg.cardsEnabled
    case "oosGateEnabled": return cfg.oosGateEnabled
    default: return false
    }
  }

  @ViewBuilder
  private func thresholdsSection(_ cfg: TuningConfig) -> some View {
    Section {
      thresholdRow("posteriorWeight", label: "Вес posterior",
        formattedValue: String(format: "%.2f", cfg.posteriorWeight),
        onDelta: { d in cfg.posteriorWeight = max(0.0, min(0.5, cfg.posteriorWeight + d)) },
        currentString: { String(format: "%.4f", cfg.posteriorWeight) },
        step: 0.05, rangeLabel: "0.00 – 0.50")

      thresholdRow("autoExcludeMinROI", label: "Auto-Exclude min ROI",
        formattedValue: String(format: "%.1f%%", cfg.autoExcludeMinROI * 100),
        onDelta: { d in cfg.autoExcludeMinROI = max(-0.5, min(0.0, cfg.autoExcludeMinROI + d)) },
        currentString: { String(format: "%.4f", cfg.autoExcludeMinROI) },
        step: 0.005, rangeLabel: "−50% … 0%")

      thresholdRow("autoExcludeMinBets", label: "Auto-Exclude min n",
        formattedValue: "\(cfg.autoExcludeMinBets)",
        onDelta: { d in
          let v = cfg.autoExcludeMinBets + Int(d.rounded())
          cfg.autoExcludeMinBets = max(5, min(200, v))
        },
        currentString: { "\(cfg.autoExcludeMinBets)" },
        step: 5, rangeLabel: "5 – 200")

      thresholdRow("stopLossCapStreak", label: "Stop-loss: cap после N LOSS",
        formattedValue: "\(cfg.stopLossCapStreak)",
        onDelta: { d in
          let v = cfg.stopLossCapStreak + Int(d.rounded())
          cfg.stopLossCapStreak = max(2, min(10, v))
        },
        currentString: { "\(cfg.stopLossCapStreak)" },
        step: 1, rangeLabel: "2 – 10")

      thresholdRow("stopLossPauseStreak", label: "Stop-loss: pause после N LOSS",
        formattedValue: "\(cfg.stopLossPauseStreak)",
        onDelta: { d in
          let v = cfg.stopLossPauseStreak + Int(d.rounded())
          let lower = cfg.stopLossCapStreak + 1
          cfg.stopLossPauseStreak = max(lower, min(15, v))
        },
        currentString: { "\(cfg.stopLossPauseStreak)" },
        step: 1, rangeLabel: "> cap · … · 15")
    } header: {
      Text("Пороги (глобальные)")
    }
  }

  @ViewBuilder
  private func marketThresholdsSection(_ cfg: TuningConfig) -> some View {
    Section {
      thresholdRow("cornersMinEV", label: "CORNERS min EV",
        formattedValue: String(format: "%.1f%%", cfg.cornersMinEV * 100),
        onDelta: { d in cfg.cornersMinEV = max(0.0, min(0.30, cfg.cornersMinEV + d)) },
        currentString: { String(format: "%.4f", cfg.cornersMinEV) },
        step: 0.005, rangeLabel: "0% … 30%")

      thresholdRow("cornersMinQCS", label: "CORNERS min QCS",
        formattedValue: String(format: "%.0f", cfg.cornersMinQCS),
        onDelta: { d in cfg.cornersMinQCS = max(40, min(100, cfg.cornersMinQCS + d)) },
        currentString: { String(format: "%.0f", cfg.cornersMinQCS) },
        step: 2, rangeLabel: "40 – 100")

      thresholdRow("cornersMaxStake", label: "CORNERS max stake",
        formattedValue: String(format: "%.1f%%", cfg.cornersMaxStake * 100),
        onDelta: { d in cfg.cornersMaxStake = max(0.002, min(0.10, cfg.cornersMaxStake + d)) },
        currentString: { String(format: "%.4f", cfg.cornersMaxStake) },
        step: 0.002, rangeLabel: "0.2% … 10%")

      thresholdRow("cornersMinSample", label: "CORNERS min sample",
        formattedValue: "\(cfg.cornersMinSample)",
        onDelta: { d in
          let v = cfg.cornersMinSample + Int(d.rounded())
          cfg.cornersMinSample = max(2, min(20, v))
        },
        currentString: { "\(cfg.cornersMinSample)" },
        step: 1, rangeLabel: "2 – 20")

      thresholdRow("cornersMinRobustEV", label: "CORNERS min robustEV",
        formattedValue: String(format: "%.1f%%", cfg.cornersMinRobustEV * 100),
        onDelta: { d in cfg.cornersMinRobustEV = max(-0.05, min(0.10, cfg.cornersMinRobustEV + d)) },
        currentString: { String(format: "%.4f", cfg.cornersMinRobustEV) },
        step: 0.005, rangeLabel: "−5% … 10%")

      thresholdRow("cornersMinMSS", label: "CORNERS min MSS",
        formattedValue: String(format: "%.0f", cfg.cornersMinMSS),
        onDelta: { d in cfg.cornersMinMSS = max(0, min(100, cfg.cornersMinMSS + d)) },
        currentString: { String(format: "%.0f", cfg.cornersMinMSS) },
        step: 5, rangeLabel: "0 – 100")

      thresholdRow("cornersMaxUncertainty", label: "CORNERS max uncertainty",
        formattedValue: String(format: "%.2f", cfg.cornersMaxUncertainty),
        onDelta: { d in cfg.cornersMaxUncertainty = max(0.05, min(0.40, cfg.cornersMaxUncertainty + d)) },
        currentString: { String(format: "%.4f", cfg.cornersMaxUncertainty) },
        step: 0.01, rangeLabel: "0.05 – 0.40")
    } header: {
      Text("Пороги CORNERS (углы)")
    }

    Section {
      thresholdRow("cardsMinEV", label: "CARDS min EV",
        formattedValue: String(format: "%.1f%%", cfg.cardsMinEV * 100),
        onDelta: { d in cfg.cardsMinEV = max(0.0, min(0.30, cfg.cardsMinEV + d)) },
        currentString: { String(format: "%.4f", cfg.cardsMinEV) },
        step: 0.005, rangeLabel: "0% … 30%")

      thresholdRow("cardsMinQCS", label: "CARDS min QCS",
        formattedValue: String(format: "%.0f", cfg.cardsMinQCS),
        onDelta: { d in cfg.cardsMinQCS = max(40, min(100, cfg.cardsMinQCS + d)) },
        currentString: { String(format: "%.0f", cfg.cardsMinQCS) },
        step: 2, rangeLabel: "40 – 100")

      thresholdRow("cardsMaxStake", label: "CARDS max stake",
        formattedValue: String(format: "%.1f%%", cfg.cardsMaxStake * 100),
        onDelta: { d in cfg.cardsMaxStake = max(0.002, min(0.10, cfg.cardsMaxStake + d)) },
        currentString: { String(format: "%.4f", cfg.cardsMaxStake) },
        step: 0.002, rangeLabel: "0.2% … 10%")

      thresholdRow("cardsMinSample", label: "CARDS min sample",
        formattedValue: "\(cfg.cardsMinSample)",
        onDelta: { d in
          let v = cfg.cardsMinSample + Int(d.rounded())
          cfg.cardsMinSample = max(2, min(20, v))
        },
        currentString: { "\(cfg.cardsMinSample)" },
        step: 1, rangeLabel: "2 – 20")

      thresholdRow("cardsMinRobustEV", label: "CARDS min robustEV",
        formattedValue: String(format: "%.1f%%", cfg.cardsMinRobustEV * 100),
        onDelta: { d in cfg.cardsMinRobustEV = max(-0.05, min(0.10, cfg.cardsMinRobustEV + d)) },
        currentString: { String(format: "%.4f", cfg.cardsMinRobustEV) },
        step: 0.005, rangeLabel: "−5% … 10%")

      thresholdRow("cardsMinMSS", label: "CARDS min MSS",
        formattedValue: String(format: "%.0f", cfg.cardsMinMSS),
        onDelta: { d in cfg.cardsMinMSS = max(0, min(100, cfg.cardsMinMSS + d)) },
        currentString: { String(format: "%.0f", cfg.cardsMinMSS) },
        step: 5, rangeLabel: "0 – 100")

      thresholdRow("cardsMaxUncertainty", label: "CARDS max uncertainty",
        formattedValue: String(format: "%.2f", cfg.cardsMaxUncertainty),
        onDelta: { d in cfg.cardsMaxUncertainty = max(0.05, min(0.40, cfg.cardsMaxUncertainty + d)) },
        currentString: { String(format: "%.4f", cfg.cardsMaxUncertainty) },
        step: 0.01, rangeLabel: "0.05 – 0.40")
    } header: {
      Text("Пороги CARDS (ЖК)")
    }

    Section {
      thresholdRow("goalsMinRobustEV", label: "GOALS min robustEV",
        formattedValue: String(format: "%.1f%%", cfg.goalsMinRobustEV * 100),
        onDelta: { d in cfg.goalsMinRobustEV = max(-0.05, min(0.10, cfg.goalsMinRobustEV + d)) },
        currentString: { String(format: "%.4f", cfg.goalsMinRobustEV) },
        step: 0.005, rangeLabel: "−5% … 10%")

      thresholdRow("goalsMinSample", label: "GOALS min sample",
        formattedValue: "\(cfg.goalsMinSample)",
        onDelta: { d in
          let v = cfg.goalsMinSample + Int(d.rounded())
          cfg.goalsMinSample = max(2, min(20, v))
        },
        currentString: { "\(cfg.goalsMinSample)" },
        step: 1, rangeLabel: "2 – 20")

      thresholdRow("goalsMaxUncertainty", label: "GOALS max uncertainty",
        formattedValue: String(format: "%.2f", cfg.goalsMaxUncertainty),
        onDelta: { d in cfg.goalsMaxUncertainty = max(0.05, min(0.40, cfg.goalsMaxUncertainty + d)) },
        currentString: { String(format: "%.4f", cfg.goalsMaxUncertainty) },
        step: 0.01, rangeLabel: "0.05 – 0.40")
    } header: {
      Text("Пороги GOALS")
    }
  }

  // [W3a] OOS-пороги
  @ViewBuilder
  private func oosThresholdsSection(_ cfg: TuningConfig) -> some View {
    Section {
      Toggle(isOn: Binding(
        get: { cfg.oosGateEnabled },
        set: { v in setFlag("oosGateEnabled", value: v, in: cfg) }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("OOS-блокировка рынков").font(.subheadline)
          Text("Блокирует рынок, если журнал за окно показывает минус.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }

      thresholdRow("oosWindowDays", label: "Окно наблюдения (дней)",
        formattedValue: "\(cfg.oosWindowDays)",
        onDelta: { d in
          let v = cfg.oosWindowDays + Int(d.rounded())
          cfg.oosWindowDays = max(14, min(365, v))
        },
        currentString: { "\(cfg.oosWindowDays)" },
        step: 5, rangeLabel: "14 – 365")

      thresholdRow("oosMinBets", label: "Min n в окне",
        formattedValue: "\(cfg.oosMinBets)",
        onDelta: { d in
          let v = cfg.oosMinBets + Int(d.rounded())
          cfg.oosMinBets = max(20, min(500, v))
        },
        currentString: { "\(cfg.oosMinBets)" },
        step: 10, rangeLabel: "20 – 500")

      thresholdRow("goalsOOSMinROI", label: "GOALS min ROI (OOS)",
        formattedValue: String(format: "%.1f%%", cfg.goalsOOSMinROI * 100),
        onDelta: { d in cfg.goalsOOSMinROI = max(-0.20, min(0.05, cfg.goalsOOSMinROI + d)) },
        currentString: { String(format: "%.4f", cfg.goalsOOSMinROI) },
        step: 0.005, rangeLabel: "−20% … 5%")

      thresholdRow("cornersOOSMinROI", label: "CORNERS min ROI (OOS)",
        formattedValue: String(format: "%.1f%%", cfg.cornersOOSMinROI * 100),
        onDelta: { d in cfg.cornersOOSMinROI = max(-0.20, min(0.05, cfg.cornersOOSMinROI + d)) },
        currentString: { String(format: "%.4f", cfg.cornersOOSMinROI) },
        step: 0.005, rangeLabel: "−20% … 5%")

      thresholdRow("cardsOOSMinROI", label: "CARDS min ROI (OOS)",
        formattedValue: String(format: "%.1f%%", cfg.cardsOOSMinROI * 100),
        onDelta: { d in cfg.cardsOOSMinROI = max(-0.20, min(0.05, cfg.cardsOOSMinROI + d)) },
        currentString: { String(format: "%.4f", cfg.cardsOOSMinROI) },
        step: 0.005, rangeLabel: "−20% … 5%")
    } header: {
      Text("OOS-валидация (W3a)")
    } footer: {
      Text("Out-of-sample по реальному журналу. Если по рынку n ≥ Min и ROI ниже порога — рынок автоматически блокируется в сканере. Обновляется после каждой докачки.")
    }
  }

  @ViewBuilder
  private func cornersWeightsSection(_ cfg: TuningConfig) -> some View {
    Section {
      thresholdRow("cornersWeightRecentOwn", label: "Own corners",
        formattedValue: String(format: "%.2f", cfg.cornersWeightRecentOwn),
        onDelta: { d in cfg.cornersWeightRecentOwn = max(0, min(1, cfg.cornersWeightRecentOwn + d)) },
        currentString: { String(format: "%.4f", cfg.cornersWeightRecentOwn) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cornersWeightRecentOpp", label: "Opp corners",
        formattedValue: String(format: "%.2f", cfg.cornersWeightRecentOpp),
        onDelta: { d in cfg.cornersWeightRecentOpp = max(0, min(1, cfg.cornersWeightRecentOpp + d)) },
        currentString: { String(format: "%.4f", cfg.cornersWeightRecentOpp) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cornersWeightLeague", label: "League avg",
        formattedValue: String(format: "%.2f", cfg.cornersWeightLeague),
        onDelta: { d in cfg.cornersWeightLeague = max(0, min(1, cfg.cornersWeightLeague + d)) },
        currentString: { String(format: "%.4f", cfg.cornersWeightLeague) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cornersWeightXG", label: "xG factor",
        formattedValue: String(format: "%.2f", cfg.cornersWeightXG),
        onDelta: { d in cfg.cornersWeightXG = max(0, min(1, cfg.cornersWeightXG + d)) },
        currentString: { String(format: "%.4f", cfg.cornersWeightXG) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cornersWeightPossession", label: "Possession",
        formattedValue: String(format: "%.2f", cfg.cornersWeightPossession),
        onDelta: { d in cfg.cornersWeightPossession = max(0, min(1, cfg.cornersWeightPossession + d)) },
        currentString: { String(format: "%.4f", cfg.cornersWeightPossession) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cornersWeightH2H", label: "H2H",
        formattedValue: String(format: "%.2f", cfg.cornersWeightH2H),
        onDelta: { d in cfg.cornersWeightH2H = max(0, min(1, cfg.cornersWeightH2H + d)) },
        currentString: { String(format: "%.4f", cfg.cornersWeightH2H) },
        step: 0.05, rangeLabel: "0.00 – 1.00")
    } header: {
      Text("Веса λ CORNERS")
    } footer: {
      Text("Сумма весов не обязана быть 1 — нормализуется автоматически. Own/Opp разлагают λ на «создаёт» и «позволяет».")
    }
  }

  @ViewBuilder
  private func cardsWeightsSection(_ cfg: TuningConfig) -> some View {
    Section {
      thresholdRow("cardsWeightRecentOwn", label: "Own cards",
        formattedValue: String(format: "%.2f", cfg.cardsWeightRecentOwn),
        onDelta: { d in cfg.cardsWeightRecentOwn = max(0, min(1, cfg.cardsWeightRecentOwn + d)) },
        currentString: { String(format: "%.4f", cfg.cardsWeightRecentOwn) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cardsWeightRecentOpp", label: "Opp cards",
        formattedValue: String(format: "%.2f", cfg.cardsWeightRecentOpp),
        onDelta: { d in cfg.cardsWeightRecentOpp = max(0, min(1, cfg.cardsWeightRecentOpp + d)) },
        currentString: { String(format: "%.4f", cfg.cardsWeightRecentOpp) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cardsWeightLeague", label: "League avg",
        formattedValue: String(format: "%.2f", cfg.cardsWeightLeague),
        onDelta: { d in cfg.cardsWeightLeague = max(0, min(1, cfg.cardsWeightLeague + d)) },
        currentString: { String(format: "%.4f", cfg.cardsWeightLeague) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cardsWeightFouls", label: "Fouls factor",
        formattedValue: String(format: "%.2f", cfg.cardsWeightFouls),
        onDelta: { d in cfg.cardsWeightFouls = max(0, min(1, cfg.cardsWeightFouls + d)) },
        currentString: { String(format: "%.4f", cfg.cardsWeightFouls) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cardsWeightReferee", label: "Referee",
        formattedValue: String(format: "%.2f", cfg.cardsWeightReferee),
        onDelta: { d in cfg.cardsWeightReferee = max(0, min(1, cfg.cardsWeightReferee + d)) },
        currentString: { String(format: "%.4f", cfg.cardsWeightReferee) },
        step: 0.05, rangeLabel: "0.00 – 1.00")

      thresholdRow("cardsWeightH2H", label: "H2H",
        formattedValue: String(format: "%.2f", cfg.cardsWeightH2H),
        onDelta: { d in cfg.cardsWeightH2H = max(0, min(1, cfg.cardsWeightH2H + d)) },
        currentString: { String(format: "%.4f", cfg.cardsWeightH2H) },
        step: 0.05, rangeLabel: "0.00 – 1.00")
    } header: {
      Text("Веса λ CARDS")
    } footer: {
      Text("Сумма весов не обязана быть 1 — нормализуется автоматически.")
    }
  }

  @ViewBuilder
  private func thresholdRow(_ key: String, label: String,
                            formattedValue: String,
                            onDelta: @escaping (Double) -> Void,
                            currentString: @escaping () -> String,
                            step: Double, rangeLabel: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label).font(.subheadline)
        Spacer()
        Text(formattedValue).font(.subheadline.monospacedDigit().bold())
          .foregroundStyle(.blue)
      }
      HStack(spacing: 8) {
        Button {
          let b = currentString(); onDelta(-step); let a = currentString()
          TuningService.log(context: context, kind: "threshold", target: key,
                            before: b, after: a, note: label)
        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.blue) }
        .buttonStyle(.plain)

        Button {
          let b = currentString(); onDelta(step); let a = currentString()
          TuningService.log(context: context, kind: "threshold", target: key,
                            before: b, after: a, note: label)
        } label: { Image(systemName: "plus.circle.fill").foregroundStyle(.blue) }
        .buttonStyle(.plain)

        Spacer()
        Text(rangeLabel).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var eventsSection: some View {
    Section {
      Button {
        if let rb = TuningService.rollbackLastThreshold(in: context) {
          rollbackMessage = "Откат: \(rb.target) → \(rb.beforeValue)"
        } else {
          rollbackMessage = "Нет изменений для отката"
        }
      } label: {
        Label("Откатить последнее изменение", systemImage: "arrow.uturn.backward")
      }
      if let msg = rollbackMessage {
        Text(msg).font(.caption).foregroundStyle(.secondary)
      }
      if events.isEmpty {
        Text("Журнал пуст").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(events.prefix(30)) { e in
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(kindLabel(e.kind)).font(.caption2.bold())
                  .foregroundStyle(kindColor(e.kind))
                Text(e.target).font(.caption.monospaced())
              }
              HStack(spacing: 4) {
                Text(e.beforeValue).font(.caption2.monospacedDigit())
                  .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2)
                  .foregroundStyle(.secondary)
                Text(e.afterValue).font(.caption2.monospacedDigit())
                  .foregroundStyle(.primary)
              }
              if !e.note.isEmpty {
                Text(e.note).font(.caption2).foregroundStyle(.tertiary)
              }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text(e.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
              if e.rolledBack {
                Text("откатано").font(.caption2).foregroundStyle(.orange)
              }
            }
          }
          .padding(.vertical, 2)
        }
      }
    } header: {
      Text("Журнал изменений")
    } footer: {
      Text("Показываются последние 30 событий. Каждое изменение порога или тумблера логируется с возможностью отката.")
    }
  }

  private func kindLabel(_ k: String) -> String {
    switch k {
    case "toggle": return "TOGGLE"
    case "threshold": return "THRESH"
    case "rollback": return "ROLL"
    case "auto": return "AUTO"
    default: return k.uppercased()
    }
  }

  private func kindColor(_ k: String) -> Color {
    switch k {
    case "toggle": return .blue
    case "threshold": return .purple
    case "rollback": return .orange
    case "auto": return .green
    default: return .gray
    }
  }

  @ViewBuilder
  private var resetSection: some View {
    Section {
      Button(role: .destructive) {
        guard let cfg = config else { return }
        let before = "custom"
        cfg.autoExcludeEnabled = true
        cfg.posteriorEnabled = true
        cfg.stopLossEnabled = true
        cfg.correlationEnabled = true
        cfg.playerImpactEnabled = true
        cfg.teamRatingEnabled = true
        cfg.posteriorWeight = 0.15
        cfg.autoExcludeMinROI = -0.05
        cfg.autoExcludeMinBets = 20
        cfg.stopLossCapStreak = 4
        cfg.stopLossPauseStreak = 7
        cfg.cornersEnabled = true
        cfg.cardsEnabled = true
        cfg.cornersMinEV = 0.03
        cfg.cardsMinEV = 0.03
        cfg.cornersMinQCS = 70
        cfg.cardsMinQCS = 70
        cfg.cornersMaxStake = 0.02
        cfg.cardsMaxStake = 0.02
        cfg.cornersMinSample = 5
        cfg.cardsMinSample = 5
        cfg.goalsMinRobustEV = 0.0
        cfg.goalsMinSample = 6
        cfg.goalsMaxUncertainty = 0.25
        cfg.cornersMinRobustEV = 0.0
        cfg.cornersMinMSS = 30
        cfg.cornersMaxUncertainty = 0.22
        cfg.cardsMinRobustEV = 0.0
        cfg.cardsMinMSS = 30
        cfg.cardsMaxUncertainty = 0.22
        cfg.oosGateEnabled = false
        cfg.oosMinBets = 100
        cfg.oosWindowDays = 90
        cfg.goalsOOSMinROI = -0.03
        cfg.cornersOOSMinROI = -0.03
        cfg.cardsOOSMinROI = -0.03
        cfg.cornersWeightRecentOwn = 0.35
        cfg.cornersWeightRecentOpp = 0.25
        cfg.cornersWeightLeague = 0.15
        cfg.cornersWeightXG = 0.10
        cfg.cornersWeightPossession = 0.05
        cfg.cornersWeightH2H = 0.10
        cfg.cardsWeightRecentOwn = 0.30
        cfg.cardsWeightRecentOpp = 0.20
        cfg.cardsWeightLeague = 0.15
        cfg.cardsWeightFouls = 0.10
        cfg.cardsWeightReferee = 0.20
        cfg.cardsWeightH2H = 0.05
        cfg.updatedAt = Date()
        TuningService.log(context: context, kind: "threshold", target: "all",
                          before: before, after: "defaults", note: "Сброс к дефолтам")
        rollbackMessage = "Сброшено к дефолтам"
      } label: {
        Label("Сбросить к дефолтам", systemImage: "arrow.clockwise")
      }
    } header: {
      Text("Сброс")
    }
  }
}
