//
//  PrefsWindowController.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

class PrefsWindowController: NSWindowController {

    // MARK: - Appearance tab controls

    private let previewView = BorderPreviewView()
    // Overlaid on the preview while spotlight mode is on, when the preview
    // renders the dimming instead of a border.
    private let spotlightPreviewHint = NSTextField(
        wrappingLabelWithString: "Spotlight mode is on — the border only appears for “Find my window” flashes."
    )
    private let borderStylePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lightModeColorWell = NSColorWell()
    private let darkModeColorWell = NSColorWell()
    private let perAppColorsCheckbox = NSButton(checkboxWithTitle: "Per-app border colors", target: nil, action: nil)
    private let glowingBorderCheckbox = NSButton(checkboxWithTitle: "Glowing border", target: nil, action: nil)
    private let strongerShadowCheckbox = NSButton(checkboxWithTitle: "Stronger shadow", target: nil, action: nil)
    private let partyModeCheckbox = NSButton(checkboxWithTitle: "Party mode 🌈", target: nil, action: nil)

    // MARK: - Behavior tab controls

    private let showWhileDraggingCheckbox = NSButton(checkboxWithTitle: "Show border while dragging", target: nil, action: nil)
    private let hideWhenMaximizedCheckbox = NSButton(checkboxWithTitle: "Hide border when window fills the screen", target: nil, action: nil)
    private let focusPulseCheckbox = NSButton(checkboxWithTitle: "Pulse border on focus change", target: nil, action: nil)
    private let spotlightModeCheckbox = NSButton(checkboxWithTitle: "Spotlight mode (dim other windows)", target: nil, action: nil)
    private let animateMovementCheckbox = NSButton(checkboxWithTitle: "Animate movement between windows", target: nil, action: nil)
    private let glideDurationSlider = NSSlider(value: Defaults.moveAnimationDuration, minValue: 0.1, maxValue: 0.75, target: nil, action: nil)
    private let glideDurationLabel = NSTextField(labelWithString: "0.25 s")
    private let dimLevelSlider = NSSlider(value: Defaults.spotlightDimAlpha, minValue: 0.1, maxValue: 0.9, target: nil, action: nil)
    private let dimLevelLabel = NSTextField(labelWithString: "45%")
    private let findMyWindowCheckbox = NSButton(checkboxWithTitle: "“Find my window” hotkey — flashes the border", target: nil, action: nil)
    private let shortcutRecorder = ShortcutRecorderButton()
    private let shakeToFindCheckbox = NSButton(checkboxWithTitle: "Shake mouse to find window", target: nil, action: nil)
    private let flashOnSpaceChangeCheckbox = NSButton(checkboxWithTitle: "Flash border when switching Spaces", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Alan at login", target: nil, action: nil)

    // MARK: - Excluded-apps tab controls

    private let excludedAppsTableView = DeletableTableView()
    private let excludedRemoveButton = NSButton(title: "Remove", target: nil, action: nil)
    private var excludedApps: [String] = []

    // Cached launch-at-login state. SMAppService.mainApp.status is an XPC
    // round-trip, so it's read once and refreshed only when it can actually
    // change (this checkbox, or the window regaining key), not on every
    // defaults notification. Coalesces slider-drag notification storms too.
    private var launchAtLoginEnabled = false
    private var syncScheduled = false

    // MARK: - Setup

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Alan Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.center()

        buildUI()
        loadValues()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // Reflect a failed (in-use) hotkey registration in the recorder.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: FocusHighlighter.hotkeyRegistrationDidChange,
            object: nil
        )

        // If the window closes mid-recording, tear the capture down so its
        // local key monitor doesn't linger and swallow keystrokes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(prefsWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )

