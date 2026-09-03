# Task 2 report — durable legacy migration plan replay

## 结论与范围

Task 2 已按 successor plan 完成，implementation commit 为 `148f6ee`
（`fix: persist legacy product migration plan`），基线为 Task 1 复审通过后的 `bc0441d`。
本任务只修改 6 个实现/测试文件：

- `src/persistence/modules/InstallFileTransaction.psm1`
- `src/persistence/modules/ProductRegistration.psm1`
- `src/persistence/modules/InstallLifecycle.psm1`
- `tests/persistence/InstallFileTransaction.SelfTest.ps1`
- `tests/persistence/ProductRegistration.SelfTest.ps1`
- `tests/persistence/InstallLifecycle.SelfTest.ps1`

没有执行真实 registry、shortcut、scheduled task、安装、卸载、进程重启、系统重启、网络、push、
tag、release 或发布操作；device-key/DPAPI state 未触碰。所有破坏性边界仅在独立临时 fixture
中模拟，wrapper 的安装路径只执行 `WhatIf`。

## 根因与 RED

旧实现只把完整历史 profile 保存在调用栈内。第一次 current registration 若已替换一个或两个与
v2.5.21 重叠的 `.lnk`，第二个进程重新执行 live capture 时会把 current/historical 混合态当成
不完整历史 profile，永久返回 `CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID`。

production 未修改时，首组 production-shaped RED 的实际结果为：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
exit 1
case=second-registration-recovers-from-partial-current-overlap-writes-only-through-a-durable-pre-capture-plan
expected=DesktopWrite:Recovered|CurrentReadBack:Recovered
actual=DesktopWrite:CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID|CurrentReadBack:CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID
```

专用 IFT wishful API 的 RED 首错为 export surface 缺少
`Read/Write-CcodInstallLegacyMigrationPlan`。真实 lifecycle RED 在 v2.5.21 -> v2.5.22 入口命中
`state\legacy-registration-migrations` `PathNotFound`，证明 orchestration 尚未持久化计划。

自审再得到三项有效 RED：

- registry 已删除而 legacy-only shortcuts 仍在时，second replay 错误返回
  `legacyPresent=False`，会永久遗留旧快捷方式；
- Ready proof generation 与 transaction generation 不一致时，旧 matcher 没有拒绝；
- live ProductTransaction 内刚发布的 plan 可被移动替换，`expected moved=False, actual=True`。

oversized historical leaf、ACL/ADS/multilink/reparse、partial cleanup、foreign replacement 与四种
overlap 组合在同一 RED/hostile 批次加入；最终均由下述 focused/final gate 覆盖。

## 实现

### IFT V6 专用能力

ABI 升为 V6，仅新增两个固定用途 export；没有导出可读任意 state leaf 的通用 reader。

- 固定目录：`state\legacy-registration-migrations`；
- 固定叶：`<20-digit Ready generation>.<Ready transactionId>.json`；
- 每次读写都要求 exact ProductTransaction root、live `AccountTransition` lease、durable Pending
  cleanup fence，并在锁内重读完整 selector/manifest/persisted Ready authority；
- write 为 no-replace create-only，最大 1 MiB；read 使用相对目录 native handle；
- plan 目录与文件使用 protected exact ACL：current SID、SYSTEM、Administrators 三项 FullControl，
  owner 为 current SID；延迟读取在同一 native handle 上复验 ACL/owner；
- 拒绝 reparse、ADS、multilink、路径/对象 identity 变化；刚发布的 plan handle 保持到 product
  transaction close，replacement 在 live proof-to-use 区间被阻止；
- generic product state directory/write surface 仍保持拒绝。

### canonical durable schema 与 replay

schema v1 固定并按顺序绑定：

`schemaVersion, transactionId, runtimeId, runtimeGeneration, manifestSha256, packageSha256,
readyTransaction, appId, expectedInstallRoot, legacyPresent, legacyRegistration, profile, snapshot,
expectedCurrentProof`。

历史 snapshot 保存 exact registry values/kinds，以及每个 shortcut 的 canonical path、原始 bytes、
length-bound hash、target、arguments、working directory；单个历史 shortcut 限制为 1..262144 bytes。
`expectedCurrentProof` 额外绑定 version/runtime/package 和两个 current shortcut 的 canonical
destination、candidate path/length/SHA、target、arguments、working directory。该 proof 只取首次
持久记录，后续进程不以新生成候选替换它。

reader 要求 strict UTF-8、所有 object 无 duplicate properties、完整 exact field set、canonical JSON
bytes 与 1 MiB 总界限；Ready transaction/runtime/generation/manifest/package 会交叉匹配，而不仅比较
单个 hash。

已有 exact plan 的 second process 逐项分类 overlap：captured historical exact 或同一 persisted
current proof exact；HH、CH、HC、CC 四态都收敛，foreign/missing required overlap 拒绝。没有 plan 的
washed hybrid 仍在 plan/current write 前失败。

legacy-only cleanup 也按 durable snapshot 做 `Absent=already done / Exact=delete / Mismatch=fail`。
因此 registry-first 删除后在 0/1/2 个 legacy-only 删除边界崩溃，second process 都只继续剩余 exact
项；registry present 的 partial shortcut 边界也可收敛；foreign replacement 零删除拒绝。registry
absent 不再被当成整个 cleanup 已完成。

### Lifecycle 接线

`RegisterProduct` 在既有 Local/Global 顺序和 cleanup fence 内打开同一个 owned ProductTransaction，
先读取或发布并 read-back exact durable plan，之后才允许 current registry / StartMenu / Desktop 写入。
second `Invoke-CcodInstall` 使用新 fake adapters、丢弃所有进程内 plan，并从同一磁盘叶在
`AlreadyInstalled` 路径恢复；不会新增 runtime 或 selector。

## 负例与故障边界

最终 focused tests 覆盖：

- Desktop write 前（StartMenu 已替换）与 current read-back（两项已替换）跨调用恢复；
- HH、CH、HC、CC 四种独立 overlap；
- no-plan washed hybrid、tampered current proof、wrong Ready/package/generation、duplicate JSON、
  unsafe path、foreign hybrid；
- Ready proof/transaction generation、manifest、package 内部不一致；
- historical shortcut 262145-byte rejection；
- registry-first 0/1/2 legacy-only partial deletion、registry-present partial deletion与 foreign tail；
- IFT wrong scope/Ready/fence、oversized record、collision、live replacement、file/directory ACL、ADS、
  multilink、file/directory reparse；
- disk plan leaf/schema/Ready identity，以及真实 lifecycle 新进程形态的 second invocation。

## frozen final gate

source 冻结后顺序执行，结果如下：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1
  41 named test groups; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
  Product registration self-tests passed: 28; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
  Install lifecycle self-tests passed: 151; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1
  Uninstall bootstrap self-tests passed: 45; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1
  21 named test groups; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1
  21 named test groups; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\Bootstrap.SelfTest.ps1
  Bootstrap self-test passed: 26; exit 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ManualWrappers.SelfTest.ps1
  12 named test groups; exit 0

PowerShell parser: 6/6 changed files, 0 errors
git diff --check: exit 0 (仅 checkout LF/CRLF conversion warning)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1
  exit 0; success path is silent
```

Lifecycle 的既有 cross-process guard 仍输出：
`exit=23 mutex=True authority=False product=False verified=False error=CCOD_PRODUCT_REGISTRATION_FAILED`。

## 边界

Task 2 与 successor plan 的本地 final gate 已完成；fresh scoped review 仍待 parent agent 发起。
本报告不声明 Tasks 5–8、合并、发布或 release readiness 完成。
