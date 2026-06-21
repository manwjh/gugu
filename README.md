# 咕咕 (Gugu) — macOS 桌面生命体

咕咕是一只活在 macOS 桌面上的 AI 小鸟。它不是聊天机器人套皮,而是一个有身体、有记忆、有作息、会随相处慢慢成长的桌面生命体。

<img width="462" height="260" alt="Gugu desktop bird preview" src="https://github.com/user-attachments/assets/0aed76b5-a46e-45a6-8fd9-23b01dd6c7d0" />

## 现在能体验什么

- **桌面小鸟**: 程序化绘制,会走动、眨眼、理毛、发呆、飞到当前窗口标题栏上栖息。
- **真实互动**: 可以拖拽、抛出去、摸摸它;被折腾狠了会记仇,摸两下又会和好。
- **工作节奏感知**: 只统计键鼠节奏,不记录输入内容;你专注时它会退到一边,并冻结大模型心跳。
- **择机开口**: 它不是你问一句才答一句,而是攒够"好奇心",在合适的停顿时说一句短话。
- **记忆与成长**: 每天深夜整理本地记忆,沉淀行为经验,随相处推进成长阶段。
- **对话与本地指令**: 菜单栏可以和它说话;记笔记、提醒、联网搜索等能力默认锁住,需要提案审批。
- **可选视觉/语音**: 摄像头、麦克风、TTS 都默认关闭。开启后仍以本机处理为主,不保存原始画面或音频。

## 系统要求

- macOS 14+
- Xcode Command Line Tools
- Swift 5.9+
- 一个 OpenAI Chat Completions 兼容的模型接口和 API key

咕咕默认会在 `~/Library/Application Support/Gugu/config.yaml` 里写入可编辑配置。你需要把自己的模型接口和 key 填进去。

## 快速开始

```bash
git clone https://github.com/manwjh/gugu.git
cd gugu
./build-app.sh
```

`build-app.sh` 会编译 release 二进制、生成 `Gugu.app`、做 ad-hoc 签名并启动应用。启动后在 macOS 菜单栏找咕咕图标。

开发模式:

```bash
./run.sh
```

停止:

```bash
pkill -f Gugu.app
pkill -f gugu/.build
```

## 配置模型

首次启动后编辑:

```bash
open "$HOME/Library/Application Support/Gugu/config.yaml"
```

关键字段:

```yaml
api:
  url: https://your-openai-compatible-endpoint
  key: your_api_key

model:
  id: your-model-id
```

三层默认共用 `model.id`;也可以分别设置:

- `model.instinct_id`: 低频心跳和短反应
- `model.conversation_id`: 主动对话
- `model.dream_id`: 夜间记忆整理

## 隐私承诺

咕咕的设计前提是:原始感知留在本机。

- 键鼠感知只统计节奏,不记录按键内容。
- 摄像头默认关闭;开启后用本机 Vision 分析,画面不上传、不保存。
- 麦克风默认关闭;用于本机唤醒词和短指令识别,音频不保存。
- 云端模型只看到整理后的文字摘要、对话文本和必要上下文。
- 本地事件、审计、提案、记忆都写在 `~/Library/Application Support/Gugu/`,可检查、可删除。
- 任何能力扩张,例如工具权限和配置变更,都需要本地提案审批。

## 本地文件结构

`~/Library/Application Support/Gugu/` 下都是纯文本或 JSONL:

- `config.yaml`: 模型、预算、感知开关、工具权限、梦境 Batch 开关
- `persona.md`: 咕咕的人格,其中 `<!-- core -->` 段是安全内核
- `memory/`: 它对你和自己的认识
- `skills/`: 它总结出的行为经验
- `events/`: 最近事件流水,7 天滚动删除
- `audit/`: 感知、记忆、提案和本地工具调用审计
- `proposals/`: 待批准的人格、配置或工具权限提案
- `snapshots/`: 应用提案前的快照
- `usage.json`: 今日 token 用量

## 用量与预算

典型心跳约 800 tokens/次。一天 80 次心跳加若干对话,可能达到十几万 tokens。

咕咕不会无限调用模型。超出 `budget.daily_tokens` 后会逐级降档,最后进入睡觉状态,第二天恢复。你专注工作时,心跳会冻结,这段时间不调用大模型。

## 调试命令

```bash
swift build
GUGU_HOME=/private/tmp/gugu-offline ./.build/debug/gugu --selftest-offline
./.build/debug/gugu --selftest
./.build/debug/gugu --audit-report
./.build/debug/gugu --restore-latest config.yaml
./.build/debug/gugu --render happy x.png
```

`--selftest-offline` 必须显式设置 `GUGU_HOME`,避免测试写入真实应用数据目录。

## 发布图片

Release 使用静态图片素材:

- `dist/gugu-preview-v2.3.0.png`
- `dist/gugu-front-v2.3.0.png`
- `dist/gugu-side-v2.3.0.png`

## 架构

```text
L0 反射  本地 0 成本   身体/物理/动画/拖拽即时反应
L1 感知  本地 0 成本   键鼠节奏 + 前台 App + 可选视觉/语音,产出文字事件
L2 直觉  instinct     攒够好奇心才心跳一次,返回心情/动作/一句话
L3 思考  conversation 主动对话和明确请求
L4 梦境  dream        每晚整理记忆、生长技能、结算成长
```

设计书见 [GUGU-DESIGN.md](GUGU-DESIGN.md)。

## 当前边界

- 目前主要面向开发者和愿意从源码运行的 macOS 用户。
- `.app` 是本地构建和 ad-hoc 签名,还没有正式 Developer ID 签名和公证。
- 本地物品识别需要可选 Core ML 模型,缺失时会静默跳过。
- `web_search` 的权限、队列、审计链路已在,当前仍以记录请求为主。

## 发布与反馈

- 发布计划: [docs/LAUNCH.md](docs/LAUNCH.md)
- 可复制发布文案: [docs/POSTS.md](docs/POSTS.md)
- FAQ: [docs/FAQ.md](docs/FAQ.md)
- Release notes: [docs/RELEASE_NOTES_v2.3.0.md](docs/RELEASE_NOTES_v2.3.0.md)
- 发布命令清单: [docs/PUBLISH_COMMANDS.md](docs/PUBLISH_COMMANDS.md)
- 变更记录: [CHANGELOG.md](CHANGELOG.md)

欢迎通过 GitHub Issues 反馈安装问题、隐私顾虑、交互体验和你希望咕咕学会的行为。

## License

MIT. See [LICENSE](LICENSE).
