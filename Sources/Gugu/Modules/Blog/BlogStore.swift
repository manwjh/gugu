import Foundation
import GuguKernel

struct BlogPost {
    let date: Date
    let markdown: String

    /// 标题取正文第一行 `# 标题`,没有就用默认。
    var title: String {
        for line in markdown.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)) }
        }
        return "咕咕日志"
    }
}

/// blog 落盘:每篇一对 `<时间戳>.md` + `.html`,外加一个手账风 `index.html`
/// (按时间倒序列出每一天:日期 + 标题 + 摘要卡片)。全部在 Paths.blogDir 下。
enum BlogStore {
    @discardableResult
    static func save(_ post: BlogPost) throws -> (md: URL, html: URL) {
        try FileManager.default.createDirectory(at: Paths.blogDir, withIntermediateDirectories: true)
        let stamp = stampFormatter.string(from: post.date)
        let mdURL = Paths.blogDir.appendingPathComponent("\(stamp).md")
        let htmlURL = Paths.blogDir.appendingPathComponent("\(stamp).html")
        try post.markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        let html = BlogRenderer.page(title: post.title, markdown: post.markdown, date: post.date)
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return (mdURL, htmlURL)
    }

    /// 重建 index.html:把每一篇渲染成一张"日子卡片"(日期/标题/两行摘要),时间倒序。
    static func rebuildIndex() {
        let entries = loadEntries()
        let cards: String
        if entries.isEmpty {
            cards = "<div class=\"empty\">还没有记录…等咕咕写下第一篇。</div>"
        } else {
            cards = entries.map { e in
                """
                <a class="entry" href="\(e.htmlFile)">
                  <div class="d">\(BlogTheme.htmlEscape(BlogTheme.prettyDate(e.date)))</div>
                  <div class="t">\(BlogTheme.htmlEscape(e.title))</div>
                  <div class="x">\(BlogTheme.htmlEscape(e.excerpt))</div>
                </a>
                """
            }.joined(separator: "\n")
        }
        let body = "<div class=\"lede\">咕咕和主人一起度过的日子,一篇篇收在这里。</div>\n\(cards)"
        let html = BlogTheme.shell(pageTitle: BlogTheme.siteTitle, body: body)
        try? html.write(to: Paths.blogDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    // MARK: - 首页素材

    private struct Entry { let date: Date; let title: String; let excerpt: String; let htmlFile: String }

    private static func loadEntries() -> [Entry] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.blogDir, includingPropertiesForKeys: nil)) ?? []
        var out: [Entry] = []
        for md in files where md.pathExtension == "md" {
            let stamp = md.deletingPathExtension().lastPathComponent
            let htmlFile = "\(stamp).html"
            guard fm.fileExists(atPath: Paths.blogDir.appendingPathComponent(htmlFile).path),
                  let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
            let date = stampFormatter.date(from: stamp) ?? Date()
            let (title, excerpt) = titleAndExcerpt(text)
            out.append(Entry(date: date, title: title, excerpt: excerpt, htmlFile: htmlFile))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// 从 markdown 取标题(首个 `# `)与摘要(前一两段正文,去掉记号)。
    private static func titleAndExcerpt(_ md: String) -> (String, String) {
        var title = "咕咕日志"
        var pieces: [String] = []
        for line in md.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("# ") { if title == "咕咕日志" { title = String(t.dropFirst(2)) }; continue }
            if t.hasPrefix("#") { continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { pieces.append(String(t.dropFirst(2))) }
            else { pieces.append(t.replacingOccurrences(of: "**", with: "")) }
            if pieces.count >= 2 { break }
        }
        return (title, pieces.joined(separator: " "))
    }

    private static let stampFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmmss"; return df
    }()
}
