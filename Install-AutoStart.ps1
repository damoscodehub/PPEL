#requires -version 5.1
<#
  Install-AutoStart.ps1
  =====================
  Sets up Option C: the launcher starts automatically the moment Premiere Pro
  launches, and exits when Premiere closes (the launcher already self-exits
  10s after Premiere closes). When Premiere is NOT running, the launcher uses
  0 MB of memory — there is no resident process.

  How it works:
    1. Enables Windows "Audit Process Creation" (Event 4688) so every process
       start is written to the Security event log.  (Requires admin; a UAC
       prompt appears once.)
    2. Creates a scheduled task "Premiere Extension Launcher AutoStart" whose
       trigger fires on Event 4688 ONLY when the created process is one of the
       installed "Adobe Premiere Pro.exe" executables (exact-path match; both
       2025 and 2026 installs are detected).
    3. The task action runs the installed launcher (%LOCALAPPDATA%\...
       PremiereExtensionLauncher\launcher.ps1), which self-exits when
       Premiere closes.

  Usage:
    runs as normal user -> self-elevates via UAC
    .\Install-AutoStart.ps1            # install / re-create
    .\Install-AutoStart.ps1 -Remove    # remove task + disable audit

  Requirements:
    - The launcher must already be installed (run Install-CEP-Bridge.ps1 once).
#>
param([switch]$Remove)

$ErrorActionPreference = "Stop"
$taskName = "Premiere Extension Launcher AutoStart"

function Test-Admin { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

# --- Self-elevate if not admin (audit policy requires admin) ---
if (-not (Test-Admin)) {
  Write-Host "Restarting elevated to enable process-creation auditing (UAC prompt)..."
  $elevatedArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
  if ($Remove) { $elevatedArgs += "-Remove" }
  Start-Process powershell.exe -ArgumentList $elevatedArgs -Verb RunAs -Wait
  exit $LASTEXITCODE
}

# --- Determine launcher path (must already be installed) ---
$launcherPs1 = Join-Path $env:LOCALAPPDATA "PremiereExtensionLauncher\launcher.ps1"
if (-not (Test-Path $launcherPs1)) {
  Write-Warning "Launcher not installed at '$launcherPs1'. Run Install-CEP-Bridge.ps1 first."
  exit 1
}

# --- Audit Process Creation (Event 4688) ---
$auditSub = "Process Creation"
if ($Remove) {
  & auditpol /set "/subcategory:$auditSub" /success:disable 2>$null
  Write-Host "Disabled Audit $auditSub (Event 4688)."
} else {
  & auditpol /set "/subcategory:$auditSub" /success:enable 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not enable Audit $auditSub (exit $LASTEXITCODE). The task will be created but never fires without Event 4688."
  } else {
    Write-Host "Enabled Audit $auditSub (Event 4688) so the trigger can see Premiere start."
  }
}

# --- Discover all installed Premiere executables ---
$exePaths = @()
Get-ChildItem "C:\Program Files\Adobe" -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'Premiere' } |
  ForEach-Object {
    $exe = Join-Path $_.FullName "Adobe Premiere Pro.exe"
    if (Test-Path $exe) { $exePaths += $exe }
  }

# Also honor an explicitly set alternate location (e.g. custom install root).
if ($env:PREMIERE_AUTOSTART_EXE -and (Test-Path $env:PREMIERE_AUTOSTART_EXE)) {
  $exePaths += $env:PREMIERE_AUTOSTART_EXE
}
$exePaths = $exePaths | Select-Object -Unique

if ($exePaths.Count -eq 0) {
  Write-Warning "No 'Adobe Premiere Pro.exe' found under C:\Program Files\Adobe. Task not created."
  if (-not $Remove) { exit 1 }
}

# --- Build event query: Event 4688 with exact NewProcessName match per exe ---
$pathOrs = (($exePaths | ForEach-Object { "Data='$_'" }) -join " or ")
$queryXml = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*[System[(EventID=4688)]] and *[EventData[Data[@Name='NewProcessName'] and ($pathOrs)]]</Select>
  </Query>
</QueryList>
"@

# --- (Re)create scheduled task via Task Scheduler COM (reliable for event triggers) ---
$schedule   = New-Object -ComObject Schedule.Service
$schedule.Connect()
$taskFolder = $schedule.GetFolder("\")

if ($Remove) {
  try { $taskFolder.DeleteTask($taskName, 0); Write-Host "Removed scheduled task '$taskName'." }
  catch { Write-Host "No scheduled task '$taskName' to remove." }
  exit 0
}

$task = $schedule.NewTask(0)

# Settings: keep alive long enough for any Premiere session, ignore battery states
$task.Settings.ExecutionTimeLimit = "PT168H"          # 7 days
$task.Settings.DisallowStartIfOnBatteries = $false
$task.Settings.StopIfGoingOnBatteries = $false
$task.Settings.StartWhenAvailable = $true
$task.Settings.Enabled = $true

# Principal: run as the current interactive user, least privilege
$task.Principal.UserId = "$env:USERDOMAIN\$env:USERNAME"
$task.Principal.LogonType = 3                        # TASK_LOGON_INTERACTIVE_TOKEN
$task.Principal.RunLevel = 0                         # LEAST_PRIVILEGE

# Trigger: event (type 0) on Security log, Event 4688, exact NewProcessName match
$trigger = $task.Triggers.Create(0)
$trigger.Subscription = $queryXml
$trigger.Enabled = $true

# Action: execute the installed launcher (hidden)
$action = $task.Actions.Create(0)
$action.Path = "powershell.exe"
$action.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPs1`""

# Register (flags 6 = CREATE + UPDATE). userId=NULL + password=NULL + LogonType=INTERACTIVE(3)
$taskFolder.RegisterTaskDefinition($taskName, $task, 6, $null, $null, 3, $null) | Out-Null
Write-Host "Scheduled task '$taskName' created (runs only when Premiere launches)."
Write-Host ""
Write-Host "Task trigger query:"
Write-Host $queryXml
Write-Host ""
Write-Host "Next steps: 1) the launcher is now started automatically by Premiere;"
Write-Host "            2) the launcher still self-exits ~10s after Premiere closes."