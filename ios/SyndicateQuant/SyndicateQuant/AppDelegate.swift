@preconcurrency import BackgroundTasks
@preconcurrency import UIKit
@preconcurrency import UserNotifications
import SwiftData

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  nonisolated static let refreshID = "com.syndicatequant.app.refresh"
  nonisolated static let processingID = "com.syndicatequant.app.processing"

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.refreshID,
      using: nil
    ) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      AppDelegate.handle(refreshTask)
    }

    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.processingID,
      using: nil
    ) { task in
      guard let processing = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      AppDelegate.handleProcessing(processing)
    }

    UNUserNotificationCenter.current().delegate = self

    NotificationService.request()
    Self.scheduleNextRefresh()
    Self.scheduleWeeklyProcessing()
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    Self.scheduleNextRefresh()
  }

  // MARK: - BGAppRefreshTask (Волна A)

  nonisolated private static func handle(_ task: BGAppRefreshTask) {
    scheduleNextRefresh()

    let work = Task { @MainActor in
      let success = await ScanCoordinator.shared.scanInBackground()
      await autoSettle()
      task.setTaskCompleted(success: success)
    }

    task.expirationHandler = {
      work.cancel()
    }
  }

  @MainActor
  private static func autoSettle() async {
    guard let container = AppDependencies.shared.container else {
      print("[BG] container недоступен — skip auto-settle")
      return
    }
    let settings = AppSettings()
    let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      print("[BG] API key пуст — skip auto-settle")
      return
    }

    let client = SStatsClient(settings: settings)
    let context = ModelContext(container)
    let result = await JournalService.settleOpenEntries(
      context: context, client: client)
    print("[BG] auto-settle: closed=\(result.closed) failed=\(result.failed)")
  }

  nonisolated private static func scheduleNextRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: refreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      print("[BG] refresh submit failed: \(error.localizedDescription)")
    }
  }

  // MARK: - BGProcessingTask (Волна G)

  nonisolated private static func handleProcessing(_ task: BGProcessingTask) {
    scheduleWeeklyProcessing()

    let work = Task { @MainActor in
      let ok = await BacktestService.shared.updateIncremental()
      task.setTaskCompleted(success: ok)
    }

    task.expirationHandler = {
      work.cancel()
    }
  }

  nonisolated private static func scheduleWeeklyProcessing() {
    let req = BGProcessingTaskRequest(identifier: processingID)
    req.requiresNetworkConnectivity = true
    req.requiresExternalPower = false
    req.earliestBeginDate = nextSundayEarlyMorning()
    do {
      try BGTaskScheduler.shared.submit(req)
      print("[BG] processing scheduled")
    } catch {
      print("[BG] processing submit failed: \(error.localizedDescription)")
    }
  }

  nonisolated private static func nextSundayEarlyMorning() -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    var comps = DateComponents()
    comps.weekday = 1
    comps.hour = 2
    comps.minute = 0
    if let next = cal.nextDate(
      after: Date(), matching: comps,
      matchingPolicy: .nextTime
    ) {
      return next
    }
    return Date().addingTimeInterval(7 * 24 * 3600)
  }
}

// MARK: - UNUserNotificationCenterDelegate (C1: deep-link)

extension AppDelegate: UNUserNotificationCenterDelegate {

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    // NotificationService пишет ключ "signal_id" в content.userInfo.
    if let signalID = userInfo["signal_id"] as? String {
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: .openSignal,
          object: nil,
          userInfo: ["signalID": signalID])
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}