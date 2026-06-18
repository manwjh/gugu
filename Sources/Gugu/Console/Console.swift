import AppKit

/// Menu-bar presence: status, poke, chat entry, audit, quit.
@MainActor
final class Console: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private weak var app: GuguApp?
    private var chatWindow: ChatInputPanel?
    private var chatInput: NSTextField?
    private var chatCloseButton: NSButton?
    private var chatUserPositioned = false
    private var chatInFlight = 0
    private let quickPanel = NSPopover()
    private var settingsController: SettingsWindowController?
    private var defaultChatPlaceholder: String { L.chatPlaceholder }

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

    @objc func showAbilities() {
        app?.pet.say(L.abilitiesSpeech)
    }

    @objc func dancePet() { app?.pet.perform(action: "dance") }

    @objc func hopPet() { app?.pet.perform(action: "hop") }

    @objc func flyPet() { app?.pet.perform(action: "fly") }

    @objc func perchPet() { app?.pet.perform(action: "perch") }

    @objc func settlePet() { app?.pet.perform(action: "settle") }

    @objc func groomPet() { app?.pet.perform(action: "groom") }

    @objc func sleepPet() { app?.pet.perform(action: "sleep") }

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

    @objc func openProposals() {
        NSWorkspace.shared.open(Paths.proposals)
    }

    @objc func approveNextProposal() {
        guard let app else { return }
        if let proposal = Evolution(memory: app.brain.memory).pendingProposals().first {
            approve(at: proposal.path)
        }
    }

    /// 批准右键菜单里点选的那一条(representedObject 携带提案文件 URL)。
    @objc func approveProposalItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        approve(at: url)
    }

    /// 批准指定提案文件并刷新一切相关状态。供"批准下一个"与"逐条批准"共用。
    private func approve(at path: URL) {
        guard let app else { return }
        do {
            let applied = try ProposalEngine().applyApprovedProposal(at: path)
            app.config = Config.load()
            app.brain.config = app.config
            app.brain.reloadPersona()
            app.refreshGrowthState()
            app.screenSensor.updateBlacklist(app.config.blacklistApps)
            if let newStage = applied.newStage {
                app.pet.celebrateEvolution(to: newStage)
            } else {
                app.pet.say(L.proposalApproved(applied.title))
            }
            // 学会新动作:计入进度(驱动里程碑),并立刻演一遍给主人看。
            if path.lastPathComponent.hasPrefix("move-") {
                app.afterInteraction(.learnedMove, surface: false)
                let moveName = applied.target.deletingPathExtension().lastPathComponent
                if MoveLibrary.shared.move(named: moveName) != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak app] in
                        app?.pet.perform(action: moveName)
                    }
                }
            }
            EventBus.shared.post(kind: "proposal", summary: L.eventProposalApproved(applied.title), weight: 25)
        } catch {
            app.pet.say(L.proposalFailed)
            Log.info("proposal", "批准失败: \(error)")
        }
        refreshMenu()
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
        let newVal = !app.visionSensor.enabled
        app.visionSensor.enabled = newVal
        if newVal {
            app.pet.say(L.cameraOpened)
        } else {
            app.pet.say(L.cameraClosed)
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

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? ChatInputPanel,
              let chatWindow,
              panel === chatWindow else { return }
        chatUserPositioned = true
        app?.pet.updateInputPanelFrame(panel.frame)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? ChatInputPanel,
              let chatWindow,
              panel === chatWindow else { return }
        app?.pet.updateInputPanelFrame(nil)
    }

    // MARK: - Chat window

    @objc func openChat() {
        if chatWindow == nil { buildChatWindow() }
        let shouldAnimate = chatWindow?.isVisible == false
        if shouldAnimate { chatWindow?.alphaValue = 0 }
        if let window = chatWindow, chatUserPositioned, isChatWindowOnVisibleScreen(window) {
            app?.pet.updateInputPanelFrame(window.frame)
        } else {
            positionChatWindowNearPet()
        }
        chatWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        chatWindow?.makeFirstResponder(chatInput)
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                chatWindow?.animator().alphaValue = 1
            }
        }
    }

    private func buildChatWindow() {
        let size = NSSize(width: 320, height: 46)
        let w = ChatInputPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless],
                               backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isFloatingPanel = false
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = false
        w.delegate = self
        w.onFrameChanged = { [weak self] frame in
            self?.app?.pet.updateInputPanelFrame(frame)
        }
        w.onUserMoved = { [weak self] in
            self?.chatUserPositioned = true
        }

        let content = DraggableVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = size.height / 2
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(calibratedWhite: 0.6, alpha: 0.22).cgColor

        let dragHandle = DraggableHandleView(frame: NSRect(x: 8, y: 8, width: 28, height: 30))
        dragHandle.toolTip = L.chatDragTooltip
        dragHandle.setAccessibilityLabel(L.chatDragTooltip)
        let handleImage = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                  accessibilityDescription: L.chatDragTooltip)
            ?? NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: L.chatDragTooltip)
        if let image = handleImage {
            dragHandle.image = image
            dragHandle.contentTintColor = NSColor.tertiaryLabelColor
        }
        content.addSubview(dragHandle)

        let input = NSTextField(frame: NSRect(x: 42, y: 11, width: 226, height: 24))
        input.placeholderString = defaultChatPlaceholder
        input.autoresizingMask = [.width]
        input.target = self
        input.action = #selector(sendChat)
        input.font = NSFont.systemFont(ofSize: 14)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        content.addSubview(input)

        let close = NSButton(title: "", target: self, action: #selector(closeChatInput))
        close.frame = NSRect(x: 278, y: 8, width: 30, height: 30)
        close.autoresizingMask = [.minXMargin]
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.imageScaling = .scaleProportionallyDown
        close.toolTip = L.chatCloseTooltip
        close.setAccessibilityLabel(L.chatCloseTooltip)
        if let image = NSImage(systemSymbolName: "keyboard.chevron.compact.down", accessibilityDescription: L.chatCloseTooltip) {
            close.image = image
            close.contentTintColor = NSColor.secondaryLabelColor
        } else if let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L.chatCloseTooltip) {
            close.image = image
            close.contentTintColor = NSColor.secondaryLabelColor
        } else {
            close.title = "×"
            close.bezelStyle = .rounded
        }
        content.addSubview(close)

        w.contentView = content
        chatWindow = w
        chatInput = input
        chatCloseButton = close
    }

    @objc private func sendChat() {
        guard let app, let input = chatInput else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""
        refocusChatInput()
        if let chatWindow {
            app.pet.perch(on: chatWindow.frame)
        }
        setChatLoading(true)
        EventBus.shared.post(kind: "chat", summary: L.eventChat(String(text.prefix(40))), weight: 0)
        app.affect.chatted()
        PetState.recordBondGain(Affect.bondGainChatted)
        app.afterChat()
        if app.pet.isSleeping { app.pet.wake() }
        if let local = app.brain.handleLocalCommand(text) {
            if local.action != "idle" {
                app.pet.perform(action: local.action)
            }
            if !local.reply.isEmpty {
                app.pet.say(local.reply)
            }
            refreshMenu()
            setChatLoading(false)
            return
        }
        if app.tryStartLearnMove(text) {
            refreshMenu()
            setChatLoading(false)
            return
        }
        Task {
            defer { setChatLoading(false) }
            do {
                let result = try await app.brain.chat(text,
                                                      rhythmLine: app.rhythmSensor.promptLine(),
                                                      mood: app.affect.promptLine(),
                                                      localCapabilities: app.localCapabilitiesContext())
                // 先做动作,再说话——主人让"过来/飞起来/坐下"时身体真的会动
                if result.action != "idle" {
                    app.pet.perform(action: result.action)
                }
                // 避免双重声音:如果动作包含 say 步骤,让动作自己说话,不再朗读 reply
                let actionHasSpeech = MoveLibrary.shared.move(named: result.action)?.steps.contains { $0.op == "say" } ?? false
                // aside 是模型写的轻量动作旁白(如"咕咕歪了歪头"),比通用动作标签更自然;
                // 没有 aside 时退回到通用动作标签。
                let asideStatus = !result.aside.isEmpty ? result.aside
                    : (result.action != "idle" ? Console.actionLabel(result.action) : "")
                if !result.reply.isEmpty && !actionHasSpeech {
                    app.pet.say(result.reply)
                    // 气泡说出口的同时,聊天框补一行轻量旁白(两个不同的展示面,不冲突)。
                    if !result.aside.isEmpty { setChatStatus(result.aside, transient: true) }
                } else if !asideStatus.isEmpty {
                    setChatStatus(asideStatus, transient: true)
                } else {
                    // 兜底:模型既没话说也没动作(空 speech + idle)。不再静默——
                    // 给一个轻微的"我听到了"反应,聊天框也提示一下,避免"反应丢失"。
                    app.pet.bird.tiltHead(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak app] in app?.pet.bird.tiltHead(false) }
                    setChatStatus(L.chatNoReply, transient: true)
                }
            } catch {
                setChatStatus(Brain.userMessage(for: error, config: app.config), transient: true)
                Log.info("chat", "失败: \(error)")
            }
        }
    }

    /// 把动作 enum 翻成可读文字,纯文本聊天记录里好读。
    private static func actionLabel(_ a: String) -> String {
        L.actionLabel(a)
    }

    private func setChatLoading(_ loading: Bool) {
        if loading {
            chatInFlight += 1
        } else {
            chatInFlight = max(0, chatInFlight - 1)
        }
        chatInput?.isEnabled = true
        chatInput?.isHidden = false
        chatCloseButton?.isEnabled = true
        setChatStatus(chatInFlight > 0 ? L.chatThinking : "", transient: false)
        refocusChatInput()
    }

    @objc private func closeChatInput() {
        chatWindow?.close()
    }

    private func setChatStatus(_ text: String, transient: Bool) {
        chatInput?.isHidden = false
        chatInput?.placeholderString = text.isEmpty ? defaultChatPlaceholder : text
        guard transient, !text.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard self?.chatInput?.placeholderString == text else { return }
            self?.setChatStatus("", transient: false)
        }
    }

    private func refocusChatInput() {
        guard let chatWindow, let chatInput else { return }
        chatWindow.makeFirstResponder(chatInput)
    }

    private func positionChatWindowNearPet() {
        guard let window = chatWindow, let petWindow = app?.pet.window else { return }
        let pf = petWindow.frame
        let birdHeadTop = pf.minY + 72
        let gap: CGFloat = 8
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(pf) }) ?? NSScreen.main
        let screenMidX = screen?.visibleFrame.midX ?? pf.midX
        let preferRight = pf.midX < screenMidX
        var origin = CGPoint(x: preferRight ? pf.maxX + gap : pf.minX - window.frame.width - gap,
                             y: birdHeadTop - window.frame.height / 2)
        if let screen {
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let primary = CGRect(origin: origin, size: window.frame.size)
            let opposite = CGRect(x: preferRight ? pf.minX - window.frame.width - gap : pf.maxX + gap,
                                  y: origin.y,
                                  width: window.frame.width,
                                  height: window.frame.height)
            let above = CGRect(x: pf.midX - window.frame.width / 2,
                               y: birdHeadTop + 8,
                               width: window.frame.width,
                               height: window.frame.height)
            let below = CGRect(x: pf.midX - window.frame.width / 2,
                               y: pf.minY + 18 - window.frame.height,
                               width: window.frame.width,
                               height: window.frame.height)
            let candidates = [primary, opposite, above, below].map { frame in
                CGRect(x: max(visible.minX, min(frame.minX, visible.maxX - frame.width)),
                       y: max(visible.minY, min(frame.minY, visible.maxY - frame.height)),
                       width: frame.width,
                       height: frame.height)
            }
            if let candidate = candidates.first(where: { !$0.intersects(pf.insetBy(dx: -2, dy: -2)) }) ?? candidates.first {
                origin = candidate.origin
            }
        }
        window.setFrameOriginProgrammatically(origin)
        app?.pet.updateInputPanelFrame(window.frame)
    }

    private func isChatWindowOnVisibleScreen(_ window: NSWindow) -> Bool {
        let frame = window.frame
        return NSScreen.screens.contains { screen in
            screen.visibleFrame.insetBy(dx: -40, dy: -40).intersects(frame)
        }
    }
}