        // Login-item state can change in System Settings while we're not
        // frontmost; re-read it when the window regains key rather than
        // polling it on every defaults change.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLaunchAtLoginStatus),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    @objc private func prefsWindowWillClose() {
        shortcutRecorder.cancelRecording()
    }

    @objc private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        launchAtLoginCheckbox.state = launchAtLoginEnabled ? .on : .off
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        let appearance = NSTabViewItem(identifier: "appearance")
        appearance.label = "Appearance"
        appearance.view = makeAppearanceTab()
        tabView.addTabViewItem(appearance)

        let behavior = NSTabViewItem(identifier: "behavior")
        behavior.label = "Behavior"
        behavior.view = makeBehaviorTab()
        tabView.addTabViewItem(behavior)

        let apps = NSTabViewItem(identifier: "apps")
        apps.label = "Excluded Apps"
        apps.view = makeExcludedAppsTab()
        tabView.addTabViewItem(apps)
    }

    // MARK: Appearance tab

    private func makeAppearanceTab() -> NSView {
        let view = NSView()

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 6
        previewView.layer?.masksToBounds = true
        view.addSubview(previewView)

        spotlightPreviewHint.translatesAutoresizingMaskIntoConstraints = false
        spotlightPreviewHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        spotlightPreviewHint.textColor = .white
        spotlightPreviewHint.isHidden = true
        previewView.addSubview(spotlightPreviewHint)
        NSLayoutConstraint.activate([
            spotlightPreviewHint.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 10),
            spotlightPreviewHint.trailingAnchor.constraint(lessThanOrEqualTo: previewView.trailingAnchor, constant: -10),
            spotlightPreviewHint.bottomAnchor.constraint(equalTo: previewView.bottomAnchor, constant: -8)
        ])

        let widthField = makeNumberField(boundTo: Key.width, min: 1, max: 20)
        let widthStepper = makeStepper(boundTo: Key.width, min: 1, max: 20)
        let insetField = makeNumberField(boundTo: Key.inset, min: 1, max: 20)
        let insetStepper = makeStepper(boundTo: Key.inset, min: 1, max: 20)
        let radiusField = makeNumberField(boundTo: Key.cornerRadius, min: 0, max: 50)
        let radiusStepper = makeStepper(boundTo: Key.cornerRadius, min: 0, max: 50)

        lightModeColorWell.target = self
        lightModeColorWell.action = #selector(lightModeChanged(_:))
        darkModeColorWell.target = self
        darkModeColorWell.action = #selector(darkModeChanged(_:))
        for well in [lightModeColorWell, darkModeColorWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 44),
                well.heightAnchor.constraint(equalToConstant: 24)
            ])
        }

        setUp(perAppColorsCheckbox, action: #selector(perAppColorsChanged(_:)))
        setUp(glowingBorderCheckbox, action: #selector(glowingBorderChanged(_:)))
        setUp(strongerShadowCheckbox, action: #selector(strongerShadowChanged(_:)))
        setUp(partyModeCheckbox, action: #selector(partyModeChanged(_:)))

        borderStylePopUp.translatesAutoresizingMaskIntoConstraints = false
        borderStylePopUp.addItems(withTitles: BorderStyle.allCases.map(\.label))
        borderStylePopUp.target = self
        borderStylePopUp.action = #selector(borderStyleChanged(_:))

        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [makeLabel("Border Width:"), widthField, widthStepper],
            [makeLabel("Border Inset:"), insetField, insetStepper],
            [makeLabel("Corner Radius:"), radiusField, radiusStepper],
            [makeLabel("Border Style:"), borderStylePopUp, empty],
            [makeLabel("Light Mode:"), lightModeColorWell, empty],
            [makeLabel("Dark Mode:"), darkModeColorWell, empty],
            [empty, perAppColorsCheckbox, empty],
            [empty, glowingBorderCheckbox, empty],
            [empty, strongerShadowCheckbox, empty],
            [empty, partyModeCheckbox, empty]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            previewView.heightAnchor.constraint(equalToConstant: 150),
            grid.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 16),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        return view
    }

    // MARK: Behavior tab

    private func makeBehaviorTab() -> NSView {
        let view = NSView()

        setUp(showWhileDraggingCheckbox, action: #selector(showFrameWhileDraggingChanged(_:)))
        setUp(hideWhenMaximizedCheckbox, action: #selector(hideBorderWhenMaximizedChanged(_:)))
        setUp(focusPulseCheckbox, action: #selector(focusPulseChanged(_:)))
        setUp(spotlightModeCheckbox, action: #selector(spotlightModeChanged(_:)))
        setUp(animateMovementCheckbox, action: #selector(animateMovementChanged(_:)))
        setUp(findMyWindowCheckbox, action: #selector(findMyWindowHotkeyChanged(_:)))
        setUp(shakeToFindCheckbox, action: #selector(shakeToFindChanged(_:)))
        setUp(flashOnSpaceChangeCheckbox, action: #selector(flashOnSpaceChangeChanged(_:)))
        setUp(launchAtLoginCheckbox, action: #selector(launchAtLoginChanged(_:)))

        glideDurationSlider.translatesAutoresizingMaskIntoConstraints = false
        glideDurationSlider.isContinuous = true
        glideDurationSlider.bind(
            .value,
            to: NSUserDefaultsController.shared,
            withKeyPath: "values.\(Key.moveAnimationDuration)",
            options: [.continuouslyUpdatesValue: true]
        )
        let glideRow = indentedRow([makeLabel("Duration:"), glideDurationSlider, glideDurationLabel])
        NSLayoutConstraint.activate([
            glideDurationSlider.widthAnchor.constraint(equalToConstant: 180),
            glideDurationLabel.widthAnchor.constraint(equalToConstant: 50)
        ])

        dimLevelSlider.translatesAutoresizingMaskIntoConstraints = false
        dimLevelSlider.isContinuous = true
        dimLevelSlider.bind(
            .value,
            to: NSUserDefaultsController.shared,
            withKeyPath: "values.\(Key.spotlightDimLevel)",
            options: [.continuouslyUpdatesValue: true]
        )
        let dimRow = indentedRow([makeLabel("Dim level:"), dimLevelSlider, dimLevelLabel])
        NSLayoutConstraint.activate([
            dimLevelSlider.widthAnchor.constraint(equalToConstant: 180),
            dimLevelLabel.widthAnchor.constraint(equalToConstant: 44)
        ])

        shortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        let shortcutRow = indentedRow([makeLabel("Shortcut:"), shortcutRecorder])
        NSLayoutConstraint.activate([
            shortcutRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [
            showWhileDraggingCheckbox,
            hideWhenMaximizedCheckbox,
            focusPulseCheckbox,
            animateMovementCheckbox,
            glideRow,
            spotlightModeCheckbox,
            dimRow,
            findMyWindowCheckbox,
            shortcutRow,
            shakeToFindCheckbox,
            flashOnSpaceChangeCheckbox,
            divider,
            launchAtLoginCheckbox
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return view
    }

    // MARK: Excluded-apps tab

    private func makeExcludedAppsTab() -> NSView {
        let view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.title = "Application"
        excludedAppsTableView.addTableColumn(column)
        excludedAppsTableView.headerView = nil
        excludedAppsTableView.rowHeight = 22
        excludedAppsTableView.allowsMultipleSelection = true
        excludedAppsTableView.delegate = self
        excludedAppsTableView.dataSource = self
        excludedAppsTableView.registerForDraggedTypes([.fileURL])
        // Delete/⌫ removes the selection, the standard Mac list gesture.
        excludedAppsTableView.onDelete = { [weak self] in
            guard let self else { return }
            self.removeExcludedApp(self)
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = excludedAppsTableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(addExcludedApp(_:)))
        let removeButton = excludedRemoveButton
        removeButton.target = self
        removeButton.action = #selector(removeExcludedApp(_:))
        removeButton.isEnabled = false      // nothing is selected yet
        addButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = makeLabel("Apps in this list never get a border. Drag applications here, or click Add.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.lineBreakMode = .byWordWrapping
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        view.addSubview(hint)
        view.addSubview(scrollView)
        view.addSubview(addButton)
        view.addSubview(removeButton)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        return view
    }

    // MARK: Small builders

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeNumberField(boundTo key: String, min: Int, max: Int) -> NSTextField {
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        // Match the paired stepper's range so a typed-in value can't diverge
        // from what the draw code clamps to — the formatter rejects
        // out-of-range entry at commit time.
        formatter.minimum = NSNumber(value: min)
        formatter.maximum = NSNumber(value: max)
        field.formatter = formatter
        field.bind(
            .value,
            to: NSUserDefaultsController.shared,
            withKeyPath: "values.\(key)",
            options: nil
        )
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return field
    }

    private func makeStepper(boundTo key: String, min: Double, max: Double) -> NSStepper {
        let stepper = NSStepper()
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.bind(
            .value,
            to: NSUserDefaultsController.shared,
            withKeyPath: "values.\(key)",
            options: nil
        )
        return stepper
    }

    private func setUp(_ checkbox: NSButton, action: Selector) {
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.target = self
        checkbox.action = action
    }

    // A horizontal row indented under its governing checkbox.
    private func indentedRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
        return row
    }

    // MARK: - State

    private func loadValues() {
        lightModeColorWell.color = UserDefaults.standard.color(forKey: Key.lightMode) ?? Defaults.lightModeColor
        darkModeColorWell.color = UserDefaults.standard.color(forKey: Key.darkMode) ?? Defaults.darkModeColor

        excludedApps = UserDefaults.standard.stringArray(forKey: Key.excludedApps) ?? []
        excludedAppsTableView.reloadData()

        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        syncDynamicUI()
    }

    @objc private func defaultsChanged() {
        // A continuous slider or color-well drag posts many notifications per
        // second; collapse them into one UI resync per run-loop turn.
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncDynamicUI()
        }
    }

    private func syncDynamicUI() {
        let defaults = UserDefaults.standard

        showWhileDraggingCheckbox.state = defaults.bool(forKey: Key.showFrameWhileDragging) ? .on : .off
        hideWhenMaximizedCheckbox.state = defaults.bool(forKey: Key.hideBorderWhenMaximized) ? .on : .off
        focusPulseCheckbox.state = defaults.bool(forKey: Key.focusPulse) ? .on : .off
        spotlightModeCheckbox.state = defaults.bool(forKey: Key.spotlightMode) ? .on : .off
        findMyWindowCheckbox.state = defaults.bool(forKey: Key.findMyWindowHotkey) ? .on : .off
        shakeToFindCheckbox.state = defaults.bool(forKey: Key.shakeToFind) ? .on : .off
        flashOnSpaceChangeCheckbox.state = defaults.bool(forKey: Key.flashOnSpaceChange) ? .on : .off
        perAppColorsCheckbox.state = defaults.bool(forKey: Key.perAppColors) ? .on : .off
        if let styleIndex = BorderStyle.allCases.firstIndex(of: BorderStyle.current) {
            borderStylePopUp.selectItem(at: styleIndex)
        }
        glowingBorderCheckbox.state = defaults.bool(forKey: Key.glowingBorder) ? .on : .off
        strongerShadowCheckbox.state = defaults.bool(forKey: Key.strongerShadow) ? .on : .off
        partyModeCheckbox.state = defaults.bool(forKey: Key.partyMode) ? .on : .off
        launchAtLoginCheckbox.state = launchAtLoginEnabled ? .on : .off

        animateMovementCheckbox.state = defaults.bool(forKey: Key.animateMovement) ? .on : .off
        glideDurationSlider.isEnabled = defaults.bool(forKey: Key.animateMovement)
        var glideDuration = defaults.double(forKey: Key.moveAnimationDuration)
        if glideDuration <= 0 {
            glideDuration = Defaults.moveAnimationDuration
        }
        glideDurationLabel.stringValue = String(format: "%.2f s", glideDuration)

        let spotlightOn = defaults.bool(forKey: Key.spotlightMode)
        dimLevelSlider.isEnabled = spotlightOn
        var dimLevel = defaults.double(forKey: Key.spotlightDimLevel)
        if dimLevel == 0 {
            dimLevel = Defaults.spotlightDimAlpha
        }
        dimLevelLabel.stringValue = "\(Int((dimLevel * 100).rounded()))%"

        // The pulse animates the border, which spotlight mode replaces, so
        // the checkbox would be a silent no-op while spotlight is on.
        focusPulseCheckbox.isEnabled = !spotlightOn
        focusPulseCheckbox.toolTip = spotlightOn
            ? "Spotlight mode replaces the border, so there is no border to pulse."
            : nil

        // While spotlight is on, the preview shows the dimming and says why.
        spotlightPreviewHint.isHidden = !spotlightOn

        shortcutRecorder.isEnabled = defaults.bool(forKey: Key.findMyWindowHotkey)
        shortcutRecorder.registrationFailed = FocusHighlighter.shared.hotkeyRegistrationFailed
        shortcutRecorder.refreshTitle()

        // The status menu's "Exclude <app>" writes to defaults directly. If
        // this window is open at the time, the private copy must follow —
        // otherwise the table shows a stale list and, worse, the next Remove
        // here would write that stale copy back over defaults, silently
        // undoing the exclusion the menu just added.
        let storedExclusions = defaults.stringArray(forKey: Key.excludedApps) ?? []
        if storedExclusions != excludedApps {
            excludedApps = storedExclusions
            excludedAppsTableView.reloadData()
            // reloadData drops the selection; keep the button honest.
            excludedRemoveButton.isEnabled = excludedAppsTableView.selectedRow >= 0
        }

        previewView.needsDisplay = true
    }

    // MARK: - Actions

    @objc func lightModeChanged(_ sender: NSColorWell) {
        UserDefaults.standard.setColor(sender.color, forKey: Key.lightMode)
    }

    @objc func darkModeChanged(_ sender: NSColorWell) {
        UserDefaults.standard.setColor(sender.color, forKey: Key.darkMode)
    }

    @objc func showFrameWhileDraggingChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.showFrameWhileDragging)
    }

    @objc func glowingBorderChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.glowingBorder)
    }

    @objc func strongerShadowChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.strongerShadow)
    }

    @objc func hideBorderWhenMaximizedChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.hideBorderWhenMaximized)
    }

    @objc func focusPulseChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.focusPulse)
    }

    @objc func perAppColorsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.perAppColors)
    }

    @objc func spotlightModeChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.spotlightMode)
    }

    @objc func animateMovementChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.animateMovement)
    }

    @objc func findMyWindowHotkeyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.findMyWindowHotkey)
    }

    @objc func partyModeChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.partyMode)
    }

    @objc func borderStyleChanged(_ sender: NSPopUpButton) {
        let index = max(0, min(BorderStyle.allCases.count - 1, sender.indexOfSelectedItem))
        UserDefaults.standard.set(BorderStyle.allCases[index].rawValue, forKey: Key.borderStyle)
    }

    @objc func shakeToFindChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.shakeToFind)
    }

    @objc func flashOnSpaceChangeChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.flashOnSpaceChange)
    }

    @objc func launchAtLoginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        refreshLaunchAtLoginStatus()
    }

    @objc func addExcludedApp(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.application]
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")

        openPanel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            if let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier {
                self?.addExcludedAppWithBundleId(bundleIdentifier)
            }
        }
    }

    @objc func removeExcludedApp(_ sender: Any) {
        let selected = excludedAppsTableView.selectedRowIndexes
        guard !selected.isEmpty else { return }

        // Remove back-to-front so earlier indices stay valid.
        for row in selected.sorted(by: >) where row < excludedApps.count {
            excludedApps.remove(at: row)
        }
        UserDefaults.standard.set(excludedApps, forKey: Key.excludedApps)
        excludedAppsTableView.reloadData()
        excludedRemoveButton.isEnabled = false
    }

    private func addExcludedAppWithBundleId(_ bundleIdentifier: String) {
        guard !excludedApps.contains(bundleIdentifier) else { return }
        excludedApps.append(bundleIdentifier)
        UserDefaults.standard.set(excludedApps, forKey: Key.excludedApps)
        excludedAppsTableView.reloadData()
    }
}

