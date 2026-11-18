import Foundation

/// Which wallpaper source is selected
enum WallpaperSource: String {
    case bing = "bing"
    case spotlight = "spotlight"
}

/// Thin wrapper around UserDefaults for persistent app preferences
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private let sourceKey = "wallpaperSource"
    private let lastAppliedDateKey = "lastAppliedDate"
    private let lastAppliedImagePathKey = "lastAppliedImagePath"
    private let lastAppliedSourceKey = "lastAppliedSource"

    private init() {}

    /// Selected wallpaper source (default: .bing)
    var source: WallpaperSource {
        get {
            let raw = defaults.string(forKey: sourceKey) ?? WallpaperSource.bing.rawValue
            return WallpaperSource(rawValue: raw) ?? .bing
        }
        set {
            defaults.set(newValue.rawValue, forKey: sourceKey)
        }
    }

    /// The last date a wallpaper was successfully applied (yyyy-MM-dd string)
    var lastAppliedDate: String? {
        get { defaults.string(forKey: lastAppliedDateKey) }
        set { defaults.set(newValue, forKey: lastAppliedDateKey) }
    }

    /// Absolute path to the image file last applied successfully (for same-day re-apply).
    var lastAppliedImagePath: String? {
        get { defaults.string(forKey: lastAppliedImagePathKey) }
        set { defaults.set(newValue, forKey: lastAppliedImagePathKey) }
    }

    /// Source that produced `lastAppliedImagePath`.
    var lastAppliedSource: WallpaperSource? {
        get {
            guard let raw = defaults.string(forKey: lastAppliedSourceKey) else { return nil }
            return WallpaperSource(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: lastAppliedSourceKey)
            } else {
                defaults.removeObject(forKey: lastAppliedSourceKey)
            }
        }
    }

    /// Returns true if wallpaper was already applied today
    var isUpToDateForToday: Bool {
        let today = todayString()
        return lastAppliedDate == today
    }

    func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    func clearLastAppliedWallpaper() {
        lastAppliedDate = nil
        lastAppliedImagePath = nil
        lastAppliedSource = nil
    }
}
