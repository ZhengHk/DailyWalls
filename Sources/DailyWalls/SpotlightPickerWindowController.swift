import AppKit

struct SpotlightPickerEntry {
    let image: WallpaperImage
    let localURL: URL
    let preview: NSImage
}

/// Large window showing up to four Spotlight previews; supports reroll and favorites.
@MainActor
final class SpotlightPickerWindowController: NSWindowController, NSWindowDelegate {

    var onSelect: ((SpotlightPickerEntry) -> Void)?
    var onFavorite: ((SpotlightPickerEntry, @escaping (Bool) -> Void) -> Void)?
    var onReroll: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var entries: [SpotlightPickerEntry] = []
    private let gridStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Loading…")
    private let rerollButton = NSButton(title: "Reroll", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var cardViews: [SpotlightPickerCardView] = []
    private var statusResetWorkItem: DispatchWorkItem?

    convenience init() {
        let width: CGFloat = 920
        let height: CGFloat = 640
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pick a Spotlight Image"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        setupUI()
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor

        rerollButton.bezelStyle = .rounded
        rerollButton.target = self
        rerollButton.action = #selector(rerollClicked)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        gridStack.orientation = .vertical
        gridStack.alignment = .centerX
        gridStack.spacing = 16
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [rerollButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let root = NSStackView(views: [statusLabel, gridStack, buttonRow])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            gridStack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48),
        ])
    }

    func showLoading(_ message: String) {
        statusLabel.stringValue = message
        clearGrid()
        rerollButton.isEnabled = false
    }

    func showError(_ message: String) {
        statusLabel.stringValue = message
        clearGrid()
        rerollButton.isEnabled = true
    }

    func update(entries: [SpotlightPickerEntry]) {
        self.entries = entries
        clearGrid()
        rerollButton.isEnabled = true
        statusLabel.stringValue = entries.isEmpty
            ? "No images returned — try Reroll."
            : "Choose a wallpaper (Save copies to ~/Pictures/ms-wallpapers/saved/)."

        let rows: [[SpotlightPickerEntry]] = {
            if entries.count <= 2 {
                return [entries]
            }
            let mid = (entries.count + 1) / 2
            return [Array(entries.prefix(mid)), Array(entries.suffix(from: mid))]
        }()

        for rowEntries in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 16
            row.alignment = .top

            for entry in rowEntries {
                let card = SpotlightPickerCardView(
                    entry: entry,
                    alreadyInFavorites: WallpaperManager.shared.isInFavorites(fileName: entry.image.fileName),
                    onUse: { [weak self] in self?.select(entry) },
                    onFavorite: { [weak self] done in self?.favorite(entry, completion: done) }
                )
                cardViews.append(card)
                row.addArrangedSubview(card)
            }
            gridStack.addArrangedSubview(row)
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func clearGrid() {
        cardViews.removeAll()
        for view in gridStack.arrangedSubviews {
            gridStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func select(_ entry: SpotlightPickerEntry) {
        onSelect?(entry)
        closePicker()
    }

    private func favorite(_ entry: SpotlightPickerEntry, completion: @escaping (Bool) -> Void) {
        onFavorite?(entry) { [weak self] success in
            if success {
                self?.flashStatus("Saved \(entry.image.fileName)")
            } else {
                self?.flashStatus("Could not save — see log.")
            }
            completion(success)
        }
    }

    private func flashStatus(_ message: String) {
        statusResetWorkItem?.cancel()
        statusLabel.stringValue = message
        statusLabel.textColor = .labelColor
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = self.entries.count
            self.statusLabel.textColor = .secondaryLabelColor
            self.statusLabel.stringValue = count == 0
                ? "No images returned — try Reroll."
                : "Choose a wallpaper (Save copies to ~/Pictures/ms-wallpapers/saved/)."
        }
        statusResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    @objc private func rerollClicked() {
        showLoading("Fetching new Spotlight images…")
        onReroll?()
    }

    @objc private func cancelClicked() {
        closePicker()
    }

    private func closePicker() {
        window?.orderOut(nil)
        onDismiss?()
    }

    func windowWillClose(_ notification: Notification) {
        onDismiss?()
    }
}

// MARK: - Card

@MainActor
private final class SpotlightPickerCardView: NSView {

    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(
        entry: SpotlightPickerEntry,
        alreadyInFavorites: Bool,
        onUse: @escaping () -> Void,
        onFavorite: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let thumb = NSImageView(image: entry.preview)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(wrappingLabelWithString: entry.image.title ?? "Untitled")
        title.font = .boldSystemFont(ofSize: 13)
        title.maximumNumberOfLines = 2

        let copyright = NSTextField(wrappingLabelWithString: entry.image.copyright ?? "")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor
        copyright.maximumNumberOfLines = 2

        let useButton = NSButton(title: "Use", target: nil, action: nil)
        useButton.bezelStyle = .rounded
        useButton.action = #selector(useTapped)
        useButton.target = self
        self.onUse = onUse

        saveButton.bezelStyle = .rounded
        saveButton.action = #selector(saveTapped)
        saveButton.target = self
        self.onFavorite = onFavorite

        setSavedState(alreadyInFavorites)

        let buttons = NSStackView(views: [useButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let textStack = NSStackView(views: [title, copyright, buttons])
        textStack.orientation = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading

        let column = NSStackView(views: [thumb, textStack])
        column.orientation = .vertical
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 400),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumb.heightAnchor.constraint(equalToConstant: 200),
            thumb.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var onUse: (() -> Void)?
    private var onFavorite: ((@escaping (Bool) -> Void) -> Void)?

    func setSavedState(_ saved: Bool) {
        if saved {
            saveButton.title = "Saved"
            saveButton.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Saved")
            saveButton.imagePosition = .imageLeading
            saveButton.contentTintColor = .controlAccentColor
        } else {
            saveButton.title = "Save"
            saveButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Save to favorites")
            saveButton.imagePosition = .imageLeading
            saveButton.contentTintColor = nil
        }
        saveButton.isEnabled = true
    }

    @objc private func useTapped() { onUse?() }

    @objc private func saveTapped() {
        saveButton.title = "Saving…"
        saveButton.image = nil
        saveButton.isEnabled = false
        onFavorite? { [weak self] success in
            guard let self else { return }
            if success {
                self.setSavedState(true)
            } else {
                self.setSavedState(false)
            }
        }
    }
}