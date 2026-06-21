import AppKit
import GuguKernel

/// Menu-bar presence: status, poke, chat entry, audit, quit.
@MainActor
final class Console: NSObject {
    private var statusItem: NSStatusItem!
    private weak var app: GuguApp?
    private let quickPanel = NSPopover()
    private var settingsController: SettingsWindowController?

    /// Chat input panel lives in its own controller; Console keeps a thin shell.
    private lazy var chatController = ChatWindowController(app: app)
    /// Proposal approval logic lives in its own coordinator; Console keeps thin shells.
    private lazy var proposalCoordinator = ProposalApprovalCoordinator(app: app)

    init(app: GuguApp) {
        self.app = app
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        quickPanel.behavior = .transient
        quickPanel.animates = true
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = symbol("bird") ?? symbol("sparkles")
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        if button.image == nil {
            button.title = "🐤"
        }
        button.toolTip = L.menuTooltip
        button.setAccessibilityLabel(L.menuAccessibility)
        // Left-click shows full menu (standard macOS status item behavior)
        statusItem.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.image = symbol("gauge.with.dots.needle.bottom.50percent")
        status.isEnabled = false
        menu.addItem(status)
        let budget = NSMenuItem(title: app?.budget.statusLine ?? "", action: nil, keyEquivalent: "")
        budget.image = symbol("chart.pie")
        budget.isEnabled = false
        menu.addItem(budget)
        let growth = NSMenuItem(title: growthLine(), action: nil, keyEquivalent: "")
        growth.image = symbol("sparkles")
        growth.isEnabled = false
        menu.addItem(growth)
        menu.addItem(.separator())
        menu.addItem(makeItem(L.menuChat, #selector(openChat), "t", icon: "bubble.left.and.text.bubble.right"))
        menu.addItem(makeItem(L.menuPoke, #selector(pokePet), "p", icon: "hand.tap"))
        menu.addItem(makeItem(app?.home.isOpen == true ? L.menuHomeClose : L.menuHome, #selector(toggleHome), "", icon: "house"))
        menu.addItem(makeItem(L.menuHeartbeatDebug, #selector(forceHeartbeat), "", icon: "heart.text.square"))
        menu.addItem(makeItem(L.menuDreamDebug, #selector(forceDream), "", icon: "moon.zzz"))
        menu.addItem(.separator())
        let camItem = makeItem(visionToggleTitle(), #selector(toggleCamera), "", icon: app?.visionSensor.enabled == true ? "eye.slash" : "eye")
        menu.addItem(camItem)
        if app?.visionSensor.enabled == true {
            let dbgTitle = app?.visionDebug?.isOpen == true ? L.menuVisionDebugClose : L.menuVisionDebug
            menu.addItem(makeItem(dbgTitle, #selector(toggleVisionDebug), "", icon: "ladybug"))
        }
        menu.addItem(makeItem(voiceToggleTitle(), #selector(toggleVoice), "", icon: app?.voice.enabled == true ? "speaker.slash" : "speaker.wave.2"))
        menu.addItem(makeItem(listenToggleTitle(), #selector(toggleListen), "", icon: app?.listener.enabled == true ? "mic.slash" : "mic"))
        menu.addItem(makeItem(L.menuAudit, #selector(openAudit), "", icon: "doc.text.magnifyingglass"))
        menu.addItem(makeItem(L.menuProposals, #selector(openProposals), "", icon: "tray.full"))
        let approve = makeItem(L.menuApproveNext, #selector(approveNextProposal), "", icon: "checkmark.seal")
        approve.isEnabled = !Evolution(memory: Memory()).pendingProposals().isEmpty
        menu.addItem(approve)
        menu.addItem(makeItem(L.menuOpenConfig, #selector(openConfigDir), "", icon: "folder"))
        menu.addItem(makeItem(L.menuSettings, #selector(openSettings), ",", icon: "gearshape"))
        menu.addItem(.separator())
        let langTitle = L.current == .en ? L.menuLangZH : L.menuLangEN
        menu.addItem(makeItem(langTitle, #selector(toggleLanguage), "", icon: "globe"))
        menu.addItem(.separator())
        menu.addItem(makeItem(L.menuQuit, #selector(quit), "q", icon: "power"))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String, icon: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let icon { item.image = symbol(icon) }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func statusLine() -> String {
        guard let app else { return "" }
        let rhythm = app.rhythmSensor.rhythm.displayName
        let frozen = app.scheduler.frozen ? " · \(L.statusDND)" : ""
        let sleeping = app.pet.isSleeping ? " · \(L.statusSleeping)" : ""
        return "\(L.statusPrefix) · \(rhythm)\(frozen)\(sleeping)"
    }

    func statusShort() -> String {
        guard let app else { return "-" }
        if app.pet.isSleeping { return L.shortSleep }
        if app.scheduler.frozen { return L.shortDND }
        switch app.rhythmSensor.rhythm {
        case .focused: return L.shortFocused
        case .busy: return L.shortBusy
        case .breather: return L.shortBreather
        case .away: return L.shortAway
        case .active: return L.shortActive
        case .agitated: return L.shortAgitated
        }
    }

    func budgetShort() -> String {
        guard let app else { return "-" }
        let total = app.budget.usage.total
        if total >= 1000 { return String(format: "%.0fk", Double(total) / 1000) }
        return "\(total)"
    }

    private func growthLine() -> String {
        let state = PetState.load()
        let stage = GrowthStage(rawStage: state.stage)
        let pending = Evolution(memory: Memory()).pendingProposals().count
        let suffix = pending > 0 ? " · \(L.proposalsPending(pending))" : ""
        return "\(L.growthPrefix) · \(stage.displayName)\(suffix)"
    }

    func stageShort() -> String {
        GrowthStage(rawStage: PetState.load().stage).shortName
    }

    /// Quick context menu for right-clicking the pet (high-frequency actions only).
    func buildQuickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(L.menuChat, #selector(openChat), "t", icon: "bubble.left.and.text.bubble.right"))
        menu.addItem(makeItem(L.menuPoke, #selector(pokePet), "p", icon: "hand.tap"))
        menu.addItem(makeItem(app?.home.isOpen == true ? L.menuHomeClose : L.menuHome, #selector(toggleHome), "", icon: "house"))
        menu.addItem(.separator())
        let camItem = makeItem(visionToggleTitle(), #selector(toggleCamera), "", icon: app?.visionSensor.enabled == true ? "eye.slash" : "eye")
        menu.addItem(camItem)
        if app?.visionSensor.enabled == true {
            let dbgTitle = app?.visionDebug?.isOpen == true ? L.menuVisionDebugClose : L.menuVisionDebug
            menu.addItem(makeItem(dbgTitle, #selector(toggleVisionDebug), "", icon: "ladybug"))
        }
        menu.addItem(makeItem(voiceToggleTitle(), #selector(toggleVoice), "", icon: app?.voice.enabled == true ? "speaker.slash" : "speaker.wave.2"))
        menu.addItem(makeItem(listenToggleTitle(), #selector(toggleListen), "", icon: app?.listener.enabled == true ? "mic.slash" : "mic"))
        menu.addItem(.separator())
        let actions = NSMenuItem(title: L.menuActions, action: nil, keyEquivalent: "")
        actions.image = symbol("star")
        let sub = NSMenu()
        // 多列网格:内置动作 + 学会的动作一起平铺,容纳更多动作而不必竖排一长条。
        var gridItems: [(label: String, name: String)] = [
            (L.menuDance, "dance"), (L.menuHop, "hop"), (L.menuFly, "fly"),
            (L.menuPerch, "perch"), (L.menuSettle, "settle"), (L.menuGroom, "groom"),
            (L.menuSleep, "sleep"),
        ]
        for move in MoveLibrary.shared.learnedMoves {
            gridItems.append((label: "✨\(move.name)", name: move.name))
        }
        let grid = ActionGridView(items: gridItems, columns: 3)
        grid.onPick = { [weak self] name in self?.app?.pet.perform(action: name) }
        let gridItem = NSMenuItem()
        gridItem.view = grid
        sub.addItem(gridItem)
        actions.submenu = sub
        menu.addItem(actions)
        // 待批准提案:逐条列出标题,点哪条批哪条(不依赖顶部状态栏图标——
        // 带刘海的 Mac 上它常被挤掉)。批准后菜单会刷新,已批的自然消失。
        let pending = Evolution(memory: Memory()).pendingProposals()
        if !pending.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "\(L.menuProposals)(\(pending.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.image = symbol("tray.full")
            menu.addItem(header)
            for proposal in pending {
                let item = NSMenuItem(title: "  ✓ \(proposal.title)", action: #selector(approveProposalItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = proposal.path
                item.image = symbol("checkmark.seal")
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(makeItem(L.menuQuit, #selector(quit), "q", icon: "power"))
        return menu
    }

    func refreshMenu() {
        statusItem.menu = buildMenu()
    }

    // MARK: - Actions

    @objc func toggleLanguage() {
        let newLang = L.current == .en ? "zh" : "en"
        L.current = newLang == "zh" ? .zh : .en
        UserDefaults.standard.set(newLang, forKey: "gugu.language")
        refreshMenu()
        app?.pet.say(L.langSwitched)
    }

    @objc func pokePet() { app?.pet.poked() }

    @objc func toggleHome() { app?.toggleHome() }

    @objc func toggleVisionDebug() { app?.toggleVisionDebug() }

    @objc func showAbilities() {
        app?.pet.say(L.abilitiesSpeech)
    }

    @objc func dancePet() { app?.pet.perform(.dance) }

    @objc func hopPet() { app?.pet.perform(.hop) }

    @objc func flyPet() { app?.pet.perform(.fly) }

    @objc func perchPet() { app?.pet.perform(.goPerch) }

    @objc func settlePet() { app?.pet.perform(.settle) }

    @objc func groomPet() { app?.pet.perform(.groom) }

    @objc func sleepPet() { app?.pet.perform(.sleep) }

    /// 演一个学会的动作(菜单项用 representedObject 携带动作名)。
    @objc func performLearnedMoveItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        app?.pet.perform(action: name)
    }

    @objc func forceHeartbeat() { app?.scheduler.requestHeartbeat(force: true) }

    @objc func forceDream() {
        guard let app else { return }
        app.pet.sleep()
        app.pet.say(L.dreamEnter)
        Task {
            do {
                let r = try await app.scheduler.dreamNow()
                app.pet.wake()
                if !r.morningWords.isEmpty { app.pet.say(r.morningWords) }
                if let title = r.proposalTitle {
                    app.pet.say(L.dreamProposal(title))
                }
                app.refreshGrowthState()
            } catch {
                app.pet.wake()
                Log.info("dream", "手动梦境失败: \(error)")
            }
        }
    }

    @objc func openAudit() {
        NSWorkspace.shared.open(Audit.report())
    }

    // MARK: - Proposal approval (thin shells → ProposalApprovalCoordinator)

    @objc func openProposals() { proposalCoordinator.openProposals() }

    @objc func approveNextProposal() { proposalCoordinator.approveNextProposal() }

    /// 批准右键菜单里点选的那一条(representedObject 携带提案文件 URL)。
    @objc func approveProposalItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        proposalCoordinator.approve(at: url)
    }

    private func visionToggleTitle() -> String {
        let on = app?.visionSensor.enabled ?? false
        return on ? L.toggleCameraOn : L.toggleCameraOff
    }

    func cameraIconName() -> String {
        app?.visionSensor.enabled == true ? "eye.slash" : "eye"
    }

    @objc func toggleCamera() {
        guard let app else { return }
        if app.visionSensor.enabled {
            app.visionSensor.enabled = false
            app.pet.say(L.cameraClosed)
            refreshMenu()
            return
        }
        // 开启:等真实结果再反馈,别在权限被拒时还假装睁眼了。
        app.visionSensor.requestEnable { [weak self] outcome in
            guard let app = self?.app else { return }
            switch outcome {
            case .started:
                app.pet.say(L.cameraOpened)
            case .denied:
                app.visionSensor.enabled = false   // 没真开起来,菜单别显示"已开"
                app.pet.say(L.cameraDenied)
            case .noDevice, .failed:
                app.visionSensor.enabled = false
                app.pet.say(L.cameraNoDevice)
            }
            self?.refreshMenu()
        }
        refreshMenu()
    }

    @objc func openConfigDir() {
        NSWorkspace.shared.open(Paths.root)
    }

    @objc func openSettings() {
        guard let app else { return }
        if settingsController == nil {
            settingsController = SettingsWindowController(app: app)
        }
        settingsController?.show()
    }

    private func voiceToggleTitle() -> String {
        (app?.voice.enabled ?? false) ? L.toggleVoiceOn : L.toggleVoiceOff
    }

    func voiceIconName() -> String {
        app?.voice.enabled == true ? "speaker.slash" : "speaker.wave.2"
    }

    @objc func toggleVoice() {
        guard let app else { return }
        app.voice.enabled.toggle()
        if app.voice.enabled {
            app.pet.say(L.voiceTest)   // 立刻出一声,验证能发声
        }
        refreshMenu()
    }

    private func listenToggleTitle() -> String {
        guard let app else { return L.toggleListenOff }
        switch app.listener.status {
        case .off:
            return L.toggleListenOff
        case .starting:
            return L.toggleListenStarting
        case .listening:
            return L.toggleListenListening
        case .muted:
            return L.toggleListenMuted
        case .unavailable:
            return L.toggleListenUnavailable
        }
    }

    func listenIconName() -> String {
        guard let app else { return "mic" }
        switch app.listener.status {
        case .off:
            return "mic"
        case .starting:
            return "waveform"
        case .listening:
            return "mic.fill"
        case .muted:
            return "mic.slash"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }

    @objc func toggleListen() {
        guard let app else { return }
        let newVal = !app.listener.enabled
        app.setVoiceConversationEnabled(newVal)
        refreshMenu()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Chat window (thin shell → ChatWindowController)

    @objc func openChat() { chatController.open() }
}
