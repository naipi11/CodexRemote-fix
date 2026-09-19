# Final fix wave report — legacy proof ordering and reclamation tail recovery

## 结论与范围

本计划唯一一次 final-review fix wave 已实现，implementation commit 为
`58db6fd`（`fix: close legacy upgrade recovery gaps`），基线为 `6b9bc7e`。
本轮只修改 5 个 production PowerShell 文件和 3 个 self-test 文件；没有执行真实
registry、shortcut、scheduled task、安装、卸载、进程重启、系统重启、网络、push、tag、
release 或发布操作。

本报告只声明 final-fix implementation 与本地验证结果。独立 scoped re-review 仍是单独
gate；原 release plan Tasks 5–8 仍保持 blocked，本报告不作 release-readiness 声明。

## Finding 1：selector commit 成功但 PointerCommitted journal 丢失

### RED

新增真实 legacy migration 失败点：generation-two selector 通过真实
`Set-CcodActiveRuntime` commit/read-back 后、`PointerCommitted` snapshot append 前抛错。
第一次尝试留下 canonical `1 old -> 2 failed-new -> 3 old` selector，transaction 中有
`RuntimePromoted`、无 `PointerCommitted`，terminal head 为 `Failed`。第二次同包调用的实际
RED 为：

```text
InstallLifecycle.SelfTest.ps1 -> exit 1
case=real-v2.5.21-selector-commit-with-a-missing-PointerCommitted-journal-resumes-the-exact-retained-runtime
error=CCOD_INSTALL_UPGRADE_SOURCE_INVALID
Failed migration phases do not match the exact selector profile
```

### GREEN

`PostPointerCompensated` 现在可由 exact three-record selector compensation 与同一 immutable
transaction identity / `RuntimePromoted` proof 分类，不再把 journal snapshot 当作唯一 pointer
commit proof。普通 pre-pointer 或任意 `RuntimePromoted -> Failed` 链仍不能进入该分支；selector、
transaction、manifest、package 或 foreign-chain 变异继续在新 mutation 前失败。重试复用同一
generation-two runtime，并只追加 generation-four Ready。

## Finding 2：current overlap write 洗掉 legacy profile 缺陷

### RED

production-shaped lifecycle fixture 模拟 current shortcut write 会补齐 missing overlap 并替换
foreign same-name leaf。未修复顺序在 `MissingMain` 首个 zero-write 断言的实际结果为：

```text
InstallLifecycle.SelfTest.ps1 -> exit 1
case=legacy-profile-is-captured-before-any-current-product-or-shortcut-write
ASSERT_EQUAL: MissingMain is rejected before the current registry write expected=[0] actual=[1]
```

同一 table 同时覆盖 missing Desktop 与 foreign main target/arguments/working-directory。

### GREEN

新增 mandatory pre-registration migration plan。它在任何 current registry/shortcut write 前：

- 解析一个完整 checked-in historical profile；
- 绑定 AppId、DisplayVersion、InstallLocation 与 quoted Inno uninstall command；
- 捕获 registry values/kinds 和每个 shortcut 的 canonical path、bytes、SHA-256；
- 按对应历史版本校验 target、arguments 与 working directory。

current registration read-back 后，cleanup 只消费此前 captured plan；overlap 只在 exact current
proof 下保留，legacy-only entry 删除前逐项 unchanged re-read，删除后再次验证同一 current proof。
registry compensation 继续使用 same-handle / create-only、replacement-safe 路径。missing main、
missing Desktop 和 foreign same-name 三项均在 current writes 为 0 时失败。

## Finding 3：irreversible generation reclamation 后的尾段不可恢复

### RED

四个 post-reclaim failure injection 均先成功使 selected generation absent，再执行第二次调用。
未修复实现的实际结果为：

```text
PhaseWrite      -> CCOD_INSTALLED_FINALIZER_INVALID, phase=TaskRemoved
ProductShortcuts -> CCOD_INSTALLED_FINALIZER_INVALID, phase=ReadyForInno
FinalReceipt    -> CCOD_INSTALLED_FINALIZER_INVALID, phase=ReadyForInno
FinalRegistry   -> CCOD_INSTALLED_FINALIZER_INVALID, phase=Completed
```

### GREEN

`PrepareInstalled` 现在把完整 staged payload record set、transaction/user、selected runtime /
manifest / epoch、historical wrapper、resume script path/length/SHA-256 和 exact resume command
写入 external transaction。generation reclaim 前，product `UninstallString` 先切到 staged
`InstalledUninstallFinalizer.ps1 -Resume`，随后写完整 recovery metadata 并 exact read-back；
old/new partial registry publish 可收敛，foreign mixed state 拒绝。

finalizer 顺序为：

1. preload 验证 current locator、transaction ACL/no-reparse、duplicate-free JSON 与完整 17-file
   staged payload length/SHA；
2. 依既有顺序取得 Local uninstall lock，再取得 Global `AccountTransition`，锁内重读 transaction；
3. 验证 caller SID、fixed InstallRoot、derived RuntimeRoot、Ready/manifest/epoch 与 exact command；
4. initial 或 replacement runtime wrapper 必须等待其 exact PID/creation/session/SID 退出；public
   staged `-Resume` 不复用旧 caller identity，但在 tree 仍存在时会证明 latest bound wrapper 已退出；
5. `TaskRemoved + present` 重新验证并 reclaim；`TaskRemoved + absent` 只有 exact write-ahead recovery
   anchor 才可推进；随后 durable `ReadyForInno`；
6. absent-or-exact 地清理 shortcuts，保持 Apps recovery registry；
7. 写并重读 `Completed` transaction 和 exact `Completed` receipt；transaction 已 Completed 而
   receipt 丢失时只补 receipt；
8. 最后通过 exact open registry handle 删除完整 recovery key，不先逐 value 删除。此后没有必需
   的 fallible write。已收敛的 serial replay 在 receipt exact 且 anchor absent 时为 no-op。

额外预审修复包括：existing `TaskRemoved` replacement `PrepareInstalled` 直接返回，不再重入
application cleanup；replacement wrapper identity 单独持久化且不改写 historical identity；同 SID
新登录 session 可恢复；epoch 在 reclaim 紧邻边界二次读取；Bootstrap 与 finalizer 均保持
Local -> Global lock acquisition order，避免 ABBA。

## 最终验证

最终源码冻结后运行：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
  Product registration self-tests passed: 24; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
  Install lifecycle self-tests passed: 150; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
  Uninstall bootstrap self-tests passed: 37; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
  37 declared cases passed; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
  21/21; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1
  21/21; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
  pass; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
  26/26; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1
  exit 0; successful aggregate intentionally emits no stdout summary
```

此外，8 个修改的 PowerShell 文件经 parser 检查均为 `0 errors`；`git diff --check` exit 0，
只有 checkout LF/CRLF conversion warning。测试只使用 GUID temp roots、内存 adapters、受控
child PowerShell 与 disposable registry doubles；未触碰真实 product/shortcut/task/install state。

## Review gate

请求以 `6b9bc7e..58db6fd` 为 implementation review range 做一次 scoped re-review，重点核对三项
原 Important、replacement-wrapper/AccountTransition 预审修复、完整 staged payload binding，
以及 Apps registry-last / Completed-receipt repair 顺序。该 review 未通过前不进入下一 wave 或
release claim。
