# Task 2：精确历史注册 profile 迁移报告

## 结论

Task 2 已在隔离 worktree `codex/v2522-install-runtime-reliability` 中实现并完成要求的 focused verification。

- 基线：`4504c1afa665bccd3cc9f9e1ffd748c795bf936d`
- implementation commit：`6be1025`（`fix: migrate exact legacy registration profiles`）
- 未运行真实安装器，未读写真实 registry、Start menu、Desktop shortcut、scheduled task 或产品进程。
- 未执行 push、tag、release、安装、重启或 reboot。
- 本报告只声明 Task 2 focused scope；全计划 aggregate、installed acceptance 与 Task 3 不在本次完成声明内。

## 历史来源与版本边界

历史 profile 直接来自 checked-in `build/CodexControlOtherDevices.iss` 与对应 `package.json`：

| Profile | 版本范围 | AppId | 精确 shortcut 集合 |
|---|---:|---|---|
| `CodexControlOtherDevicesInitial` | `2.1.0` | `{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}` | 4 个旧品牌 Start-menu shortcut，无 Desktop shortcut |
| `CodexControlOtherDevicesDesktop` | `2.1.1`–`2.1.6` | 同上 | 相同 4 个 Start-menu shortcut，加 `Desktop\Codex 设备连接 (Device Connection).lnk` |
| `CodexRemoteFix` | `2.2.0`–`2.5.21` | 同上 | 3 个 `Programs\CodexRemote-fix\...` shortcut，加 `Desktop\CodexRemote-fix.lnk` |

来源核对：

- tag `v2.1.0`：版本 `2.1.0`，4 个 `[Icons]` entry；无 Desktop entry。
- commit `2d8da0f8e86dd06571f2dd6428143fab9beb5918`：版本变为 `2.1.1`，首次增加旧品牌 Desktop entry。
- tag `v2.1.6`：保留上述 5-entry 旧品牌布局。
- commit `fedc840a66f9019de406c5e55dabd403df3b0611` / tag `v2.2.0`：切换为 4-entry `CodexRemote-fix` 布局。
- Task 1 的真实 merge-base `19803a79af3302c49f129e6a6b3ff7ffaf1b930b` 与 tag `v2.5.21` 均为版本 `2.5.21`、相同 AppId、相同 4-entry `CodexRemote-fix` 布局。

三个 profile 都要求 registry `DisplayVersion` 位于本 profile 的闭区间内，并要求 `UninstallString` 精确等于由 canonical absolute `InstallLocation` 绑定出的 `"{installLocation}\unins000.exe"`，不接受附加参数、未加引号或外部路径。

## 实现

`ProductRegistration.psm1` 新增并导出：

- `Get-CcodLegacyRegistrationProfiles`
- `Resolve-CcodLegacyRegistrationProfile -LegacyRegistration`

解析采用 Ordinal exact set：只允许一个完整 profile，不要求历史名称并集，也不接受重复、缺失、额外、跨 profile、大小写变化或 reparse/unsafe shortcut evidence。

真实 reader 会：

- 读取 legacy AppId key 的 `DisplayVersion`、`InstallLocation` 与 `UninstallString`；
- 枚举两个已知 Start-menu group 的全部直接子项，因此 unknown/extra entry 不会被 allowlist scan 隐藏；
- 读取两个历史 Desktop candidate；
- 把 directory/reparse object 标记为 unsafe，使 resolver 在任何删除前 fail closed。

Legacy snapshot 数量改为 `1 registry entry + selected profile shortcut count`，并再次校验 snapshot 中 registry/shortcut 名称与所选 profile 完全一致。

### v2.5.21 重叠路径保护

自审发现 v2.2.0–v2.5.21 的 main Start-menu 与 Desktop 路径和 v2.5.22 current shortcut 路径重叠。新注册会先安全替换这两个 leaf；legacy cleanup 不能随后把 current replacement 删除。

