<div align="center">
  <img src="assets/codexremote-fix/codexremote-fix.svg" alt="CodexRemote-fix icon" width="128" height="128">
  <h1>CodexRemote-fix</h1>
  <p>Language / 语言: <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
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

CodexRemote-fix enables the UI that ships with Codex Desktop for Windows but is hidden by a runtime defect:

**Settings → Connections → Control other devices**

This project does not modify `ChatGPT.exe`, `app.asar`, or anything under
`C:\Program Files\WindowsApps`. After installation, a persistent tray supervisor
manages everything automatically.

The public project and repository name is **CodexRemote-fix**. Legacy script
filenames, the `%LOCALAPPDATA%\CodexControlOtherDevices` runtime root, and the
scheduled-task identifiers remain unchanged internally so existing installations
can upgrade in place without losing settings or device authorization.

> [!IMPORTANT]
> Complete the MFA, SSO, or passkey checks required by your account or workspace before enrolling a device.

> [!WARNING]
> This is an unofficial runtime compatibility project. It enables Chromium debugging on a random
> `127.0.0.1` port. Run it only on a trusted Windows machine, and re-run the compatibility check
> after every Codex update.

## What this fixes

On affected Windows builds, Codex Desktop already contains **Settings → Connections →
Control other devices**, but a runtime defect hides the tab. CodexRemote-fix restores
that existing page and leaves the Codex UI, account authorization, and enrollment flow intact.

![Control other devices tab before and after](docs/assets/codexremote-fix-tab-before-after-en-US.png)

## Quick start

