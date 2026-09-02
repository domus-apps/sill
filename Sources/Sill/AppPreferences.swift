import Foundation

/* App-level preferences. Same UserDefaults caveat as the rest of the app:
   `swift run` and the bundled app use different defaults domains. */
enum AppPreferences {
    static let changed = Notification.Name("Sill.PreferencesChanged")

    private static let hideMenuBarIconKey = "pref.hideMenuBarIcon"

    static var isMenuBarIconHidden: Bool {
        get { UserDefaults.standard.bool(forKey: hideMenuBarIconKey) }
        set { set(newValue, forKey: hideMenuBarIconKey) }
    }

    private static func set(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
