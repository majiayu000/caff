# Spec — Caff 测试飞轮完整闭环

> 日期:2026-06-02
> 范围:caff 仓内,5 个新增/改动,1.5-2 天工作量
> 不在范围:aitest-kit 本体、待测系统业务代码(coupon_system 风格)

## 1. 目标

把当前"知识库 + 测试 + 报告"三件套升级到**五件套闭环**:

```
L1 知识库 ──(drift 检查)──> 源码改动触发警告
   │
   ↓
源码 + Tests ──(CI 跑 swift test)──> 报告
   │
   ↓
失败分类 ──(渲染进 report.md)──> 分类摘要
   │
   ↓
IOKit 抽象 ──(fake backend 测失败路径)──> PowerAssertionController 失败路径覆盖
```

每一项都有显式 verify_cmd(U-25 协议:构建红灯下不写新代码)。

## 2. 改动清单(5 项)

### 2.1 Phase 1:scripts/check_drift.sh(必做)

**改什么**:
- 新建 `scripts/check_drift.sh`
- 解析 `Sources/CaffCore/*.swift` 的 public 符号
- 对照 `docs/knowledge/L1_modules.md` 的模块表
- 输出"未在 L1 出现的 public 符号"清单 + exit code

**为什么**:知识库不被代码读就会默默腐烂,1 周后新人看到过期契约比没文档更糟。

**影响文件**:
- `scripts/check_drift.sh`(新建,~80 行)
- 后续维护:L1 文档(人写,脚本只报警不写)

**接口**:
```bash
scripts/check_drift.sh           # 全量检查
scripts/check_drift.sh --changed # 只对 git diff 触及的 .swift 跑
# 退出码: 0 = 全部覆盖, 1 = 有未覆盖 public 符号, 2 = 解析错误
```

**不影响**:
- 业务代码
- 已有的 render_report.sh
- 测试

**verify_cmd**:
```bash
bash scripts/check_drift.sh && echo "drift clean"
# 故意引入一个未文档化的 public func 到 test fixture,跑 check_drift.sh,期望 exit 1
```

### 2.2 Phase 2:.github/workflows/test.yml(必做)

**改什么**:
- 新建 `.github/workflows/test.yml`
- 触发:push / pull_request
- runner:macos-14(macOS-only 项目)
- 步骤:checkout → swift build → swift test --parallel → render_report.sh → upload-artifact

**为什么**:本地测试可能在 macOS 15 上跑、CI 在 14 上跑,有差异,CI 才是真实地板。

**影响文件**:
- `.github/workflows/test.yml`(新建,~30 行)
- 现有 `.github/` 目录(目录已存在,新加文件)

**接口**:标准 GitHub Actions workflow,无需 caff 侧接口。

**不影响**:任何源码,纯加文件。

**verify_cmd**:
```bash
# 本地干跑(无法跑真 macos runner,但 lint 工作流语法)
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))"
# 真验证:push 到 fork 的分支看 Actions 是否绿
```

### 2.3 Phase 3:失败结构化分类(推荐)

**改什么**:
- 改 `scripts/render_report.sh`
- 解析 swift test 输出中每个 ✘ Test 的名字
- 按命名约定归类(借鉴 aitest-kit 7 类)
- 写入 `summary.json.failures_by_class`

**为什么**:75 个测试全绿没用,真正出 bug 时需要秒级判断"是哪类错"。

**影响文件**:
- `scripts/render_report.sh`(增强 ~40 行,变成 ~160 行)
- `docs/reports/<date>/summary.json`(新增字段 `failures_by_class`)
- `docs/reports/<date>/report.md`(新增分类小节)

**分类规则**(简单可解释):
| 测试名包含 | 分类 | 理由 |
|---|---|---|
| `Rejects*` / `Refuses*` / `ErrorContains*` | `EXPECTED_FAILURE` | 故意验证函数抛错 |
| `WithInvalid*` / `*NonNumeric` | `EXPECTED_FAILURE` | 故意验证入参校验 |
| `*RejectsUnknown*` / `*DataCorrupted*` | `EXPECTED_FAILURE` | 反序列化错误路径 |
| `AgentHookManager*`(用 tmp 目录) | `TEST_SCAFFOLD` | fixture 类问题 |
| `*PowerAssertion*`(已实现) | `IO_BACKEND` | 走真实 IOKit |
| 其他 ✘ | `ASSERTION_FAILURE` | 真 bug |

**不影响**:
- 测试代码
- 源码

**verify_cmd**:
```bash
# 在某测试函数里临时加 XCTAssert(false) 之类的,跑脚本,期望 failures_by_class 含 ASSERTION_FAILURE
# 再加一个测试命名为 "remoteControlDurationRejectsGarbage",期望 EXPECTED_FAILURE
```

### 2.4 Phase 4:.githooks/pre-commit(必做)

**改什么**:
- 新建 `.githooks/pre-commit`(可执行)
- git commit 时跑 `scripts/check_drift.sh`
- 有未覆盖 public 符号 → 提示 + 询问 `git commit --no-verify` 跳过

**为什么**:CI 报警太晚(已经 push),本地 commit 时拦截更便宜。

**影响文件**:
- `.githooks/pre-commit`(新建,~15 行)
- `README.md`(新增"启用 git hooks"一段,~10 行)

**接口**:
```bash
git config core.hooksPath .githooks  # 一次性配置
```

**不影响**:
- 任何源码
- caff.exe / caff.app 行为

