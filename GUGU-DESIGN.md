# 咕咕(Gugu)——macOS 桌面生命体 设计与实现

> 版本 2.0 · 2026-06-16
> 一只活在你桌面上、随相处逐步成长的小鸟。默认由 deepseek 模型驱动(走中转通道)。
>
> 本文是**现状文档**:正文如实描述当前代码已经做到的事。半成品用 🟡 标注,
> 尚未实现的愿景统一收在 §12「路线图」,不与现状混写。§0 愿景与公理是不变的北极星。

---

## 0. 愿景与北极星

**愿景**:做一个"真实的小生命",而不是一个带皮肤的聊天机器人。

判断"真实"的三条标准(也是验收标准):

1. **它有连续性** —— 它记得你们共同的历史,关掉重开它还是它。
2. **它有自己的节奏** —— 不是你输入它输出;你不理它,它也在过自己的生活。
3. **它的聪明出现在对的时机** —— 活物感不来自调用频率,来自时机准确。

**北极星指标**:用户连续 30 天没有关掉它的比例(留存即一切——桌宠唯一的死法是被觉得烦/没用/吓人,然后被退出)。

### 设计公理(全部架构决策由此推出)

| # | 公理 | 推论 |
|---|------|------|
| A1 | 模型不是它,**persona + 记忆 + 技能 + 权限的总和才是它** | 模型可换可升级,"它"不变;进化 = 它的文件在生长 |
| A2 | 活物感 99% 来自本地,LLM 提供 1% 的"它居然注意到了" | 行为引擎全本地零成本;LLM 低频、择机、短输出 |
| A3 | 成本约束必须转化为游戏机制,而非体验缺陷 | 预算耗尽 = 困了睡觉;工作勿扰 = 心跳冻结省钱 |
| B1 | 原始画面与声音永不出本机 | 云端只见文字摘要;一切感知可审计 |
| B2 | 任何能力扩张必须由主人显式批准 | 进化、工具、自主性全部走审批;由宠物开口请求 |
| B3 | 它单纯,但不蠢 | 话少、看得准、基于真实观察说话;失败模式被人设兜住 |

---

## 0.1 实现状态速览

| 模块 | 状态 | 一句话 |
|---|---|---|
| L0 身体(物理/动画/栖息/拖拽) | ✅ | 程序化绘制,60Hz 物理,窗口栖息,抛物线抛掷,落地翻滚 |
| L1 键鼠节奏 + 前台 App 感知 | ✅ | 只统计节奏,产出文字事件 |
| L1 摄像头(人/表情/手势/视频事件) | ✅ | 本机 Vision,默认关;需菜单栏开启 + 系统授权 |
| L1 本地物品识别 | 🟡 | 代码完整,依赖未打包的 `models/gugu-objects.mlmodelc` |
| L1 麦克风唤醒词 + 本地转写 | ✅ | SFSpeechRecognizer 本机识别,默认关 |
| L1 本地 TTS 朗读 | ✅ | AVSpeechSynthesizer,默认关 |
| L2 直觉心跳(阈值触发/冻结) | ✅ | 不轮询,攒好奇心,专注冻结 |
| L3 对话 | ✅ | 打字 + 语音同一链路,预算降档切层 |
| L4 梦境(整理记忆/技能/结算/提案) | ✅ | 直连 + 可选 Batch |
| 情感引擎(energy/valence/bond/arousal) | ✅ | 记仇 30 分钟、摸两下和好 |
| 进化(经验结算 + 提案审批 + 不可变内核) | ✅ | 4 个形态(设计目标 5 个,缺边界形态) |
| 预算熔断降档 | ✅ | 三档:全速 / 关对话 / 睡觉 |
| 本地工具:notes / reminders | ✅ | 权限门控 + 审计 |
| 本地工具:web_search | 🟡 | 只记录请求,不真正联网 |
| 定时提醒到点弹通知 | 🟡 | 即时通知可用;带 due 的不会到点触发 |
| 夜间自主任务执行 | ✅ | 梦境后经本地工具层真正落地;web_search 仍只记录(下行) |
| computer use / MCP / deep 多轮 tool loop | ⚪️ | 见 §12 路线图 |

