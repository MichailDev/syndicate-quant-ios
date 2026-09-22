import Foundation
import Combine

@MainActor final class AppSettings: ObservableObject {
    @Published var apiKey:String {didSet{KeychainStore.shared.set(apiKey,for:"sstats_api_key")}}
    @Published var autoRefresh:Bool {didSet{UserDefaults.standard.set(autoRefresh,forKey:"auto_refresh")}}
    @Published var refreshMinutes:Int {didSet{UserDefaults.standard.set(refreshMinutes,forKey:"refresh_minutes")}}
    @Published var historyMatches:Int {didSet{UserDefaults.standard.set(historyMatches,forKey:"history_matches")}}
    @Published var scanMatches:Int {didSet{UserDefaults.standard.set(scanMatches,forKey:"scan_matches")}}
    @Published var notifyBets:Bool {didSet{UserDefaults.standard.set(notifyBets,forKey:"notify_bets")}}
    let baseURL="https://api.sstats.net"
    let engineVersion="v5.1.0-iOS-INSTITUTIONAL"
    init(){apiKey=KeychainStore.shared.get("sstats_api_key") ?? "";autoRefresh=UserDefaults.standard.object(forKey:"auto_refresh") as? Bool ?? true;refreshMinutes=UserDefaults.standard.object(forKey:"refresh_minutes") as? Int ?? 30;historyMatches=UserDefaults.standard.object(forKey:"history_matches") as? Int ?? 15;scanMatches=UserDefaults.standard.object(forKey:"scan_matches") as? Int ?? 10;notifyBets=UserDefaults.standard.object(forKey:"notify_bets") as? Bool ?? true}
}
