# Task 1 report — same-SID new-session TaskRemoved recovery

## 结论与范围

Task 1 已按 successor plan 完成，implementation commit 为 `9973bfd`
（`fix: recover installed TaskRemoved across sessions`），基线为 `a5ffe4a`。
本任务只修改：

- `src/persistence/UninstallBootstrap.ps1`
- `tests/persistence/UninstallBootstrap.SelfTest.ps1`

Task 2 未开始、未修改。本任务没有执行真实 registry、shortcut、scheduled task、安装、卸载、
进程重启、系统重启、网络、push、tag、release 或发布操作；device-key/DPAPI state 未触碰。

## 根因与 RED

旧实现对所有 existing transaction 先调用 generic
`Assert-CcodUninstallBootstrapTransactionMatchesContext`。该 matcher 正确要求 session ID 相同，
但也因此在一个精确、已到 `TaskRemoved` 的 installed transaction 上，拒绝同 SID 的新登录
session，尚未进入 replacement-wrapper 持久化分支。

production-shaped RED 使用：durable transaction session `1`、fresh verified context session `99`、
相同 SID、exact `TaskRemoved`、完整 installed binding、尚无 Apps recovery anchor，以及 exact 新
wrapper identity。production 未修改时实际结果：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
exit 1
case=same-SID-new-session-TaskRemoved-replacement-persists-a-fresh-wrapper-without-rerunning-cleanup
error=CCOD_UNINSTALL_TRANSACTION_MISMATCH
The existing uninstall transaction does not match the current verified runtime
```

栈命中真实 generic context matcher，不是 adapter/setup 失败。

## 实现

generic matcher 与 `New-CcodUninstallBootstrapResumeContext` 继续严格匹配 SID + session；只有
`PrepareInstalled` 的 exact `TaskRemoved` installed transaction 进入新专用 matcher。

专用路径在既有 Local uninstall -> Global `AccountTransition` 顺序取得两把锁后：

1. 再次执行真实 `ValidateInvocation`，获得 fresh runtime/selector/Ready/manifest/epoch proof；
2. 要求 transaction ID/current locator、SID、runtime ID、generation、epoch、完整 Ready evidence、
   payload records、selected runtime path、staged resume path/hash 与 immutable installed binding
   全部一致；唯一允许不同的是 fresh context session；
3. 保留 `transaction.sessionId` 与 historical `wrapper*`，只写 exact `resumeWrapperPid`、
   `resumeWrapperCreationTimeUtc`、`resumeWrapperSessionId`、`resumeWrapperUserSid`；
4. 原子写 transaction 后锁内重读完整 transaction，再写并重读 exact TaskRemoved receipt；
5. 直接返回 verified existing TaskRemoved，绝不再次调用 `RunCleanup`。

若该专用 transaction/receipt 持久化或 read-back 失败，generic catch 不把 historical TaskRemoved
改写为 Failed。普通 pre-TaskRemoved、不同 SID 或 runtime/generation/epoch/Ready/payload mismatch
仍走 strict failure boundary。

public runtime wrapper 随后使用已存在的 `-WrapperResume` 参数集；finalizer 必须匹配并等待新持久化
的 PID/creation/session/SID exact identity，之后才允许 generation reclamation。测试还覆盖第一次
external finalizer start 失败、没有 anchor，第二次同 SID session 99 public invocation 成功持久化
replacement wrapper 并完成 exact wait。

## TDD 与负例

最终 self-test 新增/强化：

- same-SID session 1 -> 99 exact TaskRemoved GREEN；fresh validation 调用两次，第二次位于
  AccountTransition acquisition 之后；
- existing TaskRemoved `RunCleanup` 调用数保持 `0`；historical session/PID 不变；
- DifferentSid、Runtime、Generation、Epoch、Ready、Payload、PreTaskRemoved 七项全部零 transaction /
  receipt write、零 cleanup；
- WrapperResume 的 PID、creation time、session、SID 四项 mutation 在 wait/reclaim 前拒绝；
- finalizer-start failure 后的新 session replacement path 等待的确切 identity 为 PID `43`、
  creation `2030-02-03T03:04:06.0000000Z`、session `99`。

## 最终验证

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
  Uninstall bootstrap self-tests passed: 40
  exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
  Manual wrapper self-tests passed
  exit 0
```

