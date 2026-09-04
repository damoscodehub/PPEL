$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1) Install the CEP bridge into the per-user CEP extension directory.
$cepDest = Join-Path $env:APPDATA "Adobe\CEP\extensions\com.premiere.extensionlauncher.cepbridge"
New-Item -ItemType Directory -Force -Path $cepDest | Out-Null
Copy-Item -Recurse -Force (Join-Path $root "cep-bridge\*") $cepDest
Write-Host "CEP bridge installed to $cepDest"

# 2) Install the UXP bridge with Adobe's UPIA if it is available.
$ccx = Join-Path $root "Premiere_Extension_Launcher_UXP_Bridge.ccx"
$upiCandidates = @(
  "$env:ProgramFiles\Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe",
  "${env:ProgramFiles(x86)}\Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe"
)
$upi = $upiCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($upi) {
  & $upi /install $ccx
  Write-Host "UXP bridge installation requested through Adobe UPIA."
} else {
  Write-Warning "Adobe UPIA was not found. Double-click the .ccx file to install the UXP bridge, or install it with UXP Developer Tool."
}

# 3) Copy the desktop launcher to a stable per-user location.
$installRoot = Join-Path $env:LOCALAPPDATA "PremiereExtensionLauncher"
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
Copy-Item -Recurse -Force (Join-Path $root "launcher\*") $installRoot
Write-Host "Desktop launcher installed to $installRoot"

# 3b) Create a desktop shortcut for manual launch.
$launchCmd = Join-Path $installRoot "Launch.cmd"
if (Test-Path $launchCmd) {
  $desktop = [Environment]::GetFolderPath("Desktop")
  $shortcutPath = Join-Path $desktop "Premiere Extension Launcher.url"
  $body = @("[InternetShortcut]", "URL=file:///$($launchCmd -replace '\\','/')")
  Set-Content -LiteralPath $shortcutPath -Value $body -Encoding Unicode
  Write-Host "Desktop shortcut created: $shortcutPath"
}

# 4) REMOVE old Startup shortcut (from previous versions).
$startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$oldShim = Join-Path $startup "Premiere Extension Launcher.cmd"
if (Test-Path $oldShim) {
  Remove-Item -Force $oldShim
  Write-Host "Removed old Startup shortcut."
}

# 5) Check for and remove any Registry Run keys from previous versions.
$regRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$regValue = Get-ItemProperty -Path $regRun -Name "PremiereExtensionLauncher" -ErrorAction SilentlyContinue
if ($regValue) {
  Remove-ItemProperty -Path $regRun -Name "PremiereExtensionLauncher" -Force
  Write-Host "Removed old Registry Run entry."
}

Write-Host ""
Write-Host "Installation complete."
Write-Host "Manual launch: double-click the 'Premiere Extension Launcher' desktop shortcut"
Write-Host "  (or run $installRoot\Launch.cmd)"
Write-Host "Hotkey: Ctrl+Shift+Alt+E"
Write-Host ""
Write-Host "The launcher is started manually now (Premiere Pro 2026 does not reliably"
Write-Host "auto-load silent CEP extensions). It stays alive until Premiere closes."
Write-Host ""
Write-Host "Restart Premiere before testing so the CEP/UXP bridges start cleanly."
