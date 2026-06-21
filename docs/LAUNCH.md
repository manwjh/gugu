# 咕咕发布计划

目标:让第一批开发者和 macOS 用户理解咕咕、跑起来、愿意反馈,而不是只收获一次性围观。

## 发布定位

一句话:

> 咕咕是一个活在 macOS 桌面上的 AI 小生命,不是套皮聊天机器人。

核心差异:

- 有身体:会走动、栖息、被拖拽、被摸、被抛出去。
- 有节奏:不是等输入才输出,会在合适时机短暂开口。
- 有连续性:本地记忆、行为经验和成长阶段会随着相处演化。
- 有边界:感知默认本机处理,摄像头和麦克风默认关闭,能力扩张需要审批。

## 发布前检查

- [x] README 首屏能在 30 秒内讲清楚项目。
- [x] README 有清晰安装、模型配置、隐私说明、当前边界。
- [x] 准备静态发布图片,不用视频/GIF。
- [x] 确认开源许可证。已添加 MIT `LICENSE`。
- [x] 统一版本号。当前计划发布版本为 `v2.3.0`;`Info.plist` 已更新为 `CFBundleShortVersionString=2.3.0` / `CFBundleVersion=230`。
- [x] 跑通 `swift build`。
- [x] 跑通 `GUGU_HOME=/private/tmp/gugu-launch-selftest-20260621-final ./.build/debug/gugu --selftest-offline`。
- [x] 用全新临时数据目录启动一次,确认首次配置路径没有误导。
- [x] 确认 GitHub repo description 和 topics。
- [x] 创建公开发布 Release: `v2.3.0`。
- [x] 创建反馈 issue:安装问题、模型配置、隐私顾虑、交互建议。

## GitHub 设置建议

Repository description:

> An AI desktop lifeform for macOS. A little bird that senses your work rhythm, remembers, grows, and speaks at the right moment.

Topics:

```text
macos
swift
spritekit
ai-agent
desktop-pet
llm
openai-compatible
privacy-first
```

Release title:

```text
Gugu v2.3.0 - public launch release
```

如果使用 GitHub CLI:

```bash
gh repo edit manwjh/gugu \
  --description "An AI desktop lifeform for macOS. A little bird that senses your work rhythm, remembers, grows, and speaks at the right moment." \
  --add-topic macos \
  --add-topic swift \
  --add-topic spritekit \
  --add-topic ai-agent \
  --add-topic desktop-pet \
  --add-topic llm \
  --add-topic openai-compatible \
  --add-topic privacy-first
```

Release notes:

```markdown
见 docs/RELEASE_NOTES_v2.3.0.md
```

## 渠道顺序

### 第 1 波:小范围技术用户

目的:先发现安装和配置问题。

- 个人朋友圈/即刻/微信群
- GitHub README + Release
- V2EX `分享创造`

观察指标:

- Star
- Clone / fork
- issue 数
- 安装失败类型
- 用户是否能说清楚“它和普通 AI 桌宠有什么不同”

### 第 2 波:公开社区

目的:扩大传播,验证定位。

- 掘金技术文章
- 少数派投稿或短文
- B 站/小红书/视频号可以后续再做真实录屏,本次 Release 不附视频/GIF
- Reddit `r/macapps`, `r/SideProject`
- Hacker News `Show HN`

### 第 3 波:产品化验证

目的:判断是否值得做签名、公证、自动更新和官网。

- Product Hunt
- 独立开发者社区
- macOS app directory
- 英文长文:building an AI desktop lifeform

## 7 天执行表

### Day 0

- README、发布文案、Release notes 完成。
- 准备静态发布图片。
- 本地验证构建和离线自测。
- 确认许可证并补充 `LICENSE`。

### Day 1

- 发布 GitHub Release。
- 发中文短帖。
- 记录所有安装和配置反馈。

### Day 2-3

- 修复最高频安装问题。
- README 补 FAQ。
- 发布第一篇技术细节文章。

### Day 4-7

- 发 HN / Reddit / 更大中文社区。
- 追加真实截图和用户反馈。
- 整理 roadmap,把真实反馈转成 issue。

## 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 用户不会配置模型 | 无法体验 | README 给最小 `config.yaml` 示例,首条 issue 收集 endpoint 适配问题 |
| macOS Gatekeeper 阻拦 | 转化下降 | 明确当前是源码构建,暂不承诺公证安装包 |
| 被理解成普通桌宠 | 传播弱 | 文案坚持“有节奏、有记忆、有边界”,图片展示真实卡通质感 |
| 隐私顾虑 | 不敢试 | 首屏放隐私承诺,摄像头/麦克风默认关闭写清楚 |
| token 成本不清楚 | 用户担心 | 写明预算熔断和专注冻结 |

## 成功标准

7 天内:

- 50+ GitHub stars
- 5+ 有内容的 issue/讨论
- 3+ 外部用户成功跑起来
- 收到至少 1 个“我愿意常驻桌面试用”的反馈

30 天内:

- 明确是否值得做签名公证安装包
- 明确第一批真实用户最在意的是陪伴、工作节奏、隐私、还是可编程能力
- 形成下一版 roadmap
