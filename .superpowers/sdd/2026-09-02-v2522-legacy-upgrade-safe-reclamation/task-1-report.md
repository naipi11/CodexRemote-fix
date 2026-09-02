# Task 1 报告：v2.5.21 legacy lifecycle upgrade bridge

## 结论

Task 1 已在隔离 worktree
`C:\Users\33384\Documents\Codex-Control-other-devices-Windows\.worktrees\codex-v2522-install-runtime-reliability`
实现并通过要求的 focused tests。实现提交为
`5114a09953e2566b1127788ffbad115c11ae072f`（`fix: bridge legacy lifecycle upgrade`），
基线为 `2aef5ff2a74219a82e98fe26c2f8170a5232a280`。

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

它只返回两种 `Kind`：

- `CurrentReady`：append-only selector 与 transaction plane 均存在；selected pointer、
  valid current manifest、manifest SHA-256 和 canonical terminal Ready transaction 的
  runtime/generation 完全一致。此分支仍执行原 durable product-cleanup resolver。
- `ProvenLegacyWithoutReady`：三个新 plane 均有精确 ItemNotFound 证明；raw
  `active.json` 是上述严格 schema-2 generation-one 形状；active runtime tree/manifest
  通过 contained path、non-reparse、no-ADS、single-link 和 hash/file-set 校验；current
  validator 的唯一失败是 `CCOD_RUNTIME_ID_MISMATCH`；随后使用历史算法复算并精确得到
  v2.5.21 两段式 runtime ID。只有此分支跳过不存在的旧 Ready cleanup resolver。

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
