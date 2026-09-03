# Runtime V7 ABI closure report

## 结论与范围

micro-plan implementation commit 为 `9d7cc90`（`fix: advance install runtime ABI to V7`），基线为
`ec8dac0`。实现只修改：

- `src/persistence/modules/InstallFileTransaction.psm1`
- `tests/persistence/InstallFileTransaction.SelfTest.ps1`

没有修改 exports、durable plan schema、file-layer 行为、ProductRegistration 或 InstallLifecycle
逻辑。

## RED

独立 `powershell.exe` child 先通过自包含 `Add-Type` 预载最小 stale：

- `CcodInstallGenerationCapabilityMarkerV6`，ABI `6`；
- internal `CcodInstallGenerationRuntimeV6`，不含最终实现方法。

然后 child 对当前模块执行 force-import。production 未修改时实际结果：

```text
InstallFileTransaction.SelfTest.ps1
exit 1
case=stale-V6-preload-cannot-capture-the-final-runtime-ABI-across-force-re-imports
child exit=17
SELECTED_RUNTIME=CcodInstallGenerationRuntimeV6
```

这证明长寿命 AppDomain 中已有 V6 marker 时，原模块会跳过新的 embedded C#，并把
`$script:CcodRuntimeType` 绑定到 stale V6。

## 实现与 GREEN

production 仅做机械 ABI 迁移：

- `CcodInstallGenerationCapabilityMarkerV6` -> `...MarkerV7`；
- `CcodInstallGenerationRuntimeV6` -> `...RuntimeV7`；
- `CapabilityAbi` 与 import-time exact assertion 从 `6` -> `7`；
- 所有 constructor、out parameter、runtime allocation 与 reflection binding 同步改为 V7。

exact tests 同步为 V7/7。独立 child 保留 stale V6，证明：

1. V6 marker/runtime 仍在同一 AppDomain；
2. force-import 选择 `CcodInstallGenerationRuntimeV7`；
3. repeated force-import 复用同一个正确 V7 `System.Type`；
4. V7 state transaction 实际写入 create-only record；
5. 既有 V4-first child 也只选择 V7。

首轮 GREEN 的 coexistence oracle 曾错误使用 `'RuntimeV6' -as [type]` 检查 internal stale runtime，
因此返回 null。独立诊断证明 global type resolution 为 null、但
`staleMarker.Assembly.GetType('CcodInstallGenerationRuntimeV6')` 返回该 internal type；修正测试
oracle 后，没有追加 production 改动。

## Frozen gate

source freeze 后结果：

```text
InstallFileTransaction.SelfTest.ps1    45 groups   exit 0
ProductRegistration.SelfTest.ps1       30/30       exit 0
InstallLifecycle.SelfTest.ps1          151/151     exit 0
UninstallBootstrap.SelfTest.ps1        45/45       exit 0
RuntimeManifest.SelfTest.ps1           21 groups   exit 0
InstalledLifecycleHarness.SelfTest.ps1 21 groups   exit 0
Bootstrap.SelfTest.ps1                 26/26       exit 0
ManualWrappers.SelfTest.ps1            12 groups   exit 0
PowerShell parser                      2/2 changed files, 0 errors
git diff --check                                   exit 0
tests\PersistenceSelfTest.ps1                      exit 0 (silent success)
```

Lifecycle 的既有 cross-process guard 仍输出：
`exit=23 mutex=True authority=False product=False verified=False error=CCOD_PRODUCT_REGISTRATION_FAILED`。

## 安全边界

未执行真实 registry、shortcut、scheduled task、安装、卸载、进程重启、系统重启、网络、push、
tag、release 或发布操作；所有新 child 行为仅使用独立临时目录并完成清理。

fresh scoped V7 review 仍待 parent agent 发起；不声明 Tasks 5–8 或 release readiness 完成。