`src/persistence/UninstallBootstrap.ps1` 与
`tests/persistence/UninstallBootstrap.SelfTest.ps1` 的 PowerShell parser 均为 `0 errors`；
`git diff --check` exit 0，仅有 checkout LF/CRLF conversion warning。

## 边界

本报告不声明 Task 2、successor plan final gate、fresh scoped review 或 release readiness 完成。
Tasks 5–8 继续 blocked。

## Fix round 1 — Failed/TaskRemoved 与 durable freshness

### Review findings 与 RED

scoped review 对 `9973bfd` 判定 FAIL（1 Critical、3 Important）。本轮在 production 未修改时
得到四组有效 RED：

```text
Disk-backed real runtime:
  ASSERT_TRUE: replacement persistence advances updatedAtUtc strictly

Failed(resumePhase=TaskRemoved):
  same session actual=CCOD_UNINSTALL_PREPARE_FAILED cleanup=1
  new session  actual=CCOD_UNINSTALL_TRANSACTION_MISMATCH cleanup=0

Historical wrapper binding:
  HistoricalSid / HistoricalSession did not throw CCOD_UNINSTALL_TRANSACTION_INVALID

Freshness:
  stale prior TaskRemoved receipt did not throw CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED
```

其中 disk-backed RED 使用真实 v2.5.22 runtime manifest、七代 append-only selector、canonical
`Prepared -> ... -> Ready` install transaction、真实 lifecycle epoch 与完整 payload records；external
transaction/receipt 通过 production atomic writer 写入受保护临时目录，并由 production reader 形成
独立反序列化对象。唯一替换的是 current-session seam 和禁止误入 cleanup 的 adapter。

### Fix

实现提交：`bf939c6`（`fix: harden TaskRemoved replacement recovery`）。

- 专用 candidate 同时接受 exact `TaskRemoved` 与 exact
  `Failed(resumePhase=TaskRemoved)`；后者在持久化前规范化回 TaskRemoved，清空 errorCode，
  same/new session 均不进入 `RunCleanup`。
- 每次 replacement persistence 必须从 adapter 获取 canonical UTC，且严格晚于 prior
  `updatedAtUtc`；transaction 与 TaskRemoved receipt 精确绑定该新 timestamp。
- receipt 比较显式区分 `null` 与空字符串；stale/null/malformed receipt、transaction no-op、
  transaction/receipt write failure、stale/malformed transaction read-back 均返回
  `CCOD_UNINSTALL_TRANSACTION_WRITE_FAILED`。
- historical `wrapperUserSid` 必须等于 transaction SID，historical `wrapperSessionId` 必须等于
  transaction session；不一致时在任何 replacement write 前拒绝。
- transaction write 后及 receipt write 后都从 durable adapter 重新读取；专用恢复失败不把原
  TaskRemoved 另写成 Failed。receipt write 中断后，下一次 exact wrapper 可写入更晚 timestamp、
  替换仅 `resumeWrapper*` 并收敛。

### Fix round 1 tests

新增/强化覆盖：

- real disk-backed verified-runtime / transaction / receipt independent deserialization；
- Failed/TaskRemoved same session 与 session 99 两条 early-return；
- historical SID/session zero-write negatives；
- DifferentSid、runtime、generation、epoch、Ready、payload、pre-TaskRemoved negatives；
- stale receipt、empty error、null receipt、transaction no-op/write failure/stale/malformed read-back、
  receipt write failure/malformed receipt；
- interrupted receipt write 后的新 wrapper retry；
- WrapperResume PID/creation/session/SID exact-wait matrix。

最终无过滤验证：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
  Uninstall bootstrap self-tests passed: 45
  exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
  Manual wrapper self-tests passed
  exit 0
```

两个修改文件 parser 均为 `0 errors`；`git diff --check` exit 0，仅有 LF/CRLF checkout warning。
未执行任何真实系统或外部操作。Task 2 未修改、仍 pending；本报告不作 final-gate 或 release
readiness 声明。
