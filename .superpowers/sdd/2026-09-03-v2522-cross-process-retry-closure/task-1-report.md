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
