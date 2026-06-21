# Outreach Status

## Current State

- GitHub Release is live: https://github.com/manwjh/gugu/releases/tag/v2.3.0
- GitHub Pages website is live and set as repository homepage: https://manwjh.github.io/gugu/
- Early feedback issue is live and pinned: https://github.com/manwjh/gugu/issues/1
- GitHub launch discussion is live: https://github.com/manwjh/gugu/discussions/2
- Media kit is available: https://github.com/manwjh/gugu/blob/main/docs/MEDIA_KIT.md
- Channel plan is available: https://github.com/manwjh/gugu/blob/main/docs/CHANNEL_PLAN.md
- Release assets are static PNG images only:
  - https://github.com/manwjh/gugu/releases/download/v2.3.0/gugu-preview-v2.3.0.png
  - https://github.com/manwjh/gugu/releases/download/v2.3.0/gugu-front-v2.3.0.png
  - https://github.com/manwjh/gugu/releases/download/v2.3.0/gugu-side-v2.3.0.png

## V2EX

Status: blocked by account activation.

Visited:

```text
https://www.v2ex.com/go/create
```

Current browser state shows the user logged in with Google but not activated. V2EX requires an invitation code or the Solana/V2EX token activation path on:

```text
https://www.v2ex.com/invite/activate
```

Do not use random leaked/sold invitation codes. Use a code from an existing V2EX member or the official token activation path.

Suggested title:

```text
[分享创造] 我做了一个 macOS 桌面小生命:会感知工作节奏、记忆、成长的小鸟
```

Suggested body:

```text
大家好,我最近在做一个 macOS 桌面小生命,叫咕咕。

它不是一个“聊天机器人换皮”。我想做的是一个真的活在桌面上的小东西:它会走动、停靠窗口、被摸、被拖拽,也会记住你们的相处历史,并根据你的工作节奏在合适的时候说一句短话。

几个设计点:

- 键鼠感知只统计节奏,不记录输入内容
- 专注工作时冻结大模型心跳,不打扰也不烧 token
- 摄像头/麦克风默认关闭,开启后原始画面和音频也不上传、不保存
- 记忆、审计、提案都在本地纯文本目录
- 工具权限和能力扩张需要本地审批

现在是源码优先的公开版本,主要适合愿意从源码运行的 macOS 用户。需要 macOS 14+、Swift 5.9+ 和一个 OpenAI Chat Completions 兼容模型接口。

预览图:
https://github.com/manwjh/gugu/releases/download/v2.3.0/gugu-preview-v2.3.0.png

GitHub:
https://github.com/manwjh/gugu

Release:
https://github.com/manwjh/gugu/releases/tag/v2.3.0

早期反馈 issue:
https://github.com/manwjh/gugu/issues/1

我最想听到的反馈是:

1. 你能不能顺利跑起来?
2. 它的隐私边界是否足够清楚?
3. 你会不会愿意让它常驻桌面?
```

Before final submission through browser UI, confirm with the owner because posting is representational communication to a third-party site.

## Next Channels

## Hacker News

Status: blocked by login.

Visited:

```text
https://news.ycombinator.com/submit
```

Current browser state shows the Hacker News login/create-account page. Use the Show HN copy in `docs/POSTS.md` after login.

## Next Channels

- 即刻/朋友圈/技术群: use the short Chinese post in `docs/POSTS.md`.
- Reddit: use the Reddit copy in `docs/POSTS.md` after login.
- X/Twitter: use the X copy in `docs/POSTS.md` after login.

## Browser Automation

Status: blocked by Chrome extension setup.

Chrome is running, but the selected Chrome profile does not have the Codex Chrome Extension installed/enabled. To continue browser-based posting from the logged-in browser session, install and enable:

```text
https://chromewebstore.google.com/detail/codex/hehggadaopoacecdllhhajmbjkdcmajg
```

After extension setup, resume from the X composer and replace the draft with the shorter X copy in `docs/POSTS.md`. Confirm with the owner immediately before clicking the final Post/Submit button on any third-party site.
