import Foundation

enum Preferences {
    static let autoRehideDelayKey = "autoRehideDelay"

    /// Seconds before items revealed in the menu bar are hidden again. 0 disables auto-hide.
    static var autoRehideDelay: TimeInterval {
        UserDefaults.standard.object(forKey: autoRehideDelayKey) as? Double ?? 10
    }
}
