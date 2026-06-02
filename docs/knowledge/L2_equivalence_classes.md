# L2 — 等价类与边界

> 测试设计输入。L1 已经写明契约,本文件把契约翻译成可执行的具体用例。
> caff 不接 codegen 编译为 Swift 测试,所以 L2 不写成 Markdown 用例格式,只列等价类 + 已有覆盖度。

## 覆盖度矩阵

| 模块 | 现有覆盖 | 缺口 | 优先级 |
|---|---|---|---|
| `PowerAssertionController` | start 正常 / start+display / stop | 失败路径(createFailed / cleanupAfterCreateFailed / 多次 stop) | **高** |
| `SafetyPolicy` | standard 默认 / 1h 电池拒绝 / 4h 电池允许 | 临界(59/60 分钟)、Indefinitely 电池、formatMinutes 边界 | **高** |
| `SessionDuration` | presets / nil / 正数 | 边界(0/负数由构造器挡) | 低 |
| `WakeSession` | sourceLabel / assertionSummary / compactStatus | capped session / updatingAssertions 演进 | 中 |
| `SessionHistory` | — 旧 exited 兼容 | 正常往返、未知 result 错误、sortOrder | **高** |
| `AgentHookManager` | install / remove / 幂等 / 保留 | 非法 JSON、目录不存在、shellEscaped | 中 |
| `AgentActivityCooldown` | touch / evaluate / 过期 / receipt / 政策 | normalizedSource 边界(""/空白) | 低(已覆盖) |
| `RemoteControlParser` | 45/nil/"0" invalid / removed source | cooldown 错误、bool 各种值、source 空 | **高** |

## 待补 XCTest 清单(本轮)

1. **`PowerAssertionControllerTests`**(新建)
   - 重复 start 不累积断言
   - 重复 stop 不抛错
   - start 后 activeAssertions 顺序与 sortOrder 一致

2. **`SafetyPolicyTests`**(新建)
   - 边界:59 分钟电池通过
   - 边界:60 分钟电池拒绝
   - Indefinitely 电池拒绝
   - Indefinitely 电池允许 + effectiveEnd = start+maxMinutes
   - formatMinutes 60→"1h",120→"2h",61→"61m",59→"59m"
   - sessionNotes 在 AC / battery 下的差异

3. **`SessionHistoryTests`**(新建)
   - 正常编解码往返
   - 旧 `"exited"` 映射
   - 未知 result 抛 `dataCorruptedError`
   - summary 字符串构造

4. **`RemoteControlParserTests`**(新建)
   - duration: nil / "" / "0" / "-5" / "45" / "99999"
   - source: nil / "" / "manual" / "url" / "process" / "workspace" / 未知大小写
   - cooldownSeconds: nil / "" / "0" / "60" / "1800" / "-1" / "abc"
   - bool: nil / "true" / "TRUE" / "1" / "yes" / "on" / "no" / "garbage"

5. **`SessionDurationTests`**(新建,小)
   - 自定义 minutes(45)
   - formatMinutes 全边界(0/30/59/60/61/119/120/240)

## 不属于 caff 风格的:UNPARSED 断言回写规则

caff 不存在"Markdown → XCTest codegen",所以本仓不维护 UNPARSED 规则。如果以后引入 Markdown 测试设计层(可能通过本地 skill 适配),再补。
