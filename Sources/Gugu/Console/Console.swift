import AppKit

/// Menu-bar presence: status, poke, chat entry, audit, quit.
@MainActor
final class Console: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private weak var app: GuguApp?
    private var chatWindow: ChatInputPanel?
    private var chatInput: NSTextField?
    private var chatStatusLabel: NSTextField?
    private var chatCloseButton: NSButton?
    private var chatUserPositioned = false
    private var chatInFlight = 0
    private let quickPanel = NSPopover()
    private let defaultChatPlaceholder = "对咕咕说..."

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
        button.toolTip = "咕咕"
        button.setAccessibilityLabel("咕咕快捷面板")
        button.target = self
        button.action = #selector(toggleQuickPanel)
    }

    @objc private func toggleQuickPanel() {
        guard let button = statusItem.button else { return }
        if quickPanel.isShown {
            quickPanel.performClose(nil)
        } else {
            quickPanel.contentViewController = QuickPanelController(console: self)
            quickPanel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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
        menu.addItem(makeItem("和咕咕说话…", #selector(openChat), "t", icon: "bubble.left.and.text.bubble.right"))
        menu.addItem(makeItem("戳一下", #selector(pokePet), "p", icon: "hand.tap"))
        menu.addItem(makeItem("心跳一次(调试)", #selector(forceHeartbeat), "", icon: "heart.text.square"))
        menu.addItem(makeItem("做梦一次(调试)", #selector(forceDream), "", icon: "moon.zzz"))
        menu.addItem(.separator())
        let camItem = makeItem(visionToggleTitle(), #selector(toggleCamera), "", icon: app?.visionSensor.enabled == true ? "eye.slash" : "eye")
        menu.addItem(camItem)
        menu.addItem(makeItem(voiceToggleTitle(), #selector(toggleVoice), "", icon: app?.voice.enabled == true ? "speaker.slash" : "speaker.wave.2"))
        menu.addItem(makeItem(listenToggleTitle(), #selector(toggleListen), "", icon: app?.listener.enabled == true ? "mic.slash" : "mic"))
        menu.addItem(makeItem("今天看到了什么", #selector(openAudit), "", icon: "doc.text.magnifyingglass"))
        menu.addItem(makeItem("待批准提案", #selector(openProposals), "", icon: "tray.full"))
        let approve = makeItem("批准下一个提案", #selector(approveNextProposal), "", icon: "checkmark.seal")
        approve.isEnabled = !Evolution(memory: Memory()).pendingProposals().isEmpty
        menu.addItem(approve)
        menu.addItem(makeItem("打开配置目录", #selector(openConfigDir), "", icon: "folder"))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出", #selector(quit), "q", icon: "power"))
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
        let rhythm = app.rhythmSensor.rhythm.rawValue
        let frozen = app.scheduler.frozen ? " · 勿扰中" : ""
        let sleeping = app.pet.isSleeping ? " · 睡着了" : ""
        return "状态 · \(rhythm)\(frozen)\(sleeping)"
    }

    func statusShort() -> String {
        guard let app else { return "-" }
        if app.pet.isSleeping { return "睡" }
        if app.scheduler.frozen { return "静" }
        switch app.rhythmSensor.rhythm {
        case .focused: return "专"
        case .busy: return "忙"
        case .breather: return "歇"
        case .away: return "离"
        case .active: return "闲"
        case .agitated: return "躁"
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
        let suffix = pending > 0 ? " · \(pending) 个提案待批" : ""
        return "形态 · \(stage.displayName)\(suffix)"
    }

    func stageShort() -> String {
        GrowthStage(rawStage: PetState.load().stage).shortName
    }

    func refreshMenu() {
        statusItem.menu = nil
        if quickPanel.isShown {
            quickPanel.contentViewController = QuickPanelController(console: self)
        }
    }

    // MARK: - Actions

    @objc func pokePet() { app?.pet.poked() }

    @objc func showAbilities() {
        app?.pet.say("我会聊天、跳舞、蹦一下、飞一下、理毛,也能看你回来、听唤醒词。")
    }

    @objc func dancePet() { app?.pet.perform(action: "dance") }

    @objc func hopPet() { app?.pet.perform(action: "hop") }

    @objc func flyPet() { app?.pet.perform(action: "fly") }

    @objc func perchPet() { app?.pet.perform(action: "perch") }

    @objc func settlePet() { app?.pet.perform(action: "settle") }

    @objc func groomPet() { app?.pet.perform(action: "groom") }

    @objc func sleepPet() { app?.pet.perform(action: "sleep") }

    @objc func forceHeartbeat() { app?.scheduler.requestHeartbeat(force: true) }

    @objc func forceDream() {
        guard let app else { return }
        app.pet.sleep()
        app.pet.say("(进入梦乡…)")
        Task {
            do {
                let r = try await app.scheduler.dreamNow()
                app.pet.wake()
                if !r.morningWords.isEmpty { app.pet.say(r.morningWords) }
                if let title = r.proposalTitle {
                    app.pet.say("我梦见自己好像能长大了。\(title),等你批准。")
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
        let proposals = Evolution(memory: app.brain.memory).pendingProposals()
        if let proposal = proposals.first {
            do {
                let applied = try ProposalEngine().applyApprovedProposal(at: proposal.path)
                app.config = Config.load()
                app.brain.config = app.config
                app.brain.reloadPersona()
                app.refreshGrowthState()
                app.screenSensor.updateBlacklist(app.config.blacklistApps)
                if let newStage = applied.newStage {
                    app.pet.celebrateEvolution(to: newStage)
                } else {
                    app.pet.say("批准了。\(applied.title)")
                }
                EventBus.shared.post(kind: "proposal", summary: "主人批准提案:\(applied.title)", weight: 25)
            } catch {
                app.pet.say("这个提案没法批准。")
                Log.info("proposal", "批准失败: \(error)")
            }
        }
        refreshMenu()
    }

    private func visionToggleTitle() -> String {
        let on = app?.visionSensor.enabled ?? false
        return on ? "让咕咕闭上眼睛(关摄像头)" : "让咕咕睁眼看你(开摄像头·仅本机)"
    }

    func cameraIconName() -> String {
        app?.visionSensor.enabled == true ? "eye.slash" : "eye"
    }

    @objc func toggleCamera() {
        guard let app else { return }
        let newVal = !app.visionSensor.enabled
        app.visionSensor.enabled = newVal
        if newVal {
            app.pet.say("(咕咕睁开眼睛看了看你)")
        } else {
            app.pet.say("(咕咕闭上了眼睛)")
        }
        refreshMenu()
    }

    @objc func openConfigDir() {
        NSWorkspace.shared.open(Paths.root)
    }

    private func voiceToggleTitle() -> String {
        (app?.voice.enabled ?? false) ? "让咕咕安静(关朗读)" : "让咕咕出声说话(本地朗读)"
    }

    func voiceIconName() -> String {
        app?.voice.enabled == true ? "speaker.slash" : "speaker.wave.2"
    }

    @objc func toggleVoice() {
        guard let app else { return }
        app.voice.enabled.toggle()
        if app.voice.enabled {
            app.pet.say("咕!")   // 立刻出一声,验证能发声
        }
        refreshMenu()
    }

    private func listenToggleTitle() -> String {
        (app?.listener.enabled ?? false) ? "让咕咕别听了(关麦克风)" : "对咕咕说话(开麦克风·喊“咕咕”唤醒)"
    }

    func listenIconName() -> String {
        app?.listener.enabled == true ? "mic.slash" : "mic"
    }

    @objc func toggleListen() {
        guard let app else { return }
        let newVal = !app.listener.enabled
        app.listener.enabled = newVal
        app.pet.say(newVal ? "(咕咕竖起了耳朵)" : "(咕咕不听了)")
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
        dragHandle.toolTip = "拖动输入框"
        dragHandle.setAccessibilityLabel("拖动输入框")
        let handleImage = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                  accessibilityDescription: "拖动输入框")
            ?? NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动输入框")
        if let image = handleImage {
            dragHandle.image = image
            dragHandle.contentTintColor = NSColor.tertiaryLabelColor
        }
        content.addSubview(dragHandle)

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 42, y: 12, width: 226, height: 22)
        status.font = NSFont.systemFont(ofSize: 13)
        status.textColor = NSColor.secondaryLabelColor
        status.isHidden = true
        status.autoresizingMask = [.width]
        content.addSubview(status)

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
        close.toolTip = "关闭输入框"
        close.setAccessibilityLabel("关闭输入框")
        if let image = NSImage(systemSymbolName: "keyboard.chevron.compact.down", accessibilityDescription: "关闭输入框") {
            close.image = image
            close.contentTintColor = NSColor.secondaryLabelColor
        } else if let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭输入框") {
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
        chatStatusLabel = status
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
        EventBus.shared.post(kind: "chat", summary: "主人和你聊天:\(String(text.prefix(40)))", weight: 0)
        app.affect.chatted()
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
                if !result.reply.isEmpty {
                    app.pet.say(result.reply)
                } else if result.action != "idle" {
                    setChatStatus(Console.actionLabel(result.action), transient: true)
                }
            } catch {
                setChatStatus("咕咕没听清。", transient: true)
                Log.info("chat", "失败: \(error)")
            }
        }
    }

    /// 把动作 enum 翻成中文,纯文本聊天记录里好读。
    private static func actionLabel(_ a: String) -> String {
        switch a {
        case "come", "approach": return "扑棱扑棱跑过来了"
        case "walk": return "走了两步"
        case "fly": return "飞了起来"
        case "perch": return "飞上去站住了"
        case "settle", "sit": return "蹲下来,把脚收进羽毛里歇着"
        case "dance": return "晃起身子来"
        case "hop", "jump": return "蹦了一下"
        case "nod", "yes": return "一点一点地点头"
        case "stare": return "歪头盯着你"
        case "peck": return "啄了啄"
        case "groom": return "理了理毛"
        case "retreat", "away": return "扭头走开了"
        case "sleep": return "打起瞌睡"
        default: return a
        }
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
        setChatStatus(chatInFlight > 0 ? "咕咕在想..." : "", transient: false)
        refocusChatInput()
    }

    @objc private func closeChatInput() {
        chatWindow?.close()
    }

    private func setChatStatus(_ text: String, transient: Bool) {
        chatStatusLabel?.stringValue = ""
        chatStatusLabel?.isHidden = true
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
        preferredContentSize = NSSize(width: 236, height: 308)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 308))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        build()
    }

    private func build() {
        guard let console else { return }
        let root = NSStackView(frame: view.bounds.insetBy(dx: 12, dy: 10))
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.autoresizingMask = [.width, .height]
        view.addSubview(root)

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.distribution = .fillEqually
        statusRow.widthAnchor.constraint(equalToConstant: 212).isActive = true
        statusRow.addArrangedSubview(chip(title: console.statusShort(), icon: "gauge.with.dots.needle.bottom.50percent"))
        statusRow.addArrangedSubview(chip(title: console.budgetShort(), icon: "chart.pie"))
        statusRow.addArrangedSubview(chip(title: console.stageShort(), icon: "sparkles"))
        root.addArrangedSubview(statusRow)

        let buttons = [
            ("说话", "bubble.left.and.text.bubble.right", #selector(Console.openChat)),
            ("戳一下", "hand.tap", #selector(Console.pokePet)),
            ("才艺", "star", #selector(Console.showAbilities)),
            ("跳舞", "music.note", #selector(Console.dancePet)),
            ("蹦跳", "arrow.up.circle", #selector(Console.hopPet)),
            ("飞一下", "wind", #selector(Console.flyPet)),
            ("站窗口", "rectangle.on.rectangle", #selector(Console.perchPet)),
            ("蹲坐", "chair", #selector(Console.settlePet)),
            ("理毛", "sparkles", #selector(Console.groomPet)),
            ("睡觉", "moon", #selector(Console.sleepPet)),
            ("心跳", "heart.text.square", #selector(Console.forceHeartbeat)),
            ("做梦", "moon.zzz", #selector(Console.forceDream)),
            ("摄像头", console.cameraIconName(), #selector(Console.toggleCamera)),
            ("朗读", console.voiceIconName(), #selector(Console.toggleVoice)),
            ("麦克风", console.listenIconName(), #selector(Console.toggleListen)),
            ("审计", "doc.text.magnifyingglass", #selector(Console.openAudit)),
            ("提案", "tray.full", #selector(Console.openProposals)),
            ("批准", "checkmark.seal", #selector(Console.approveNextProposal)),
            ("配置", "folder", #selector(Console.openConfigDir)),
            ("退出", "power", #selector(Console.quit)),
        ] as [(String, String, Selector)]

        for row in 0..<5 {
            let rowView = NSStackView()
            rowView.orientation = .horizontal
            rowView.spacing = 8
            rowView.distribution = .fillEqually
            rowView.widthAnchor.constraint(equalToConstant: 212).isActive = true
            for col in 0..<4 {
                let item = buttons[row * 4 + col]
                rowView.addArrangedSubview(iconButton(label: item.0, symbol: item.1, action: item.2))
            }
            root.addArrangedSubview(rowView)
        }
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

    private func iconButton(label: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 47, height: 42))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = self.symbol(symbol)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.target = console
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 47).isActive = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
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
