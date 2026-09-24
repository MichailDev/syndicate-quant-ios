import Foundation
import UserNotifications

enum NotificationService {
  static let categorySignal = "SQ_SIGNAL"

  static func request() {
    Task {
      let center = UNUserNotificationCenter.current()
      try? await center.requestAuthorization(options: [.alert, .sound, .badge])

      // Категория с action-button "Открыть"
      let openAction = UNNotificationAction(
        identifier: "SQ_OPEN",
        title: "Открыть",
        options: [.foreground])
      let category = UNNotificationCategory(
        identifier: categorySignal,
        actions: [openAction],
        intentIdentifiers: [],
        options: [.customDismissAction])
      center.setNotificationCategories([category])
    }
  }

  /// Уведомляем только про S/A BET. Дедупликация по id сигнала.
  static func notify(signals: [BetSignal]) async {
    let important = signals.filter {
      $0.classification == "S BET" || $0.classification == "A BET"
    }
    guard !important.isEmpty else { return }

    let center = UNUserNotificationCenter.current()
    let defaults = UserDefaults.standard
    let alreadyNotified = Set(defaults.stringArray(forKey: "notified_signal_ids") ?? [])

    var newlyNotified: [String] = []
    for s in important.prefix(3) {
      if alreadyNotified.contains(s.id) { continue }
      newlyNotified.append(s.id)

      let c = UNMutableNotificationContent()
      c.title = "\(s.classification): \(s.home) — \(s.away)"
      let linePart: String = s.line.map { " \($0)" } ?? ""
      let oddsStr = String(format: "%.2f", s.odds)
      let evStr = String(format: "%+.1f%%", s.ev * 100)
      let qcsStr = String(format: "%.0f", s.qcs)
      c.body = "\(s.league)\n\(s.market) · \(s.selection)\(linePart)\nOdds \(oddsStr) · EV \(evStr) · QCS \(qcsStr)"
      c.sound = .default
      c.categoryIdentifier = categorySignal
      c.userInfo = [
        "signal_id": s.id,
        "game_id": s.gameID,
      ]

      let r = UNNotificationRequest(
        identifier: "sq-\(s.id)",
        content: c,
        trigger: nil)
      try? await center.add(r)
    }

    // Обновляем сохранённый список id, чтобы не дублировать в будущем
    if !newlyNotified.isEmpty {
      var all = alreadyNotified
      for id in newlyNotified { all.insert(id) }
      // Ограничиваем размер, чтобы UserDefaults не разрастался
      let trimmed = Array(all.suffix(200))
      defaults.set(trimmed, forKey: "notified_signal_ids")
    }
  }

  /// Сброс дедупликации (принудительно)
  static func resetDedupe() {
    UserDefaults.standard.removeObject(forKey: "notified_signal_ids")
  }
}