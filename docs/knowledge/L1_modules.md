# L1 — 模块契约

> 来源:`Sources/CaffCore/` 10 个文件(Phase 5 之后,新增 `IOPowerAssertionBackend.swift`)。本文件逐模块抽取公开接口、关键不变量、失败模式。

---

## 1. `PowerAssertionController`

**公开 API**:
- `init(backend: IOPowerAssertionBackend = SystemIOPowerAssertionBackend())` — 默认参数让现有 call site 零改动
- `var isRunning: Bool`
- `var activeAssertions: Set<PowerAssertionKind>`
- `func start(options: SessionOptions) throws`
- `func stop() throws`
- `deinit`(兜底释放)

**不变量**:
- start 先 stop 现有断言,再创建新的(idempotent)
- 释放时收集所有失败但只抛出第一个,剩余的 ID 保留在字典中
- createAssertion 失败时尝试清理已创建的断言,若清理也失败抛 `cleanupAfterCreateFailed`
- 所有 IOKit 调用通过 `backend` 协议层,测试 target 可注入 fake backend 覆盖失败路径

**失败模式**:
- `.createFailed(kind, code)`
- `.releaseFailed(kind, code)`
- `.cleanupAfterCreateFailed(createFailure, cleanupFailure)`

---

## 1b. `IOPowerAssertionBackend` (Phase 5 新增)

**公开 API**:
- `protocol IOPowerAssertionBackend: Sendable`
  - `func createAssertion(type: CFString, level: IOPMAssertionLevel, reason: CFString) -> (status: IOReturn, id: IOPMAssertionID)`
  - `func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn`
- `struct SystemIOPowerAssertionBackend: IOPowerAssertionBackend` — 真实 IOKit 包装

**不变量**:
- `SystemIOPowerAssertionBackend.createAssertion` 失败时 id 保持 0(对齐 IOKit 行为)
- 协议只有两个方法,故意保持最小面(避免 backend 变成 mock 大杂烩)
- 测试 fake 位于 `Tests/CaffCoreTests/PowerAssertionControllerFakeBackendTests.swift`,不进入生产模块公开 API

**等价类**:
| 等价类 | 期望 |
|---|---|
| start 一次 | isRunning=true;activeAssertions ⊇ {idleSystemSleep} |
| start + keepDisplayAwake | activeAssertions == {idleSystemSleep, displaySleep} |
| start 两次 | 第二次 start 等价 stop+start(断言全部重建) |
| stop 后 start | 正常路径 |
| create 成功一半后 display create 失败 | cleanup 释放已创建断言,最终抛 create failure |
| create 成功一半后 display create 失败且 cleanup release 失败 | 抛 `cleanupAfterCreateFailed`,保留 release 失败的断言 ID |
| 失败时 deinit | 仍会尽力释放已有断言 |

---

## 2. `SafetyPolicy`

**公开 API**:
- `init(maximumSessionMinutes: Int = 240, longSessionBatteryThresholdMinutes: Int = 60, allowLongSessionsOnBattery: Bool = false)`
- `static let standard: SafetyPolicy`
- `var summary: String`
- `func validate(duration: SessionDuration, powerSource: PowerSourceState) throws`
- `func effectiveEndDate(for: SessionDuration, startedAt: Date) -> Date?`
- `func sessionNotes(for: SessionDuration, powerSource: PowerSourceState) -> [String]`
- `static func formatMinutes(_ minutes: Int) -> String`

**不变量**:
- `validate` 触发拒绝的条件:powerSource == battery AND !allowLongSessionsOnBattery AND duration.isLongBattery
- `effectiveEndDate` 取 min(requested, maximum) — 不超过 maximum
- `Indefinitely` 的 endDate 永远为 nil,policy 把它截到 maximum
- `isLongBatterySession`:Indefinitely 一律算长;有 minutes 则 minutes >= threshold

**等价类**:
| duration | power | allowLongOnBattery | 期望 |
|---|---|---|---|
| 30m | AC | * | 通过 |
| 30m | battery | * | 通过(< 60 阈值) |
| 60m | battery | false | **拒绝** |
| 60m | battery | true | 通过 |
| 4h | battery | false | 拒绝 |
| Indefinitely | battery | false | 拒绝 |
| Indefinitely | battery | true | 通过,effectiveEnd = start+maxMinutes |
| 4h | AC | false | 通过,effectiveEnd = start+4h |

**formatMinutes 边界**:
- 60 → "1h"
- 120 → "2h"
- 61 → "61m"
- 30 → "30m"

---

## 3. `SessionDuration`

**公开 API**:
- `init(label: String, minutes: Int?)`
- 4 个 preset:`indefinitely` / `thirtyMinutes` / `oneHour` / `fourHours`
- `static let presets: [SessionDuration]`
- `var timeInterval: TimeInterval?`
- `func endDate(from: Date) -> Date?`

**不变量**:
- `presets` 顺序固定
- `indefinitely` 的 minutes=nil ⇒ timeInterval=nil ⇒ endDate=nil

**等价类**:
- nil minutes ⇒ nil endDate
- 正数 minutes ⇒ 准确的 endDate
- 自定义 minutes(例如 45)— 允许

---

## 4. `SessionOptions`

值对象,4 字段。默认 `source=.manual, keepDisplayAwake=false, reason="Caff is keeping this Mac awake"`。

无业务逻辑,无需专门测试。

