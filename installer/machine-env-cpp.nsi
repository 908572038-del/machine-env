Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"

!ifndef SourceExe
  !define SourceExe "..\build\machine-env-cpp.exe"
!endif
!ifndef ConfigScript
  !define ConfigScript "configure-mcp.ps1"
!endif
!ifndef OutputFile
  !define OutputFile "..\build\machine-env-cpp-setup.exe"
!endif

!define AppName "machine-env-cpp"
!define AppVersion "0.2.0"
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
  SetOutPath "$INSTDIR"
  File /oname=machine-env-cpp.exe "${SourceExe}"
  File /oname=configure-mcp.ps1 "${ConfigScript}"

  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\configure-mcp.ps1" -Mode Install -ExePath "$INSTDIR\machine-env-cpp.exe"'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "MCP configuration failed (error code: $0). The files are installed; fix the configuration and retry."
    Abort
  ${EndIf}

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UninstallKey}" "DisplayName" "${AppName}"
  WriteRegStr HKCU "${UninstallKey}" "DisplayVersion" "${AppVersion}"
  WriteRegStr HKCU "${UninstallKey}" "Publisher" "machine-env"
  WriteRegStr HKCU "${UninstallKey}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UninstallKey}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UninstallKey}" "NoModify" 1
  WriteRegDWORD HKCU "${UninstallKey}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\configure-mcp.ps1" -Mode Uninstall -ExePath "$INSTDIR\machine-env-cpp.exe"'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Could not safely update the MCP configuration (error code: $0). Uninstall was cancelled."
    Abort
  ${EndIf}

  DeleteRegKey HKCU "${UninstallKey}"
  Delete "$INSTDIR\machine-env-cpp.exe"
  Delete "$INSTDIR\configure-mcp.ps1"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
