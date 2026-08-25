# CodexRemote-fix release notes

This file keeps the release record. GitHub Release bodies are generated from the English section only.

## Unreleased

No unreleased changes.

## v2.5.9

### English

- Fixed release publication so the Inno Setup installer executable is uploaded alongside the portable ZIP and manifests.

### 简体中文

- 修复发布上传：现在 Inno Setup 安装包可执行文件会与便携 ZIP 和清单一起上传。

## v2.5.8

### English

- Fixed the live supervisor startup so the default trusted logon identity adapter matches its module contract and returns assertion-ready token facts. Fresh installs now prove supervisor and tray readiness instead of failing closed during activation.

### 简体中文

- 修复守护程序真实启动：默认可信登录身份适配器现与其模块契约一致，并返回可供断言使用的令牌事实。全新安装现在能证明 Supervisor 与托盘已就绪，而不是在激活阶段失败关闭。

## v2.5.7

### English

- Fixed the verified portable installer to create and revalidate each manifest-bound nested staging directory before copying payload files. This restores first-run portable installation while continuing to reject reparse paths.

### 简体中文

- 修复经验证的便携安装器：复制载荷文件前会创建并重新验证每个受清单绑定的嵌套 staging 目录。在继续拒绝重解析点路径的同时，恢复首次便携安装。

## v2.5.6

### English

- Replaced the unsigned self-extracting installer release with a manifest-bound portable ZIP. Release validation now binds the ZIP, checksum, TrayHost provenance, external payload manifest, and every archived payload file.
- Added a verified portable entrypoint that scans the payload with Microsoft Defender before installation, without disabling protection or adding exclusions.
- Added a staged portable uninstall finalizer that removes only the marker-bound current-user payload after the existing fail-closed cleanup proves the runtime/session boundary. The DPAPI device-key store remains untouched.

### 简体中文

- 将无签名自解压安装器发布改为带清单绑定的便携 ZIP。发布校验现会绑定 ZIP、校验和、TrayHost provenance、外置 payload manifest 以及归档内的每一个载荷文件。
- 新增经验证的便携入口：安装前使用 Microsoft Defender 扫描载荷，不关闭防护，也不添加排除项。
- 新增 staged 便携卸载终结器：只有既有失败即停止清理已经证明 runtime/会话边界后，才删除带标记绑定的当前用户载荷；DPAPI 设备密钥存储保持不变。

## v2.5.5

### English

- Added a tightly scoped compatibility inspection for an older manifest-sealed controller that omitted its `ProcessControl` import. It accepts only the exact correlated legacy failure and requires a manifest-verified read-only ordinary-session recheck immediately before each protected uninstall deletion boundary.
- New `SessionController` runtimes now load `ProcessControl` globally, and regression coverage rejects every other controller failure or changed compatibility proof.

### 简体中文

- 为遗漏 `ProcessControl` 导入的旧版清单封存 controller 增加了严格限定的兼容探测。它只接受精确关联的旧版失败特征，并在每个受保护卸载删除边界之前重新执行经清单验证的只读普通会话检查。
- 新版 `SessionController` runtime 现会全局加载 `ProcessControl`；回归覆盖会拒绝其他任何 controller 失败或已变化的兼容性证明。

## v2.5.4

### English

- Made fail-closed uninstall recovery preclaim a durable nonempty controller result placeholder so it works with a still-manifest-sealed older controller runtime.
- Added regression coverage for the legacy strict byte-array writer and the prelaunch placeholder ordering.

### 简体中文

- 调整失败即停止的卸载恢复：预占并认证的 controller 结果文件现在会持久写入非空占位内容，因此仍可由清单封存的旧 controller runtime 安全替换。
- 新增旧版严格字节数组写入器及控制器启动前占位写入顺序的回归覆盖。

## v2.5.3

### English

- Fixed fail-closed uninstall recovery when its authenticated controller result placeholder is initially empty.
- Added regression coverage for atomically replacing the empty preclaimed controller result file.

### 简体中文

- 修复失败即停止的卸载恢复：已认证的 controller 结果占位文件为空时，恢复结果可安全原子写入。
- 新增回归覆盖，可原子替换预先创建的空 controller 结果文件。

## v2.5.2

### English

- Fixed the fail-closed uninstaller payload to include `TrustedLogonIdentity.psm1`, required by the staged `StateStore` dependency.
- Added a regression that imports staged `InstallLifecycle` before cleanup, proving its payload-local dependency closure is complete.

### 简体中文

- 修复失败即停止的卸载载荷，补齐 staged `StateStore` 依赖的 `TrustedLogonIdentity.psm1`。
- 新增回归：在清理前导入 staged `InstallLifecycle`，证明其载荷内依赖闭包完整。

## v2.5.1

