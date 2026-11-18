import AppKit
import Foundation
import UniformTypeIdentifiers

/// Handles downloading wallpaper images and applying them across all screens and spaces.
final class WallpaperManager {
    static let shared = WallpaperManager()

    private let fileManager = FileManager.default
    private let picturesDir: URL
    private var isRefreshing = false
    private var pickerController: SpotlightPickerWindowController?
    private var spaceChangeDebounce: DispatchWorkItem?
    private var spaceObserverRegistered = false
    /// Spotlight files downloaded for the open picker session (exempt until dismiss/reroll).
    private var pickerSessionPaths: Set<String> = []

    private init() {
        let home = fileManager.homeDirectoryForCurrentUser
        picturesDir = home.appendingPathComponent("Pictures/ms-wallpapers")
        Preferences.shared.migrateLegacyKeysIfNeeded()
        registerActiveSpaceObserver()
        Task { @MainActor in
            pruneAllFeedCaches()
        }
    }

    var savedFavoritesDirectory: URL {
        picturesDir.appendingPathComponent("saved", isDirectory: true)
    }

    // MARK: - Public API

    /// Daily auto-change: fetches once per calendar day per feed when not paused.
    func refreshIfNeeded() {
        let prefs = Preferences.shared
        if prefs.dailyAutoPaused {
            Logger.shared.log("Daily auto-change is paused; skipping fetch.")
            return
        }
        let source = prefs.source
        if prefs.isUpToDateForToday(source: source) {
            Logger.shared.log("Daily wallpaper already fetched today for \(source.rawValue).")
            return
        }
        Logger.shared.log("Triggering daily wallpaper fetch for \(source.rawValue).")
        Task { await fetchAndApplyDaily(for: source) }
    }

    /// Re-applies the current wallpaper file to every display and Space (wake / switch / menu).
    func reapplyCurrentWallpaper() {
        Task { await reapplyCurrentWallpaperAsync() }
    }

    /// Switch feed and restore the last wallpaper that was active for that feed.
    func activateSource(_ source: WallpaperSource) {
        Preferences.shared.source = source
        Task { await restoreSourceWallpaper(source) }
    }

    /// Opens the Spotlight picker (batch of four, reroll supported).
    func presentSpotlightPicker() {
        Task { await loadAndShowSpotlightPicker() }
    }