// MARK: - Excluded-apps table

extension PrefsWindowController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return excludedApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bundleIdentifier = excludedApps[row]

        let cellIdentifier = NSUserInterfaceItemIdentifier("ExcludedAppCell")
        var cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView

        if cellView == nil {
            cellView = NSTableCellView()
            cellView?.identifier = cellIdentifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView?.addSubview(textField)
            cellView?.textField = textField

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cellView?.addSubview(imageView)
            cellView?.imageView = imageView

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor)
            ])
        }

        // Get app name and icon from bundle identifier. Cells are reused, so
        // both branches must set every attribute they touch.
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            cellView?.textField?.stringValue = FileManager.default.displayName(atPath: appURL.path)
            cellView?.textField?.textColor = .labelColor
            cellView?.imageView?.image = NSWorkspace.shared.icon(forFile: appURL.path)
            cellView?.toolTip = nil
        } else {
            // App not installed: show the bundle ID muted, with a generic app
            // icon and a tooltip, so the row reads as inert rather than broken.
            cellView?.textField?.stringValue = bundleIdentifier
            cellView?.textField?.textColor = .secondaryLabelColor
            cellView?.imageView?.image = NSWorkspace.shared.icon(for: .applicationBundle)
            cellView?.toolTip = "Not currently installed (\(bundleIdentifier))"
        }

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        excludedRemoveButton.isEnabled = excludedAppsTableView.selectedRow >= 0
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !applicationURLs(from: info).isEmpty else { return [] }
        // The list is unordered; highlight the whole table.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = applicationURLs(from: info)
        guard !urls.isEmpty else { return false }

        for url in urls {
            if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier {
                addExcludedAppWithBundleId(bundleIdentifier)
            }
        }
        return true
    }

    private func applicationURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" }
    }
}

