# Apelin 自定义推理强度设计

## 目标

让 Apelin 能新增内置列表之外的推理强度原始值，并把这些值同步到每个模型的推理强度候选列表。自定义值在候选列表中的位置可配置为最前或最后；请求发送时保持用户输入的原始字符串。

## 非目标

- 不自动为所有模型勾选新加的自定义强度；只让它成为可勾选项，现有逐模型配置保持不变。
- 不升级 kwwk 依赖，继续使用当前固定提交 997b8c5。
- 不为没有命名强度字段的供应商臆造数值预算映射。

## 约束

- AgentReasoningEffort 是七项封闭枚举；EnabledModels 保存时还会按 allCases 过滤，必须改成可容纳任意原始值的类型并停止过滤。
- kwwk 的 ThinkingLevel 与 ReasoningLevel 都是封闭枚举，但 Model.thinkingLevelMap 允许把已知级别映射到任意供应商字符串。
- 应用、Worker 和 Agent 之间用 AgentReasoningEffort.rawValue 传递，顺序与显示名由应用侧提供。

## 方案比较

1. 全局自定义列表：一处新增、所有模型可选，利用 thinkingLevelMap 把自定义原始值透传；改动集中。
2. 每个模型单独新增：最精确，但要给每个供应商配置重复维护，界面和持久化都要重做。
3. 聊天栏单次自由输入：最轻量，但不能稳定同步到每个模型的候选列表，也无法集中排序。

选择方案一。新增值对所有模型可见；是否启用仍由每个模型自己的勾选决定。

## 数据设计

- UserDefaults 新增 agent.customReasoningEfforts，保存有序原始字符串数组。
- 新增 agent.customReasoningPosition，取值 first 或 last，默认 last。
- AgentReasoningEffort 改为 RawRepresentable、Codable、Hashable、Sendable 的开放值类型；静态常量保留 off/minimal/low/medium/high/xhigh/max。
- 自定义值显示名就是原始值；内置值保持现有本地化标题。

## 修改范围

- 设置中的模型页新增“自定义推理强度”管理入口，支持新增、删除和选择“放最前 / 放最后”。
- ModelActivationController 的候选列表改为内置值加自定义值；保存与读取不再丢弃未知原始值。
- EnabledModels 合并自定义值到每个模型的候选列表，并发送已有变更通知让聊天页刷新。
- ComposerModelSelection 与 ComposerModelBar 支持任意原始值的显示与选择。
- Agent 协议继续传 AgentReasoningEffort；Worker 把自定义原始值记录到会话配置，运行时选一个已知 ThinkingLevel 作为载体，并通过 Model.thinkingLevelMap 将该载体映射到自定义原始值。
- 变更模型或推理强度时，聊天页按新顺序刷新菜单；已有会话仍按原始值读回。

## 兼容与验证

- 删除自定义值不会破坏历史会话，只是不再出现在新选择器里。
- 自定义值为空、含空白或超过长度上限时拒绝新增；与内置值冲突时不重复添加。
- 单元测试覆盖：开放原始值编解码、候选顺序、持久化不过滤、请求映射使用原始值。
- 运行 swift test --package-path Packages/ApelinAgent 与 xcodebuild 的 Verify Debian Packages 流程，确认工具调用、历史记录和 Codex 叠加层开关未受影响。
