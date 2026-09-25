import Charts
import SwiftData
import SwiftUI

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

  private var currentSnapshot: BacktestSnapshot? { snapshots.first }
  private var tuningConfig: TuningConfig? { tuningConfigs.first }

  private var correlationMatrix: CorrelationMatrix {
    CorrelationBuilder.build(from: journal)
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack { forecast }
        .tabItem { Label("Прогноз", systemImage: "sparkles") }
        .tag(0)
      NavigationStack { journalView }
        .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
        .tag(1)
      NavigationStack { autoView }
        .tabItem { Label("Авто", systemImage: "gearshape.2") }
        .tag(2)
      NavigationStack { diagnosticsView }
        .tabItem { Label("Контроль", systemImage: "checkmark.shield") }
        .tag(3)
      NavigationStack { settingsView }
        .tabItem { Label("Настройки", systemImage: "gearshape") }
        .tag(4)
    }
    .tint(.blue)
    .preferredColorScheme(settings.colorScheme.toColorScheme)
    .task {
      _ = BacktestService.fetchOrCreate(in: context)
      _ = TuningService.fetchOrCreate(in: context)
      await refresh()
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
          ContentUnavailableView(
            "Запись не найдена", systemImage: "magnifyingglass",
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
            SignalCard(signal: s, oddsFormat: settings.oddsFormat)
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
            NavigationLink {
              JournalEntryDetailView(entry: e)
            } label: {
              journalRow(e)
            }
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
    let curve = Metrics.equityCurve(journal, bankroll: settings.effectiveBankroll)
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
        Text("Auto-Exclude, posterior (B2), TeamRating (B3), корреляция (B4), stop-loss (B5), player impact (B6).")
          .font(.caption).foregroundStyle(.secondary)
      }

      selfTuningLinkSection
      liveMonitorSection
      leagueMarketHeatmapSection

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
      LabeledContent("Матчей под наблюдением",
                     value: "\(liveMonitor.snapshots.count)")
      if let t = liveMonitor.lastTick {
        LabeledContent("Последний цикл",
                       value: t.formatted(date: .omitted, time: .standard))
      }
      if let err = liveMonitor.lastError {
        Text(err).font(.caption).foregroundStyle(.orange)
      }

      if liveMonitor.isRunning {
        Button(role: .destructive) {
          liveMonitor.stop()
        } label: {
          Label("Остановить", systemImage: "stop.circle")
        }
      } else {
        Button {
          liveMonitor.start(settings: settings)
        } label: {
          Label("Запустить", systemImage: "play.circle")
        }
        .disabled(!settings.liveMonitorEnabled || signals.isEmpty)
      }
    } header: {
      Text("Live (D1)")
    } footer: {
      Text("Следит за активными матчами раз в \(settings.liveMonitorIntervalSec) сек. Запускается автоматически после скана, если включено в Настройках.")
    }

    if !liveMonitor.movements.isEmpty {
      Section("Движения линии (D2)") {
        let top = liveMonitor.movements.prefix(5)
        ForEach(Array(top)) { m in
          HStack(alignment: .top, spacing: 8) {
            Text(m.direction)
              .font(.body.bold())
              .foregroundStyle(m.delta < 0 ? .green : (m.delta > 0 ? .red : .secondary))
            VStack(alignment: .leading, spacing: 2) {
              Text("\(m.market) · \(m.selection)\(m.line.map { " \($0)" } ?? "")")
                .font(.caption)
                .lineLimit(1)
              Text(String(format: "%.2f → %.2f · книг: %d",
                          m.previousAvg, m.currentAvg, m.booksAgreeing))
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if m.isSharp {
              Text("SHARP")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.purple)
                .clipShape(Capsule())
            }
            Text(String(format: "%+.1f%%", m.delta * 100))
              .font(.caption.monospacedDigit())
              .foregroundStyle(m.delta < 0 ? .green : .red)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var selfTuningLinkSection: some View {
    Section {
      NavigationLink {
        SelfTuningView()
      } label: {
        HStack {
          Image(systemName: "slider.horizontal.3")
            .foregroundStyle(.blue)
          VStack(alignment: .leading, spacing: 2) {
            Text("Self-Tuning панель").font(.headline)
            if let cfg = tuningConfig {
              Text("Активных: \(activeCount(cfg)) из 6 · порогов: 5")
                .font(.caption).foregroundStyle(.secondary)
            } else {
              Text("Открыть настройки автотюнинга")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
        }
      }
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
    return n
  }

  @ViewBuilder
  private var leagueMarketHeatmapSection: some View {
    let stats = currentSnapshot?.decodedLeagueMarketStats() ?? [:]
    if !stats.isEmpty {
      let leagues = LeaguePool.pool.map { $0.name }
      let markets = ["1X2", "GOALS", "CARDS", "CORNERS"]
      Section("Лиги × Рынки (ROI)") {
        Text("Цвет: зелёный — плюс, красный — минус. Точки: n ставок.")
          .font(.caption2).foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: false) {
          Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
              Text("").frame(width: 100, alignment: .leading)
              ForEach(markets, id: \.self) { mk in
                Text(mk)
                  .font(.caption2.bold())
                  .frame(width: 66)
              }
            }
            ForEach(leagues, id: \.self) { lg in
              GridRow {
                Text(lg)
                  .font(.caption2)
                  .frame(width: 100, alignment: .leading)
                  .lineLimit(1)
                ForEach(markets, id: \.self) { mk in
                  let key = "\(lg)|\(mk)"
                  let s = stats[key]
                  heatCell(s)
                }
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

  @ViewBuilder
  private func heatCell(_ s: StoredSegmentStats?) -> some View {
    if let s, s.bets > 0 {
      VStack(spacing: 1) {
        Text(String(format: "%+.0f%%", s.roi * 100))
          .font(.caption2.monospacedDigit().bold())
        Text("n=\(s.bets)")
          .font(.caption2)
          .opacity(0.7)
      }
      .frame(width: 66, height: 34)
      .background(heatColor(s.roi).opacity(0.28))
      .clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
      Text("—")
        .font(.caption2)
        .foregroundStyle(.secondary)
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
    let ev = VolatilityStop.evaluate(
      journal, capThreshold: cap, pauseThreshold: pause)
    Section("Volatility stop (B5)") {
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
    }
  }

  @ViewBuilder
  private var correlationSection: some View {
    let m = correlationMatrix
    let enabled = tuningConfig?.correlationEnabled ?? true
    Section("Correlation matrix (B4)") {
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
    let enabled = tuningConfig?.playerImpactEnabled ?? true
    Section("Player impact (B6)") {
      LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
      Text("Применяется, когда в gameInfo есть состав (lineups) и у команды ≥ 6 игроков в истории. Отсутствие топ-8 → −5…−12% к λ.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var teamRatingsSection: some View {
    let top = Array(teamRatings.prefix(20))
    let enabled = tuningConfig?.teamRatingEnabled ?? true
    if !top.isEmpty || !enabled {
      Section("Team ratings (B3)") {
        LabeledContent("Флаг", value: enabled ? "включён" : "ВЫКЛ")
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
    let cfg = tuningConfig
    let minROI = cfg?.autoExcludeMinROI ?? AutoExclude.defaultMinROI
    let minBets = cfg?.autoExcludeMinBets ?? AutoExclude.defaultMinBets
    let enabled = cfg?.autoExcludeEnabled ?? true
    let rules = AutoExclude.rules(from: snap, minROI: minROI, minBets: minBets)
    let excluded = rules.filter { $0.excluded }
    Section("Auto-Exclude") {
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
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.red)
          }
        }
      }
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
    Section("Posterior buckets (B2)") {
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
      Section("Self-Tuning") {
        if let cfg = tuningConfig {
          LabeledContent("Активных механизмов",
                         value: "\(activeCount(cfg)) из 6")
          LabeledContent("posteriorWeight",
                         value: String(format: "%.2f", cfg.posteriorWeight))
          LabeledContent("autoExcludeMinROI",
                         value: String(format: "%.1f%%", cfg.autoExcludeMinROI * 100))
          LabeledContent("autoExcludeMinBets",
                         value: "\(cfg.autoExcludeMinBets)")
          LabeledContent("stopLossCap/Pause",
                         value: "\(cfg.stopLossCapStreak)/\(cfg.stopLossPauseStreak)")
          LabeledContent("Событий в логе", value: "\(tuningEvents.count)")
        } else {
          Text("Конфиг не создан")
            .font(.caption).foregroundStyle(.secondary)
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
      Section("Live-монитор (D1)") {
        LabeledContent("Статус", value: liveMonitor.isRunning ? "идёт" : "стоп")
        LabeledContent("Матчей", value: "\(liveMonitor.snapshots.count)")
        LabeledContent("Движений", value: "\(liveMonitor.movements.count)")
        let sharpCount = liveMonitor.movements.filter { $0.isSharp }.count
        LabeledContent("Sharp", value: "\(sharpCount)")
        if let t = liveMonitor.lastTick {
          LabeledContent("Last tick",
                         value: t.formatted(date: .omitted, time: .standard))
        }
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
      Section("Отображение") {
        Picker("Формат коэффициентов", selection: $settings.oddsFormatRaw) {
          ForEach(OddsFormat.allCases) { f in
            Text(f.label).tag(f.rawValue)
          }
        }
        Text(settings.oddsFormat.hint)
          .font(.caption2).foregroundStyle(.secondary)

        Picker("Тема", selection: $settings.colorSchemeRaw) {
          ForEach(AppColorScheme.allCases) { s in
            Text(s.label).tag(s.rawValue)
          }
        }
      }
      Section("Банк") {
        Toggle("Ставки в деньгах", isOn: $settings.useMoneyStakes)
        if settings.useMoneyStakes {
          HStack {
            Text("Размер банка")
            Spacer()
            TextField("0", value: $settings.bankroll, format: .number)
              .keyboardType(.decimalPad)
              .multilineTextAlignment(.trailing)
              .frame(width: 140)
              .monospacedDigit()
          }
        }
        Text("При включённом режиме стейк отображается в деньгах (2% банка = 0.02 × размер).")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Section("Live-монитор") {
        Toggle("Следить за линией", isOn: $settings.liveMonitorEnabled)
        if settings.liveMonitorEnabled {
          Stepper("Интервал: \(settings.liveMonitorIntervalSec) сек",
                  value: $settings.liveMonitorIntervalSec,
                  in: 30...300, step: 30)
        }
        Text("Опрашивает /Odds/live/{id}. Если эндпоинт недоступен — использует /Odds/{id}.")
          .font(.caption2).foregroundStyle(.secondary)
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

    // Волна D (D1): регистрируем активные матчи для live-монитора.
    liveMonitor.clearObserved()
    for s in signals {
      liveMonitor.observe(gameID: s.gameID, numericID: Int(s.gameID))
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
  }

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
      Text(marketLine)
        .font(.subheadline).foregroundStyle(.secondary)
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
        if signal.posteriorWeight != nil { Text("PST").foregroundStyle(.purple) }
        if signal.stopApplied != nil { Text("STOP").foregroundStyle(.red) }
        if signal.playerImpactHome != nil || signal.playerImpactAway != nil {
          Text("PLR").foregroundStyle(.orange)
        }
        if signal.sharpMoney == true { Text("SHARP").foregroundStyle(.purple) }
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
        LabeledContent("Рынок", value: signal.market)
        LabeledContent("Выбор", value: selectionLine)
      }

      matchPreviewSection

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
        LabeledContent("Odds", value: OddsFormatter.format(signal.odds, as: settings.oddsFormat))
        LabeledContent("Fair odds",
                       value: OddsFormatter.format(signal.fairOdds, as: settings.oddsFormat))
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
          if signal.bookmakers >= 3, avg > 0 {
            let spread = (best - worst) / avg * 100
            Text(String(format: "Разброс: %.1f%%", spread))
              .font(.caption2).foregroundStyle(.secondary)
          }
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
                .foregroundStyle(.purple)
                .font(.subheadline.bold())
            }
            Text("≥3 книги одновременно двигают линию в одну сторону.")
              .font(.caption2).foregroundStyle(.secondary)
          } else {
            Text("Движение односторонним не признано")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
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
        }
      }

      Section("Интервал неопределённости") {
        HStack {
          intervalBlock("P10", String(format: "%.1f%%", signal.probabilityLow * 100))
          intervalBlock("P50", String(format: "%.1f%%", signal.probability * 100))
          intervalBlock("P90", String(format: "%.1f%%", signal.probabilityHigh * 100))
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
          if settings.useMoneyStakes, let money = signal.stakeMoney {
            Text(String(format: "%.0f", money))
              .font(.subheadline.monospacedDigit().bold())
          } else {
            Text(String(format: "%.3f%%", signal.stake * 100))
              .font(.subheadline.monospacedDigit().bold())
          }
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
    .task {
      await loadPreview()
    }
  }

  @ViewBuilder
  private var matchPreviewSection: some View {
    Section("Форма (последние матчи)") {
      if previewLoading && homeHistory.isEmpty && awayHistory.isEmpty {
        HStack {
          ProgressView().scaleEffect(0.8)
          Text("Загружаю последние матчи…")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else if let err = previewError {
        Text(err).font(.caption).foregroundStyle(.secondary)
      } else {
        teamFormBlock(
          title: signal.home,
          records: homeHistory,
          accent: .blue)
        teamFormBlock(
          title: signal.away,
          records: awayHistory,
          accent: .purple)
      }
    }
  }

  @ViewBuilder
  private func teamFormBlock(
    title: String, records: [TeamRecord], accent: Color
  ) -> some View {
    let last5 = Array(records.prefix(5))
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.subheadline.bold())
          .foregroundStyle(accent)
        Spacer()
        if !last5.isEmpty {
          let summary = formSummary(last5)
          Text(summary).font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      if last5.isEmpty {
        Text("Нет данных")
          .font(.caption2).foregroundStyle(.secondary)
      } else {
        HStack(spacing: 6) {
          ForEach(Array(last5.enumerated()), id: \.offset) { (_, r) in
            formBadge(r)
          }
          Spacer()
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func formSummary(_ records: [TeamRecord]) -> String {
    var w = 0, d = 0, l = 0
    for r in records {
      guard let gf = r.gf, let ga = r.ga else { continue }
      if gf > ga { w += 1 }
      else if gf == ga { d += 1 }
      else { l += 1 }
    }
    return "\(w)В · \(d)Н · \(l)П"
  }

  private func formBadge(_ r: TeamRecord) -> some View {
    let gf = r.gf ?? 0
    let ga = r.ga ?? 0
    let (resultChar, color): (String, Color) = {
      if gf > ga { return ("В", .green) }
      if gf == ga { return ("Н", .orange) }
      return ("П", .red)
    }()
    return VStack(spacing: 1) {
      Text(resultChar)
        .font(.caption2.bold())
      Text("\(Int(gf)):\(Int(ga))")
        .font(.caption2.monospacedDigit())
      Text(r.isHome ? "Д" : "Г")
        .font(.caption2)
        .opacity(0.6)
    }
    .frame(width: 38, height: 46)
    .background(color.opacity(0.20))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private func loadPreview() async {
    if previewLoading { return }
    previewLoading = true
    previewError = nil
    defer { previewLoading = false }

    guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      previewError = "Нет API key"
      return
    }

    let client = SStatsClient(settings: settings)
    do {
      let info = try await client.gameInfo(signal.gameID)
      guard let data = info.object?["data"]?.object,
            let game = data["game"]?.object
      else {
        previewError = "Нет данных матча"
        return
      }

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
        previewError = "Не удалось определить команды"
        return
      }

      async let hFetch = client.fetchTeamHistory(teamID: hID, count: 5)
      async let aFetch = client.fetchTeamHistory(teamID: aID, count: 5)
      let (h, a) = await (hFetch, aFetch)
      homeHistory = h
      awayHistory = a
      if h.isEmpty && a.isEmpty {
        previewError = "Нет данных по последним матчам"
      }
    } catch {
      previewError = "Ошибка загрузки: \(error.localizedDescription)"
    }
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
    if let line = entry.line {
      return "\(entry.selection) \(line)"
    }
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
        thresholdsSection(cfg)
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
      if configs.isEmpty {
        _ = TuningService.fetchOrCreate(in: context)
      }
    }
  }

  @ViewBuilder
  private func decisionsSection(_ cfg: TuningConfig) -> some View {
    let decisions = TuningService.decisions(
      config: cfg,
      snapshot: snapshot,
      journal: journal,
      corr: correlationMatrix)
    Section {
      ForEach(decisions) { d in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(d.title).font(.subheadline.bold())
            Spacer()
            Toggle("", isOn: Binding(
              get: { d.enabled },
              set: { newValue in
                setFlag(d.flagKey, value: newValue, in: cfg)
              }
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

  private func setFlag(_ key: String, value: Bool, in cfg: TuningConfig) {
    let before = currentFlagValue(key, cfg)
    switch key {
    case "autoExcludeEnabled": cfg.autoExcludeEnabled = value
    case "posteriorEnabled": cfg.posteriorEnabled = value
    case "stopLossEnabled": cfg.stopLossEnabled = value
    case "correlationEnabled": cfg.correlationEnabled = value
    case "playerImpactEnabled": cfg.playerImpactEnabled = value
    case "teamRatingEnabled": cfg.teamRatingEnabled = value
    default: return
    }
    cfg.updatedAt = Date()
    TuningService.log(
      context: context,
      kind: "toggle", target: key,
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
    default: return false
    }
  }

  @ViewBuilder
  private func thresholdsSection(_ cfg: TuningConfig) -> some View {
    Section {
      thresholdRow(
        "posteriorWeight",
        label: "Вес posterior",
        formattedValue: String(format: "%.2f", cfg.posteriorWeight),
        onDelta: { d in
          cfg.posteriorWeight = max(0.0, min(0.5, cfg.posteriorWeight + d))
        },
        currentString: { String(format: "%.4f", cfg.posteriorWeight) },
        step: 0.05,
        rangeLabel: "0.00 – 0.50")

      thresholdRow(
        "autoExcludeMinROI",
        label: "Auto-Exclude min ROI",
        formattedValue: String(format: "%.1f%%", cfg.autoExcludeMinROI * 100),
        onDelta: { d in
          cfg.autoExcludeMinROI = max(-0.5, min(0.0, cfg.autoExcludeMinROI + d))
        },
        currentString: { String(format: "%.4f", cfg.autoExcludeMinROI) },
        step: 0.005,
        rangeLabel: "−50% … 0%")

      thresholdRow(
        "autoExcludeMinBets",
        label: "Auto-Exclude min n",
        formattedValue: "\(cfg.autoExcludeMinBets)",
        onDelta: { d in
          let v = cfg.autoExcludeMinBets + Int(d.rounded())
          cfg.autoExcludeMinBets = max(5, min(200, v))
        },
        currentString: { "\(cfg.autoExcludeMinBets)" },
        step: 5,
        rangeLabel: "5 – 200")

      thresholdRow(
        "stopLossCapStreak",
        label: "Stop-loss: cap после N LOSS",
        formattedValue: "\(cfg.stopLossCapStreak)",
        onDelta: { d in
          let v = cfg.stopLossCapStreak + Int(d.rounded())
          cfg.stopLossCapStreak = max(2, min(10, v))
        },
        currentString: { "\(cfg.stopLossCapStreak)" },
        step: 1,
        rangeLabel: "2 – 10")

      thresholdRow(
        "stopLossPauseStreak",
        label: "Stop-loss: pause после N LOSS",
        formattedValue: "\(cfg.stopLossPauseStreak)",
        onDelta: { d in
          let v = cfg.stopLossPauseStreak + Int(d.rounded())
          let lower = cfg.stopLossCapStreak + 1
          cfg.stopLossPauseStreak = max(lower, min(15, v))
        },
        currentString: { "\(cfg.stopLossPauseStreak)" },
        step: 1,
        rangeLabel: "> cap · … · 15")
    } header: {
      Text("Пороги")
    } footer: {
      Text("Изменения применяются со следующего скана. Каждое изменение пишется в журнал ниже.")
    }
  }

  @ViewBuilder
  private func thresholdRow(
    _ key: String,
    label: String,
    formattedValue: String,
    onDelta: @escaping (Double) -> Void,
    currentString: @escaping () -> String,
    step: Double,
    rangeLabel: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label).font(.subheadline)
        Spacer()
        Text(formattedValue)
          .font(.subheadline.monospacedDigit().bold())
          .foregroundStyle(.blue)
      }
      HStack(spacing: 8) {
        Button {
          let b = currentString()
          onDelta(-step)
          let a = currentString()
          TuningService.log(
            context: context, kind: "threshold", target: key,
            before: b, after: a, note: label)
        } label: {
          Image(systemName: "minus.circle.fill").foregroundStyle(.blue)
        }
        .buttonStyle(.plain)

        Button {
          let b = currentString()
          onDelta(step)
          let a = currentString()
          TuningService.log(
            context: context, kind: "threshold", target: key,
            before: b, after: a, note: label)
        } label: {
          Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
        }
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
        Text("Журнал пуст")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(events.prefix(30)) { e in
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(kindLabel(e.kind))
                  .font(.caption2.bold())
                  .foregroundStyle(kindColor(e.kind))
                Text(e.target).font(.caption.monospaced())
              }
              HStack(spacing: 4) {
                Text(e.beforeValue)
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2)
                  .foregroundStyle(.secondary)
                Text(e.afterValue)
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.primary)
              }
              if !e.note.isEmpty {
                Text(e.note).font(.caption2).foregroundStyle(.tertiary)
              }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text(e.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
              if e.rolledBack {
                Text("откатано")
                  .font(.caption2).foregroundStyle(.orange)
              }
            }
          }
          .padding(.vertical, 2)
        }
      }
    } header: {
      Text("Журнал изменений")
    } footer: {
      Text("Показываются последние 30 событий.")
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
        cfg.updatedAt = Date()
        TuningService.log(
          context: context,
          kind: "threshold", target: "all",
          before: before, after: "defaults",
          note: "Сброс к дефолтам")
        rollbackMessage = "Сброшено к дефолтам"
      } label: {
        Label("Сбросить к дефолтам", systemImage: "arrow.clockwise")
      }
    } header: {
      Text("Сброс")
    }
  }
}