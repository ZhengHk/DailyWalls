import Foundation

/// Which wallpaper feed drives daily auto-change (mutually exclusive in the menu).
enum WallpaperSource: String, CaseIterable {
    case bing = "bing"
    case spotlight = "spotlight"
}

/// Thin wrapper around UserDefaults for persistent app preferences
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private let sourceKey = "wallpaperSource"
    private let dailyAutoPausedKey = "dailyAutoPaused"
    private let customImagePathKey = "customImagePath"
    private let currentWallpaperPathKey = "currentWallpaperPath"

    private func storedPathKey(for source: WallpaperSource) -> String {
        "storedImagePath.\(source.rawValue)"
    }

    private func lastAutoDateKey(for source: WallpaperSource) -> String {
        "lastAutoApplyDate.\(source.rawValue)"
    }

    private init() {}

    /// Feed used for daily automatic updates (Bing or Spotlight).
    var source: WallpaperSource {
        get {
            let raw = defaults.string(forKey: sourceKey) ?? WallpaperSource.bing.rawValue
            return WallpaperSource(rawValue: raw) ?? .bing
        }
        set {
            defaults.set(newValue.rawValue, forKey: sourceKey)
        }
    }

    var dailyAutoPaused: Bool {
        get { defaults.bool(forKey: dailyAutoPausedKey) }
        set { defaults.set(newValue, forKey: dailyAutoPausedKey) }
    }

    /// Last manually chosen file (outside Bing / Spotlight caches).
    var customImagePath: String? {
        get { defaults.string(forKey: customImagePathKey) }
        set { defaults.set(newValue, forKey: customImagePathKey) }
    }

    /// Most recently applied wallpaper (any origin) — used on wake / re-apply.
    var currentWallpaperPath: String? {
        get { defaults.string(forKey: currentWallpaperPathKey) }
        set { defaults.set(newValue, forKey: currentWallpaperPathKey) }
    }

    func storedImagePath(for source: WallpaperSource) -> String? {
        defaults.string(forKey: storedPathKey(for: source))
    }

    func setStoredImagePath(_ path: String?, for source: WallpaperSource) {
        defaults.set(path, forKey: storedPathKey(for: source))
    }

    func lastAutoApplyDate(for source: WallpaperSource) -> String? {
        defaults.string(forKey: lastAutoDateKey(for: source))
    }

    func setLastAutoApplyDate(_ date: String?, for source: WallpaperSource) {
        defaults.set(date, forKey: lastAutoDateKey(for: source))
    }

    func isUpToDateForToday(source: WallpaperSource) -> Bool {
        lastAutoApplyDate(for: source) == todayString()
    }

    func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    /// One-time migration from older single-path preferences.
    func migrateLegacyKeysIfNeeded() {
        guard defaults.string(forKey: "lastAppliedImagePath") != nil else { return }
        if let path = defaults.string(forKey: "lastAppliedImagePath"),
           let raw = defaults.string(forKey: "lastAppliedSource"),
           let legacySource = WallpaperSource(rawValue: raw) {
            if storedImagePath(for: legacySource) == nil {
                setStoredImagePath(path, for: legacySource)
            }
            if let date = defaults.string(forKey: "lastAppliedDate") {
                setLastAutoApplyDate(date, for: legacySource)
            }
            currentWallpaperPath = path
        }
        defaults.removeObject(forKey: "lastAppliedImagePath")
        defaults.removeObject(forKey: "lastAppliedSource")
        defaults.removeObject(forKey: "lastAppliedDate")
    }
}