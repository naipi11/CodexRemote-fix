# Task 3：manifest-bound native generation reclamation 报告

## 结论与范围

Task 3 已在隔离 worktree `codex/v2522-install-runtime-reliability` 中实现，并完成要求的 focused、shared 与 aggregate 验证。

- 基线：`3682b810138ea43127762c92a860d45d96ca3d3d`
- implementation commit：`1d57736197df0bfcd1c0e54d96be63dfa54602df`
- 新接口：`Remove-CcodVerifiedGenerationTree -InstallRoot -RuntimeRoot -RuntimeId -ExpectedManifestSha256`
- 未运行真实安装器，未读写真实安装目录、registry、Start menu、Desktop shortcut、scheduled task、产品进程或真实 DPAPI/device-key store。
- 未执行 push、tag、release、安装、重启或 reboot。
- 本报告只声明 Task 3 implementation/verification scope；controller 的独立 scoped review 与最终 whole-plan review 仍是单独 gate。

## 根因与生产改动

原 `InstalledUninstallFinalizer.ps1` 先用路径验证 selected generation，随后重新把权限降级为 pathname，并执行：

```powershell
Remove-Item -LiteralPath $expected -Recurse -Force
```

验证与物理删除之间没有持有任何对象身份。树在验证后增加未知对象、发生 identity replacement，或只有一个 child 被其他 handle 打开时，旧实现会整树删除或先部分删除再失败。

新 `GenerationReclamation.psm1` 只导出 `Remove-CcodVerifiedGenerationTree`。其 CLR assembly 只公开 inert `CcodGenerationReclamationMarkerV1`；实际 native runtime 为 internal type。

生产路径现在：

1. 严格校验 canonical `RuntimeRoot == <InstallRoot>\runtime\<RuntimeId>` 与 64-hex manifest binding。
2. 绝对打开并验证 install root，然后只通过 parent native handle 相对打开 `runtime`、selected generation 和每个 descendant；所有 selected-tree handle 请求 `DELETE`、read-attributes、list/read-data 与 synchronize 权限，share 只允许 read，不允许 write/delete sharing，并始终使用 open-reparse-point 语义。
3. 每个 held object 保存 final path、volume serial、file ID、type、parent/name；拒绝 reparse、ADS/non-default stream，regular file 还要求 single link。
4. 从 pinned manifest handle 读取严格 UTF-8 JSON；拒绝任意层 duplicate property、非精确字段、非 canonical record、乱序/重复 path、错误 runtimeId digest/nonce binding。
5. exact file set 明确为 `manifest.json + manifest.files`；exact directory set为这些 manifest files 的全部 parent directories。额外空目录也被拒绝。
6. 全树 second enumeration、final path、volume/file ID、stream/link/length/hash revalidation 通过后才进入 disposition。
7. `UninstallBootstrap.ps1` 的 durable payload allowlist 增加该 module；default installed finalizer 只调用该 API，生产文件不再包含 `Remove-Item`、`Copy-Item` 或 `Move-Item` 路径删除/替换。

成功结果是显式对象：

```text
phase=Completed
result=Reclaimed
runtimeId=<exact selected id>
fileCount=<manifest.json + manifest.files>
directoryCount=<selected root + manifest parent directories>
```

只有该 proof 返回且 selected root absence 再次成立，transaction 才从 `TaskRemoved` 推进到 `ReadyForInno`；之后才允许 product removal 和 completion receipt。

## Windows disposition ruling

临时 NTFS 树的 native probe 得到：

- classic `FileDispositionInfo` 对 readonly immutable file 返回 Win32 `5`；
- `FileDispositionInfoEx(Delete | IgnoreReadonly = 0x11)` 可 arm，也可用 flags `0` disarm；
- 当 child 仅被标记、handle 仍打开且名称仍存在时，对 parent directory 标记删除返回 Win32 `145` (`Directory not empty`)；加入 POSIX flag 仍为 `145`，本机 ON_CLOSE 组合返回 `50`。

因此“files + all parent directories 全部 arm、所有 handle 始终保持打开、最后统一 close”在目标 Windows 语义上不可实现。controller 接受以下必要细化：

- `PinnedValidated`：完整 pin、manifest exact-set 与 second validation；零 disposition。
- `FilesArmed`：先 arm 全部 files，仍为可逆屏障。任一 file-arm 失败时，对已 arm handles 反向 disarm，并重新验证完整树；成功恢复后报 `CCOD_GENERATION_RECLAMATION_INVALID`。若恢复本身失败，使用独立 `CCOD_GENERATION_RECLAMATION_ROLLBACK_FAILED`。
- `CommitStarted`：只有全部 file arm 成功后才进入不可逆提交；close files，随后 deepest directories 逐个 mark+close，selected root last。
- commit 阶段的 directory mark/close/absence failure 使用稳定 `CCOD_GENERATION_RECLAMATION_COMMIT_FAILED`。此时 selected generation 可能只剩部分失败边界，但 install root、siblings、state/device key 与 outside objects 不受影响；finalizer 不执行 absence proof、product removal 或 completion receipt，也不写假成功。

## TDD 证据

### 干净基线

- `UninstallBootstrap.SelfTest.ps1`：`23/23`，exit `0`。
- `InstallFileTransaction.SelfTest.ps1`：baseline suite pass，exit `0`。