1. Download `CodexRemote-fix-2.5.1-setup.exe` and `CodexRemote-fix-2.5.1-setup.exe.sha256.txt` from the [Releases](https://github.com/naipi11/CodexRemote-fix/releases) page, then verify the SHA-256.
2. Run `CodexRemote-fix-2.5.1-setup.exe`; no administrator rights are required.
   Windows 10 users should ensure that .NET Framework 4.8 is installed for the native TrayHost.
3. The tray supervisor starts automatically and creates the desktop shortcut **CodexRemote-fix**. Setup waits until the new runtime and TrayHost are ready, then offers **Restart now** or **Later**. Choose **Restart now** only when it is safe for Codex to close and relaunch into a repaired session; choose **Later** to leave the current Codex session untouched and resume safely after a later manual or normal Codex launch. When the connection reports **Connected**, open **Settings → Connections → Control other devices** to enroll or use the device.

The current installer and its SHA-256 checksum are always published on the
[Releases](https://github.com/naipi11/CodexRemote-fix/releases) page.

To upgrade, run the new installer over the previous installation. Existing settings and device
keys are preserved in place. The installer waits for the new runtime and tray before it offers
the restart choice, and it safely clears only completed recovery work left by an interrupted
upgrade.

Verified on Windows 11 · Codex Desktop `26.818.2441.0` · Node.js `22.23.1`:
the hidden controller tab, native tray menu, bilingual menu switching, and persistent
supervisor are working.

## What's new in v2.5.1

- Fixed the new-install Supervisor startup contract so the complete schema-two active runtime pointer is accepted before readiness is signaled.
- Added a regression test for both fresh-install and upgrade-shaped active runtime pointers.

## What's new in v2.5.0

- Rebuilt restart and repair as a durable Supervisor-owned lifecycle that resumes safely after delayed or manual Codex launches.
- Simplified the tray to truthful connection/protection status, one repair action, language, logs, About, and safe Exit.
- Made upgrades wait for the new runtime and tray, preserved authorized devices, and unified Windows Settings and direct uninstall behind a fail-closed cleanup flow.

## What's new in v2.4.23

- Replaced the embedded COM activator with the standard Windows AppsFolder launch route.
- Preserved reliable **Restart now** behavior while removing the signature that triggered Defender's download heuristic.
- Added regression coverage for the exact Explorer AppsFolder activation request.

## What's new in v2.4.22

- Fixed **Restart now** closing Codex without reopening it by using Windows' native packaged-app activation API.
- Ordinary recovery uses the exact Codex AUMID instead of executing the WindowsApps binary directly.
- Added a regression test that keeps ordinary and controlled launch paths separate.

## What's new in v2.4.21

- Fixed a TrayHost parent-reader disposal race that could make the tray icon disappear while the controlled Codex session remained active.
- TrayHost shutdown now waits for its background pipe threads before releasing synchronization handles.
- Added a native regression test for the remote-fault disposal race.

## What's new in v2.4.20

- After installation, show an English prompt: restart Codex now or restart it manually later.
- The installer never closes or restarts Codex automatically; choosing **Later** leaves the current session untouched.
- The installer now stops the prior CodexRemote-fix supervisor from its persistent runtime, validates the packaged TrayHost payload, and shows the prompt only after the new runtime is active.
- Choosing **Restart now** safely closes the current Codex session and launches a fresh controlled session after explicit user confirmation.
- Runtime activation now continues in a background worker, so the setup window can finish without freezing during the handoff.
- Tray language changes wait for the native menu host to acknowledge the new presentation before returning.
- The reissued installer verifies an ordinary Codex recovery before controlled activation, preventing a single-instance launch race.
- If restart confirmation cannot be completed, the new runtime stays active and the user is asked to restart Codex manually instead of receiving a false activation-failure message.

## What's new in v2.4.19

- Added a native **About** menu item; it opens an information dialog with the active CodexRemote-fix version, such as `2.4.19`.
- The installer now stops the verified running supervisor before replacing the installed runtime, while preserving device keys and persistent state.
- The existing atomic runtime upgrade remains in place; old runtime files are retired only after the new runtime is activated successfully.

## What's new in v2.4.18

- Centered the CodexRemote-fix icon, product name, language switch, and verified project badges in both README languages.
- Enabled repository Dependabot alerts and automatic security updates.
- Added scheduled and push/PR CodeQL scanning for the JavaScript/TypeScript and C# portions of the project.

## What's new in v2.4.17

- Major fix: authorized remote-control devices now survive Codex updates without re-pairing.
- Restored the preserved enrollment mapping through Codex's host bridge before refreshing remote connections.
- Patched an already-cached native device-key addon export in place, so existing Codex consumers use the corrected implementation.
- Kept the existing device keys, server-side authorization, and normal Codex enrollment flow unchanged.

## What's new in v2.4.16

- Fixed a Windows PowerShell redirected-input UTF-8 preamble that could make TrayHost exit before signaling readiness.
- Kept strict protocol validation: only the initial bootstrap frame accepts one BOM; authenticated frames remain unchanged.
- Added Windows GitHub Actions validation for pull requests and pushes to `main`.
- Preserved the existing native Win32 tray, encrypted device-key store, and server-side authorization.

## Everyday use

- The logon task `Codex Control Other Devices Supervisor` starts the tray supervisor automatically; no manual steps are needed.
- The desktop shortcut **CodexRemote-fix** is an optional way to start the tray supervisor if its icon is not visible. It does not start a repair or change a Codex session by itself.
- When the connection status is **Connected**, open **Settings → Connections → Control other devices** to enroll or use it.
- New Codex builds start with `--remote-debugging-port` but no `--inspect`; the supervisor recognizes that launch shape and performs the takeover automatically.
- The tray menu supports Follow system, Chinese, and English; switching applies immediately without restarting anything.
- Updating this project or Codex does not require reinstalling the supervisor; the installer atomically switches versioned runtimes.
- If an explicit repair is needed, use **Check and repair remote connection**. Codex may close and relaunch once, and existing device pairing and authorization are preserved. A completed recovery left behind by an interrupted upgrade is cleared safely on the next supervisor start.

## Connection and protection status

The tray reports two independent, truthful status lines instead of inferring readiness from color alone.

- Connection is one of **Waiting for Codex**, **Checking**, **Connected**, **Repair needed**, or **Error**.
- Protection is one of **Running**, **Reconnecting**, or **Stopping**.
- **Check and repair remote connection** is the one repair action. It may request a controlled Codex restart only when needed; it never removes device authorization.
- **Exit** is a Safe Exit: it stops CodexRemote-fix protection and may restore Codex to ordinary mode before the tray host exits. Relaunch the desktop shortcut or sign in again to resume protection.

## Releases

Every tagged release ships a Windows installer and its SHA-256 checksum as release assets.
The `.github/workflows/release.yml` workflow builds the installer from the tag automatically,
so the 2.5.1 release includes the ready-to-run `CodexRemote-fix-2.5.1-setup.exe`
and `CodexRemote-fix-2.5.1-setup.exe.sha256.txt`.

Each release appends a short English change summary to the GitHub release body. The README and
[CHANGELOG.md](CHANGELOG.md) retain the bilingual documentation history.

After a Codex Desktop update, check the [Releases](https://github.com/naipi11/CodexRemote-fix/releases)
page for a newer installer, or run the **CodexRemote-fix compatibility check** shortcut from the Start menu
to confirm the current supervisor still matches.

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=naipi11/CodexRemote-fix&type=Date)](https://www.star-history.com/#naipi11/CodexRemote-fix&Date)

## External renderer shared CDP

When the External renderer Windows runtime is installed, the supervisor automatically
uses its saved renderer port, or `9335` when no saved state exists, if that
loopback port is available for the special Codex session. The renderer CDP port
can therefore be shared with External renderer; the temporary Electron main-process
Inspector remains separate and is closed after bridge installation.

If that preferred port is paused, unavailable, excluded because it is already
the main Inspector port, or occupied by a non-Codex listener, CodexRemote-fix
selects a different dynamic loopback renderer port. An External renderer
`pause` marker skips integration. Missing or invalid External renderer state, and a
failed handoff, are handled safely without blocking the Codex session. The
integration does not promise Browser-ID or port reuse in these fallback cases.

Neither Codex nor External renderer installation files are modified.

## Tray menu

![Real Windows tray menu capture](docs/assets/codexremote-fix-real-tray-menu-zh-CN.png)

*Real Windows capture; UI language is mixed Chinese/English and no desktop or skin is included.*

The compiled native Win32 TrayHost menu presents the connection and protection status, then only
**Check and repair remote connection**, language, logs, About, and **Exit**. It has no automation,
candidate-trial, or uninstall command.

## Troubleshooting

Still no **Control other devices** tab?

1. Check the tray's connection and protection labels; **Waiting for Codex** or **Checking** means it is not yet ready.
2. Run the **CodexRemote-fix compatibility check** shortcut from the Start menu and confirm `Ready: True`.
3. Check the logs under `%LOCALAPPDATA%\CodexControlOtherDevices\logs\`.
4. Make sure security software is not blocking `node.exe` from loopback access.
5. Exit all Codex processes and retry; the supervisor restarts Codex at most once.

Enrollment or authorization fails?

- Complete MFA/SSO/passkey required by the account or workspace.
- Use the same ChatGPT account and workspace in Codex and the browser.
- For organization workspaces, confirm the admin allows Remote Control.

External renderer did not attach to an already-running session?

Exit Codex, open **CodexRemote-fix** from the desktop, then relaunch Codex.

## Uninstall

The tray has no uninstall command. Use **Windows Settings → Apps → Installed apps** to uninstall
**CodexRemote-fix**, or run the installed `unins000.exe` directly from the application folder.
Both entries use the same external, fail-closed cleanup transaction; if it cannot prove the current
runtime and session identity, it protects the installed files instead of guessing. The DPAPI device
key store remains in place, so existing authorized devices are preserved. Removing a local key would
not revoke server authorization; revoke the device in Codex first if that is your intent.

## What it fixes

Affected Windows packages have all of the following characteristics:

1. The Windows controller page, strings, and backend calls are already shipped.
2. Statsig gate `782640499` is consumed with inverted semantics: `true` hides `showControlOtherDevices`.
3. The main-process device-key entry point accepts only `process.platform === "darwin"`.
4. The Windows package does not ship `remote-control-device-key.node`.

Official docs: [Remote connections](https://learn.chatgpt.com/docs/remote-connections).
This project only fills the local Windows runtime gap. It does not bypass account authorization,
MFA/SSO/passkeys, workspace policy, or server permissions.

## Security model

- Debug ports bind only to a random `127.0.0.1`; the main-process Inspector must close after injection.
- Any process running as the same Windows user can reach these ports, so only use a trusted machine.
- The device private key is stored at `%CODEX_HOME%\remote-control-device-keys.windows.json`
  (or `%USERPROFILE%\.codex\...` when `CODEX_HOME` is unset), encrypted with DPAPI current-user scope.
  It is a software key, not a TPM-backed non-exportable key.
- Moving or deleting the local key does not revoke server authorization; revoke the device in Codex first.

See [SECURITY.md](SECURITY.md) and [docs/TECHNICAL.md](docs/TECHNICAL.md).

## Diagnostics

Logs live in `%LOCALAPPDATA%\CodexControlOtherDevices\logs\`: `install.log`, `supervisor.log`,
`bootstrap.log`, and `transactions.log`.

## Project layout

```text
src/persistence/   Tray supervisor, session controller, installer lifecycle
src/runtime/       Clean-room bridge implementation
tests/             Repository tests and persistence tests
docs/              Technical docs, clean-room notes, bilingual screenshots
```

## License and provenance

[MIT](LICENSE) © 2026 naipi11. Root-cause analysis and the runtime technique come from
[hunterbeach's Codex Windows runtime remote control Gist](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80);
the main-process approach credits [zdaar/codex-hacks](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py),
and the renderer injection pattern adapts [brunolemos' feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae).
The final `src/runtime` is an isolated clean-room rewrite with no unlicensed upstream source text;
see [docs/CLEANROOM.md](docs/CLEANROOM.md) and [NOTICE.md](NOTICE.md).
This project is unofficial, is not affiliated with OpenAI, and does not redistribute OpenAI binaries or assets.