图例:✅ 可用 · 🟡 部分(下文标注边界) · ⚪️ 未实现(仅愿景)

---

## 1. 总体架构

### 1.1 五层认知架构

```
L0 反射层   本地 · 0成本 · 60fps    身体、物理、动画状态机、对光标/拖拽的即时反应
L1 感知层   本地 · 0成本 · 常驻     传感器采集 + 本地识别,产出「事件」而非原始数据
L2 直觉层   instinct · 高频低价     心跳决策:心情/小动作/嘟囔一句(结构化输出)
L3 思考层   conversation · 中频      认真对话、重大事件理解
L4 梦境层   dream · 每晚一次         记忆固化 + 自我反思 + 进化提案(可选 Batch)
```

L2/L3/L4 三层默认共用同一个模型(出厂 `deepseek-v4-flash`),分层只是按调用频率与
token 上限区分,而非绑定不同型号;需要时可在 `config.yaml` 里给某一层单独指定模型。
代码对应 `Config.ModelTier`(instinct/conversation/dream)。

数据流:

```
传感器 ──→ L1 事件队列(EventBus)──→ 本地好奇心积分
                              │ 阈值触发(不轮询!)
                              ▼
                    L2 心跳(instinct, JSON out)──→ L0 执行动作/说话
                              │ 主人主动对话时
                              ▼
                    L3 对话/深思(conversation)
                              │ 当日流水
                              ▼
                    L4 夜间梦境(可选 Batch)──→ 重写 memory/ · 生长 skills/ · 产出 proposals/
```

### 1.2 一切皆配置文件

`~/Library/Application Support/Gugu/`,纯文本,热加载(Scheduler 检测 mtime 变化重载),
用户可直接编辑。离线测试用 `GUGU_HOME=/private/tmp/...` 指到临时目录。

```
Gugu/
├── config.yaml          # 模型、预算、感知开关、心跳参数、工具权限
├── persona.md           # 人格系统提示(含不可变 <!-- core --> 段)
├── evolution.yaml       # 形态定义(出厂内置)
├── state.json           # 当前形态、经验指标、信任分、待批准进化
├── pinned.json          # 主人显式要求记住的固定事实(如名字)
├── scheduler.json       # 夜间梦境交付状态(已蒸馏到哪一天)
├── dream_batch.json     # 可选 Batch 梦境的待回收状态
├── autonomy_tasks.jsonl # 自主任务队列
├── usage.json           # 当日 token 计量(熔断依据,含 byTier 分层统计)
├── gugu.log             # 本机运行日志
├── memory/              # owner.md / projects.md / self.md(夜间重写);bond.md 见 §5 注
├── skills/              # 它自己长出来的行为策略(情境匹配,渐进披露)
├── proposals/           # 待批准的自我修改(过期即删);applied/ 归档已应用项
├── snapshots/           # 应用提案前的快照
├── events/YYYY-MM-DD.jsonl   # 当日事件流水,7 天滚动删除
└── audit/               # 感知/记忆/提案/工具调用的审计日志
```

`config.yaml` 核心段(出厂默认):

```yaml
pet:
  name: 咕咕

api:
  url: https://taas.hk
  key: ""                       # 单机版从 config.yaml 读取;钥匙串是后续加固项

model:
  id: deepseek-v4-flash         # 三层默认共用这一个模型
  instinct_max_tokens: 200      # L2 心跳
  conversation_max_tokens: 400  # L3 对话
  dream_max_tokens: 1500        # L4 梦境
  # instinct_id / conversation_id / dream_id 可选:留空则回落到 id

budget:
  daily_tokens: 200000          # 随形态缩放,见 §7

heartbeat:
  min_interval: 600             # 秒
  max_interval: 3600
  freeze_when_focused: true     # 主人专注工作 = 心跳冻结

senses:
  screen: true
  input_rhythm: true
  blacklist_apps: [1Password, Keychain Access]
  # 摄像头/麦克风不在此处:由菜单栏 UserDefaults 开关控制,默认关

tools:
  web_search: false             # 必须经 proposals 批准
  notes: false
  reminders: false
  local_notifications: false

dream:
  use_batch: false              # 开启后夜间梦境走 /v1/messages/batches
```

---

## 2. 身体与表现层(L0) ✅

