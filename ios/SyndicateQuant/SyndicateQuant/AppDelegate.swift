import BackgroundTasks
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  static let refreshID = "com.syndicatequant.app.refresh"
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
      Task { await Self.run(task as! BGAppRefreshTask) }
    }
    NotificationService.request()
    return true
  }
  func applicationDidEnterBackground(_ application: UIApplication) { schedule() }
  static func run(_ task: BGAppRefreshTask) async {
    task.expirationHandler = {}
    let key = KeychainStore.shared.get("sstats_api_key") ?? ""
    guard !key.isEmpty else {
      task.setTaskCompleted(success: false)
      return
    }
    let settings = await MainActor.run { AppSettings() }
    let client = SStatsClient(settings: settings)
    do {
      _ = try await client.listToday()
      task.setTaskCompleted(success: true)
    } catch { task.setTaskCompleted(success: false) }
  }
  func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}
