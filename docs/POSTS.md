# 咕咕发布文案

## 中文短帖

```text
我做了一个 macOS 桌面小生命:咕咕。

它不是聊天机器人套皮,而是一只会活在桌面上的小鸟:会走动、停靠窗口、被摸、被拖拽、记住相处历史,还会根据你的工作节奏在合适的时机说一句短话。

专注工作时它会退到一边,并冻结大模型心跳。摄像头和麦克风默认关闭;开启后原始画面/音频也不上传、不保存。

现在先开源给愿意从源码跑的 macOS 用户试试。

官网: https://manwjh.github.io/gugu/
GitHub: https://github.com/manwjh/gugu
```

## 中文长帖

```text
我做了一个 macOS 桌面生命体:咕咕。

最开始我不想做“聊天机器人 + 可爱皮肤”。如果它只是等我输入问题,然后弹出一段回答,那它本质上还是一个聊天窗口。

所以咕咕的目标是另一件事:像一个小生命一样待在桌面上。

它有身体:会走动、眨眼、理毛、发呆,也会飞到当前窗口标题栏上栖息。你可以拖拽它、抛出去、摸摸它。

它有节奏:它会感知你的工作节奏,但只统计键鼠节奏,不记录输入内容。你专注时它会退到一边,并冻结大模型心跳,既不打扰也不烧 token。

它有连续性:它会把相处过程写成本地记忆,每天深夜整理,沉淀自己的行为经验,并随时间成长。

它有边界:摄像头、麦克风、TTS 都默认关闭。开启后原始画面和音频仍不上传、不保存。工具权限和能力扩张也需要本地提案审批。

现在还不是面向所有人的成品安装包,更像是给开发者和愿意折腾的 macOS 用户的第一版公开源码。欢迎试用、提 issue,尤其欢迎反馈:你会不会愿意让这样一个小东西常驻在桌面上。

官网: https://manwjh.github.io/gugu/
GitHub: https://github.com/manwjh/gugu
```

## V2EX 标题

```text
[分享创造] 我做了一个 macOS 桌面小生命:会感知工作节奏、记忆、成长的小鸟
```

## V2EX 正文

```text
大家好,我最近在做一个 macOS 桌面小生命,叫咕咕。

它不是一个“聊天机器人换皮”。我想做的是一个真的活在桌面上的小东西:它会走动、停靠窗口、被摸、被拖拽,也会记住你们的相处历史,并根据你的工作节奏在合适的时候说一句短话。

几个设计点:

- 键鼠感知只统计节奏,不记录输入内容
- 专注工作时冻结大模型心跳,不打扰也不烧 token
- 摄像头/麦克风默认关闭,开启后原始画面和音频也不上传、不保存
- 记忆、审计、提案都在本地纯文本目录
- 工具权限和能力扩张需要本地审批

现在是第一版公开源码,主要适合愿意从源码运行的 macOS 用户。需要 macOS 14+、Swift 5.9+ 和一个 OpenAI Chat Completions 兼容模型接口。

官网: https://manwjh.github.io/gugu/
GitHub: https://github.com/manwjh/gugu

我最想听到的反馈是:

1. 你能不能顺利跑起来?
2. 它的隐私边界是否足够清楚?
3. 你会不会愿意让它常驻桌面?
```

## Hacker News

Title:

```text
Show HN: Gugu, an AI desktop lifeform for macOS
```

Body:

```text
I built Gugu, an AI desktop lifeform for macOS.

It is not a chatbot with a skin. It lives on your desktop as a small SpriteKit bird, senses your work rhythm, remembers shared history, grows over time, and speaks only when the timing feels right.

Some design choices:

- Local work-rhythm sensing without recording input content
- Camera and microphone are opt-in and off by default
- Raw audio/video is not uploaded or saved
- The model sees text summaries, not raw sensory streams
- Focused work freezes model heartbeats to reduce interruptions and token usage
- Local memory, audit logs, proposals, and config are plain files

It is currently a source-first release for developers and macOS users willing to build it locally. macOS 14+ and an OpenAI Chat Completions compatible endpoint are required.

Website: https://manwjh.github.io/gugu/
GitHub: https://github.com/manwjh/gugu
```

## Reddit

Title:

```text
I built an AI desktop lifeform for macOS
```

Body:

```text
I built Gugu, a small AI bird that lives on the macOS desktop.

The goal was not to make another chatbot window. Gugu has a body, local memory, work-rhythm sensing, growth stages, and a low-frequency "heartbeat" that lets it speak only when the timing feels right.

Privacy was a major design constraint: keyboard/mouse sensing only counts rhythm, camera and microphone are opt-in, raw audio/video is not uploaded or saved, and local memory/audit/proposal files are inspectable.

This is an early source-first release, not a polished signed app yet. It requires macOS 14+, Swift 5.9+, and an OpenAI-compatible model endpoint.

Website: https://manwjh.github.io/gugu/
GitHub: https://github.com/manwjh/gugu
```

## X / Twitter

```text
Gugu: an AI desktop lifeform for macOS.

A tiny bird that remembers, grows, and lives on your desktop.

https://manwjh.github.io/gugu/
```

## GitHub Release Notes

```markdown
Public launch release of Gugu, an AI desktop lifeform for macOS.

Highlights:
- Programmatic SpriteKit desktop bird
- Local work-rhythm sensing without recording input content
- Memory, growth stages, daily dream distillation
- OpenAI Chat Completions compatible model transport
- Optional camera, wake word, and local TTS
- Proposal-gated local tools and auditable local state
- MIT-licensed source release

Current limitations:
- Built from source; no notarized downloadable app yet
- macOS 14+ only
- Requires your own OpenAI-compatible model endpoint and API key
- Optional object recognition requires a local Core ML model
```