### English

- Fixed a Supervisor startup contract mismatch that rejected the complete schema-two active runtime pointer immediately after installation.
- Added regression coverage that reads the canonical active pointer before Supervisor readiness, including upgrade pointers with a previous runtime.

### 简体中文

- 修复 Supervisor 启动时错误拒绝完整 schema-two active runtime 指针、导致安装后立即退出的问题。
- 新增回归覆盖：Supervisor 就绪前读取标准 active 指针，并覆盖带有 previous runtime 的升级指针。

## v2.5.0

### English

- Rebuilt restart and repair as a durable Supervisor-owned lifecycle that resumes safely after delayed or manual Codex launches.
- Simplified the tray to truthful connection/protection status, one repair action, language, logs, About, and safe Exit.
- Made upgrades wait for the new runtime and tray, preserved authorized devices, and unified Windows Settings and direct uninstall behind a fail-closed cleanup flow.

## v2.4.24

### English

- Fixed upgrades leaving no tray icon even though the controlled Codex session was active.
- The installer now waits for the previous `IgnoreNew` scheduled-task instance to leave `Running` before starting the new Supervisor.
- Added lifecycle regression coverage and a stable `CCOD_INSTALL_SUPERVISOR_TASK_BUSY` failure when the old task cannot exit within the bounded wait.

### 简体中文

- 修复升级后受控 Codex 会话已经生效、但托盘图标消失的问题。
- 安装器现在会等待旧 `IgnoreNew` 计划任务实例退出 `Running`，再启动新的 Supervisor。
- 新增生命周期回归测试；旧任务在限定时间内无法退出时，会返回稳定错误 `CCOD_INSTALL_SUPERVISOR_TASK_BUSY`。

## v2.4.23

### English

- Replaced the embedded COM application activator with the standard Windows `explorer.exe shell:AppsFolder\<AUMID>` route.
- Preserved reliable ordinary Codex relaunch while removing the new embedded interop signature that triggered Defender's `Program:Win32/Contebrew.A!ml` download heuristic.
- Added regression coverage that forbids the embedded COM activator and verifies the exact AppsFolder launch request.

### 简体中文

- 将内嵌 COM 应用激活器替换为 Windows 标准 `explorer.exe shell:AppsFolder\<AUMID>` 路径。
- 在保留普通 Codex 可靠重启的同时，移除触发 Defender `Program:Win32/Contebrew.A!ml` 下载启发式检测的新增互操作特征。
- 新增回归测试，禁止内嵌 COM 激活器，并验证精确的 AppsFolder 启动请求。

## v2.4.22

### English

- Fixed **Restart now** closing Codex without reopening it by activating the ordinary packaged app through Windows' native Application Activation Manager.
- Ordinary launches now use the exact Codex AUMID `OpenAI.Codex_2p2nqsd0c76g0!App`; controlled launches with debugging arguments keep their existing verified executable path.
- Added a regression test that rejects direct WindowsApps executable launches for ordinary Codex recovery.

### 简体中文

- 修复选择 **立即重启** 后只关闭 Codex、没有重新启动的问题：普通打包应用改由 Windows 原生 Application Activation Manager 激活。
- 普通启动使用精确 Codex AUMID `OpenAI.Codex_2p2nqsd0c76g0!App`；携带调试参数的受控启动继续使用现有验证路径。
- 新增回归测试，禁止普通 Codex 恢复流程直接运行 WindowsApps 中的可执行文件。

## v2.4.21

### English

- Fixed a TrayHost parent-reader disposal race that could terminate the persistent supervisor after the remote-control session had already become active.
- The parent now waits for TrayHost reader, writer, and stderr threads to leave their pipe operations before disposing synchronization handles.
- Added a native regression test for a remote-fault shutdown race, preventing the `System.ObjectDisposedException` observed in the parent reader.

### 简体中文

- 修复 TrayHost 父端读取线程的释放竞态：远程控制会话已生效后，持久 Supervisor 不会再因该竞态退出。
- 父端现在会等待 TrayHost 的读取、写入和 stderr 线程退出管道操作后，才释放同步句柄。
- 新增原生回归测试，覆盖远端故障与关闭并发场景，防止 ParentReader 出现 `System.ObjectDisposedException`。

## v2.4.20

### English

- Added an English post-install prompt: restart Codex now or restart it manually later.
- The installer never closes or restarts Codex automatically; **Later** leaves the current session untouched.
- The installer now stops the persistent prior supervisor, validates the packaged TrayHost payload, and prompts only after the new runtime is active.
- **Restart now** safely closes the current Codex session and launches a fresh controlled session after explicit confirmation.
- Runtime activation runs in a background worker so the setup window remains responsive.
- Tray language changes wait for native-host acknowledgement before completing.
- Reissued the installer with a verified restart chain: recover a proven ordinary Codex session first, then activate the controlled session.
- If restart confirmation fails after activation, the new runtime remains active and the event is recorded as `RESTART_UNCONFIRMED` rather than a false activation failure.

