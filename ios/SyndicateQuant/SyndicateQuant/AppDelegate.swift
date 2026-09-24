@preconcurrency import BackgroundTasks
@preconcurrency import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  static let refreshID = "com.syndicatequant.app.refresh"
  private static var pendingSchedule = false

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

    NotificationService.request()
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    Self.scheduleNextRefresh()
  }

  // MARK: - BGTask handling

  nonisolated private static func handle(_ task: BGAppRefreshTask) {
    // Планируем следующую попытку сразу — BGTaskScheduler требует наличие хотя бы
    // одной зарегистрированной задачи, иначе iOS перестанет нас будить.
    scheduleNextRefresh()

    let work = Task { @MainActor in
      let success = await ScanCoordinator.shared.scanInBackground()
      task.setTaskCompleted(success: success)
    }

    task.expirationHandler = {
      work.cancel()
    }
  }

  nonisolated private static func scheduleNextRefresh() {
    // Защита от параллельного планирования
    guard !pendingSchedule else { return }
    pendingSchedule = true
    defer { pendingSchedule = false }

    let request = BGAppRefreshTaskRequest(identifier: refreshID)
    // iOS сам решит, когда запускать (обычно от 15 минут). Ставим 30 минут
    // как минимум — iOS всё равно может отложить.
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      print("[BG] submit failed: \(error.localizedDescription)")
    }
  }
}