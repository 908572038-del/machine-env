Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"

!ifndef SourceExe
  !define SourceExe "..\build\machine-env-cpp.exe"
!endif
!ifndef ConfigScript
  !define ConfigScript "configure-mcp.ps1"
!endif
; configure-mcp.ps1 no longer carries the per-client layout table; it reads it
; from client-registry.ps1 at runtime. Both files have to ship together or the
; registration step fails with "client registry not found".
!ifndef RegistryScript
  !define RegistryScript "client-registry.ps1"
!endif
; The installer registers the editor it can configure unattended. Other clients
; are opt-in through install.ps1 -Client, so the default is stated explicitly
; here instead of relying on the script default staying the same.
!ifndef InstallClient
  !define InstallClient "copilot"
!endif
!ifndef OutputFile
  !define OutputFile "..\build\machine-env-cpp-setup.exe"
!endif

!define AppName "machine-env-cpp"
!define AppVersion "0.3.1"
!define UninstallKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\machine-env-cpp"

Name "${AppName}"
Caption "${AppName} ${AppVersion} Setup"
OutFile "${OutputFile}"
InstallDir "$LOCALAPPDATA\Programs\machine-env-cpp"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUnInstDetails show

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "Install"
  ; The editor may already be running the installed copy, and replacing an
  ; executable that is in use is not guaranteed to succeed. Stopping it first
  ; makes an upgrade deterministic rather than dependent on the sharing mode.
  ; taskkill answers "process not found" whenever nothing is running, which is
  ; the ordinary case for a first install, and ExecToLog would print that as an
  ; error line in a step that succeeded. The output is captured and dropped:
  ; the side effect is the point, and the exit code is not consulted.
  nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /IM machine-env-cpp.exe /F'
  Pop $0
  Pop $1
  SetOutPath "$INSTDIR"
  File /oname=machine-env-cpp.exe "${SourceExe}"
  File /oname=configure-mcp.ps1 "${ConfigScript}"
  File /oname=client-registry.ps1 "${RegistryScript}"

  ; Register the uninstaller first, so a failed configuration still leaves a
  ; product the user can remove through Apps & features.
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UninstallKey}" "DisplayName" "${AppName}"
  WriteRegStr HKCU "${UninstallKey}" "DisplayVersion" "${AppVersion}"
  WriteRegStr HKCU "${UninstallKey}" "Publisher" "machine-env"
  WriteRegStr HKCU "${UninstallKey}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UninstallKey}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UninstallKey}" "NoModify" 1
  WriteRegDWORD HKCU "${UninstallKey}" "NoRepair" 1

  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\configure-mcp.ps1" -Mode Install -ExePath "$INSTDIR\machine-env-cpp.exe" -Client ${InstallClient}'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "MCP configuration failed (error code: $0). The server files are installed but not registered; run the uninstaller, or fix the configuration and retry."
    Abort
  ${EndIf}
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\configure-mcp.ps1" -Mode Uninstall -ExePath "$INSTDIR\machine-env-cpp.exe" -Client ${InstallClient}'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Could not safely update the MCP configuration (error code: $0). Uninstall was cancelled."
    Abort
  ${EndIf}

  ; The server is started by the editor, so it is running during an uninstall in
  ; the normal case and holds its own executable open. Without stopping it the
  ; delete silently fails and leaves a stale executable and folder behind while
  ; the uninstaller still reports success. Its "process not found" answer for a
  ; server that was not running is dropped instead of being logged as an error
  ; during an uninstall that is in fact proceeding normally.
  nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /IM machine-env-cpp.exe /F'
  Pop $0
  Pop $1

  DeleteRegKey HKCU "${UninstallKey}"
  Delete "$INSTDIR\machine-env-cpp.exe"
  Delete "$INSTDIR\configure-mcp.ps1"
  Delete "$INSTDIR\client-registry.ps1"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  ; A file that could not be removed must not be reported as a clean removal.
  ${If} ${FileExists} "$INSTDIR\machine-env-cpp.exe"
    Delete /REBOOTOK "$INSTDIR\machine-env-cpp.exe"
    RMDir /REBOOTOK "$INSTDIR"
    MessageBox MB_ICONEXCLAMATION "The server was still in use, so its files could not be removed now. They will be removed the next time Windows restarts."
  ${EndIf}
SectionEnd
