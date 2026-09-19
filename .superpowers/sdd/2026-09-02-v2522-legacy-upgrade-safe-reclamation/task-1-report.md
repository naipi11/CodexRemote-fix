# Task 1 报告：v2.5.21 legacy lifecycle upgrade bridge

## 结论

Task 1 已在隔离 worktree
`C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`
实现并通过要求的 focused tests。实现提交为
`5114a09953e2566b1127788ffbad115c11ae072f`（`fix: bridge legacy lifecycle upgrade`），
基线为 `2aef5ff2a74219a82e98fe26c2f8170a5232a280`。
review fix round 1 实现提交为
`52d3962b9bc91c91350317a148a145efdc9aa0c9`（`fix: resume failed legacy migration`）。

本报告不声称 Task 2/Task 3、整分支验收或 release readiness 已完成。

## 历史来源与 fixture

fixture 直接以 merge-base
`19803a79af3302c49f129e6a6b3ff7ffaf1b930b` 为格式来源：

- `active.json` 是严格 schema 2，字段顺序为
  `schemaVersion,activeRuntime,previousRuntime,generation,updatedAtUtc`；
- runtime manifest 是 schema 1，字段为
  `schemaVersion,projectVersion,runtimeId,files`；
- v2.5.21 runtime ID 使用旧的 `version-digest16` 两段式算法，digest 来自按
  ordinal path 排序后的 `path/length/sha256` manifest records，不含 v2.5.22 nonce；
- mutable activation receipt 位于 `state\post-install-activation.json`；
- fixture 不创建 `state\active-generation`、`state\install-transactions` 或
  `state\product-cleanup-fences`。

测试没有用“projectVersion 写成 2.5.21、但 runtime ID/Ready 仍是当前格式”的伪 legacy
fixture。另有显式负例拒绝带 v2.5.22 nonce 的 current-format v2.5.21 lookalike。

## 实现

新增私有分类接口：

```text
Get-CcodLegacyUpgradeCompatibilityContext
  -InstallRoot
  -ExistingPointer
  -ActiveValidation
  -GlobalTransaction
```

初始实现返回两种 `Kind`；fix round 1 增加第三种严格恢复分类：

- `CurrentReady`：append-only selector 与 transaction plane 均存在；selected pointer、
  valid current manifest、manifest SHA-256 和 canonical terminal Ready transaction 的
  runtime/generation 完全一致。此分支仍执行原 durable product-cleanup resolver。
- `ProvenLegacyWithoutReady`：三个新 plane 均有精确 ItemNotFound 证明；raw
  `active.json` 是上述严格 schema-2 generation-one 形状；active runtime tree/manifest
  通过 contained path、non-reparse、no-ADS、single-link 和 hash/file-set 校验；current
  validator 的唯一失败是 `CCOD_RUNTIME_ID_MISMATCH`；随后使用历史算法复算并精确得到
  v2.5.21 两段式 runtime ID。只有此分支跳过不存在的旧 Ready cleanup resolver。
- `LegacyMigrationRetry`：只接受一个已到 `RuntimePromoted` 的严格 v2.5.22 Failed
  transaction、仍完整有效的 failed runtime/manifest/package、无 cleanup fence，以及下列一个
  canonical selector profile。此分支复用 retained failed runtime，不创建另一个 runtime tree。

在真实 legacy upgrade 中，同一个 opaque file transaction 先打开 manifest-bound retained
legacy generation，并发布 generation-one selector genesis；普通新 runtime pointer 随后以
generation two 提交。旧 `active.json` 保持 byte-for-byte 不变，只作为迁移证据。成功路径会
写出 canonical Ready transaction；新 runtime 在 Ready 前失败时，旧 runtime 会被重新选择并
启动。

## TDD 证据

### 基线

- `InstallLifecycle.SelfTest.ps1`：129/129，exit 0。
- `InstalledLifecycleHarness.SelfTest.ps1`：20/20，exit 0。

### RED 1：真实旧 runtime ID