### 有效 RED：当前 pathname deletion

首个 production-path RED 先执行真实 `ValidateSelectedGeneration`，验证成功后插入 `unexpected-after-validation.bin`，再走默认 installed finalizer：

```text
exit=1
case=installed-finalizer-rejects-an-unexpected-post-validation-child-without-deleting-any-generation-state
error=CCOD_RECLAMATION_RED_PATHNAME_DELETE
recursive pathname deletion accepted and removed the changed selected tree
```

随后以 `CCOD_RECLAMATION_RED_CASE` 分别运行以下六项；旧生产实现全部 exit `1` 并命中 `CCOD_RECLAMATION_RED_PATHNAME_DELETE`：

- `UnexpectedFile`
- `UnexpectedDirectory`（额外空目录）
- `Reparse`
- `Hardlink`
- `Ads`
- `OpenChild`

前五项证明旧实现接受变化后整树删除；`OpenChild` 证明旧递归路径删除可先删除其他 manifest members，再在 open child 处失败。

### 有效 RED：新 native contract

- `IdentityChange`：exit `1` / `CCOD_RECLAMATION_RED_MODULE_MISSING`；wished-for pinned boundary 尚不存在。
- `MarkFailure`：exit `1` / `CCOD_RECLAMATION_RED_MODULE_MISSING`；wished-for arm/disarm retry boundary 尚不存在。
- IFT production-shape case：exit `1` / `CCOD_RECLAMATION_RED_MODULE_MISSING`；真实 immutable transaction 创建并 Ready-close 的 readonly generation 尚无 reclamation API。
- commit-failure injection：exit `1` / `ASSERT_THROWS expected CCOD_GENERATION_RECLAMATION_COMMIT_FAILED`；seam 尚未被 commit phase 消费。

测试构造期间出现过并已排除的非有效 RED：并行启动 suite 争用同一 user mutex、loop closure metadata error，以及长路径上的 PowerShell ADS cmdlet fixture error。它们未被计作功能证据；对应用例改为串行、同步 case capture 和短 `manifest.json` ADS target 后重新得到上述有效 RED。

### 最终 GREEN

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\UninstallBootstrap.SelfTest.ps1`
  - `Uninstall bootstrap self-tests passed: 32`
  - exit `0`
  - 包含 six hostile mutations、identity exchange blocked、file-arm disarm/full-tree retry、CommitStarted stable failure，以及 default staged finalizer negative matrix。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallFileTransaction.SelfTest.ps1`
  - `37` 个 declared cases 全部 pass
  - exit `0`
  - 新 case 使用真实 IFT 生成 nested readonly generation；结果只删除 selected generation，install root/outside sentinel 不变。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  - `Install lifecycle self-tests passed: 148`
  - exit `0`
  - 既有 unapproved-verb warnings 与负向 `CCOD_CROSS_PROCESS_OBSERVED ... CCOD_PRODUCT_REGISTRATION_FAILED` 不改变最终 pass。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PersistenceSelfTest.ps1`
  - exit `0`
  - aggregate 成功时无 stdout 汇总；只读进程观察确认其依次推进 Lifecycle、ProductRegistration、StateStore、TrayUi 等 child suites 后正常退出。

### Parser、surface 与 diff

- 以下 5 个文件 PowerShell parser 各 `0` errors：
  - `src\persistence\modules\GenerationReclamation.psm1`
  - `src\persistence\InstalledUninstallFinalizer.ps1`
  - `src\persistence\UninstallBootstrap.ps1`
  - `tests\persistence\UninstallBootstrap.SelfTest.ps1`
  - `tests\persistence\InstallFileTransaction.SelfTest.ps1`
- module exports：仅 `Remove-CcodVerifiedGenerationTree`。
- marker ABI：`1`；assembly exported CLR types：仅 `CcodGenerationReclamationMarkerV1`。
- production static scan：`InstalledUninstallFinalizer.ps1` 与 `GenerationReclamation.psm1` 中 `Remove-Item|Copy-Item|Move-Item` 零命中。
- `git diff --check`：exit `0`；只有 checkout line-ending conversion warning，无 whitespace error。

## 自审与审查边界

自审逐项确认：

- 所有 selected-tree 对象从已持有 parent handle 相对打开；reparse 不会被 follow。
- 每个 regular file 在任何 disposition 前已绑定 path、volume/file ID、default stream、single link、length 与 SHA-256。
- manifest 本身属于 exact file set，不由 manifest 自引用；其 hash 绑定 durable transaction。
- unexpected file、unexpected empty directory、reparse、hardlink、ADS、open child、root identity exchange 均在零删除前失败。
- file-arm failure 可逆恢复后，完整同一 tree 可由第二次调用成功 reclaim。
- success 只删除 selected generation；sibling generation、install root、state 和 device-key sentinel 均保留。
- CommitStarted failure 不声称 tree rollback；它明确 fail closed，不进入 product/final receipt。

独立 scoped review 与 fresh whole-plan review 由 controller 使用 implementation commit `1d57736197df0bfcd1c0e54d96be63dfa54602df` 执行；本报告不把 implementer 自审当成独立 review。Tasks 5–8 的原 release plan 仍保持 blocked，直到本计划完成独立 review 和最终总 gate。
