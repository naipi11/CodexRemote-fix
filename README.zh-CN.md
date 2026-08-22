<div align="center">
  <img src="assets/codexremote-fix/codexremote-fix.svg" alt="CodexRemote-fix 图标" width="128" height="128">
  <h1>CodexRemote-fix</h1>
  <p>语言 / Language：<strong>简体中文</strong> · <a href="README.md">English</a></p>
</div>

<p align="center">
  <a href="https://github.com/naipi11/CodexRemote-fix"><img src="https://img.shields.io/badge/Windows-desktop-0078D4?logo=windows&logoColor=white" alt="Windows desktop"></a>
  <a href="https://nodejs.org/"><img src="https://img.shields.io/badge/Node.js-22%2B-339933?logo=node.js&logoColor=white" alt="Node.js 22+"></a>
  <a href="https://learn.microsoft.com/powershell/"><img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1+"></a>
  <a href="https://dotnet.microsoft.com/download/dotnet-framework/net48"><img src="https://img.shields.io/badge/.NET%20Framework-4.8-512BD4?logo=.net&logoColor=white" alt=".NET Framework 4.8"></a>
  <a href="https://github.com/naipi11/CodexRemote-fix/actions/workflows/ci.yml"><img src="https://github.com/naipi11/CodexRemote-fix/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/naipi11/CodexRemote-fix/actions/workflows/codeql.yml"><img src="https://github.com/naipi11/CodexRemote-fix/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
  <a href="https://github.com/naipi11/CodexRemote-fix/releases/latest"><img src="https://img.shields.io/github/v/release/naipi11/CodexRemote-fix?display_name=tag" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License"></a>
</p>

CodexRemote-fix 在 Windows 版 Codex Desktop 中启用随应用一起打包、但因运行时缺陷被隐藏的：

**设置 → 连接 → 控制其他设备（Control other devices）**

本项目不修改 `ChatGPT.exe`、`app.asar`，不写入 `C:\Program Files\WindowsApps`
中的任何文件。安装发布版安装包后，由常驻托盘守护程序自动接管。

项目和仓库的公开名称现为 **CodexRemote-fix**。为保证旧安装可以原地升级、
不丢失设置和设备授权，旧脚本文件名、`%LOCALAPPDATA%\CodexControlOtherDevices`
运行时目录以及计划任务内部标识会继续保留。

> [!IMPORTANT]
> 注册设备时请完成账号或工作区要求的 MFA、SSO 或 passkey 验证。

> [!WARNING]
> 这是非官方运行时兼容方案，会在随机 `127.0.0.1` 端口启用 Chromium 调试接口。
> 请仅在可信的 Windows 电脑上运行，并在每次 Codex 更新后重新执行兼容性检查。

## 本项目修复什么

在受影响的 Windows 版本中，Codex Desktop 本来就包含
**设置 → 连接 → 控制其他设备**，但运行时缺陷会把这个标签隐藏。CodexRemote-fix
恢复这个已有页面，不修改 Codex UI、账号授权或原生配对流程。

![控制其他设备标签修复前后](docs/assets/codexremote-fix-tab-before-after-zh-CN.png)

## 快速开始

