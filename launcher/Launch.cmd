@echo off
rem Launch the Premiere Extension Launcher manually.
setlocal
set "SCRIPT_DIR=%~dp0"
set "LAUNCHER=%SCRIPT_DIR%launcher.ps1"
if exist "%LAUNCHER%" goto run
set "LAUNCHER=%LOCALAPPDATA%\PremiereExtensionLauncher\launcher.ps1"
if not exist "%LAUNCHER%" (
  echo Could not find launcher.ps1. Please run Install-CEP-Bridge.ps1 first.
  pause
  exit /b 1
)
:run
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LAUNCHER%"
exit /b 0
