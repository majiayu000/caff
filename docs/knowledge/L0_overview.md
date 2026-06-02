# L0 — Caff 系统全景

## 用途

Caff 是一款 macOS 菜单栏小工具,职责单一:**让 Mac 在跑长任务时不进入睡眠**。它通过 IOKit 的两个电源断言 API 实现:

- `PreventUserIdleSystemSleep` — 阻止因用户空闲导致的系统睡眠
- `NoDisplaySleepAssertion` — 阻止显示器进入睡眠(可选)

## 三种使用模式

| 模式 | 触发 | 适用 |
|---|---|---|
| **Manual** | 菜单栏按钮(30 分钟 / 1 小时 / 4 小时) | 已知时长的任务 |
| **Agent** | agent-touch CLI 配合 hook | 长跑 agent(Codex / Claude) |
| **CLI / URL** | `caff start ...` / `caff://...` | 脚本与跨进程控制 |

## 模块全景(CaffCore)

| 模块 | 职责 | 关键不变量 |
|---|---|---|
| `PowerAssertionController` | 包装 IOKit 电源断言 | start/stop 幂等;deinit 兜底释放 |
| `SafetyPolicy` | 决定哪些 session 允许在电池下跑 | 电池+长 session+未允许 ⇒ 拒绝 |
| `SessionDuration` | 时长值对象 + 时间格式化 | 4 个 preset;Indefinitely=nil |
| `SessionOptions` | session 入参(时长+源+reason) | 普通值对象 |
| `WakeSession` | 运行时 session 状态 | 由 options 派生;断言集合可演进 |
| `SessionHistory` | 历史记录(持久化用) | JSON 编解码;兼容 `exited` → `stopped` |
| `AgentHookManager` | 安装/移除 Codex/Claude 的 hook | 幂等;不破坏已有非 Caff 配置 |
| `AgentActivityCooldown` | agent-touch 冷却窗口 | 默认 1800s;空 source → "agent" |
| `RemoteControlParser` | 解析 CLI/URL 入参 | 严格模式(负数/未知值抛错) |

## 失败分类(借鉴 aitest-kit 思想)

| 分类 | 含义 | 例子 |
|---|---|---|
| `PRECONDITION_MISSING` | 运行环境不具备(AC 电源缺失等) | 电池下请求 4 小时未允许 |
| `ENVIRONMENT_ERROR` | 系统调用失败 | IOKit 断言创建失败 |
| `ASSERTION_FAILURE` | 行为契约违反 | session 提前超时 |
| `INVALID_INPUT` | 入参校验失败 | 负数 minutes、未知 source |

## 飞轮(简化版,无 codegen)

```
代码 / 文档
  ↓
knowledge-build  ←  本仓 docs/knowledge/L1 + L2
  ↓
test-audit      ←  对比 L2 等价类清单与现有 Tests/ 覆盖度
  ↓
test-write      ←  缺失等价类直接补 XCTest
  ↓
swift test      ←  本地验证
  ↓
scripts/render_report.sh  ←  渲染 Markdown 报告
```
