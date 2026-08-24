[Setup]
#ifndef TrayHostArtifactDirectory
#define TrayHostArtifactDirectory SourcePath + "\generated\trayhost"
#endif
AppId={{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}
AppName=CodexRemote-fix
AppVersion={#ProjectVersion}
AppVerName=CodexRemote-fix {#ProjectVersion}
AppPublisher=naipi11
AppPublisherURL=https://github.com/naipi11/CodexRemote-fix
AppSupportURL=https://github.com/naipi11/CodexRemote-fix/issues
AppUpdatesURL=https://github.com/naipi11/CodexRemote-fix/releases
VersionInfoVersion={#ProjectVersion}.0
DefaultDirName={localappdata}\CodexControlOtherDevices-installer
DefaultGroupName=CodexRemote-fix
UsePreviousGroup=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=CodexRemote-fix-{#ProjectVersion}-setup
SetupIconFile=..\assets\codexremote-fix\codexremote-fix.ico
UninstallDisplayIcon={app}\assets\CodexRemote-fix.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no
SetupLogging=yes
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.zh-CN.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\NOTICE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\SECURITY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\package.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\CodexControlOtherDevices.iss"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\build.ps1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\build-trayhost.ps1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\TrayHostBuild.psm1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\TrayHostReferencePack.psm1"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "..\build\trayhost-packages.lock.json"; DestDir: "{app}\build"; Flags: ignoreversion
Source: "{#TrayHostArtifactDirectory}\CodexRemote.TrayHost.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#TrayHostArtifactDirectory}\CodexRemote.TrayHost.exe.config"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#TrayHostArtifactDirectory}\trayhost-build-provenance.json"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\.github\workflows\release.yml"; DestDir: "{app}\.github\workflows"; Flags: ignoreversion
Source: "..\assets\codexremote-fix\codexremote-fix.ico"; DestDir: "{app}\assets"; DestName: "CodexRemote-fix.ico"; Flags: ignoreversion
Source: "..\assets\codexremote-fix\codexremote-fix.ico"; DestDir: "{app}\assets\codexremote-fix"; Flags: ignoreversion
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\tests\*"; DestDir: "{app}\tests"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\Install-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Uninstall-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Start-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Reset-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Test-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Activate-CcodRemoteFix.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Prompt-CcodRestart.ps1"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{userprograms}\Codex Control other devices\Codex Control other devices for Windows.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Open the tray supervisor.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Compatibility check.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Uninstall Codex Control other devices.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\CodexRemote-fix.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\CodexRemote-fix compatibility check.lnk"
Type: files; Name: "{userprograms}\Codex Control other devices\Uninstall CodexRemote-fix.lnk"
Type: dirifempty; Name: "{userprograms}\Codex Control other devices"
Type: files; Name: "{userdesktop}\Codex 设备连接 (Device Connection).lnk"

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-CodexControlOtherDevices.ps1"" -BackupDeviceKeyStore"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallCodexControlOtherDevices"

[Icons]
Name: "{group}\CodexRemote-fix"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{localappdata}\CodexControlOtherDevices\bootstrap.ps1"" -InstallRoot ""{localappdata}\CodexControlOtherDevices"" -EntryMode Explicit"; WorkingDir: "{localappdata}\CodexControlOtherDevices"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{group}\CodexRemote-fix compatibility check"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Test-CodexControlOtherDevices.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{group}\Uninstall CodexRemote-fix"; Filename: "{app}\unins000.exe"; IconFilename: "{app}\assets\CodexRemote-fix.ico"
Name: "{userdesktop}\CodexRemote-fix"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{localappdata}\CodexControlOtherDevices\bootstrap.ps1"" -InstallRoot ""{localappdata}\CodexControlOtherDevices"" -EntryMode Explicit"; WorkingDir: "{localappdata}\CodexControlOtherDevices"; IconFilename: "{app}\assets\CodexRemote-fix.ico"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Parameters: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  Parameters := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\Activate-CcodRemoteFix.ps1') + '" -AppRoot "' + ExpandConstant('{app}') + '" -InstallRoot "' + ExpandConstant('{localappdata}\CodexControlOtherDevices') + '"';
  if not WizardSilent then
    Parameters := Parameters + ' -Prompt';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '', SW_HIDE, ewNoWait, ResultCode);
end;