---

## 5. `WakeSession`

**公开 API**:
- `init(options:startedAt:activeAssertions:errorMessage:endDate:)`
- `func updatingAssertions(_:keepDisplayAwake:errorMessage:) -> WakeSession`
- `var sourceLabel: String`
- `var assertionSummary: String`(按 sortOrder 排序,逗号分隔)
- `var compactStatus(now:)`(errorMessage 不空时 → "error",否则用 RemainingTimeFormatter)

**不变量**:
- `endDate` 默认为 `options.duration.endDate(from: startedAt)`,但可被 init 覆盖(用于 capped session)
- `updatingAssertions` 保留 source/duration/startedAt/endDate/reason,只更新断言集合/keepDisplayAwake/errorMessage

**等价类**:
- 普通 session:sourceLabel=源标签,assertionSummary=断言展示名按顺序
- 错误 session:compactStatus="error"
- capped session:endDate=policy.effectiveEndDate

---

## 6. `SessionHistory` / `SessionHistoryEntry` / `SessionHistoryResult`

**公开 API**:
- `enum SessionHistoryResult`: `.stopped` / `.timedOut` / `.policyStopped` / `.error`
- 自定义 `Codable`:**兼容 `"exited"` 旧名映射到 `.stopped`**,未知 result 抛 `dataCorruptedError`
- `struct SessionHistoryEntry`:JSON 序列化所有 session 关键字段
- `init(session:endedAt:result:errorMessage:)` 从 WakeSession 派生

**不变量**:
- assertionKinds 按 sortOrder 排序后展示
- `summary == "{result.label}: {source} - {durationLabel}"`

**等价类**:
- 正常 JSON 编解码往返
- 旧 `"exited"` → `.stopped`
- 未知 result → 抛 `DecodingError.dataCorruptedError`

---

## 7. `AgentHookManager`

**公开 API**:
- `init(homeDirectory:executablePath:cooldownSeconds:)`
- `func install(targets:) throws -> [AgentHookChange]`
- `func remove(targets:) throws -> [AgentHookChange]`
- `func configURL(for:) -> URL`

**不变量**:
- install 幂等(再装一次 changed=false)
- 保留所有非 Caff hooks
- claude 需要 `matcher: "*"`,codex 不需要
- shell escape 用单引号包裹(单引号转义为 `'\''`)

**等价类**:
- 空文件 → 正常写入
- 已有非 Caff hook → 保留
- 已有 Caff hook(同 source)→ 不重复(幂等)
- 已有 Caff hook(不同 source)→ 保留不删
- 缺目录 → 自动创建
- 非法 JSON → 抛 `invalidJSON`
- 根节点非 object → 抛 `unsupportedRoot`

---

## 8. `AgentActivityCooldown`

**公开 API**:
- `static let defaultCooldownSeconds = 1_800`
- `static func policyDurationMinutes(cooldownSeconds:) -> Int`(max(1, seconds/60))
- `static func cappedCooldownEndDate(lastActivityAt:cooldownUntil:maximumSessionMinutes:) -> Date`
- `static func touch(source:cooldownSeconds:now:) -> AgentActivityState`
- `static func evaluate(state:now:) -> AgentActivityEvaluation`

**不变量**:
- `normalizedSource`:trim 空白;空字符串 → "agent"
- `evaluate(state: nil)`:isKeepingAwake=false,所有字段 nil/0
- `evaluate` 过期时 remainingSeconds=0,source/lastActivityAt/cooldownUntil **仍保留**(用于显示)
- `cappedCooldownEndDate`:取 min(cooldownUntil, lastActivityAt + maxMinutes)

**等价类**:
- policyDurationMinutes: 0→1, 59→1, 60→1, 1800→30, 3599→59, 3600→60
- evaluate nil: 全零状态
- evaluate 活跃: 29m/s 之类的 summary
- evaluate 过期: summary="Agent activity idle",isKeepingAwake=false
- normalizedSource: " codex "→"codex", "" → "agent", "codex"→"codex"

---

## 9. `RemoteControlParser`

**公开 API**:
- `static func duration(minutes:) throws -> SessionDuration`
- `static func source(_:) throws -> SessionSource`
- `static func cooldownSeconds(_:) throws -> Int`
- `static func bool(_:) -> Bool`

**不变量**:
- `duration` 空/nil → `.indefinitely`;非正整数 → `invalidDuration`
- `source` 空/nil → `.cli`;非枚举值 → `invalidSource`
- `cooldownSeconds` 空/nil → default(1800);非正整数 → `invalidCooldownSeconds`
- `bool`:`"1"/"true"/"yes"/"on"`(不区分大小写)→ true;其它 → false

**等价类**:
| 输入 | duration | source | cooldown | bool |
|---|---|---|---|---|
| nil | .indefinitely | .cli | 1800 | false |
| "" | .indefinitely | .cli | 1800 | false |
| "0" | throw invalidDuration | — | — | — |
| "-5" | throw | — | — | — |
| "45" | minutes=45 | — | — | — |
| "manual" | — | .manual | — | — |
| "url" | — | .url | — | — |
| "process" | — | throw | — | — |
| "60" | — | — | 60 | — |
| "0" | — | — | throw | — |
| "true" | — | — | — | true |
| "YES" | — | — | — | true |
| "1" | — | — | — | true |
| "garbage" | — | — | — | false |
