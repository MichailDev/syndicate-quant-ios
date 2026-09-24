import Foundation
import UserNotifications

enum NotificationService {
    static func request(){Task{try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge])}}
    static func notify(signals:[BetSignal]) async {guard let s=signals.first else{return};let c=UNMutableNotificationContent();c.title="SYNDICATE QUANT";c.body="\(s.classification): \(s.home) — \(s.away) · \(s.market) \(s.selection) · EV \(String(format:"%+.1f%%",s.ev*100))";c.sound=.default;let r=UNNotificationRequest(identifier:"sq-\(s.id)-\(Int(Date().timeIntervalSince1970))",content:c,trigger:nil);try? await UNUserNotificationCenter.current().add(r)}
}
