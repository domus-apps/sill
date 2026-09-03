import Foundation

/* App-level preferences. Same UserDefaults caveat as the rest of the app:
   `swift run` and the bundled app use different defaults domains. */
enum AppPreferences {
    static let changed = Notification.Name("Sill.PreferencesChanged")

    private static let hideMenuBarIconKey = "pref.hideMenuBarIcon"
    private static let learnFromHelpKey = "pref.learnFromHelp"

    static var isMenuBarIconHidden: Bool {
        get { UserDefaults.standard.bool(forKey: hideMenuBarIconKey) }
        set { set(newValue, forKey: hideMenuBarIconKey) }
    }

    /// Run unknown commands with `--help` to learn their options (off by
    /// default: it executes programs the corpus has never heard of).
    static var learnsFromHelp: Bool {
        get { UserDefaults.standard.bool(forKey: learnFromHelpKey) }
        set { set(newValue, forKey: learnFromHelpKey) }
    }

    private static func set(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
