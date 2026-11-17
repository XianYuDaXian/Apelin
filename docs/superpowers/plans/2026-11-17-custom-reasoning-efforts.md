# 自定义推理强度实施计划

> **给执行代理：** 必须按任务逐项执行，使用复选框跟踪进度。

**目标：** 让 Apelin 支持任意原始字符串作为推理强度，并把自定义值同步到每个模型的候选列表，位置可设为最前或最后。

**架构：** 先把协议层的封闭枚举改为开放原始值类型，再由应用偏好保存自定义值和位置；模型设置、聊天栏和 Agent 运行时读取同一份值。运行时利用 Model.thinkingLevelMap 把自定义原始值映射到 kwwk 已知级别的载体，不升级 kwwk 依赖。

**技术栈：** Swift、UIKit、swift-testing、XCTest、UserDefaults、ApelinProtocol、ApelinAgent。

**规格：** docs/superpowers/specs/2026-11-17-custom-reasoning-efforts-design.md

## 全局约束

- kwwk 固定提交保持 997b8c58047c9bda25f95dce55390d5439bb02bd。
- 默认位置为 last，可切换为 first。
- 自定义值为非空且不含空白的字符串，保留输入顺序。
- 新增后不自动替任何模型勾选；旧会话继续按原字符串读取。
- 不修改 Codex 叠加层提示词和开关逻辑。
- 执行方式为本机直接实现，不启用子代理。

## 审查重点

- 自定义原始值经过协议编解码后必须完全不变。
- EnabledModels 保存/读取不得再过滤掉未知原始值。
- 自定义值映射到 kwwk 载体级别时，不能污染其他强度的请求。
- 位置切换后，模型设置菜单、聊天栏菜单和当前选择显示必须同时更新。
- 删除自定义值后，历史会话不能丢失或退回默认值。

---

### 任务 1：开放协议层推理强度类型

**文件：**
- 修改：Packages/ApelinKit/Sources/ApelinProtocol/Operations/Agent.swift
- 测试：Packages/ApelinKit/Tests/ApelinProtocolTests/AgentReasoningEffortTests.swift

**接口：**
- 产出：AgentReasoningEffort(rawValue: String)、AgentReasoningEffort.off/minimal/low/medium/high/xhigh/max、AgentReasoningEffort.knownCases

- [ ] **步骤 1：编写失败测试**

验证任意原始值可构造、内置常量值不变、Codable 往返保持原值。

- [ ] **步骤 2：运行测试并确认失败**

运行 swift test --package-path Packages/ApelinKit --filter AgentReasoningEffortTests。

- [ ] **步骤 3：实现开放值类型**

将枚举改为 RawRepresentable、Codable、Hashable、Sendable 结构体，提供静态常量和 knownCases。

- [ ] **步骤 4：运行测试并确认通过**

运行同一测试命令，结果必须为 PASS。

- [ ] **步骤 5：提交**

提交信息：feat: 开放推理强度协议类型。

### 任务 2：保存自定义列表与位置

**文件：**
- 新建：Apelin/Interface/Settings/Accounts/CustomReasoningEfforts.swift
- 测试：在 Packages/ApelinKit/Tests/ApelinProtocolTests/AgentReasoningEffortTests.swift 中增加纯函数测试

**接口：**
- 产出：CustomReasoningEfforts.all、CustomReasoningEfforts.position、CustomReasoningEfforts.save、CustomReasoningEfforts.options

- [ ] **步骤 1：编写失败测试**

验证去重、空白过滤、大小写保留、first 与 last 两种合并顺序。

- [ ] **步骤 2：运行测试并确认失败**

运行对应过滤测试，结果必须为 FAIL。

- [ ] **步骤 3：实现偏好层与合并函数**

用 UserDefaults 保存有序字符串数组，位置只接受 first/last。

- [ ] **步骤 4：运行测试并确认通过**

运行对应过滤测试，结果必须为 PASS。

- [ ] **步骤 5：提交**

提交信息：feat: 保存自定义推理强度配置。

### 任务 3：同步模型候选与聊天菜单

**文件：**
- 修改：Apelin/Interface/Settings/Accounts/EnabledModels.swift
- 修改：Apelin/Interface/Settings/Accounts/ModelActivationController.swift
- 修改：Apelin/Interface/Chats/Composer/ComposerModelSelection.swift
- 修改：Apelin/Interface/Chats/Composer/Sections/ComposerModelBar.swift

**接口：**
- 消费：CustomReasoningEfforts.options
- 产出：每个模型可勾选的推理强度包含自定义值；聊天栏按保存顺序显示并可选择。

- [ ] **步骤 1：移除固定枚举过滤**

保存和读取原始字符串数组，标题对未知值回退为原值。

- [ ] **步骤 2：合并自定义候选**

模型设置和聊天栏读取 CustomReasoningEfforts.options，位置切换后发送已有变更通知。

- [ ] **步骤 3：执行 Xcode 构建**

运行项目既有构建命令，必须无编译错误。

- [ ] **步骤 4：提交**

提交信息：feat: 同步自定义推理强度到模型列表。

### 任务 4：Agent 运行时透传

**文件：**
- 修改：Packages/ApelinAgent/Sources/ApelinAgent/Session/AgentSessionConfiguration.swift
- 修改：Packages/ApelinAgent/Sources/ApelinAgent/Session/AgentSession.swift
- 修改：Packages/ApelinAgent/Sources/ApelinAgent/Session/ProviderConfiguration.swift
- 修改：Packages/ApelinAgent/Sources/ApelinAgentWorker/AgentWorker.swift
- 测试：Packages/ApelinAgent/Tests/ApelinAgentTests/CustomReasoningEffortTests.swift

**接口：**
- 产出：会话配置携带 reasoningEffortRaw；ProviderReasoning.model 在自定义值时把载体级别映射到原始值。

- [ ] **步骤 1：编写失败测试**

验证自定义值选择后，Model.thinkingLevelMap 的载体键映射到该原始值，内置值不受影响。

- [ ] **步骤 2：运行测试并确认失败**

运行 swift test --package-path Packages/ApelinAgent --filter CustomReasoningEffortTests。

- [ ] **步骤 3：实现原始值透传**

Worker 保存原始值，LiveModel 随模型和强度切换更新，流式请求前应用映射。

- [ ] **步骤 4：运行测试并确认通过**

运行同一测试命令，结果必须为 PASS。

- [ ] **步骤 5：提交**

提交信息：feat: 透传自定义推理强度原始值。

### 任务 5：新增设置界面与全量验证

**文件：**
- 修改：Apelin/Interface/Settings/Accounts/ModelProvidersController.swift

- [ ] **步骤 1：实现管理入口**

在模型供应商设置中提供新增、删除自定义强度和位置切换，使用现有中文/本地化文案风格。

- [ ] **步骤 2：运行包测试**

运行 swift test --package-path Packages/ApelinAgent，结果必须为 PASS。

- [ ] **步骤 3：构建 Debian 包**

运行项目既有 Build and verify Debian packages 流程，确认成功。

- [ ] **步骤 4：提交验证修正**

如有修正，提交信息：test: 完善自定义推理强度验证。
