import AppKit
import Foundation

/// Handles downloading wallpaper images and applying them across all screens and spaces.
final class WallpaperManager {
    static let shared = WallpaperManager()

    private let fileManager = FileManager.default
    private let picturesDir: URL
    private var isRefreshing = false

    private init() {
        let home = fileManager.homeDirectoryForCurrentUser
        picturesDir = home.appendingPathComponent("Pictures/ms-wallpapers")
    }

    // MARK: - Public API

    /// Refreshes wallpaper only if today's hasn't been applied yet.
    func refreshIfNeeded() {
        guard !Preferences.shared.isUpToDateForToday else {
            Logger.shared.log("Wallpaper already up to date for today (\(Preferences.shared.todayString())), skipping.")
            return
        }
        Logger.shared.log("Triggering wallpaper refresh (daily check).")
        Task { await performRefresh(fetchNewImage: true) }
    }

    /// Re-applies today's wallpaper to every display and Space, or fetches once if none yet today.
    func forceRefresh() {
        Logger.shared.log("Force refresh requested.")
        Task { await performRefresh(fetchNewImage: false) }
    }

    // MARK: - Core Logic

    @MainActor
    private func performRefresh(fetchNewImage: Bool) async {
        guard !isRefreshing else {
            Logger.shared.log("Refresh already in progress, skipping duplicate trigger.")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let source = Preferences.shared.source
        let today = Preferences.shared.todayString()

        if !fetchNewImage, let reapplyURL = lastAppliedImageURLForToday(source: source) {
            Logger.shared.log("Re-applying today's wallpaper to all displays and Spaces: \(reapplyURL.path)")
            do {
                try applyWallpaper(fileURL: reapplyURL)
                Logger.shared.log("Wallpaper re-applied successfully.")
            } catch {
                Logger.shared.log("ERROR: \(error.localizedDescription)")
            }
            return
        }

        let sourceName = source == .spotlight ? "Microsoft Spotlight" : "Bing (official)"
        Logger.shared.log("Fetching \(sourceName) wallpaper...")

        do {
            let image = try await WallpaperAPI.shared.fetchTodayImage(source: source)
            let credit = image.copyright.map { " — \($0)" } ?? ""
            Logger.shared.log("Got image for \(image.date): \(image.title ?? "(no title)")\(credit)")

            let localURL = try await downloadImage(image: image, source: source)
            Logger.shared.log("Image saved to \(localURL.path)")
            try writeMetadataSidecar(for: image, imageFileURL: localURL)

            try applyWallpaper(fileURL: localURL)
            Logger.shared.log("Wallpaper applied successfully to all screens.")

            recordSuccessfulApply(fileURL: localURL, source: source, date: today)

        } catch {
            Logger.shared.log("ERROR: \(error.localizedDescription)")
        }
    }

    private func lastAppliedImageURLForToday(source: WallpaperSource) -> URL? {
        let prefs = Preferences.shared
        guard prefs.isUpToDateForToday,
              prefs.lastAppliedSource == source,
              let path = prefs.lastAppliedImagePath,
              fileManager.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func recordSuccessfulApply(fileURL: URL, source: WallpaperSource, date: String) {
        let prefs = Preferences.shared
        prefs.lastAppliedDate = date
        prefs.lastAppliedImagePath = fileURL.standardizedFileURL.path
        prefs.lastAppliedSource = source
    }

    // MARK: - Download

    private func downloadImage(image: WallpaperImage, source: WallpaperSource) async throws -> URL {
        guard let remoteURL = URL(string: image.imageUrl) else {
            throw WallpaperError.invalidImageURL(image.imageUrl)
        }

        let destDir = picturesDir.appendingPathComponent(source.rawValue)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = destDir.appendingPathComponent(image.fileName)

        if fileManager.fileExists(atPath: destFile.path) {
            Logger.shared.log("Using cached image at \(destFile.path)")
            return destFile
        }

        Logger.shared.log("Downloading from \(remoteURL.absoluteString)")
        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw WallpaperError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }

        if fileManager.fileExists(atPath: destFile.path) {
            try fileManager.removeItem(at: destFile)
        }
        try fileManager.moveItem(at: tempURL, to: destFile)

        return destFile
    }

    private func writeMetadataSidecar(for image: WallpaperImage, imageFileURL: URL) throws {
        let sidecarURL = imageFileURL.deletingPathExtension().appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(image.metadata)
        try data.write(to: sidecarURL, options: .atomic)
        Logger.shared.log("Metadata saved to \(sidecarURL.path)")
    }

    // MARK: - Apply Wallpaper

    private func applyWallpaper(fileURL: URL) throws {
        let resolved = fileURL.standardizedFileURL
        let workspace = NSWorkspace.shared
        var errors: [Error] = []

        for screen in NSScreen.screens {
            do {
                try workspace.setDesktopImageURL(
                    resolved,
                    for: screen,
                    options: [
                        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                        .allowClipping: true,
                    ]
                )
            } catch {
                errors.append(error)
                Logger.shared.log("Warning: failed to set wallpaper on screen '\(screen.localizedName)': \(error.localizedDescription)")
            }
        }

        applyWallpaperToAllSpaces(fileURL: resolved)

        if errors.count == NSScreen.screens.count, NSScreen.screens.isEmpty == false {
            throw WallpaperError.allScreensFailed
        }
    }

    /// Sets the same image on every Mission Control Space (including inactive desktops).
    private func applyWallpaperToAllSpaces(fileURL: URL) {
        let escaped = appleScriptEscapedPath(fileURL.path)

        runAppleScript("""
        tell application "System Events"
            try
                set picture of every desktop to "\(escaped)"
            end try
        end tell
        """, label: "System Events (every desktop)")

        runAppleScript("""
        tell application "System Events"
            try
                repeat with d in desktops
                    set picture of d to "\(escaped)"
                end repeat
            end try
        end tell
        """, label: "System Events (per desktop)")

        runAppleScript("""
        tell application "Finder"
            try
                set desktop picture to POSIX file "\(escaped)"
            end try
        end tell
        """, label: "Finder")
    }

    private func appleScriptEscapedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String, label: String) {
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: source) {
            appleScript.executeAndReturnError(&error)
            if let err = error {
                Logger.shared.log("AppleScript (\(label)) warning: \(err)")
            } else {
                Logger.shared.log("AppleScript (\(label)) completed.")
            }
        }
    }
}

enum WallpaperError: LocalizedError {
    case invalidImageURL(String)
    case downloadFailed(String)
    case allScreensFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageURL(let url): return "Invalid image URL: \(url)"
        case .downloadFailed(let reason): return "Download failed: \(reason)"
        case .allScreensFailed: return "Failed to set wallpaper on any screen"
        }
    }
}