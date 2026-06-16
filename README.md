# 咕咕 (Gugu) — macOS 桌面生命体

一只由大模型驱动、活在你桌面上的小鸟。它感知你的工作节奏、记得你们的相处、会说短而准的话,并随相处逐步成长。
<img width="462" height="260" alt="image" src="https://github.com/user-attachments/assets/0aed76b5-a46e-45a6-8fd9-23b01dd6c7d0" />

## 快速开始

```bash
cd /path/to/gugu
./build-app.sh      # 编译并启动 Gugu.app(菜单栏找 🐤)
```

或开发模式(裸二进制,后台常驻):
```bash
./run.sh
```

停止:

```bash
pkill -f Gugu.app        # .app 模式
pkill -f gugu/.build     # run.sh 开发模式
```

## 它能做什么

- **身体**:程序化绘制的小鸟,站在屏幕底边,会走动、理毛、发呆、眨眼。可以拖拽抛出去(它会挣扎、落地翻滚、记仇半小时,摸两下就和好)。会飞到你当前窗口的标题栏上栖息。
- **感知你工作**:统计键鼠节奏(只数次数,永不记录内容)判断你在专注/歇口气/离开/加班。你专注工作时它退到一边不打扰——而且**专注期它完全不调用大模型,你工作越久越省钱**。
- **择机开口**:不是你问它答。它攒"好奇心",在你刚停下来歇口气这种好时机才说一句短话。说的话基于它真实观察到的东西。
- **记忆与成长**:每天深夜"做梦"整理记忆,把当天见闻蒸馏进 `memory/`,还会总结出自己的行为经验(`skills/`)并结算成长阶段。第二天它更懂你。
- **对话与本地指令**:菜单栏"和咕咕说话"或唤醒词后的语音指令会走同一条对话链路。记笔记、提醒和联网搜索等能力默认锁住,需要它生成提案并由你批准。
- **看你(可选)**:菜单栏可开摄像头,本机流式识别你是否在座位、有没有在笑/惊讶/犯困,也能识别挥手、手掌、点赞、OK、指向等少量手势;还会用最近几秒的结构化轨迹判断靠近、离远、左右移动、手靠近镜头等视频事件——画面只在本机分析、看完即忘,绝不上传或保存。默认关闭。若把本地 Core ML 物品模型放到 `models/gugu-objects.mlmodelc`,咕咕还能流式识别物品并判断出现/消失/移动,但只把防抖后的文字事件写入记忆流。
- **听唤醒词(可选)**:菜单栏可开麦克风监听,本机语音识别"咕咕/小咕"等唤醒词,只把唤醒词后的简短指令交给对话链路。唤醒后的文字指令会写入本机事件/聊天日志用于记忆和审计;音频不保存、不上传。默认关闭。
- **本机朗读(可选)**:菜单栏可开 TTS,咕咕说话时用 macOS `AVSpeechSynthesizer` 朗读气泡文字。默认关闭。

## 配置(全部纯文本,改完即生效)

`~/Library/Application Support/Gugu/`。离线测试可用 `GUGU_HOME=/private/tmp/...` 指到临时目录。

- `config.yaml` — 模型、预算、心跳间隔、感知开关、工具权限、梦境 Batch 开关
- `persona.md` — 它的人格(`<!-- core -->` 段是不可改的安全内核)
- `evolution.yaml` / `state.json` — 形态定义与当前成长状态
- `memory/` — 它对你和自己的认识(它自己写,你也能改)
- `skills/` — 它总结的行为经验
- `events/` — 它今天看到了什么(7天滚动删除,可审计)
- `audit/` — 感知、记忆、提案和本地工具调用的审计记录
- `proposals/` — 待你批准的人格、配置或工具权限提案
- `snapshots/` — 应用提案前的配置/记忆快照,可用命令恢复
- `models/` — 可选本地视觉模型目录;物品识别模型固定读取 `gugu-objects.mlmodelc`
- `usage.json` — 今日 token 用量(超预算它会困了去睡觉)
- `dream_batch.json` — 开启 Batch 梦境后记录待回收的批处理状态

## 用量

约 800 tokens/次调用,典型一天 80 次心跳 + 若干对话 ≈ **十几万 tokens/天**。
超出 `daily_tokens` 上限会逐级降档,最后困了去睡觉,第二天醒来。用量只按 token 计,不涉及金额。

## 模型

走 `config.yaml` 里的中转通道。心跳用 `models.instinct_id`,对话用 `models.conversation_id`,梦境用 `models.dream_id`。默认值会在首次启动时写入配置,可直接编辑后热加载。

## 调试命令

```bash
swift build
GUGU_HOME=/private/tmp/gugu-offline ./.build/debug/gugu --selftest-offline
./.build/debug/gugu --selftest             # 真实模型 API 全链路,需要 config.yaml 配好 key
./.build/debug/gugu --audit-report         # 生成并打印今日审计报告路径
./.build/debug/gugu --restore-latest config.yaml
./.build/debug/gugu --render happy x.png   # 离屏渲染小鸟某个姿态到 PNG
```

`--selftest-offline` 必须显式设置 `GUGU_HOME`,避免测试写入真实 `~/Library/Application Support/Gugu`。

## 架构(五层)

```
L0 反射  本地·0成本  身体/物理/动画/对光标和拖拽的即时反应
L1 感知  本地·0成本  键鼠节奏 + 前台App,产出文字事件(原始数据不出本机)
L2 直觉  Haiku       攒够好奇心才心跳一次,返回 心情/动作/一句话
L3 思考  Sonnet      你主动对话时
L4 梦境  Haiku       每晚整理记忆、生长技能、结算成长,可选 Batch
```

设计书全文见仓库内的 `GUGU-DESIGN.md`。
