# 模型未配置或失效时的处理与引导

## 改进概述

当模型没有配置或者失效时，gugu现在能够：
1. **识别错误类型**：区分API key缺失、认证失败、网络问题
2. **给出具体引导**：告诉用户如何打开设置并配置
3. **保持性格一致**：用小鸟的口吻解释技术问题
4. **首次启动提示**：温和地引导新用户配置

## 改动文件

### 1. Sources/Gugu/Core/Strings.swift
**新增错误消息**：
- `errorNoApiKey`: API key 未配置时的提示（引导去设置）
- `errorAuthFailed`: API key 失效时的提示（401/403错误）
- `errorNetwork`: 网络故障时的提示
- `voiceFailedNoKey`: 语音命令遇到未配置key
- `voiceFailedAuth`: 语音命令遇到认证失败
- `learnFailedNoKey`: 学习动作遇到未配置key
- `greetingNeedsSetup`: 首次启动且未配置key的欢迎语

### 2. Sources/Gugu/Brain/Brain.swift
**新增错误分类函数**：
```swift
static func userMessage(for error: Error, config: Config) -> String
```
- 优先检查 API key 是否为空
- 根据 LLMError 类型（http/transport/malformed/empty）返回对应消息
- 401/403 特殊处理为认证失败
- transport 错误识别为网络问题

### 3. Sources/Gugu/Console/Console.swift
**改进聊天错误处理**：
- 使用 `Brain.userMessage(for:config:)` 替代泛泛的 `L.chatFailed`
- 根据具体错误类型给出针对性提示

### 4. Sources/Gugu/main.swift
**改进两处错误处理**：
1. `handleVoiceCommand()`: 语音命令失败时使用分类错误消息
2. `tryStartLearnMove()`: 学习动作失败时使用分类错误消息

**启动时配置检查**：
- 检测 API key 是否为空
- 首次启动 + 未配置时显示 `greetingNeedsSetup` 引导用户

## 用户体验流程

### 场景1：首次安装（未配置API key）
1. **启动时**：咕咕说 "咕!(我还没接上脑子。右键我 → 设置,填上 API Key 就能和你说话了)"
2. **尝试聊天**：显示 "(咕咕想说话,但还没接上脑子。右键我 → 设置,填上 API Key)"
3. **尝试语音**：说 "(咕咕还没接上脑子,先去菜单栏图标 → 设置里填 API Key)"

### 场景2：API key失效（401/403）
1. **尝试聊天**：显示 "(咕咕脑子接不上了,密钥可能失效了。右键我 → 设置)"
2. **尝试语音**：说 "(密钥好像失效了,去设置里看看?)"

### 场景3：网络问题
1. **尝试聊天**：显示 "(咕咕的脑子在远方,网络卡住了,等会儿再试?)"
2. 用户知道这是临时问题，不是配置错误

### 场景4：其他错误
1. 回退到原有的温和提示："咕咕没听清。"

## 设计原则

1. **保持性格**：所有错误消息都用小鸟的口吻（"我的脑子在远方"而不是"LLM服务不可用"）
2. **可操作性**：每条错误消息都告诉用户下一步怎么做
3. **非侵入式**：首次启动提示温和，不打断用户
4. **渐进增强**：已有用户不受影响，只在真正出错时才看到新消息

## 测试建议

### 手动测试
```bash
# 1. 测试未配置key场景
cd ~/.gugu
mv config.yaml config.yaml.bak
# 确保 api.key 为空
cat > config.yaml << 'EOF'
api:
  url: https://taas.hk
  key: ""
  provider: openai
model:
  id: deepseek-v4-flash
budget:
  daily_tokens: 200000
EOF

# 启动gugu，应该看到引导消息
./gugu

# 2. 测试认证失败（需要一个失效的key）
# 编辑 config.yaml，填入无效key
# 尝试聊天，应该看到"密钥可能失效了"

# 3. 测试网络问题（断网或使用错误URL）
# 编辑 config.yaml，改 url 为 https://invalid.domain.test
# 尝试聊天，应该看到"网络卡住了"

# 恢复配置
mv config.yaml.bak config.yaml
```

### 验证点
- [ ] 首次启动且key为空时显示设置引导
- [ ] 聊天时key为空显示具体错误
- [ ] 401/403错误识别为认证失败
- [ ] 网络错误识别为网络问题
- [ ] 所有消息保持小鸟性格
- [ ] 中英文双语正确切换

## 后续优化方向

1. **在设置窗口增加"测试连接"按钮**：让用户配置后立即验证
2. **记住错误状态**：多次失败后降低心跳频率，减少无效请求
3. **日志记录**：将认证失败/网络问题写入审计日志，方便排查
4. **友好的配置模板**：在设置界面添加常见provider的快速配置
5. **离线模式**：当检测到长期无法连接时，提供纯本地互动模式

## 相关代码位置

- 错误消息定义: [Strings.swift:100-220](Sources/Gugu/Core/Strings.swift)
- 错误分类逻辑: [Brain.swift:148-177](Sources/Gugu/Brain/Brain.swift)
- 聊天错误处理: [Console.swift:579-583](Sources/Gugu/Console/Console.swift)
- 语音错误处理: [main.swift:282-286](Sources/Gugu/main.swift)
- 学习错误处理: [main.swift:322-326](Sources/Gugu/main.swift)
- 启动配置检查: [main.swift:63-81](Sources/Gugu/main.swift)