    func chooseWallpaperFromFile() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.title = "Choose Wallpaper"
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.image]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try await applyManualWallpaper(fileURL: url)
            } catch {
                Logger.shared.log("ERROR: \(error.localizedDescription)")
            }
        }
    }

    /// Copies the currently applied wallpaper into `~/Pictures/ms-wallpapers/saved/`.
    func favoriteCurrentWallpaper() {
        Task { await favoriteCurrentWallpaperAsync() }
    }

    // MARK: - Daily fetch

    @MainActor
    private func fetchAndApplyDaily(for source: WallpaperSource) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sourceName = source == .spotlight ? "Microsoft Spotlight" : "Bing"
        Logger.shared.log("Fetching daily \(sourceName) wallpaper...")
        do {
            let image = try await WallpaperAPI.shared.fetchTodayImage(source: source)
            try await commitWallpaper(image: image, source: source, markDailyAuto: true)
        } catch {
            Logger.shared.log("ERROR: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func restoreSourceWallpaper(_ source: WallpaperSource) async {
        if let path = Preferences.shared.storedImagePath(for: source),
           fileManager.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            Logger.shared.log("Restoring last \(source.rawValue) wallpaper: \(path)")
            do {
                try applyWallpaper(fileURL: url)
                recordCurrentWallpaper(fileURL: url)
            } catch {
                Logger.shared.log("ERROR: \(error.localizedDescription)")
            }
            return
        }
        Logger.shared.log("No saved \(source.rawValue) wallpaper; fetching.")
        await fetchAndApplyDaily(for: source)
    }

    @MainActor
    private func reapplyCurrentWallpaperAsync() async {
        if let path = Preferences.shared.currentWallpaperPath,
           fileManager.fileExists(atPath: path) {
            Logger.shared.log("Re-applying current wallpaper: \(path)")
            do {
                try applyWallpaper(fileURL: URL(fileURLWithPath: path))
            } catch {
                Logger.shared.log("ERROR: \(error.localizedDescription)")
            }
            return
        }
        await restoreSourceWallpaper(Preferences.shared.source)
    }

    @MainActor
    private func applyManualWallpaper(fileURL: URL) async throws {
        let resolved = fileURL.standardizedFileURL
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw WallpaperError.downloadFailed("File not found")
        }
        try applyWallpaper(fileURL: resolved)
        Preferences.shared.customImagePath = resolved.path
        recordCurrentWallpaper(fileURL: resolved)
        Logger.shared.log("Applied manual wallpaper: \(resolved.path)")
    }

    @MainActor
    private func commitWallpaper(
        image: WallpaperImage,
        source: WallpaperSource,
        markDailyAuto: Bool
    ) async throws {
        let localURL = try await downloadImage(image: image, source: source)
        Logger.shared.log("Image saved to \(localURL.path)")
        try writeMetadataSidecar(for: image, imageFileURL: localURL)
        try applyWallpaper(fileURL: localURL)
        Preferences.shared.setStoredImagePath(localURL.path, for: source)
        if markDailyAuto {
            Preferences.shared.setLastAutoApplyDate(Preferences.shared.todayString(), for: source)
        }
        recordCurrentWallpaper(fileURL: localURL)
        if source == .spotlight {
            Preferences.shared.source = .spotlight
        } else if source == .bing {
            Preferences.shared.source = .bing
        }
        Logger.shared.log("Wallpaper applied successfully.")
        pruneFeedCache(source, retainPickerSession: false)
    }

    private func recordCurrentWallpaper(fileURL: URL) {
        Preferences.shared.currentWallpaperPath = fileURL.standardizedFileURL.path
    }

    // MARK: - Spotlight picker

    @MainActor
    private func loadAndShowSpotlightPicker() async {
        if pickerController == nil {
            let controller = SpotlightPickerWindowController()
            controller.onSelect = { [weak self] entry in
                Task { await self?.pickerDidSelect(entry) }
            }
            controller.onFavorite = { [weak self] entry, completion in
                Task {
                    let ok = await self?.saveFavorite(entry: entry) ?? false
                    completion(ok)
                }
            }
            controller.onReroll = { [weak self] in
                Task { await self?.reloadSpotlightPicker() }
            }
            controller.onDismiss = { [weak self] in
                guard let self else { return }
                self.pickerSessionPaths = []
                self.pickerController = nil
                Task { @MainActor in
                    self.pruneFeedCache(.spotlight, retainPickerSession: false)
                }
            }
            pickerController = controller
        }

        pickerController?.present()
        await reloadSpotlightPicker()
    }

    @MainActor
    private func reloadSpotlightPicker() async {
        pickerSessionPaths = []
        pruneFeedCache(.spotlight, retainPickerSession: false)
        pickerController?.showLoading("Fetching new Spotlight images…")
        do {
            let entries = try await buildPickerEntries()
            pickerController?.update(entries: entries)
        } catch {
            pickerController?.showError("Failed to load images: \(error.localizedDescription)")
        }
    }

    private func buildPickerEntries() async throws -> [SpotlightPickerEntry] {
        let images = try await WallpaperAPI.shared.fetchSpotlightOptions(count: 4)
        var entries: [SpotlightPickerEntry] = []
        var sessionPaths = Set<String>()
        for image in images {
            let localURL = try await downloadImage(image: image, source: .spotlight)
            try writeMetadataSidecar(for: image, imageFileURL: localURL)
            sessionPaths.insert(localURL.standardizedFileURL.path)
            guard let preview = NSImage(contentsOf: localURL) else { continue }
            entries.append(SpotlightPickerEntry(image: image, localURL: localURL, preview: preview))
        }
        let pathsForSession = sessionPaths
        await MainActor.run {
            self.pickerSessionPaths = pathsForSession
        }
        return entries
    }

    @MainActor
    private func pickerDidSelect(_ entry: SpotlightPickerEntry) async {
        do {
            try applyWallpaper(fileURL: entry.localURL)
            Preferences.shared.setStoredImagePath(entry.localURL.path, for: .spotlight)
            Preferences.shared.source = .spotlight
            recordCurrentWallpaper(fileURL: entry.localURL)
            pickerSessionPaths = []
            pruneFeedCache(.spotlight, retainPickerSession: false)
            Logger.shared.log("Applied Spotlight pick: \(entry.image.title ?? entry.image.fileName)")
        } catch {
            Logger.shared.log("ERROR: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache prune

    /// Removes unpicked downloads in `bing/` and `spotlight/`; never touches `saved/`.
    @MainActor
    private func pruneAllFeedCaches() {
        for source in WallpaperSource.allCases {
            pruneFeedCache(source, retainPickerSession: false)
        }
    }

    /// Keeps: current wallpaper, each feed's last chosen image, and (optional) open picker batch.
    @MainActor
    private func pruneFeedCache(_ source: WallpaperSource, retainPickerSession: Bool) {
        let feedDir = picturesDir.appendingPathComponent(source.rawValue)
        guard fileManager.fileExists(atPath: feedDir.path) else { return }

        var protected = protectedCachePaths()
        if retainPickerSession {
            protected.formUnion(pickerSessionPaths)
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: feedDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var removed = 0
        for file in files {
            if isCacheFileProtected(file, protected: protected) { continue }

            try? fileManager.removeItem(at: file)
            removed += 1

            let json = file.deletingPathExtension().appendingPathExtension("json")
            if file.pathExtension.lowercased() != "json",
               fileManager.fileExists(atPath: json.path),
               !isCacheFileProtected(json, protected: protected) {
                try? fileManager.removeItem(at: json)
                removed += 1
            }
        }

        if removed > 0 {
            Logger.shared.log("Pruned \(removed) unneeded file(s) from ms-wallpapers/\(source.rawValue)/")
        }
    }

    private func protectedCachePaths() -> Set<String> {
        let prefs = Preferences.shared
        var paths = Set<String>()

        func add(_ path: String?) {
            guard let path, fileManager.fileExists(atPath: path) else { return }
            paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        }

        add(prefs.currentWallpaperPath)
        if let custom = prefs.customImagePath,
           custom.hasPrefix(picturesDir.path) {
            add(custom)
        }
        for source in WallpaperSource.allCases {
            add(prefs.storedImagePath(for: source))
        }
        return paths
    }

    private func isCacheFileProtected(_ url: URL, protected: Set<String>) -> Bool {
        let path = url.standardizedFileURL.path
        if protected.contains(path) { return true }

        if url.pathExtension.lowercased() == "json" {
            let base = url.deletingPathExtension()
            for ext in ["jpg", "jpeg", "png", "heic", "webp"] {
                let candidate = base.appendingPathExtension(ext).standardizedFileURL.path
                if protected.contains(candidate) { return true }
            }
        }
        return false
    }

    // MARK: - Favorites

    func isInFavorites(fileName: String) -> Bool {
        let dest = savedFavoritesDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: dest.path)
    }

    @MainActor
    private func favoriteCurrentWallpaperAsync() async {
        guard let path = Preferences.shared.currentWallpaperPath else {
            Logger.shared.log("No current wallpaper to favorite.")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try saveFavorite(fileURL: url)
        } catch {
            Logger.shared.log("ERROR: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func saveFavorite(entry: SpotlightPickerEntry) async -> Bool {
        do {
            try saveFavorite(fileURL: entry.localURL, metadata: entry.image.metadata)
            Logger.shared.log("Favorited: \(entry.image.title ?? entry.image.fileName)")
            return true
        } catch {
            Logger.shared.log("ERROR: \(error.localizedDescription)")
            return false
        }
    }

    private func saveFavorite(fileURL: URL, metadata: WallpaperMetadata? = nil) throws {
        try fileManager.createDirectory(at: savedFavoritesDirectory, withIntermediateDirectories: true)
        let dest = savedFavoritesDirectory.appendingPathComponent(fileURL.lastPathComponent)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: fileURL, to: dest)

        let sidecarSource = fileURL.deletingPathExtension().appendingPathExtension("json")
        if fileManager.fileExists(atPath: sidecarSource.path) {
            let sidecarDest = dest.deletingPathExtension().appendingPathExtension("json")
            if fileManager.fileExists(atPath: sidecarDest.path) {
                try fileManager.removeItem(at: sidecarDest)
            }
            try fileManager.copyItem(at: sidecarSource, to: sidecarDest)
        } else if let metadata {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: dest.deletingPathExtension().appendingPathExtension("json"))
        }
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
        try encoder.encode(image.metadata).write(to: sidecarURL, options: .atomic)
    }

    // MARK: - Apply Wallpaper

    /// macOS only updates the *active* Space immediately. We also re-apply when you switch Spaces
    /// (see `registerActiveSpaceObserver`) so inactive desktops catch up without restarting Dock.
    private func applyWallpaper(fileURL: URL) throws {
        let resolved = fileURL.standardizedFileURL
        let screenErrors = applyWallpaperToScreens(fileURL: resolved)
        applyWallpaperToAllSpaces(fileURL: resolved)

        if screenErrors.count == NSScreen.screens.count, !NSScreen.screens.isEmpty {
            throw WallpaperError.allScreensFailed
        }
    }

    @discardableResult
    private func applyWallpaperToScreens(fileURL: URL) -> [Error] {
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
        return errors
    }

    private func registerActiveSpaceObserver() {
        guard !spaceObserverRegistered else { return }
        spaceObserverRegistered = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleApplyOnSpaceChange()
        }
    }

    /// Re-apply when entering a Space so Mission Control desktops eventually match (Apple API limitation).
    private func scheduleApplyOnSpaceChange() {
        spaceChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyWallpaperForActiveSpace()
        }
        spaceChangeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func applyWallpaperForActiveSpace() {
        guard let path = Preferences.shared.currentWallpaperPath,
              fileManager.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        applyWallpaperToScreens(fileURL: url)
        applyAppleScriptToCurrentSpace(fileURL: url)
    }

    private func applyWallpaperToAllSpaces(fileURL: URL) {
        let escaped = appleScriptEscapedPath(fileURL.path)
        runAppleScript("""
        set wallpaperFile to POSIX file "\(escaped)"
        tell application "System Events"
            try
                repeat with d in desktops
                    set picture of d to wallpaperFile
                end repeat
            end try
        end tell
        """, label: "System Events (all desktops)")

        runAppleScript("""
        set wallpaperFile to POSIX file "\(escaped)"
        tell application "Finder"
            try
                set desktop picture to wallpaperFile
            end try
        end tell
        """, label: "Finder")
    }

    /// Lighter AppleScript pass used when switching Spaces (targets the live desktop).
    private func applyAppleScriptToCurrentSpace(fileURL: URL) {
        let escaped = appleScriptEscapedPath(fileURL.path)
        runAppleScript("""
        set wallpaperFile to POSIX file "\(escaped)"
        tell application "System Events"
            try
                set picture of desktop 1 to wallpaperFile
            end try
        end tell
        """, label: "System Events (active space)")
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