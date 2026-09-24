@preconcurrency import BackgroundTasks
@preconcurrency import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  static let refreshID = "com.syndicatequant.app.refresh"

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.refreshID,
      using: .main
    ) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Self.handle(refreshTask)
    }

    NotificationService.request()
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    schedule()
  }

  private static func handle(_ task: BGAppRefreshTask) {
    task.expirationHandler = nil

    let settings = AppSettings()
    let key = settings.apiKey
    guard !key.isEmpty else {
      task.setTaskCompleted(success: false)
      return
    }

    Task { @MainActor in
      let client = SStatsClient(settings: settings)
      do {
        _ = try await client.listToday()
        task.setTaskCompleted(success: true)
      } catch {
        task.setTaskCompleted(success: false)
      }
    }
  }

  private func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}