1. 从 [Releases](https://github.com/naipi11/CodexRemote-fix/releases) 下载 `CodexRemote-fix-2.4.20-setup.exe` 和 `CodexRemote-fix-2.4.20-setup.exe.sha256.txt`，并核对 SHA-256。
2. 运行 `CodexRemote-fix-2.4.20-setup.exe`，无需管理员权限。
   Windows 10 用户请确认已安装 .NET Framework 4.8，原生 TrayHost 需要该组件。
3. 托盘守护程序会自动启动，并创建桌面快捷方式 **CodexRemote-fix**。托盘图标为绿色时，打开 **设置 → 连接 → 控制其他设备** 即可注册或使用。

当前安装包及其 SHA-256 校验值始终发布在
[Releases](https://github.com/naipi11/CodexRemote-fix/releases) 页面。

升级时直接运行新版安装包即可，现有设置与设备密钥会保留。

已验证：Windows 11 · Codex Desktop `26.818.2441.0` · Node.js `22.23.1`；
隐藏的控制器标签、原生托盘菜单、双语菜单切换和常驻守护程序均可用。

## v2.4.20 更新内容

- 安装完成后弹出英文提示，由用户选择立即重启 Codex 或稍后手动重启。
- 安装器不会自动关闭或重启 Codex；选择“稍后”会保持当前会话不受影响。
- 安装器会从持久运行时可靠关闭旧 CodexRemote-fix Supervisor，验证打包的 TrayHost，并且只在新运行时已激活后显示提示。
- 只有用户明确选择“立即重启”后，才会安全关闭当前 Codex 并启动新的受控会话。
- 运行时激活改为后台工作器执行，安装窗口可正常结束，不会在交接阶段卡死。
- 托盘语言切换会等待原生菜单宿主确认新快照后才返回。

## v2.4.19 更新内容

- 新增原生 **关于** 菜单项，点击后显示当前 CodexRemote-fix 版本，例如 `2.4.19`。
- 安装器会在替换已安装运行时前，先停止并验证当前守护程序，同时保留设备密钥和持久化状态。
- 保留现有原子 runtime 升级流程，只有新运行时成功激活后才清理旧运行时文件。

## v2.4.18 更新内容

- 中英文 README 顶部统一居中显示 CodexRemote-fix 图标、项目名、语言切换和真实项目徽章。
- 已启用仓库 Dependabot alerts 和自动安全更新。
- 新增 CodeQL 定期扫描及 main 的 push/PR 扫描，覆盖 JavaScript/TypeScript 与 C#。

## v2.4.17 更新内容

- 重大修复：Codex 更新后，已授权的远程控制设备无需重新配对即可保留。
- 在刷新远程连接前，通过 Codex host bridge 恢复保留的 enrollment 映射。
- 原地修补已经被 Codex 缓存的原生设备密钥模块导出对象，使现有调用方使用修复后的实现。
- 保持现有设备密钥、服务器端授权和 Codex 原生注册流程不变。

## v2.4.16 更新内容

- 修复 Windows PowerShell 重定向输入中的 UTF-8 前导标记导致 TrayHost 在报告就绪前退出的问题。
- 保持严格协议校验：仅初始 bootstrap 帧兼容一个 BOM，后续认证帧不变。
- 新增 GitHub Actions Windows CI，检查 Pull Request 和推送到 `main` 的变更。
- 保留现有原生 Win32 托盘、加密设备密钥和服务器端授权。

## 日常使用

- 登录后计划任务 `Codex Control Other Devices Supervisor` 自动启动托盘守护程序，无需手动操作。
- 若未看到托盘图标，可双击桌面上的 **CodexRemote-fix** 启动托盘守护程序；它本身不会启动修复，也不会改变当前 Codex 会话。
- 托盘图标为绿色时，当前会话已生效；打开 **设置 → 连接 → 控制其他设备** 即可注册或使用。
- 新版 Codex 正常启动自带 `--remote-debugging-port`（没有 `--inspect`），守护程序已能识别这种启动方式并自动完成接管。
- 托盘菜单支持跟随系统、中文、English，切换即时生效，无需重启。
- 升级本项目或 Codex 后无需重装守护程序本体，安装器只会原子切换版本化运行时。
- 如需显式修复，Codex 可能会关闭并重新启动一次。请从托盘菜单选择 **重试上次修复**；已有设备配对和授权会被保留。若升级中断后遗留了已完成的恢复事务，守护程序会在下次启动时安全清理它。

## 发布（Releases）

每个带 tag 的发布都会附带 Windows 安装包及其 SHA-256 校验文件。
`.github/workflows/release.yml` 会在 tag 上自动构建安装包，因此后续每次更新都会
为 2.4.20 发布提供可直接运行的 `CodexRemote-fix-2.4.20-setup.exe`
及 `CodexRemote-fix-2.4.20-setup.exe.sha256.txt`。

每次发布都会在本 README 和 GitHub Release 正文中追加简短的中英文更新说明。
完整历史见 [CHANGELOG.md](CHANGELOG.md)。

Codex Desktop 更新后，请到 [Releases](https://github.com/naipi11/CodexRemote-fix/releases)
查看是否有更新安装包；也可以从开始菜单运行 **CodexRemote-fix compatibility check（兼容性检查）**
快捷方式，确认当前守护程序仍匹配。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=naipi11/CodexRemote-fix&type=Date)](https://www.star-history.com/#naipi11/CodexRemote-fix&Date)

## External renderer 共享 CDP

当已安装 External renderer Windows 运行时时，守护程序会自动使用其已保存的 renderer
端口；如果没有已保存状态，则在该回环端口可用于特殊 Codex 会话时使用 `9335`。
因此 renderer CDP 端口可以与 External renderer 共享；临时的 Electron 主进程 Inspector
保持独立，并会在桥接安装后关闭。

如果首选端口处于暂停状态、不可用、因已作为主进程 Inspector 端口而被排除，或被非
Codex 监听器占用，CodexRemote-fix 会选择不同的动态回环 renderer 端口。
External renderer 的 `pause` 标记会跳过集成。External renderer 状态缺失或无效，以及 handoff
失败，都会安全处理而不会阻塞 Codex 会话；在这些回退场景中，集成不保证 Browser-ID
或端口复用。

不会修改 Codex 或 External renderer 的安装文件。

## 托盘菜单

![真实 Windows 托盘菜单截图](docs/assets/codexremote-fix-real-tray-menu-zh-CN.png)

*真实 Windows 截图；未包含桌面皮肤和其他应用。*

编译后的原生 Win32 TrayHost 菜单按语义状态显示或隐藏操作：立即应用、重试、自动化开关、兼容更新试用、日志、卸载。
卸载必须先确认。

| 颜色 | 状态 | 含义 |
|---|---|---|
| 灰色 | Waiting / Inspecting / Transitioning | 等待 Codex、检查当前会话或正在应用桥接 |
| 绿色 | Active / ActivePaused | 当前会话已验证可用 |
| 黄色 | Suppressed | 兼容操作被抑制，需手动重试或新运行时 |
| 黄色 | RendererHandoff | External renderer handoff 未完成；已验证的 Codex 会话仍保持可用 |
| 红色 | Recovered / Error | 已安全恢复普通 Codex，或自动操作被阻止 |

## 常见问题

仍然没有“控制其他设备”标签？

1. 确认托盘图标为绿色（灰色表示等待 Codex 或自动化已暂停）。
2. 从开始菜单运行 **CodexRemote-fix compatibility check（兼容性检查）**，确认 `Ready: True`。
3. 查看 `%LOCALAPPDATA%\CodexControlOtherDevices\logs\` 下的日志。
4. 确认安全软件没有阻止 `node.exe` 访问本机回环端口。
5. 退出所有 Codex 进程后重试；守护程序最多自动重开一次。

注册或授权失败？

- 完成账号或工作区要求的 MFA/SSO/passkey。
- 确认 Codex 与浏览器使用同一 ChatGPT 账号和工作区。
- 组织工作区请确认管理员允许 Remote Control。

External renderer 未附加到已经运行的会话？

退出 Codex，双击桌面 **CodexRemote-fix** 启动托盘守护程序，
然后重新启动 Codex。

## 卸载

通过托盘菜单 → **卸载**，或在 Windows 设置 → 应用 → 已安装的应用中卸载
**CodexRemote-fix**。卸载时会保留或备份设备密钥；本地移除密钥不会撤销
服务器授权，请先在 Codex 中撤销设备。

## 它解决了什么

受影响的 Windows 包具备全部以下特征：

1. Windows 控制器页面、字符串和后端调用已随包提供。
2. Statsig 开关 `782640499` 语义相反：`true` 反而隐藏 `showControlOtherDevices`。
3. 主进程设备密钥入口只接受 `process.platform === "darwin"`。
4. Windows 包未附带 `remote-control-device-key.node`。

官方文档见 [Remote connections](https://learn.chatgpt.com/docs/remote-connections)。
本项目只修复本地 Windows 运行时缺口，不绕过账号授权、MFA/SSO/passkey、
工作区策略或服务器权限。

## 安全模型

- 调试端口只绑定随机 `127.0.0.1`；主进程 Inspector 注入完成后必须关闭。
- 与当前 Windows 用户同权限的进程可访问这些端口，因此不要在不可信电脑上运行。
- 设备私钥保存在 `%CODEX_HOME%\remote-control-device-keys.windows.json`
  （未设置 `CODEX_HOME` 时为 `%USERPROFILE%\.codex\...`），使用 DPAPI 当前用户范围加密，
  是软件密钥而非 TPM 不可导出密钥。
- 移动或删除本地密钥不会撤销服务器端授权，请先在 Codex 中撤销设备。

详见 [SECURITY.md](SECURITY.md) 和 [docs/TECHNICAL.md](docs/TECHNICAL.md)。

## 诊断

日志位于 `%LOCALAPPDATA%\CodexControlOtherDevices\logs\`，主要有 `install.log`、
`supervisor.log`、`bootstrap.log`、`transactions.log`。

## 项目结构

```text
src/persistence/   托盘守护程序、会话控制器、安装生命周期
src/runtime/       clean-room 桥接实现
tests/             仓库自测与持久化测试
docs/              技术文档、隔离记录、双语截图
```

## 许可与来源

[MIT](LICENSE) © 2026 naipi11。问题定位与运行时技术来自
[hunterbeach 的 Codex Windows runtime remote control Gist](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80)；
上游思路分别来自 [zdaar/codex-hacks](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py)
和 [brunolemos 的 feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae)。
最终 `src/runtime` 采用隔离 clean-room 独立重写，不包含无许可上游源码文本；
原始贡献与来源边界见 [docs/CLEANROOM.md](docs/CLEANROOM.md) 和 [NOTICE.md](NOTICE.md)。
本项目非官方，与 OpenAI 无关，不分发 OpenAI 的程序文件或资源。
