import AppKit
import Security

/* Gatekeeper's App Translocation: a quarantined app that was COPIED (not
   Finder-moved) into place runs from a randomized read-only path under
   /private/var/folders/…/AppTranslocation/. Sparkle cannot update an app
   running there ("can't be updated if it's running from the location it
   was downloaded to"), even though the bundle the user sees sits in
   /Applications. Rather than teach every user the move-vs-copy
   distinction, heal at launch: resolve the real bundle, strip its
   quarantine flag, and relaunch from the real location. Once healed the
   flag is gone, so translocation never applies again — however the app
   got to where it lives.

   Call first thing in applicationDidFinishLaunching; a true return means
   a relaunch is underway and the caller must skip its normal startup. */
enum TranslocationHealer {
    static func healIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.path.contains("/AppTranslocation/") else {
            /* Not translocated (properly moved, relaunched after a heal, or
               never quarantined): still shed any lingering quarantine flag
               so nothing downstream ever trips over it. */
            stripQuarantine(at: bundleURL)
            return false
        }
        guard let original = originalURL(for: bundleURL) else { return false }
        stripQuarantine(at: original)
        relaunch(original)
        return true
    }

    /* The translocated path doesn't reveal its origin; Security.framework
       knows. The symbol is private but long-stable (the window-manager
       ecosystem leans on it); LaunchServices' registered copies are the
       fallback. */
    private static func originalURL(for translocated: URL) -> URL? {
        typealias CreateOriginalPath = @convention(c) (
            CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?
        if let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
            let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
        {
            let create = unsafeBitCast(symbol, to: CreateOriginalPath.self)
            if let url = create(translocated as CFURL, nil)?.takeRetainedValue() {
                return url as URL
            }
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .first {
                !$0.path.contains("/AppTranslocation/")
                    && FileManager.default.fileExists(atPath: $0.path)
            }
    }

    private static func stripQuarantine(at url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /* The relaunch must start AFTER this instance exits — with it still
       running, Launch Services would just re-activate the translocated
       instance instead of launching the healed original. */
    private static func relaunch(_ url: URL) {
        let escaped = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(escaped)\""]
        try? shell.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
