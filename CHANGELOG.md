# CodexRemote-fix release notes

This file keeps the release record. GitHub Release bodies are generated from the English section only.

## Unreleased

No unreleased changes.

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
