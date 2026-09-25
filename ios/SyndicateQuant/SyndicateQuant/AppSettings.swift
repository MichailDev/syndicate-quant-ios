import Combine
import Foundation

@MainActor final class AppSettings: ObservableObject {
  @Published var apiKey: String {
    didSet { KeychainStore.shared.set(apiKey, for: "sstats_api_key") }
  }
  @Published var autoRefresh: Bool {
    didSet { UserDefaults.standard.set(autoRefresh, forKey: "auto_refresh") }
  }
  @Published var refreshMinutes: Int {
    didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refresh_minutes") }
  }
  @Published var historyMatches: Int {
    didSet { UserDefaults.standard.set(historyMatches, forKey: "history_matches") }
  }
  @Published var scanMatches: Int {
    didSet { UserDefaults.standard.set(scanMatches, forKey: "scan_matches") }
  }
  @Published var notifyBets: Bool {
    didSet { UserDefaults.standard.set(notifyBets, forKey: "notify_bets") }
  }

  @Published var oddsFormatRaw: String {
    didSet { UserDefaults.standard.set(oddsFormatRaw, forKey: "odds_format") }
  }

  @Published var colorSchemeRaw: String {
    didSet { UserDefaults.standard.set(colorSchemeRaw, forKey: "color_scheme") }
  }

  @Published var bankroll: Double {
    didSet { UserDefaults.standard.set(bankroll, forKey: "bankroll") }
  }
  @Published var useMoneyStakes: Bool {
    didSet { UserDefaults.standard.set(useMoneyStakes, forKey: "use_money_stakes") }
  }

  // Волна D (D1): Live monitor.
  @Published var liveMonitorEnabled: Bool {
    didSet { UserDefaults.standard.set(liveMonitorEnabled, forKey: "live_monitor_enabled") }
  }
  @Published var liveMonitorIntervalSec: Int {
    didSet { UserDefaults.standard.set(liveMonitorIntervalSec, forKey: "live_monitor_interval") }
  }

  let baseURL = "https://api.sstats.net"
  let engineVersion = "v5.6.0-iOS-INSTITUTIONAL"

  init() {
    apiKey = KeychainStore.shared.get("sstats_api_key") ?? ""
    autoRefresh = UserDefaults.standard.object(forKey: "auto_refresh") as? Bool ?? true
    refreshMinutes = UserDefaults.standard.object(forKey: "refresh_minutes") as? Int ?? 30
    historyMatches = UserDefaults.standard.object(forKey: "history_matches") as? Int ?? 15
    scanMatches = UserDefaults.standard.object(forKey: "scan_matches") as? Int ?? 10
    notifyBets = UserDefaults.standard.object(forKey: "notify_bets") as? Bool ?? true

    oddsFormatRaw = UserDefaults.standard.string(forKey: "odds_format") ?? "eu"
    colorSchemeRaw = UserDefaults.standard.string(forKey: "color_scheme") ?? "system"

    bankroll = UserDefaults.standard.object(forKey: "bankroll") as? Double ?? 10_000
    useMoneyStakes = UserDefaults.standard.object(forKey: "use_money_stakes") as? Bool ?? false

    liveMonitorEnabled = UserDefaults.standard.object(forKey: "live_monitor_enabled") as? Bool ?? false
    let stored = UserDefaults.standard.object(forKey: "live_monitor_interval") as? Int ?? 60
    liveMonitorIntervalSec = max(30, min(300, stored))
  }

  var oddsFormat: OddsFormat {
    OddsFormat(rawValue: oddsFormatRaw) ?? .eu
  }

  var colorScheme: AppColorScheme {
    AppColorScheme(rawValue: colorSchemeRaw) ?? .system
  }

  var effectiveBankroll: Double? {
    useMoneyStakes && bankroll > 0 ? bankroll : nil
  }
}