import AppKit
import GuguKernel

/// The floating chat input panel: build, position near the pet, send a line to the
/// brain, and surface the reply/aside. Cross-module dispatch (Brain.chat, affect,
/// pet.say/perform, afterChat) all goes through `app`.
///
/// Console keeps a thin @objc `openChat()` shell that forwards to `open()`.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private weak var app: GuguApp?

    private var chatWindow: ChatInputPanel?
    private var chatInput: NSTextField?
    private var chatCloseButton: NSButton?
    private var chatUserPositioned = false
    private var chatInFlight = 0
    private var defaultChatPlaceholder: String { L.chatPlaceholder }

    init(app: GuguApp?) {
        self.app = app
        super.init()
    }

    // MARK: - Open / position

    func open() {
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

    // MARK: - Send

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
        Perception.shared.heardOrTyped(text, via: "打字")
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
            app.console?.refreshMenu()
            setChatLoading(false)
            return
        }
        if app.tryStartLearnMove(text) {
            app.console?.refreshMenu()
            setChatLoading(false)
            return
        }
        if app.modules.module(BlogModule.self)?.handleTrigger(text) == true {
            app.console?.refreshMenu()
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
                    : (result.action != "idle" ? Self.actionLabel(result.action) : "")
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

    // MARK: - NSWindowDelegate (chat panel only)

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
}

// MARK: - ChatInputPanel (borderless floating input window)

final class ChatInputPanel: NSPanel {
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

// MARK: - Drag helpers (the titlebar-less chat panel is moved by its grab handle)

final class DraggableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class DraggableHandleView: NSImageView {
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