### 2.1 形态

透明无边框置顶 `NSWindow` + SpriteKit。程序化绘制(`BirdNode`)的小圆鸟,含 body/belly/
head/eyes/eyelids/beak/wings/feet/tail/crest/blush/zzz 各部件,支持 front/back/side
三视角及过渡。四个成长形态(hatchling/fledgling/adult/spirit)有不同体型缩放。

### 2.2 物理与栖息

- **有重力**:`PetController` 60Hz 物理循环,重力 2400 pt/s²,站屏幕底边(visibleFrame.minY)。
- **窗口栖息**:`CGWindowListCopyWindowInfo` 取前台窗口,可飞上去站在标题栏。
- **拖拽**:被拎起时挣扎;松手按采样速度做抛物线飞出;硬落地(速度够大)触发翻滚动画。
- **多显示器**:遍历 `NSScreen.screens`,取与窗口相交的屏幕。

### 2.3 动画状态机

```
idle ↔ walk ↔ fly ── perch(窗口标题栏)
  ├── dragged(挣扎→抛掷)→ falling(抛物线)→ land(翻滚)
  ├── approach / retreat
  ├── peck · dance · stare · groom
  └── sleep(深夜 / 预算耗尽 / 主动哄睡)
```

L2/L3 只返回**高层动作标签**(enum),具体演出由 L0 决定——模型输出极短,演出质量不依赖模型。

> 🟡 设计里列了 `yawn`(打哈欠),但 `PetController.perform(action:)` 没有对应分支,
> `BirdNode` 也无 `yawnOnce()`——目前不会打哈欠。

### 2.4 表达通道

| 通道 | 实现 | 用途 |
|---|---|---|
| 气泡 | 跟随身体的 `SpeechBubble`,自动消失,带尾巴与避让 | 说话(主通道) |
| 语音(可选) | `AVSpeechSynthesizer` 本地 TTS,按情绪调 pitch/rate | 默认关,菜单栏开 |
| 肢体 | 动画本身 | 大多数情绪不必说话 |
| 红晕/歪头/扑翅 | `BirdNode` 微动画 | 对摸/笑/手势的即时反应 |
| 菜单栏 | `NSStatusItem` | 开关、审计入口、调试触发 |

---

## 3. 感知系统(L1)

铁律(公理 B1):**本地识别,只上传文字摘要;原始帧与音频不出本机。**

### 3.1 键鼠节奏 ✅ —— 一等公民信号

`RhythmSensor` 用 `CGEventSource.secondsSinceLastEventType` 读键鼠最近活动,分钟级聚合,
**只统计节奏,永不记录内容**。导出状态:focused / busy / breather / away / active /
agitated,含深夜加班检测。

| 节奏 | 推导状态 | 宠物行为 | 心跳影响 |
|---|---|---|---|
| 持续高强度输入 | 专注 | 退到一边勿扰 | **冻结,零消耗** |
| 键鼠交替密集 | 忙碌 | 勿扰 | 冻结 |
| 输入停几分钟 | 歇口气 | 主动凑近的好时机 | 触发心跳 |
| 长时间无输入 | 离开 | 自己玩/睡 | 间隔拉满 |
| 输入恢复 | 回来了 | 迎接 | 事件入队 |

**专注 = 心跳冻结,工作越久越省钱**(公理 A3)。

### 3.2 前台 App ✅

`ScreenSensor` 监听 `NSWorkspace` 应用切换,黑名单过滤,统计驻留时长,产出
`"切到 Xcode,已持续 2h"` 这类文字事件。黑名单 App 在前台时静默。

### 3.3 摄像头(默认关) ✅ / 🟡

`VisionSensor` + `AVCaptureSession` 前置摄像头,本机 Vision:

- ✅ 人脸检测(`VNDetectFaceLandmarksRequest`)→ 有人/无人
- ✅ 表情(landmark 几何)→ 笑 / 惊讶 / 困倦
- ✅ 手势(`VNDetectHumanHandPoseRequest`)→ 挥手 / 手掌 / 点赞 / OK / 指向
- ✅ 视频事件(几秒结构化轨迹)→ 靠近 / 离远 / 左右移动 / 手靠近镜头
- 🟡 **本地物品识别**:代码完整,但需主人把编译好的 Core ML 模型放到
  `models/gugu-objects.mlmodelc`;文件不存在则自动跳过。