**verify_cmd**:
```bash
# 故意 commit 一个引入新 public func 的改动,期望 hook 阻断
# 再 commit --no-verify,期望通过
```

### 2.5 Phase 5:IOKit 注入抽象(必做,高风险)

**改什么**:
- 在 `Sources/CaffCore/` 引入 `IOPowerAssertionBackend` protocol
- 新增 `SystemIOPowerAssertionBackend`(真实 IOKit 包装)
- 在测试 target 新增 `FakeIOPowerAssertionBackend`(测试用,可控 create / release 返回值)
- `PowerAssertionController` 改用 backend,init 接受 backend 参数
- 更新所有 call site(`Sources/caff/` 下的 `PowerAssertionController()` 调用)
- 新增测试覆盖 `createFailed` / `cleanupAfterCreateFailed` / `releaseFailed`

**为什么**:目前 `PowerAssertionController` 直接调 IOKit,失败路径不可测。这是可测性缺口。

**影响文件**:
- `Sources/CaffCore/PowerAssertionController.swift`(重写 ~50 行)
- `Sources/CaffCore/IOPowerAssertionBackend.swift`(新建,新协议 + 真实系统实现,~35 行)
- `Sources/caff/` 下所有 `PowerAssertionController()` 调用点(预计 2-4 个文件,AppDelegate 系列)
- `Tests/CaffCoreTests/PowerAssertionControllerFakeBackendTests.swift`(追加 fake backend + 失败路径测试)
- `docs/knowledge/L1_modules.md`(更新 PowerAssertionController 章节,新增 backend 说明)

**API 兼容性**:
- **breaking change**:`PowerAssertionController.init()` 签名变化
- **降级方案**:提供默认参数 `init(backend: IOPowerAssertionBackend = SystemIOPowerAssertionBackend())`,所有现有 call site 不传参数即可,源代码层零修改
- 这条降级方案让 breaking change 在源码调用点变成 non-breaking,**但 protocol 是 public,如果有外部 caff 用户也用了 PowerAssertionController,需要走 SemVer 主版本号**

**接口**:
```swift
public protocol IOPowerAssertionBackend: Sendable {
    func createAssertion(type: CFString, level: IOPMAssertionLevel, reason: CFString) -> (IOReturn, IOPMAssertionID)
    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn
}

public struct SystemIOPowerAssertionBackend: IOPowerAssertionBackend { ... }

public final class PowerAssertionController {
    private let backend: IOPowerAssertionBackend
    public init(backend: IOPowerAssertionBackend = SystemIOPowerAssertionBackend()) {
        self.backend = backend
    }
    // ...
}
```

**不影响**:
- 其它 CaffCore 模块
- 测试文件(只追加,不删)
- CHANGELOG(破坏性变更需要 CHANGELOG,但因为有默认参数兼容,可记录为"feature")

**verify_cmd**:
```bash
swift build
swift test
# 新增 5+ 个测试覆盖:
#   - createFailed 抛 PowerAssertionError.createFailed
#   - releaseFailed 抛 PowerAssertionError.releaseFailed
#   - cleanupAfterCreateFailed 嵌套错误
#   - backend 被正常调用计数
swift test --filter "powerAssertion"
```

## 3. 顺序与依赖

```
Phase 1 (drift)  ──┐
                    ├──> Phase 2 (CI) 把全部串起来
Phase 5 (IOKit)  ──┤
                    │
                    ├──> Phase 3 (分类) 依赖 1+5(否则没新失败路径可分类)
                    │
                    └──> Phase 4 (hook) 包装 1
```

实际执行顺序:**1 → 2 → 3 → 4 → 5**,理由:
- 1 + 2 风险最低,价值最高
- 3 改 render_report.sh,在 1 + 2 基础上扩
- 4 用 1 的产物
- 5 最大,放最后,前面有进展可以提早停下

## 4. 验收标准

| 项 | 验证 |
|---|---|
| 75+ 个 swift test 全绿 | `swift test` exit 0 |
| check_drift.sh 通过 | `bash scripts/check_drift.sh` exit 0 |
| render_report.sh 端到端 | 跑出 docs/reports/<date>/{log.txt,summary.json,report.md},含 failures_by_class |
| CI workflow 语法合法 | `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))"` 不抛 |
| pre-commit 钩子可执行 | `git config core.hooksPath .githooks` 后,故意 commit 触发,期望提示 |
| IOKit 抽象不破现有 | 现有 75 个测试不改一行,继续全绿 |
| IOKit 抽象新增覆盖 | `swift test --filter "fakeBackend\|createFailed\|releaseFailed\|cleanupAfter"` 全绿,新增 ≥5 个测试 |

## 5. 不在范围(明确排除)

- ❌ 改 aitest-kit 本体
- ❌ 把 caff 接入 codegen 链路
- ❌ 重写 render_report.sh 用 Swift(保持 bash + python)
- ❌ 把 5 项合并为 1 个 PR(每项独立可审,Phase 5 单独一个 commit)
- ❌ 添加新 Swift 依赖(用 Foundation/IOKit/AppKit 标准库)

## 6. 回滚方案

每项独立可回滚:
- Phase 1:删 `scripts/check_drift.sh`
- Phase 2:删 `.github/workflows/test.yml`
- Phase 3:git revert 该 commit
- Phase 4:`git config core.hooksPath` 改回默认
- Phase 5:revert 即可,新文件 IOPowerAssertionBackend.swift 一并删,旧 PowerAssertionController 恢复