### 简体中文

- 安装完成后新增英文提示，可选择立即重启 Codex 或稍后手动重启。
- 安装器不会自动关闭或重启 Codex；选择“稍后”会保持当前会话不受影响。
- 安装器会关闭持久运行时中的旧 Supervisor，验证打包 TrayHost，并且只在新运行时已激活后提示。
- 只有明确选择“立即重启”后，才会安全关闭当前 Codex 并启动新的受控会话。
- 运行时激活改由后台工作器执行，安装窗口可保持响应。
- 托盘语言切换会等待原生宿主确认新快照后完成。
- 重新发布安装包：重启链路会先恢复并确认普通 Codex 会话，再激活受控会话。
- 如果激活完成后无法确认重启，新运行时仍保持已激活状态，并记录为 `RESTART_UNCONFIRMED`，不再误报激活失败。

## v2.4.19

### English

- Added a native About menu item that displays the active CodexRemote-fix version.
- The installer now stops and verifies the running supervisor before replacing the installed runtime.
- Preserved device keys and persistent state through the safe atomic runtime upgrade; old runtimes are retired after activation.

### 简体中文

- 新增原生“关于”菜单项，显示当前 CodexRemote-fix 版本。
- 安装器替换已安装运行时前，会先停止并验证当前守护程序。
- 安全的原子 runtime 升级会保留设备密钥和持久化状态，新运行时激活后才清理旧运行时。

## v2.4.18

### English

- Centered the CodexRemote-fix icon, product name, language switch, and verified project badges in both README languages.
- Enabled repository Dependabot alerts and automatic security updates.
- Added scheduled and push/PR CodeQL scanning for the JavaScript/TypeScript and C# portions of the project.

### 简体中文

- 中英文 README 顶部统一居中显示 CodexRemote-fix 图标、项目名、语言切换和真实项目徽章。
- 已启用仓库 Dependabot alerts 和自动安全更新。
- 新增 CodeQL 定期扫描及 main 的 push/PR 扫描，覆盖 JavaScript/TypeScript 与 C#。

## v2.4.17

### English

- Major fix: authorized remote-control devices now survive Codex updates without re-pairing.
- Restored the preserved enrollment mapping through Codex's host bridge before refreshing remote connections.
- Patched already-cached native device-key addon exports in place so existing Codex consumers use the corrected implementation.
- Kept device keys, server-side authorization, and the normal Codex enrollment flow unchanged.

### 简体中文

- 重大修复：Codex 更新后，已授权的远程控制设备无需重新配对即可保留。
- 在刷新远程连接前，通过 Codex host bridge 恢复保留的 enrollment 映射。
- 原地修补已被缓存的原生设备密钥模块导出对象，使现有 Codex 调用方使用修复后的实现。
- 保持设备密钥、服务器端授权和 Codex 原生注册流程不变。

## v2.4.16

### English

- Fixed a Windows PowerShell redirected-input UTF-8 preamble that could make TrayHost exit before signaling readiness.
- Kept strict protocol validation and limited the compatibility path to one BOM on the initial bootstrap frame only.
- Added Windows GitHub Actions validation for pull requests and pushes to `main`.
- Added a concise before/after showcase image of the real Control other devices tab.

### 简体中文

- 修复 Windows PowerShell 重定向输入中的 UTF-8 前导标记导致 TrayHost 在报告就绪前退出的问题。
- 保持严格协议校验，仅允许初始 bootstrap 帧兼容一个 BOM，不放宽后续认证帧。
- 新增 GitHub Actions Windows CI，检查 Pull Request 和推送到 `main` 的变更。
- 新增真实“控制其他设备”标签的简洁修复前后展示图。

## v2.4.15

### English

- Rebuilt the tray UI as a compiled native Win32 TrayHost with the standard Windows context menu behavior.
- Added the CodexRemote-fix product icon, Start-menu entry, and desktop shortcut.
- Preserved bilingual tray controls: Follow system, 中文, and English.
- Hardened interrupted-session recovery and kept the encrypted device-key store unchanged.

### 简体中文

- 托盘 UI 重构为编译后的原生 Win32 TrayHost，使用 Windows 默认右键菜单行为。
- 新增 CodexRemote-fix 产品图标、开始菜单入口和桌面快捷方式。
- 保留双语托盘控制：跟随系统、中文、English。
- 加固中断会话恢复流程，保持加密设备密钥不变。

## Future releases

Each new tag should append one short `vX.Y.Z` section with matching English and Chinese bullets.
