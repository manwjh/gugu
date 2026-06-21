import Foundation

/// "咕咕和主人的心流记录"的视觉主题:暖纸色调、衬线标题、一只小鸟,温暖而克制。
/// 页面与首页共用同一套 CSS / 页头 / 页框,改一处全站一致。明暗两色自动适配。
enum BlogTheme {
    static let siteTitle = "咕咕和主人的心流记录"
    static let siteTagline = "一只小鸟,陪着你的日子"

    /// 一只圆滚滚的小鸟(内联 SVG,暖色,明暗皆宜)。
    static func bird(_ size: Int) -> String {
        """
        <svg class="bird" viewBox="0 0 80 80" width="\(size)" height="\(size)" aria-hidden="true">
          <ellipse cx="40" cy="45" rx="24" ry="22" fill="#d98c5f"/>
          <ellipse cx="40" cy="50" rx="14.5" ry="13" fill="#f4e3cf"/>
          <path d="M19 40 q-8 7 -1 16 q8 -3 10 -12 z" fill="#b3683f"/>
          <path d="M40 21 q-4 -9 2 -11 q1 7 5 9 z" fill="#b3683f"/>
          <circle cx="33" cy="35" r="3.2" fill="#2c2620"/>
          <circle cx="34.2" cy="33.8" r="1" fill="#fff"/>
          <path d="M45 36 l10 -2.5 l-9 7 z" fill="#e8a33d"/>
          <circle cx="29.5" cy="43" r="3" fill="#e58b6b" opacity=".5"/>
          <g stroke="#e8a33d" stroke-width="2.4" stroke-linecap="round" fill="none">
            <path d="M34 65 v6 M30 71 h8"/><path d="M47 65 v6 M43 71 h8"/>
          </g>
        </svg>
        """
    }

    /// 站点页头(点击回首页)。
    static var masthead: String {
        """
        <a class="masthead" href="/">
          \(bird(46))
          <span class="brand"><span class="title">\(siteTitle)</span><span class="tag">\(siteTagline)</span></span>
        </a>
        """
    }

    /// 整页外壳:把内容包进暖纸页框。
    static func shell(pageTitle: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(pageTitle)</title>
        <style>\(css)</style>
        </head><body><div class="wrap">
        \(masthead)
        <hr class="rule">
        \(body)
        </div></body></html>
        """
    }

    /// 温暖的中文日期:2026年6月21日 周六 · 13:14
    static func prettyDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 EEEE · HH:mm"
        return df.string(from: date)
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static let css = """
    :root{
      --bg:#faf6ef; --card:#fffdf8; --ink:#39342e; --soft:#938a7c; --faint:#b9b1a1;
      --line:#ece3d3; --accent:#c2744a;
    }
    @media (prefers-color-scheme: dark){
      :root{ --bg:#1a1714; --card:#221e1a; --ink:#ece4d6; --soft:#9a9285; --faint:#6e665a;
        --line:#332d26; --accent:#e3a173; }
    }
    *{box-sizing:border-box}
    html{color-scheme:light dark}
    body{margin:0; background:var(--bg); color:var(--ink);
      font:17px/1.85 -apple-system,"PingFang SC",system-ui,sans-serif;
      -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;}
    .wrap{max-width:660px; margin:0 auto; padding:42px 22px 90px}
    .masthead{display:flex; align-items:center; gap:14px; text-decoration:none; color:inherit}
    .masthead .brand{display:flex; flex-direction:column}
    .masthead .title{font:600 1.32em/1.2 "Songti SC","STSong",Georgia,serif; letter-spacing:.01em}
    .masthead .tag{color:var(--soft); font-size:.82em; margin-top:3px}
    .bird{flex:0 0 auto; filter:drop-shadow(0 2px 3px rgba(0,0,0,.08))}
    .rule{height:1px; background:var(--line); border:0; margin:24px 0 30px}
    .back{display:inline-block; color:var(--accent); text-decoration:none; font-size:.86em; margin-bottom:14px}
    .back:hover{opacity:.7}
    .meta{color:var(--accent); font-size:.8em; letter-spacing:.03em; margin-bottom:.4em}
    article{font-size:1.02em}
    article h1{font:600 1.74em/1.4 "Songti SC","STSong",Georgia,serif; margin:.1em 0 .35em}
    article h2{font:600 1.28em/1.45 "Songti SC",Georgia,serif; margin:1.4em 0 .4em}
    article h3{font:600 1.1em/1.45 "Songti SC",Georgia,serif}
    article p{margin:1.05em 0}
    article ul{padding-left:1.15em} article li{margin:.45em 0}
    article strong{color:var(--ink)}
    article img{max-width:100%; border-radius:12px; margin:1em 0}
    .signoff{display:flex; align-items:center; gap:9px; color:var(--soft);
      font-size:.86em; margin-top:3.6em; padding-top:1.4em; border-top:1px solid var(--line)}
    /* 首页:日子卡片 */
    .lede{color:var(--soft); font-size:.92em; margin:-10px 0 22px}
    .entry{display:block; text-decoration:none; color:inherit; background:var(--card);
      border:1px solid var(--line); border-radius:16px; padding:18px 20px; margin:14px 0;
      transition:transform .14s ease, box-shadow .14s ease, border-color .14s ease}
    .entry:hover{transform:translateY(-2px); box-shadow:0 10px 26px rgba(80,50,20,.07); border-color:var(--accent)}
    .entry .d{color:var(--accent); font-size:.78em; letter-spacing:.03em}
    .entry .t{font:600 1.18em/1.4 "Songti SC","STSong",Georgia,serif; margin:4px 0 6px}
    .entry .x{color:var(--soft); font-size:.92em; line-height:1.65;
      display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden}
    .empty{color:var(--soft); text-align:center; padding:48px 0}
    """
}
