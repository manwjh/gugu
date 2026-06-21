import Foundation

/// 极简 markdown → 自包含 HTML(移动端友好,即"h5")。只覆盖日志常用语法:
/// `#/##/###` 标题、`- ` 列表、空行分段、行内 `**加粗**`。文本一律转义,零第三方依赖。
/// 视觉外壳走 BlogTheme(暖纸手账风),这里只管把正文 markdown 转成文章 HTML。
enum BlogRenderer {
    /// 一篇日志的完整页面(暖纸页框 + 文章 + 落款)。
    static func page(title: String, markdown: String, date: Date) -> String {
        let body = """
        <a class="back" href="/">← 回到记录</a>
        <article>
        <div class="meta">\(escape(BlogTheme.prettyDate(date)))</div>
        \(renderBody(markdown))
        </article>
        <div class="signoff">\(BlogTheme.bird(22)) 咕咕陪着你 · \(escape(BlogTheme.prettyDate(date)))</div>
        """
        return BlogTheme.shell(pageTitle: title, body: body)
    }

    static func renderBody(_ md: String) -> String {
        var out: [String] = []
        var listOpen = false
        func closeList() { if listOpen { out.append("</ul>"); listOpen = false } }
        for rawLine in md.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeList(); continue }
            if line.hasPrefix("### ") { closeList(); out.append("<h3>\(inline(String(line.dropFirst(4))))</h3>") }
            else if line.hasPrefix("## ") { closeList(); out.append("<h2>\(inline(String(line.dropFirst(3))))</h2>") }
            else if line.hasPrefix("# ") { closeList(); out.append("<h1>\(inline(String(line.dropFirst(2))))</h1>") }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !listOpen { out.append("<ul>"); listOpen = true }
                out.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else {
                closeList(); out.append("<p>\(inline(line))</p>")
            }
        }
        closeList()
        return out.joined(separator: "\n")
    }

    /// 先转义,再把 **x** 变粗体(转义后不会与 HTML 标签冲突)。
    private static func inline(_ s: String) -> String {
        var t = escape(s)
        while let open = t.range(of: "**"),
              let close = t.range(of: "**", range: open.upperBound..<t.endIndex) {
            let inner = String(t[open.upperBound..<close.lowerBound])
            t.replaceSubrange(open.lowerBound..<close.upperBound, with: "<strong>\(inner)</strong>")
        }
        return t
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
