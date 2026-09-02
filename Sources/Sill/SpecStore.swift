import CryptoKit
import Foundation

/* Keeps the downloaded spec corpus fresh. The corpus lives as the assets of
   the repo's rolling "specs" release (built by .github/workflows/
   spec-bundle.yml): specs.zip plus a tiny manifest with version + sha256.
   First run downloads it; afterwards a daily check compares versions
   (re-evaluated hourly while the app stays running).
   Progress and outcome are published as `status` so Settings can show what
   is going on instead of a button that seems to do nothing. */
final class SpecStore {
    static let updated = Notification.Name("Sill.SpecsUpdated")
    static let statusChanged = Notification.Name("Sill.SpecsStatusChanged")

    enum Status: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case upToDate
        case updated(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .idle: return ""
            case .checking: return "Checking…"
            case .downloading: return "Downloading…"
            case .installing: return "Installing…"
            case .upToDate: return "Up to date"
            case .updated(let version): return "Updated to \(version)"
            case .failed(let reason): return reason
            }
        }
    }

    private static let manifestURL = URL(
        string: "https://github.com/domus-apps/sill/releases/download/specs/specs-manifest.json")!
    private static let bundleURL = URL(
        string: "https://github.com/domus-apps/sill/releases/download/specs/specs.zip")!

    private static let versionKey = "specs.installedVersion"
    private static let checkedKey = "specs.lastCheck"
    private static let checkInterval: TimeInterval = 24 * 3600

    static var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sill")
    }
    static var specsDirectory: URL { supportDirectory.appendingPathComponent("specs") }

    static var installedVersion: String? {
        UserDefaults.standard.string(forKey: versionKey)
    }

    static var lastCheck: Date? {
        UserDefaults.standard.object(forKey: checkedKey) as? Date
    }

    private(set) var status: Status = .idle {
        didSet { NotificationCenter.default.post(name: Self.statusChanged, object: self) }
    }

    private var periodicTimer: Timer?

    /// Checks now, then keeps checking hourly so the daily cadence holds for
    /// an app that stays running for days (the check itself is a no-op until
    /// a day has passed since the last one).
    func startPeriodicUpdates() {
        updateIfNeeded()
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.updateIfNeeded()
        }
        periodicTimer?.tolerance = 300
    }

    /// First run (nothing installed) or a stale daily check kicks off a
    /// background update. Cheap to call any time. `force` is the Settings
    /// button.
    func updateIfNeeded(force: Bool = false) {
        guard !status.isBusy else { return }
        let installed = FileManager.default.fileExists(
            atPath: Self.specsDirectory.appendingPathComponent("index.json").path)
        let lastCheck = Self.lastCheck ?? .distantPast
        guard force || !installed || Date().timeIntervalSince(lastCheck) > Self.checkInterval
        else { return }

        status = .checking
        Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.update(alreadyInstalled: installed) { [weak self] phase in
                Task { @MainActor [weak self] in self?.status = phase }
            }
            await MainActor.run { [weak self] in
                self?.status = outcome
                if case .updated = outcome {
                    NotificationCenter.default.post(name: Self.updated, object: nil)
                }
            }
        }
    }

    private struct Manifest: Decodable {
        let version: String
        let sha256: String
    }

    private static func update(alreadyInstalled: Bool,
                               report: @escaping (Status) -> Void) async -> Status {
        do {
            let (manifestData, manifestResponse) = try await URLSession.shared.data(from: manifestURL)
            if let http = manifestResponse as? HTTPURLResponse, http.statusCode != 200 {
                return .failed("Spec server replied \(http.statusCode)")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            UserDefaults.standard.set(Date(), forKey: checkedKey)
            if alreadyInstalled,
               UserDefaults.standard.string(forKey: versionKey) == manifest.version {
                return .upToDate
            }

            report(.downloading)
            let (zipURL, zipResponse) = try await URLSession.shared.download(from: bundleURL)
            if let http = zipResponse as? HTTPURLResponse, http.statusCode != 200 {
                return .failed("Download failed (\(http.statusCode))")
            }
            guard sha256Hex(of: zipURL) == manifest.sha256 else {
                NSLog("Sill: spec bundle checksum mismatch — keeping the current corpus")
                return .failed("Download didn't verify; kept the current specs")
            }

            report(.installing)
            // Unzip next to the live directory, then swap atomically-ish so
            // a lookup never sees a half-extracted corpus.
            let staging = supportDirectory.appendingPathComponent("specs.new")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(
                at: supportDirectory, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zipURL.path, staging.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                return .failed("Couldn't unpack the spec bundle")
            }
            // The zip contains a top-level "specs" folder.
            let extracted = staging.appendingPathComponent("specs")
            try? FileManager.default.removeItem(at: specsDirectory)
            try FileManager.default.moveItem(at: extracted, to: specsDirectory)
            try? FileManager.default.removeItem(at: staging)

            UserDefaults.standard.set(manifest.version, forKey: versionKey)
            NSLog("Sill: spec corpus updated to %@", manifest.version)
            return .updated(manifest.version)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failed("No internet connection")
        } catch {
            NSLog("Sill: spec update failed: \(error.localizedDescription)")
            return .failed("Update failed — see Console for details")
        }
    }

    private static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