private final class QuickPanelController: NSViewController {
    private weak var console: Console?

    init(console: Console) {
        self.console = console
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 240, height: 420)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 420))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        build()
    }

    private func build() {
        guard let console else { return }
        let contentWidth: CGFloat = 216

        let root = NSStackView(frame: view.bounds.insetBy(dx: 12, dy: 10))
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 8
        root.autoresizingMask = [.width, .height]
        view.addSubview(root)

        // --- Status chips ---
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.distribution = .fillEqually
        statusRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        statusRow.addArrangedSubview(chip(title: console.statusShort(), icon: "gauge.with.dots.needle.bottom.50percent"))
        statusRow.addArrangedSubview(chip(title: console.budgetShort(), icon: "chart.pie"))
        statusRow.addArrangedSubview(chip(title: console.stageShort(), icon: "sparkles"))
        root.addArrangedSubview(statusRow)

        // --- Main action buttons (large, with text) ---
        let mainRow = NSStackView()
        mainRow.orientation = .horizontal
        mainRow.spacing = 8
        mainRow.distribution = .fillEqually
        mainRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        mainRow.addArrangedSubview(primaryButton(label: L.panelTalk, symbol: "bubble.left.and.text.bubble.right", action: #selector(Console.openChat)))
        mainRow.addArrangedSubview(primaryButton(label: L.panelPoke, symbol: "hand.tap", action: #selector(Console.pokePet)))
        root.addArrangedSubview(mainRow)

        // --- Sensory toggles ---
        let senseRow = NSStackView()
        senseRow.orientation = .horizontal
        senseRow.spacing = 8
        senseRow.distribution = .fillEqually
        senseRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        senseRow.addArrangedSubview(toggleButton(label: L.panelCamera, symbol: console.cameraIconName(), action: #selector(Console.toggleCamera), on: console.cameraIconName() == "eye.slash"))
        senseRow.addArrangedSubview(toggleButton(label: L.panelVoice, symbol: console.voiceIconName(), action: #selector(Console.toggleVoice), on: console.voiceIconName() == "speaker.slash"))
        senseRow.addArrangedSubview(toggleButton(label: L.panelMic, symbol: console.listenIconName(), action: #selector(Console.toggleListen), on: console.listenIconName() == "mic.fill" || console.listenIconName() == "mic.slash"))
        root.addArrangedSubview(senseRow)

        // --- Action icons row ---
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 4
        actionRow.distribution = .fillEqually
        actionRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        let actions: [(String, String, Selector)] = [
            (L.menuDance, "music.note", #selector(Console.dancePet)),
            (L.menuHop, "arrow.up.circle", #selector(Console.hopPet)),
            (L.menuFly, "wind", #selector(Console.flyPet)),
            (L.menuPerch, "rectangle.on.rectangle", #selector(Console.perchPet)),
            (L.menuSettle, "chair", #selector(Console.settlePet)),
            (L.menuGroom, "sparkles", #selector(Console.groomPet)),
            (L.menuSleep, "moon", #selector(Console.sleepPet)),
        ]
        for item in actions {
            actionRow.addArrangedSubview(smallIconButton(label: item.0, symbol: item.1, action: item.2))
        }
        root.addArrangedSubview(actionRow)

        // --- Separator ---
        root.addArrangedSubview(separator(width: contentWidth))

        // --- Menu list ---
        let menuItems: [(String, String, Selector)] = [
            (L.panelAbilities, "star", #selector(Console.showAbilities)),
            (L.menuAudit, "doc.text.magnifyingglass", #selector(Console.openAudit)),
            (L.menuProposals, "tray.full", #selector(Console.openProposals)),
            (L.menuApproveNext, "checkmark.seal", #selector(Console.approveNextProposal)),
            (L.menuHeartbeatDebug, "heart.text.square", #selector(Console.forceHeartbeat)),
            (L.menuDreamDebug, "moon.zzz", #selector(Console.forceDream)),
            (L.menuOpenConfig, "folder", #selector(Console.openConfigDir)),
            (L.menuSettings, "gearshape", #selector(Console.openSettings)),
            (L.menuQuit, "power", #selector(Console.quit)),
        ]
        for item in menuItems {
            let row = menuRow(label: item.0, symbol: item.1, action: item.2)
            row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            root.addArrangedSubview(row)
        }
    }

    // MARK: - Components

    private func primaryButton(label: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.image = self.symbol(symbol)
        button.title = label
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        button.contentTintColor = .labelColor
        button.target = console
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    private func toggleButton(label: String, symbol: String, action: Selector, on: Bool) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.image = self.symbol(symbol)
        button.title = label
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleProportionallyDown
        button.font = NSFont.systemFont(ofSize: 10)
        button.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
        button.target = console
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func smallIconButton(label: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = self.symbol(symbol)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = console
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func menuRow(label: String, symbol: String, action: Selector) -> NSView {
        let row = MenuRowView(target: console, action: action)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let imageView = NSImageView(frame: .zero)
        imageView.image = self.symbol(symbol)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(imageView)

        let text = NSTextField(labelWithString: label)
        text.font = NSFont.systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            imageView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -8),
        ])
        return row
    }

    private func chip(title: String, icon: String) -> NSView {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor

        let imageView = NSImageView(frame: NSRect(x: 6, y: 7, width: 14, height: 14))
        imageView.image = symbol(icon)
        imageView.contentTintColor = .secondaryLabelColor
        box.addSubview(imageView)

        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 24, y: 5, width: 38, height: 18)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        box.addSubview(label)
        box.toolTip = title
        return box
    }

    private func separator(width: CGFloat) -> NSView {
        let sep = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        sep.boxType = .separator
        sep.widthAnchor.constraint(equalToConstant: width).isActive = true
        return sep
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

// MARK: - ActionGridView (multi-column grid of action buttons for a menu item)

/// 一个塞进 NSMenuItem.view 的多列动作网格。NSMenu 原生只能竖排单列;
/// 用自定义视图就能多列平铺,容纳内置 + 学会的全部动作。点按钮即演动作并收起菜单。
@MainActor
private final class ActionGridView: NSView {
    private var names: [String] = []
    var onPick: ((String) -> Void)?

    init(items: [(label: String, name: String)], columns: Int = 3) {
        super.init(frame: .zero)
        let cellW: CGFloat = 96, cellH: CGFloat = 28, gap: CGFloat = 4, margin: CGFloat = 8
        let cols = max(1, columns)
        let rows = max(1, Int(ceil(Double(items.count) / Double(cols))))
        let width = margin * 2 + CGFloat(cols) * cellW + CGFloat(cols - 1) * gap
        let height = margin * 2 + CGFloat(rows) * cellH + CGFloat(rows - 1) * gap
        frame = NSRect(x: 0, y: 0, width: width, height: height)

        for (i, item) in items.enumerated() {
            let col = i % cols, row = i / cols
            let b = NSButton(frame: NSRect(
                x: margin + CGFloat(col) * (cellW + gap),
                y: height - margin - cellH - CGFloat(row) * (cellH + gap),
                width: cellW, height: cellH))
            b.title = item.label
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 12)
            b.lineBreakMode = .byTruncatingTail
            b.tag = i
            b.target = self
            b.action = #selector(tap(_:))
            names.append(item.name)
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tap(_ sender: NSButton) {
        let name = names[sender.tag]
        enclosingMenuItem?.menu?.cancelTracking()   // 收起菜单
        onPick?(name)
    }
}

// MARK: - MenuRowView (clickable row with hover highlight)

private final class MenuRowView: NSView {
    private weak var target: AnyObject?
    private var action: Selector?
    private var trackingArea: NSTrackingArea?

    init(target: AnyObject?, action: Selector?) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        if let target, let action, bounds.contains(convert(event.locationInWindow, from: nil)) {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}

private final class DraggableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class DraggableHandleView: NSImageView {
    private let dragTracker = WindowDragTracker()

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragTracker.begin(window: window)
    }

    override func mouseDragged(with event: NSEvent) {
        dragTracker.drag(window: window)
    }

    override func mouseUp(with event: NSEvent) {
        dragTracker.end()
    }
}

@MainActor
private final class WindowDragTracker {
    private var startMouse: CGPoint?
    private var startOrigin: CGPoint?

    func begin(window: NSWindow?) {
        guard let window else { return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window.frame.origin
    }

    func drag(window: NSWindow?) {
        guard let window, let startMouse, let startOrigin else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                      y: startOrigin.y + mouse.y - startMouse.y))
    }

    func end() {
        startMouse = nil
        startOrigin = nil
    }
}

private final class ChatInputPanel: NSPanel {
    var onFrameChanged: ((CGRect?) -> Void)?
    var onUserMoved: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrameOrigin(_ point: NSPoint) {
        let movedByUser = !isInProgrammaticMove && frame.origin != point
        super.setFrameOrigin(point)
        reportFrameChange(userInitiated: movedByUser)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let movedByUser = !isInProgrammaticMove && frame.origin != frameRect.origin
        super.setFrame(frameRect, display: flag)
        reportFrameChange(userInitiated: movedByUser)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        let movedByUser = !isInProgrammaticMove && frame.origin != frameRect.origin
        super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
        reportFrameChange(userInitiated: movedByUser)
    }

    func setFrameOriginProgrammatically(_ point: NSPoint) {
        isInProgrammaticMove = true
        defer { isInProgrammaticMove = false }
        setFrameOrigin(point)
    }

    private var isInProgrammaticMove = false
    private var lastReportedFrame: CGRect?

    private func reportFrameChange(userInitiated: Bool) {
        let current = frame
        guard lastReportedFrame != current else { return }
        lastReportedFrame = current
        if userInitiated { onUserMoved?() }
        onFrameChanged?(current)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
    }
}