// MARK: - Excluded-apps table view

// An NSTableView that reports Delete/Forward-Delete presses, so the standard
// Mac gesture for removing a list row works.
final class DeletableTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Live preview

// A mock desktop with a mock window, bordered by the real drawing code —
// what you tweak is what you get.
final class BorderPreviewView: NSView {

    private var redrawTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    // Party mode cycles and per-app colors change without defaults
    // notifications, so the preview repaints on a timer while it's on screen.
    // The timer is *started and stopped* by the window's occlusion state, not
    // left running with an isVisible guard in its body: the Settings window is
    // isReleasedWhenClosed = false and only ordered out on close, so this view
    // stays installed, `window` never returns to nil, viewDidMoveToWindow is
    // never called again, and a body-guarded timer would keep waking the
    // process 30×/s forever after Settings is opened once. Occlusion covers
    // close (loses .visible), reopen (gains it), and miniaturize.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }

        guard let window else {
            stopRedrawTimer()
            return
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] note in
            guard let self, let changed = note.object as? NSWindow else { return }
            self.updateRedrawTimer(visible: changed.occlusionState.contains(.visible))
        }
        updateRedrawTimer(visible: window.occlusionState.contains(.visible))
    }

    private func updateRedrawTimer(visible: Bool) {
        visible ? startRedrawTimer() : stopRedrawTimer()
    }

    private func startRedrawTimer() {
        guard redrawTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        timer.tolerance = (1.0 / 30.0) * 0.1
        RunLoop.current.add(timer, forMode: .common)
        redrawTimer = timer
    }

    private func stopRedrawTimer() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        redrawTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Desktop
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        // Mock window, leaving room around it for inset, border, and glow
        let windowRect = bounds.insetBy(dx: 90, dy: 38)
        let windowPath = NSBezierPath(roundedRect: windowRect, xRadius: 9, yRadius: 9)
        NSColor.windowBackgroundColor.setFill()
        windowPath.fill()
        NSColor.separatorColor.setStroke()
        windowPath.lineWidth = 1
        windowPath.stroke()

        // Traffic lights, for charm
        let dotColors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for (i, dotColor) in dotColors.enumerated() {
            let dot = NSRect(
                x: windowRect.minX + 10 + CGFloat(i) * 12,
                y: windowRect.maxY - 16,
                width: 7,
                height: 7
            )
            dotColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        if UserDefaults.standard.bool(forKey: Key.spotlightMode) {
            // Spotlight mode replaces the border with dimming, so previewing
            // a border that won't be there was a lie. Same math as DimView:
            // dim everything but the window, cut out with the window's own
            // rounded corners — and the dim-level slider previews live.
            var dimLevel = UserDefaults.standard.double(forKey: Key.spotlightDimLevel)
            if dimLevel == 0 {
                dimLevel = Defaults.spotlightDimAlpha
            }
            dimLevel = max(0.05, min(0.9, dimLevel))

            let dimPath = NSBezierPath(rect: bounds)
            dimPath.append(NSBezierPath(roundedRect: windowRect, xRadius: 9, yRadius: 9))
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(CGFloat(dimLevel)).setFill()
            dimPath.fill()
            return
        }

        // The real border, drawn by the real code
        NSGraphicsContext.current?.saveGraphicsState()
        HighlightView.drawBorder(around: windowRect)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// MARK: - Shortcut recorder

// A button that records the next keystroke as the find-my-window hotkey.
// Click, press a combo (it needs ⌘, ⌃, or ⌥ — a global hotkey without one
// would shadow plain typing), Escape cancels.
final class ShortcutRecorderButton: NSButton {

    private var keyMonitor: Any?
    private var isRecording = false

    // Set by the prefs controller from FocusHighlighter's registration state:
    // true means the recorded combo is already claimed by another app.
    var registrationFailed = false {
        didSet { if oldValue != registrationFailed { refreshTitle() } }
    }

    convenience init() {
        self.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording(_:))
        refreshTitle()
    }

    func refreshTitle() {
        if isRecording {
            title = "Type shortcut…"
            toolTip = nil
            return
        }
        let label = UserDefaults.standard.string(forKey: Key.findMyWindowShortcutLabel)
            ?? Defaults.findMyWindowDefaultLabel
        if registrationFailed {
            title = "\(label) — in use"
            toolTip = "This shortcut is already used by another app. Record a different one."
        } else {
            title = label
            toolTip = nil
        }
    }

    // Cancel an in-progress recording (e.g. the window is closing) so the
    // local key monitor isn't left installed, silently swallowing keystrokes.
    func cancelRecording() {
        if isRecording {
            endRecording()
        }
    }

    @objc private func toggleRecording(_ sender: Any?) {
        isRecording ? endRecording() : beginRecording()
    }

    private func beginRecording() {
        isRecording = true
        // Suspend the active Carbon hotkey so the combo the user types reaches
        // this monitor instead of being consumed system-wide (which would fire
        // the hotkey and make the current combo impossible to re-record).
        FocusHighlighter.shared.suspendHotkeyForRecording()
        refreshTitle()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if Int(event.keyCode) == kVK_Escape {
                self.endRecording()
                return nil
            }

            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }

            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: Key.findMyWindowKeyCode)
            defaults.set(Self.carbonModifiers(from: flags), forKey: Key.findMyWindowModifiers)
            defaults.set(Self.displayString(for: event, flags: flags), forKey: Key.findMyWindowShortcutLabel)

            self.endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        isRecording = false
        // Re-register with whatever combo was just recorded (or the previous
        // one if the user cancelled).
        FocusHighlighter.shared.resumeHotkeyAfterRecording()
        refreshTitle()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    private static func displayString(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += keyName(for: event)
        return result
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}
