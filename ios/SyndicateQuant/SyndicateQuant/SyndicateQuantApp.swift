import SwiftUI
import SwiftData

@main struct SyndicateQuantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings=AppSettings()
    var body: some Scene { WindowGroup { RootView().environmentObject(settings) }.modelContainer(for:[JournalEntry.self,CalibrationSample.self,BacktestRun.self]) }
}
