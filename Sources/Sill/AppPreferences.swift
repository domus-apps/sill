import Foundation

/* App-level preferences. Same UserDefaults caveat as the rest of the app:
   `swift run` and the bundled app use different defaults domains. */
enum AppPreferences {
    static let changed = Notification.Name("Sill.PreferencesChanged")

    private static let hideMenuBarIconKey = "pref.hideMenuBarIcon"
    private static let learnFromHelpKey = "pref.learnFromHelp"
    private static let completeCommandNamesKey = "pref.completeCommandNames"

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

    /// Offer the command itself from the first letter typed (off by
    /// default: a popup on every prompt is a lot of motion for a word most
    /// people type without help).
    static var completesCommandNames: Bool {
        get { UserDefaults.standard.bool(forKey: completeCommandNamesKey) }
        set { set(newValue, forKey: completeCommandNamesKey) }
    }

    private static func set(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