因此 cleanup 现在要求 exact current three-record proof：current registry、Start-menu、Desktop 的 runtime/version/package/name/hash 必须一致。只有 snapshot 中 path 和 SHA-256 同时绑定该 proof 的两个重叠 entry 才从 legacy deletion set 排除。实际删除的是 legacy registry、compatibility shortcut、uninstall shortcut。删除后再次读取并逐字段验证同一个 current proof；若漂移，则按反序补偿所有已删除 legacy-only entry。

旧 profile 与 current 路径不重叠，仍完整删除 `5` 或 `6` 个 snapshot entry。

原有安全语义保持：

- 删除失败后只反序恢复已删除或部分删除的 exact entry；
- replacement 已占用名称时不覆盖；
- restore 失败或 replacement mismatch 会写 create-only unresolved compensation record；
- current proof 或 profile 不完整时执行零 legacy deletion。

## TDD 证据

### 干净基线

- `ProductRegistration.SelfTest.ps1`：`13/13`，exit `0`。
- `InstallLifecycle.SelfTest.ps1`：`148/148`，exit `0`。

### RED 1：真实 v2.5.21 四 shortcut 集合

Production 尚未修改时运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1
```

结果：exit `1`；首个真实 case 为 `real-v2.5.21-registration-removes-its-exact-four-shortcut-profile`，错误为 `CCOD_LEGACY_PRODUCT_REGISTRATION_INVALID`，原因是旧实现要求 union-of-eight。

随后加入 table-driven profile 与 negative matrix；旧实现仍在 exact legacy cleanup 前以同一错误失败。

### GREEN 1：profile resolution 与动态 snapshot

- ProductRegistration：`17/17`，exit `0`。

覆盖 profile 边界以及 AppId、missing、extra、cross-profile、case-varied、reparse、version binding/gap/too-new、uninstall outside/arguments/unquoted、relative InstallLocation、same-count foreign snapshot。

### RED 2：current shortcut overlap

自审补充 overlap RED 后，旧 profile implementation 运行 ProductRegistration suite：exit `1`；首失败为：

```text
ASSERT_EQUAL: exact migration removes only the three non-current legacy entries expected=[3] actual=[5]
```

该 RED 证明仅按 profile snapshot 全删会删掉刚写入并验证的 current Start-menu/Desktop replacement。

另先写入两个 safety RED：overlap snapshot hash mismatch 必须在零删除前失败；cleanup 后 current proof 漂移必须反序补偿三项 legacy-only 删除。

### 最终 GREEN

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\ProductRegistration.SelfTest.ps1`
  - `Product registration self-tests passed: 19`
  - exit `0`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\persistence\InstallLifecycle.SelfTest.ps1`
  - `Install lifecycle self-tests passed: 148`
  - exit `0`

Lifecycle 的真实 v2.5.21 fixture 现在经过实际 ProductRegistration module，仅把 registry/shortcut 外部副作用替换为内存 adapters。断言：

- 新 current registration 在 terminal Ready 后完成；
- legacy cleanup 删除恰好 registry、compatibility、uninstall 三项并保留两个 proof-bound current shortcuts；
- 无 unresolved compensation record；
- 第二次同 package 调用返回 `AlreadyInstalled`，不增加 runtime/selector，不安装 task、不启动进程、不重复 legacy deletion。

最终静态检查：

- `src\persistence\modules\ProductRegistration.psm1` parser：`0` errors。
- `tests\persistence\ProductRegistration.SelfTest.ps1` parser：`0` errors。
- `tests\persistence\InstallLifecycle.SelfTest.ps1` parser：`0` errors。
- `git diff --check`：exit `0`。

## 审查边界与后续

- Focused self-review 未发现新的 Task 2 blocker。
- 独立 review 仍由 controller 执行；本报告不把自审当成独立 review。
- 全 persistence aggregate、installed scenario、Setup/Defender、真实升级与发布仍在后续总体验收 gate 之后。