命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1
```

结果：exit 1。

```text
CCOD_SELFTEST_FAILED case=real-v2.5.21-legacy-lifecycle-state-upgrades-through-the-v2.5.22-install-entrypoint error=CCOD_INSTALL_RUNTIME_ACTIVATION_UNPROVEN
The active runtime manifest is invalid before upgrade
```

这比计划中预期的 null Ready resolver 更早：当前 validator 先拒绝旧两段式 runtime ID。
实现因此只接管 exact `CCOD_RUNTIME_ID_MISMATCH`，其他 validator failure 保持拒绝。

### RED 2：不可重建的 legacy generation

加入 generation two、但没有 append-only history 的 legacy pointer 后，命令 exit 1：

```text
ASSERT_EQUAL: legacy generation without reconstructable append-only history creates no immutable generation expected=[1] actual=[2]
```

分类随后收紧为 generation one，并在 staging 前拒绝无法安全重建历史的输入。

### RED 3：generation-one previousRuntime 不一致

加入 generation one 但 `previousRuntime` 非 null 的 lookalike 后，命令 exit 1：

```text
ASSERT_EQUAL: generation-one active pointer with a previous runtime uses the expected fail-closed boundary expected=[CCOD_INSTALL_UPGRADE_SOURCE_INVALID] actual=[]
```

raw legacy pointer 随后收紧为 generation one 且 `previousRuntime = null`。

### 最终 GREEN

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  -> `Install lifecycle self-tests passed: 140`，exit 0。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstalledLifecycleHarness.SelfTest.ps1`
  -> 21/21（含 exact checksum-bound v2.5.21 -> v2.5.22 adapted Upgrade），exit 0。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\RuntimeManifest.SelfTest.ps1`
  -> 21/21，exit 0。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
  -> 30/30，exit 0。
- PowerShell parser：3 个修改文件均 0 errors。
- `git diff --check`：exit 0。

Lifecycle 覆盖还包括：孤立 selector、无 Ready fence plane、schema-one active、
generation/history ambiguity、current-format lookalike、wrong manifest version、runtime junction，
均在 staging/task mutation 前失败；以及 pre-pointer 与 post-pointer 两类 Ready 前失败均恢复
旧 runtime。

## 无真实操作证明

- 所有 install roots、source roots、installer bytes 和证据目录均位于 GUID 临时目录；
- scheduled task、Supervisor/TrayHost、product registration、shortcut 和 installed scenario 均由
  现有 fake/adapters 驱动；
- 没有运行真实 Setup/installer，没有修改真实 registry/shortcut/scheduled task/device key，
  没有安装、重启、重启系统、网络、push、tag 或 release 操作；
- 测试创建的 junction 只位于临时目录，使用 `.NET Directory.Delete(link)` 删除链接并验证
  外部临时 target 未被跟随。

## 边界与后续

- 本 Task 只支持有完整历史证据可安全映射为 selector genesis 的 v2.5.21
  generation-one profile。generation greater than one 无法从单个 mutable active pointer 重建
  完整 append-only 历史，因此在 staging 前 fail closed；如要支持该形状，需要单独设计并提供
  可验证历史来源，不能伪造 selector records。
- Task 2 的 exact historical product-registration profile 迁移尚未实现；Task 1 测试只用适配器
  证明 lifecycle/Ready/rollback 边界。
- 尚待独立 reviewer 对本提交做 Task 1 scoped review；本报告不替代该门禁。

## Fix round 1：Failed legacy migration 可精确重试

### Review finding 与裁定

第一次 true-legacy migration 在 Ready 前失败后，原分类器只接受 `CurrentReady` 或三个新 plane
全缺失的 `ProvenLegacyWithoutReady`。因此第二次完全相同的升级会在 staging 前返回
`CCOD_INSTALL_UPGRADE_SOURCE_INVALID`，即使失败 runtime 已经完整 sealed 且旧 runtime 已恢复。

本轮接受两个、且仅两个 selector profile：

- pre-pointer：latest selector 是 generation 1 legacy；重试复用原 Failed transaction 的
  `newRuntimeId`，提交 selector/Ready generation 2；
- post-pointer compensated：完整 selector chain 必须是
  `1 legacy -> 2 failed-new -> 3 legacy`；重试追加 generation 4 指向同一 failed-new runtime，
  Ready transaction 使用 generation 4。旧 selector records 不删除、不改写。

### RED

在现有 pre-pointer 与 post-pointer failure tests 中移除 transient failure 后立即执行第二次真实
`Invoke-CcodInstall`。两者最初均 exit 1：

```text
CCOD_SELFTEST_FAILED case=real-v2.5.21-upgrade-failure-before-new-pointer-commit-keeps-the-legacy-selector-active-and-restarts-it error=CCOD_INSTALL_UPGRADE_SOURCE_INVALID
CCOD_SELFTEST_FAILED case=real-v2.5.21-upgrade-failure-before-new-Ready-restarts-the-retained-legacy-runtime error=CCOD_INSTALL_UPGRADE_SOURCE_INVALID
```

自审另加入 premature-Failed RED：把 transaction chain 缩短为
`Prepared -> PackageVerified -> Failed`，但保留 selector/runtime。旧实现错误接受并成功重试：

```text
ASSERT_EQUAL: Failed chain without RuntimePromoted evidence fails through the retry compatibility boundary expected=[CCOD_INSTALL_UPGRADE_SOURCE_INVALID] actual=[]
```

根因是原 retry 分类只绑定 Failed head、selector 和 manifest，没有证明第一次尝试已经完成
runtime promotion 与 immutable initialization。修复要求 chain 包含 `RuntimePromoted`，并交叉要求
pre-pointer profile 不得包含 `PointerCommitted`、post-pointer compensated profile 必须包含
`PointerCommitted`。

### 实现边界

- `LegacyMigrationRetry` 重新验证 raw legacy `active.json`、v2.5.21 historical manifest/hash、
  transaction store 中唯一 transaction ID、Failed immutable identity、current v2.5.22 failed
  runtime manifest/hash、exact source file records、sealed package SHA-256 和 selector chain。
- IFT ABI 从 V4 升为 V5，增加私有 migration-retry transaction capability。它只能在 `state`
  子树写 create-only records、打开一个 manifest-bound retained generation、并通过该 retained
  capability append pointer；不能创建 generation、copy payload、写 manifest、retire generation
  或进入 product special-folder surface。公共 export surface 未扩大。
- Failed 是 terminal，因此 retry 使用新的 transaction ID，但复用原 sealed runtime。新 Ready
  transaction 的 generation 与新 append pointer 精确一致。
- 负例覆盖：legacy manifest identity drift、Failed `newGeneration` drift、foreign terminal chain、
  缺少 `RuntimePromoted`、cleanup fence plane、unexpected selector generation、failed runtime
  manifest bytes drift、different sealed package identity。全部在 runtime/pointer/transaction/task
  新 mutation 前失败。

### 最终 GREEN（fix round 1）

- `InstallLifecycle.SelfTest.ps1`：148/148，exit 0。
- `InstalledLifecycleHarness.SelfTest.ps1`：21/21，exit 0。
- `RuntimeManifest.SelfTest.ps1`：21/21，exit 0。
- `InstallFileTransaction.SelfTest.ps1`：36/36，exit 0。
- 四个修改 PowerShell 文件 parser：0 errors。
- `git diff --check`：exit 0。

一次候选 final run 曾返回 `CCOD_INSTALL_TRANSACTION_INVALID`：私有 opener 用强制 re-import
创建了另一个 IFT module instance，而后续 exported commands 仍绑定旧 instance 的 capability
table。最终实现从同一个 canonical module instance 调用私有 opener；修复后的 Lifecycle
148/148 与 IFT 36/36 均重新运行通过。

本轮仍只使用 GUID 临时目录、fake/adapters 和子进程测试；没有执行真实 installer、registry、
shortcut、scheduled task、产品进程、网络、安装、重启、push、tag 或 release 操作。