只入队文字事件,原始图像不保存、不上传。需菜单栏开启 + 系统授权。

### 3.4 麦克风(默认关) ✅

`Listener` 用 `SFSpeechRecognizer`(zh-CN,`requiresOnDeviceRecognition = true`)。
本机识别唤醒词(咕咕/小咕等),只把唤醒词后的简短指令交给对话链路。指令去重 + 冷却,
TTS 说话时自我静音(回声抑制)。音频不保存、不上传。

---

## 4. 认知与调度(L2 / L3) ✅

### 4.1 触发模型:不轮询,攒阈值

`Scheduler` 每 30 秒评估一次(不是每次都调模型)。本地 `EventBus` 维护**好奇心**积分,
事件按权重加分(主人回来 +28、被戳 +20、被摔 +25、看见笑 +18…)。心跳触发需同时满足:

1. 好奇心 ≥ 阈值(30)**或**超过 `max_interval`;
2. 未被冻结(主人非 focused/busy);
3. 距上次心跳 ≥ `min_interval`;
4. 预算未到睡眠档,且非深夜睡眠时段。

poke/chat 等交互可 `requestHeartbeat(force:)` 强制一次(仍不绕过冻结,除非显式 force)。

### 4.2 L2 直觉心跳(instinct 层)

请求构造(注意缓存友好):

```json
{
  "model": "deepseek-v4-flash",
  "max_tokens": 200,
  "system": [{ "type": "text", "text": "<persona.md 全文,字节级稳定>",
               "cache_control": {"type": "ephemeral"} }],
  "messages": [{ "role": "user", "content": "<成长状态 + 记忆摘要 + 激活技能 + 最近事件 + 节奏 + 情感>" }],
  "output_config": { "format": { "type": "json_schema", "schema": {
    "properties": {
      "mood":   {"enum": ["开心","平静","好奇","心疼","无聊","困","委屈"]},
      "action": {"enum": ["idle","walk","approach","retreat","perch","sleep","dance","stare","peck","groom"]},
      "speech": {"type": "string"},
      "memory_note": {"type": "string"}
    },
    "required": ["mood","action","speech","memory_note"], "additionalProperties": false
  }}}
}
```

- 动态内容永远在 user 消息,persona 永不掺动态字节——前缀缓存命中(若中转通道支持)。
- `skills/` 按情境(时间/节奏)由本地代码挑 0–2 条附入——**渐进披露**,单次 token 不膨胀。

### 4.3 L3 思考层(conversation)

主人主动对话时走此层:菜单栏「和咕咕说话」或唤醒词后的语音指令,**同一条链路**
(`Brain.chat`)。携带成长状态 + 记忆摘要 + 最近 ≤20 轮对话 + 节奏 + 情感 + 本机能力说明。

**预算降档**:`budget.degradeLevel >= 1` 时,对话从 conversation 层降到更便宜的
instinct 层(`Brain.chat` 内切换),并压低 max_tokens。

本地命令(记笔记/提醒/研究)先经 `LocalCommandParser` 关键词分流——**不烧 token**,
直接入工具或自主队列(见 §8)。

### 4.4 人设校准:单纯但敏锐

`persona.md` 约束话少、看得准、基于真实观察。`<!-- core -->` 段是程序禁止改写的安全内核
(诚实、不伤害主人利益、不假装看到没观察到的、不绕过授权)。

---

## 5. 记忆系统与梦境(L4) ✅

### 5.1 记忆分层

