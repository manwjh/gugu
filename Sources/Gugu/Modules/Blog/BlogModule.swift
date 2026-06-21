import AppKit
import GuguKernel

/// 第一个实验模块:咕咕以助理视角写「心流记录」。取材当天小记/对话/事件 → LLM 生成
/// markdown → 落本地 `blog/` 一对 md+html;可选在局域网只读暴露(默认关)。
///
/// 触发方式:① 夜间自动(每天傍晚一篇,文件去重);② 主动(菜单/语音"写篇日记");
/// ③ 重要时刻经 EventBus 进当天素材(不单独成篇)。整块能力由 `modules.blog` 门控。
@MainActor
final class BlogModule: GuguModule {
    static let id = "blog"

    private weak var ctx: ModuleContext?
    private var server: BlogLANServer?
    private var writing = false

    func isEnabled(_ config: Config) -> Bool { config.moduleBlogEnabled }

    func activate(_ context: ModuleContext) {
        ctx = context
        startServerIfEnabled(context.config)
    }

    func deactivate() {
        server?.stop()
        server = nil
        ctx = nil
    }

    /// 局域网访问地址(开了 LAN 才有)。
    var lanURL: String? { server?.url }

    private func startServerIfEnabled(_ config: Config) {
        guard config.blogLanEnabled else { return }
        let s = BlogLANServer(directory: Paths.blogDir, port: 8420)
        do {
            try s.start()
            server = s
            Log.info("blog", "局域网心流记录已开:\(s.url)")
        } catch {
            Log.info("blog", "局域网服务启动失败:\(error)")
        }
    }

    // MARK: - 触发

    /// 语音/聊天里说"写篇日记 / 记录今天 / blog"之类 → 接管并写,返回是否已处理。
    func handleTrigger(_ text: String) -> Bool {
        let t = text.replacingOccurrences(of: " ", with: "").lowercased()
        let phrases = ["写日记", "写篇日记", "写日志", "写篇日志", "记录今天", "写写今天", "今天的记录", "blog"]
        guard phrases.contains(where: { t.contains($0) }) else { return false }
        writeToday()
        return true
    }

    /// 分钟循环每分钟叫一次:傍晚之后、当天还没写过 → 安静地自动写一篇。
    func tickNightly(now: Date = Date()) {
        guard let ctx, ctx.config.moduleBlogEnabled, !writing else { return }
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= 21 else { return }          // 傍晚/睡前才写
        guard !hasPost(on: now) else { return }   // 当天已有(手动或自动)就不重复
        writeToday(announce: false)               // 夜里不打扰,静静地写
    }

    /// 写今天的「心流记录」:取材 → LLM → 落 md+html。announce 控制是否出声+打开浏览器。
    func writeToday(announce: Bool = true) {
        guard let ctx, !writing else { return }
        writing = true
        if announce { ctx.announce(L.blogWriting) }
        let brain = ctx.brain
        let say = ctx.announce
        Task { @MainActor in
            defer { self.writing = false }
            do {
                let material = BlogMaterial.gatherToday()
                let markdown = try await brain.writeBlog(material: material)
                let post = BlogPost(date: Date(), markdown: markdown)
                let saved = try BlogStore.save(post)
                BlogStore.rebuildIndex()
                Audit.record(kind: "module.blog.write", summary: post.title,
                             detail: ["file": saved.html.lastPathComponent])
                Log.info("blog", "写好:\(saved.html.lastPathComponent)")
                if announce {
                    say(L.blogDone)
                    NSWorkspace.shared.open(saved.html)
                }
            } catch {
                Log.info("blog", "写作失败:\(error)")
                if announce { say(L.blogFailed) }
            }
        }
    }

    /// 菜单"翻看心流记录":重建首页后用浏览器打开(开了 LAN 用本机地址,否则开本地文件)。
    func openJournal() {
        BlogStore.rebuildIndex()
        let target: URL = server != nil
            ? (URL(string: "http://localhost:8420/") ?? Paths.blogDir.appendingPathComponent("index.html"))
            : Paths.blogDir.appendingPathComponent("index.html")
        NSWorkspace.shared.open(target)
    }

    private func hasPost(on date: Date) -> Bool {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let prefix = df.string(from: date)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.blogDir.path)) ?? []
        return files.contains { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }
    }
}
