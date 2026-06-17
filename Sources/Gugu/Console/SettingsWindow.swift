import AppKit

/// Simple settings form for the essentials people actually change: API URL, key,
/// and model — plus a collapsible "Advanced" area for per-tier model overrides,
/// token caps, and the daily budget. Everything else stays in config.yaml and is
/// preserved on save (see ConfigWriter).
///
/// Save writes only the fields that changed, then asks the app to hot-reload.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: GuguApp?

    // Basic fields
    // Basic fields
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()

    // Advanced fields (tier id overrides: blank = use base model)
    private let instinctID = NSTextField()
    private let conversationID = NSTextField()
    private let dreamID = NSTextField()
    private let sparkID = NSTextField()
    private let instinctTokens = NSTextField()
    private let conversationTokens = NSTextField()
    private let dreamTokens = NSTextField()
    private let sparkTokens = NSTextField()
    private let dailyTokens = NSTextField()

    private var advancedRevealed = false
    private var advancedContainer: NSStackView!
    private var disclosureButton: NSButton!
    private var rootStack: NSStackView!

    /// Snapshot of raw config values at load time, to diff on save.
    private var rawValues: [String: String] = [:]

    init(app: GuguApp) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L.settingsTitle
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        loadValues()                    // refresh in case the file changed underneath us
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Build

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        rootStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: content.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // --- Basic rows ---
        providerPopup.addItem(withTitle: L.settingsProviderAnthropic)   // tag/index 0
        providerPopup.addItem(withTitle: L.settingsProviderOpenAI)      // tag/index 1
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        rootStack.addArrangedSubview(controlRow(L.settingsProvider, providerPopup, width: 200))
        rootStack.addArrangedSubview(formRow(L.settingsURL, urlField, placeholder: "https://api.anthropic.com"))
        rootStack.addArrangedSubview(formRow(L.settingsKey, keyField, placeholder: "sk-…"))
        rootStack.addArrangedSubview(formRow(L.settingsModel, modelField, placeholder: "deepseek-v4-flash"))

        // --- Disclosure ---
        disclosureButton = NSButton()
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.title = ""
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleAdvanced)
        let discLabel = NSTextField(labelWithString: L.settingsAdvanced)
        discLabel.font = .systemFont(ofSize: 12, weight: .medium)
        discLabel.textColor = .secondaryLabelColor
        let discRow = NSStackView(views: [disclosureButton, discLabel])
        discRow.orientation = .horizontal
        discRow.spacing = 4
        rootStack.addArrangedSubview(discRow)

        // --- Advanced container (hidden by default) ---
        advancedContainer = NSStackView()
        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 8
        advancedContainer.isHidden = true

        advancedContainer.addArrangedSubview(sectionLabel(L.settingsTierModels))
        advancedContainer.addArrangedSubview(formRow(L.settingsInstinctModel, instinctID, placeholder: L.settingsInheritsBase))
        advancedContainer.addArrangedSubview(formRow(L.settingsConversationModel, conversationID, placeholder: L.settingsInheritsBase))
        advancedContainer.addArrangedSubview(formRow(L.settingsDreamModel, dreamID, placeholder: L.settingsInheritsBase))
        advancedContainer.addArrangedSubview(formRow(L.settingsSparkModel, sparkID, placeholder: L.settingsSparkOff))
        advancedContainer.addArrangedSubview(sectionLabel(L.settingsMaxTokens))
        advancedContainer.addArrangedSubview(formRow(L.settingsInstinctTokens, instinctTokens, placeholder: "200"))
        advancedContainer.addArrangedSubview(formRow(L.settingsConversationTokens, conversationTokens, placeholder: "400"))
        advancedContainer.addArrangedSubview(formRow(L.settingsDreamTokens, dreamTokens, placeholder: "1500"))
        advancedContainer.addArrangedSubview(formRow(L.settingsSparkTokens, sparkTokens, placeholder: "220"))
        advancedContainer.addArrangedSubview(sectionLabel(L.settingsBudget))
        advancedContainer.addArrangedSubview(formRow(L.settingsDailyTokens, dailyTokens, placeholder: "200000"))
        rootStack.addArrangedSubview(advancedContainer)

        // --- Buttons ---
        let cancel = NSButton(title: L.settingsCancel, target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"     // Esc
        let save = NSButton(title: L.settingsSave, target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"           // Return
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancel, save])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40).isActive = true
    }

    /// A label + field row with a fixed-width label column.
    private func formRow(_ label: String, _ field: NSTextField, placeholder: String) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true

        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        field.font = .systemFont(ofSize: 12)

        let row = NSStackView(views: [title, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func sectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// Like `formRow` but for an arbitrary control (e.g. the provider popup),
    /// keeping the same right-aligned label column.
    private func controlRow(_ label: String, _ control: NSView, width: CGFloat) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true

        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: - Load / Save

    private func loadValues() {
        let text = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        let yaml = MiniYAML(text: text)
        rawValues = yaml.values

        urlField.stringValue = yaml.str("api.url", "")
        keyField.stringValue = yaml.str("api.key", "")
        modelField.stringValue = yaml.str("model.id", "")
        providerPopup.selectItem(at: yaml.str("api.provider", "anthropic") == "openai" ? 1 : 0)
        updateURLPlaceholder()

        // Tier overrides: show only if explicitly set, else blank (placeholder).
        instinctID.stringValue = rawValues["model.instinct_id"] ?? ""
        conversationID.stringValue = rawValues["model.conversation_id"] ?? ""
        dreamID.stringValue = rawValues["model.dream_id"] ?? ""
        sparkID.stringValue = rawValues["model.spark_id"] ?? ""
        instinctTokens.stringValue = rawValues["model.instinct_max_tokens"] ?? ""
        conversationTokens.stringValue = rawValues["model.conversation_max_tokens"] ?? ""
        dreamTokens.stringValue = rawValues["model.dream_max_tokens"] ?? ""
        sparkTokens.stringValue = rawValues["model.spark_max_tokens"] ?? ""
        dailyTokens.stringValue = rawValues["budget.daily_tokens"] ?? ""
    }

    @objc private func toggleAdvanced() {
        advancedRevealed.toggle()
        advancedContainer.isHidden = !advancedRevealed
        disclosureButton.state = advancedRevealed ? .on : .off
        window?.layoutIfNeeded()
        // Resize the window to fit the new content height.
        if let window {
            let fitting = rootStack.fittingSize
            var frame = window.frame
            let delta = fitting.height - window.contentView!.frame.height
            frame.size.height += delta
            frame.origin.y -= delta            // grow downward, keep title in place
            window.setFrame(frame, display: true, animate: true)
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    /// Currently selected provider as a config value.
    private var selectedProvider: String {
        providerPopup.indexOfSelectedItem == 1 ? "openai" : "anthropic"
    }

    @objc private func providerChanged() {
        updateURLPlaceholder()
    }

    /// Hint a sensible default endpoint for the chosen provider.
    private func updateURLPlaceholder() {
        urlField.placeholderString = selectedProvider == "openai"
            ? "https://api.deepseek.com"
            : "https://api.anthropic.com"
    }

    @objc private func save() {
        var changes: [(key: String, value: String?)] = []

        // A trimmed-string field maps to a key: write when changed; for tier
        // overrides an empty value means "delete the key" (fall back to base).
        func sync(_ key: String, _ field: NSTextField, deletable: Bool) {
            let newVal = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldVal = rawValues[key]
            if newVal.isEmpty {
                if deletable {
                    if oldVal != nil { changes.append((key, nil)) }     // delete
                }
                // non-deletable empty: leave the file as-is (don't write blank)
                return
            }
            if newVal != oldVal { changes.append((key, yamlEscape(newVal))) }
        }

        // Provider comes from the popup, not a text field.
        let provider = selectedProvider
        if provider != (rawValues["api.provider"] ?? "anthropic") {
            changes.append(("api.provider", provider))
        }
        sync("api.url", urlField, deletable: false)
        sync("api.key", keyField, deletable: false)
        sync("model.id", modelField, deletable: false)
        sync("model.instinct_id", instinctID, deletable: true)
        sync("model.conversation_id", conversationID, deletable: true)
        sync("model.dream_id", dreamID, deletable: true)
        sync("model.spark_id", sparkID, deletable: true)
        sync("model.instinct_max_tokens", instinctTokens, deletable: false)
        sync("model.conversation_max_tokens", conversationTokens, deletable: false)
        sync("model.dream_max_tokens", dreamTokens, deletable: false)
        sync("model.spark_max_tokens", sparkTokens, deletable: false)
        sync("budget.daily_tokens", dailyTokens, deletable: false)

        if !changes.isEmpty {
            do {
                try ConfigWriter.update(Paths.config, changes: changes)
                app?.reloadConfigFromDisk()
            } catch {
                Log.info("settings", "保存配置失败: \(error)")
                let alert = NSAlert()
                alert.messageText = L.settingsSaveFailed
                alert.informativeText = "\(error)"
                alert.runModal()
                return
            }
        }
        window?.close()
    }

    /// Quote a value if it contains YAML-significant characters; otherwise leave
    /// it bare to match the file's existing unquoted style.
    private func yamlEscape(_ value: String) -> String {
        let needsQuote = value.contains(":") || value.contains("#")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.hasPrefix("[") || value.hasPrefix("\"") || value.hasPrefix("'")
        guard needsQuote else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
