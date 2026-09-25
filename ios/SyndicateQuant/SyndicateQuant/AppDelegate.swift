@preconcurrency import BackgroundTasks
@preconcurrency import UIKit
import SwiftData

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  nonisolated static let refreshID = "com.syndicatequant.app.refresh"

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
    // Планируем следующую попытку сразу.
    scheduleNextRefresh()

    let work = Task { @MainActor in
      let success = await ScanCoordinator.shared.scanInBackground()
      // A1: авто-settle журнала после фонового скана.
      // Запускается даже если scan вернул false — чтобы закрыть "зависшие" OPEN.
      await autoSettle()
      task.setTaskCompleted(success: success)
    }

    task.expirationHandler = {
      work.cancel()
    }
  }

  /// A1: закрывает OPEN-записи журнала через общий ModelContainer.
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
      print("[BG] submit failed: \(error.localizedDescription)")
    }
  }
}