| 层 | 载体 | 生命周期 | 进入 prompt 方式 |
|---|---|---|---|
| 工作记忆 | 进程内 | 当次会话 | 最近事件/对话 |
| 当日流水 | events/*.jsonl | 7 天滚动删 | 夜间被蒸馏 |
| 长期记忆 | memory/owner·projects·self.md | 永续,夜间重写 | 摘要(`digest()`)进每次心跳 |
| 固定事实 | pinned.json | 永续 | 主人名字等,梦境不可覆盖 |
| 技能 | skills/*.md | 永续,可修订 | 情境匹配,渐进披露 |

> 🟡 设计里有 `bond.md`(大事记),进化之夜会向它追加;但 `Memory.digest()` **不读**
> bond.md,所以大事记目前不进心跳 prompt。
>
> 🟡 遗忘机制部分:旧 notes 在梦境后清除,但 skills 无过期/修剪逻辑。

### 5.2 梦境任务(每晚 03:00–05:00,错过则醒后补做)

`Scheduler.maybeDream` 判断目标记忆日,跑一次梦境。输入:当日流水 + 现有 memory/ +
skills 索引 + state 指标。`Brain.dream` 产出并应用:

1. **重写 memory/**:蒸馏当日,合并 owner/projects/self,保持简短(强制遗忘)。
2. **生长/修订 skills/**。
3. **经验结算**:days_together / events_seen / interactions / bond / trust 更新进 state.json。
4. **proposals/**(若有):性格修改或扩权请求,待批。

可选 Batch(`dream.use_batch: true`):`submitDreamBatch` 提交,下次评估
`refreshDreamBatchStatus` → `applyReadyDreamBatch` 回收。

梦境产出的 morning_words 缓存,主人早晨回来时由 `deliverMorningWordsIfAny` 说出来——
**梦境产出直接成为产品时刻**。

---

## 6. 情感引擎(本地,零成本) ✅

`Affect` 持有四个标量,随时间和事件演化:

```
energy   昼夜节律(正弦,峰值约 14:00)+ 互动消耗 → 动作活泼度
valence  事件加减(被摸+,被摔-,主人回来+)     → 动画基调
bond     长期缓慢增长,写入 state.json          → 敢不敢亲近
arousal  烦躁/突发事件拉高                       → 退多远
```

三件事:① 实时驱动 L0 表现(不经 LLM);② 作为一行文字进 prompt("你现在有点困");
③ 调制行为。**记仇与和好**是本地规则:被摔 → valence 锁低 30 分钟、躲着你;摸两下提前和好。
`isSleepyTime`(约 02:00–07:00)驱动夜间睡眠。

> 🟡 `Affect.bond` 与 `PetState.bond` 是两处存储,靠 main.swift 在摸/读时手动同步,
> 存在不一致风险(待统一为单一来源)。

---

## 7. 进化系统 ✅

### 7.1 本体论(公理 A1)

**模型不会进化,但"它"会**——它 = persona + memory + skills + 权限。进化 = 它的文件在生长 +
被允许借用的大脑越来越强。实现上是"按阶段加载不同配置 + 一个 diff 审批器"。
模型不绑定型号:出厂三层共用 `deepseek-v4-flash`,进化到高阶时由主人换上更强的模型即可。

### 7.2 形态(当前 4 个)

代码里的 `GrowthStage`:**hatchling → fledgling → adult → spirit**。每个形态有
displayName / speechGuidance / visualScale / budgetMultiplier(缩放每日 token 上限)。

```yaml
# evolution.yaml(出厂内置;模型留给 config.yaml,这里只描述形态与解锁条件)
stages:
  hatchling:  { speech_style: 只会鸣叫和单词,        daily_tokens: 40000 }
  fledgling:  { speech_style: 短句会表达观察,         daily_tokens: 120000, unlock_events: 500, unlock_interactions: 50 }
  adult:      { speech_style: 正常对话有性格,         daily_tokens: 200000, unlock_days: 14 }
  spirit:     { speech_style: 有观点会开玩笑,         daily_tokens: 800000, unlock_days: 60 }
```

> 🟡 设计目标是 5 个形态(最高「边界形态」:全部工具 + computer use + 自主长程任务),
> 目前缺这第 5 个。它对应的能力(见 §12)本就是路线图。

### 7.3 经验值 = 记忆本身

不造抽象 XP,直接度量已有之物,L4 夜间顺手结算:阅历(事件累计)、羁绊(互动/抚摸)、
知识(skills 数与激活)、信任(已授权限/建议采纳)。

### 7.4 进化仪式

阈值达成 → 当晚梦境生成 stage 提案 → 次日它开口:"我好像…长大了一点,可以吗?" →
主人在菜单栏「待批准提案」确认 → 应用形态。**每次进化必须主人按下同意**(公理 B2)。

### 7.5 自我修改与提案审批

`ProposalEngine` 支持四类提案,均经审批后才生效:

- `stage`(形态升级)、`persona_append`(性格追加)、`config_set`(配置项,白名单限定)、
  `tool_permission`(工具开关,白名单限定)。
- **不可变内核**:拒绝任何修改 persona.md `<!-- core -->` 段的提案。
- 应用前 `SnapshotStore` 快照 config/persona/state,应用后归档到 `proposals/applied/`。
- 未批准的提案 7 天过期自删。

可用 `--restore-latest <file>` 从最近快照恢复。

---

## 8. 能力与自主性

### 8.1 本地工具 ✅ / 🟡

`LocalToolExecutor` 三个工具,均受 `config.tools.*` 权限门控 + 审计:

- ✅ `notes.add` —— 写本地笔记
- ✅ `reminders.add` —— 记提醒
- 🟡 `web_search.request` —— **只写一条 pending 记录,不真正联网搜索**

`LocalNotifier` 用 `UNUserNotificationCenter` 发即时系统通知。
🟡 但带 `due` 时间的提醒**不会到点触发**——目前没有定时调度。

### 8.2 自主任务队列 ✅

`AutonomyTaskQueue`(JSONL 持久化)支持 note/reminder/research 入队,带 due 时间,
完整的 pending→completed/failed 状态机 + 审计。`Scheduler` 在梦境后调用
`runDue(limit: 5)` 跑到期任务,注入 `toolRunner(config:)`——每个任务按 kind 转交
`LocalToolExecutor`(复用即时命令那套工具层)**真正落地**:笔记写进 notes.jsonl、
提醒写进 reminders.jsonl、研究请求记入 research_requests.jsonl。

工具被拒(权限未开)时任务标为 failed 并留痕,而非假装完成——审计如实反映"没干成"。
`offlineRunner`(只返回描述字符串)保留给离线自测使用。

> 🟡 research 任务落地的仍是"待研究请求"记录,不真正联网搜索——受限于
> web_search 本身(§8.1),见 §12。

### 8.3 自主性三原则(对已落地部分成立)

**事先明示授权**(工具默认关,经提案开启)、**事中逐步留痕**(audit/)、**事后主动汇报**
(morning words + 审计页)。computer use / MCP 见 §12。

---

## 9. 成本工程

### 9.1 结构性手段(按杠杆排序)

1. **不调用**:阈值触发 + 专注冻结 + 睡眠时段——最大头的钱是没花出去的钱。✅
2. **调最便宜的**:默认全程同一个便宜模型(deepseek);高阶形态才可能换更贵大脑。✅
3. **输出极短**:人设限制 + `max_tokens` 150–400 + 结构化输出。✅
4. **Batch**:不赶时间的梦境可走 Batch(若通道支持)。✅
5. **前缀缓存**:persona 字节级冻结置顶,动态内容后置(具体前缀阈值视模型)。✅
6. **视觉本地化**:摄像头帧只在本机处理,只把文字事件进心跳。✅

### 9.2 计量(本地,纯 token)

`Budget` 把字符按 `ceil(chars / 3.2)` 估成 token(中转通道 usage 不可靠)。
`usage.json` 实时记账,新增 `byTier` 按 instinct/conversation/dream 分层统计。
**只按 token 计,不涉及金额。**

### 9.3 熔断与降档

`degradeLevel` 三档(按当日用量比例):

- 0(<85%)= 全速
- 1(≥85%)= 对话降到 instinct 层、压低输出
- 2(≥100%)= 困了睡觉(L0 全功能照常),次日醒来

所有降档以宠物状态呈现(困了/想休息),不弹报错(公理 A3)。

---

## 10. 隐私与安全

| 层 | 措施 | 状态 |
|---|---|---|
| 数据 | 原始帧/音频不出本机;键鼠只存节奏计数;事件 7 天滚动删 | ✅ |
| 透明 | 「咕咕今天看到了什么」审计页;工具/感知/提案逐条留痕 | ✅ |
| 控制 | 摄像头/麦克风默认关、逐项授权;黑名单 App 静默 | ✅ |
| 凭证 | 单机版从 `config.yaml` 读 key;钥匙串/服务端代理是加固项 | 🟡 |
| 自我修改 | persona 不可变内核;proposals 永不静默生效 | ✅ |

---

## 11. 工程结构

### 11.1 技术栈

- **客户端**:Swift / AppKit + SpriteKit(身体)、Vision、Speech、UserNotifications、
  CGEventSource 节奏采样、AVFoundation(摄像头/TTS)。
- **API**:`URLSession` 直连中转通道,走 **Anthropic 兼容的 Messages 协议**
  (`POST /v1/messages`,`x-api-key` + `anthropic-version`);Batch 走 `/v1/messages/batches`。
  默认模型是 deepseek,但协议格式是 Anthropic 风格(`AnthropicClient`)。

### 11.2 模块划分(实际目录)

```
Sources/Gugu/
├── Body/        BirdNode(绘制) · PetController(物理/状态机) · Render(离屏)
├── Senses/      RhythmSensor · ScreenSensor(Sensors) · VisionSensor · Listener · Voice · EventBus
├── Affect/      Affect(情感标量)
├── Brain/       Brain · Scheduler · AnthropicClient · Memory · DreamBatchStore · LocalCommandParser
├── Evolution/   Evolution · GrowthStage · ProposalEngine · SnapshotStore · Audit
├── Budget/      Budget(计量/熔断/降档)
├── Tools/       LocalToolExecutor · LocalNotifier
├── Autonomy/    AutonomyTaskQueue
├── Core/        Config · Paths
├── Console/     菜单栏 · 审计入口 · 调试触发
├── SelfTest.swift   离线/在线自测
└── main.swift       组合根:senses → affect → scheduler → brain → body
```

### 11.3 命令行入口

```bash
swift build
GUGU_HOME=/private/tmp/gugu-offline ./.build/debug/gugu --selftest-offline  # 全链路离线自测
./.build/debug/gugu --selftest             # 真实 API 全链路(需配好 key)
./.build/debug/gugu --audit-report         # 打印今日审计报告路径
./.build/debug/gugu --restore-latest config.yaml
./.build/debug/gugu --render happy x.png   # 离屏渲染某姿态到 PNG
```

`--selftest-offline` 必须显式设 `GUGU_HOME`,避免写入真实数据目录。

### 11.4 失败模式(被人设兜住)

| 故障 | 表现 |
|---|---|
| 断网 / API 5xx | 发呆,L0 照常;`AnthropicClient` 指数退避重试 |
| 预算耗尽 | 困了,睡 |
| 模型理解错 | 那是咕咕单纯,主人纠正会写进当日流水 |
| 配置损坏 | 回退最近快照 |

---

## 12. 路线图(尚未实现的愿景)

下列是设计愿景,**当前代码未实现**,从正文剥离至此以免与现状混淆:

| 方向 | 目标 | 当前差距 |
|---|---|---|
| 替你深度思考 | 更强模型 + thinking + web_search 多轮 tool loop,"飞走研究"叼回报告 | web_search 只记录不联网;无 tool loop |
| 夜间研究真正联网 | research 任务真正联网搜索并叼回结果 | 仅记录请求,受限于 web_search(§8.1);note/reminder 已真正落地 |
| 定时提醒 | 带 due 的提醒到点弹通知 | 无定时调度(§8.1) |
| 操作电脑 | 沙盒 computer use,逐步留痕可回放 | 未实现 |
| 接入主人的世界 | MCP servers(日历/笔记/todo) | 未实现 |
| 第 5 形态 | 「边界形态」:全部工具 + 自主长程任务 | 仅 4 形态(§7.2) |
| 大事记进记忆 | bond.md 进心跳 prompt | digest() 未读(§5.1) |
| 打哈欠 | yawn 动作 | 状态机缺分支(§2.3) |
| 跨设备 | 记忆同步 / 导出「把咕咕带走」 | 未实现 |
| 凭证加固 | 钥匙串或服务端薄代理统一管 key | 单机版明文读 config |

---

## 13. 结语

> **把生命感交给本地,把灵光交给模型,把成长交给文件,把边界交给主人。**

它便宜,因为它有节制;它可信,因为它透明;它动人,因为它的每一次开口都落在你真实生活的
节奏上。"它"从来不是模型——是和你共同长出来的那一堆记忆。
