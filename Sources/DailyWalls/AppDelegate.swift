import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var bingMenuItem: NSMenuItem!
    private var spotlightMenuItem: NSMenuItem!
    private var pauseMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.log("DailyWalls started.")

        setupStatusItem()
        registerSystemObservers()

        WallpaperManager.shared.reapplyCurrentWallpaper()
        WallpaperManager.shared.refreshIfNeeded()
    }

    // MARK: - Menu Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let iconImage = loadMenuBarIcon() {
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Wallpaper Rotation")
            }
            button.image?.isTemplate = true
            button.toolTip = "DailyWalls"
        }

        statusItem.menu = buildMenu()
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "menubar_icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        bingMenuItem = NSMenuItem(title: "Bing", action: #selector(selectBing), keyEquivalent: "")
        bingMenuItem.target = self

        spotlightMenuItem = NSMenuItem(title: "Spotlight", action: #selector(selectSpotlight), keyEquivalent: "")
        spotlightMenuItem.target = self

        updateSourceCheckmarks()

        menu.addItem(bingMenuItem)
        menu.addItem(spotlightMenuItem)
        menu.addItem(NSMenuItem.separator())

        let pickSpotlightItem = NSMenuItem(
            title: "Pick Spotlight Image…",
            action: #selector(pickSpotlight),
            keyEquivalent: ""
        )
        pickSpotlightItem.target = self
        menu.addItem(pickSpotlightItem)

        let reapplyItem = NSMenuItem(
            title: "Re-apply Wallpaper",
            action: #selector(reapplyWallpaper),
            keyEquivalent: "r"
        )
        reapplyItem.target = self
        menu.addItem(reapplyItem)

        let chooseItem = NSMenuItem(
            title: "Choose Image from File…",
            action: #selector(chooseImage),
            keyEquivalent: "o"
        )
        chooseItem.target = self
        menu.addItem(chooseItem)

        let favoriteItem = NSMenuItem(
            title: "★ Favorite Current Wallpaper",
            action: #selector(favoriteCurrent),
            keyEquivalent: ""
        )
        favoriteItem.target = self
        menu.addItem(favoriteItem)

        menu.addItem(NSMenuItem.separator())

        pauseMenuItem = NSMenuItem(
            title: "Pause Daily Auto-Change",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseMenuItem.target = self
        updatePauseCheckmark()
        menu.addItem(pauseMenuItem)

        menu.addItem(NSMenuItem.separator())

        let exitItem = NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "q")
        exitItem.target = self
        menu.addItem(exitItem)

        return menu
    }

    private func updateSourceCheckmarks() {
        let current = Preferences.shared.source
        bingMenuItem.state = (current == .bing) ? .on : .off
        spotlightMenuItem.state = (current == .spotlight) ? .on : .off
    }

    private func updatePauseCheckmark() {
        pauseMenuItem.state = Preferences.shared.dailyAutoPaused ? .on : .off
    }

    // MARK: - Menu Actions

    @objc private func selectBing() {
        Logger.shared.log("Source switched to Bing.")
        Preferences.shared.source = .bing
        updateSourceCheckmarks()
        WallpaperManager.shared.activateSource(.bing)
    }

    @objc private func selectSpotlight() {
        Logger.shared.log("Source switched to Spotlight.")
        Preferences.shared.source = .spotlight
        updateSourceCheckmarks()
        WallpaperManager.shared.activateSource(.spotlight)
    }

    @objc private func pickSpotlight() {
        Logger.shared.log("Pick Spotlight Image requested.")
        WallpaperManager.shared.presentSpotlightPicker()
    }

    @objc private func reapplyWallpaper() {
        Logger.shared.log("Re-apply wallpaper requested.")
        WallpaperManager.shared.reapplyCurrentWallpaper()
    }

    @objc private func chooseImage() {
        Logger.shared.log("Choose image from file requested.")
        WallpaperManager.shared.chooseWallpaperFromFile()
    }

    @objc private func favoriteCurrent() {
        Logger.shared.log("Favorite current wallpaper requested.")
        WallpaperManager.shared.favoriteCurrentWallpaper()
    }

    @objc private func togglePause() {
        Preferences.shared.dailyAutoPaused.toggle()
        updatePauseCheckmark()
        Logger.shared.log(Preferences.shared.dailyAutoPaused ? "Daily auto-change paused." : "Daily auto-change resumed.")
    }

    @objc private func exitApp() {
        Logger.shared.log("DailyWalls exiting.")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - System Notifications

    private func registerSystemObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        wsCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func systemDidWake(_ notification: Notification) {
        Logger.shared.log("System woke from sleep.")
        WallpaperManager.shared.reapplyCurrentWallpaper()
        WallpaperManager.shared.refreshIfNeeded()
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        Logger.shared.log("Screen unlocked.")
        WallpaperManager.shared.reapplyCurrentWallpaper()
        WallpaperManager.shared.refreshIfNeeded()
    }
}