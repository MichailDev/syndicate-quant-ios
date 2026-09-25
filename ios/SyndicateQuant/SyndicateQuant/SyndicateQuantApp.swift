import SwiftData
import SwiftUI

@main struct SyndicateQuantApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var settings = AppSettings()

  private let container: ModelContainer

  init() {
    let schema = Schema([
      JournalEntry.self,
      CalibrationSample.self,
      BacktestRun.self,
    ])
    let config = ModelConfiguration(
      schema: schema, isStoredInMemoryOnly: false)

    let c: ModelContainer
    do {
      c = try ModelContainer(for: schema, configurations: [config])
    } catch {
      fatalError("ModelContainer init failed: \(error)")
    }
    self.container = c
    // A9: контейнер доступен из фоновых задач через AppDependencies.shared.
    AppDependencies.shared.container = c
  }

  var body: some Scene {
    WindowGroup {
      RootView().environmentObject(settings)
    }
    .modelContainer(container)
  }
}