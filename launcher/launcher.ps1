#requires -version 5.1
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$logDir = Join-Path $env:LOCALAPPDATA "PremiereExtensionLauncher\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir "launcher.log"

function Write-Log($msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "$ts  $msg"
  try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch {}
}

# Debug tracing can be enabled by creating "%LOCALAPPDATA%\PremiereExtensionLauncher\debug.flag"
# (or passing -DebugLevel). When on, Write-DebugLog emits rich per-step traces.
$script:debug = Test-Path (Join-Path $env:LOCALAPPDATA "PremiereExtensionLauncher\debug.flag")
function Write-DebugLog($msg) {
  if (-not $script:debug) { return }
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
  try { Add-Content -Path $logFile -Value ("$ts  [dbg] $msg") -ErrorAction Stop } catch {}
}
if ($script:debug) { Write-Log "DEBUG MODE ON (debug.flag present)" }

Write-Log "Launcher started (PID $PID)"

# --- Single-instance Mutex ---
Write-Log "Creating mutex..."
$createdNew = $false
try {
  $mutex = New-Object System.Threading.Mutex($true, "Local\PremiereExtensionLauncher", [ref]$createdNew)
  Write-Log "Mutex created. createdNew=$createdNew"
} catch {
  Write-Log "Mutex creation failed: $($_.Exception.Message). Continuing anyway."
  $createdNew = $true
}
if (-not $createdNew) {
  Write-Log "Another instance is already running. Exiting."
  exit
}
Write-Log "Mutex acquired."

# --- Win32 interop for drag, hotkey ---
$cs = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class Win32 {
  public const int WM_HOTKEY = 0x0312;
  public const int MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_ALT = 0x1;
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("kernel32.dll")] public static extern uint GetLastError();

  public const int WM_NCLBUTTONDOWN = 0xA1;
  public const int HTCAPTION = 0x2;
  public const int HTBOTTOMRIGHT = 0x12;
  public const int HTLEFT = 0x0A;
  public const int HTRIGHT = 0x0B;
  public const int HTTOP = 0x0C;
  public const int HTTOPLEFT = 0x0D;
  public const int HTTOPRIGHT = 0x0E;
  public const int HTBOTTOM = 0x0F;
  public const int HTBOTTOMLEFT = 0x10;
  [DllImport("user32.dll")] public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();

  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  public const int SW_RESTORE = 9;
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
}

public class HotKeyWindow : NativeWindow {
  public event EventHandler HotKeyPressed;
  public HotKeyWindow() { CreateHandle(new CreateParams()); }
  protected override void WndProc(ref Message m) {
    if (m.Msg == Win32.WM_HOTKEY && HotKeyPressed != null) HotKeyPressed(this, EventArgs.Empty);
    base.WndProc(ref m);
  }
  public void DisposeHotKey(int id) { Win32.UnregisterHotKey(this.Handle, id); DestroyHandle(); }
}
"@
Write-Log "Adding Win32 interop types..."
try {
  Add-Type $cs -ReferencedAssemblies System.Windows.Forms
  Write-Log "Win32 types added successfully."
} catch {
  Write-Log "Failed to add Win32 types: $($_.Exception.Message)"
  exit
}

# --- Filesystem CEP scan (primary catalog source; Premiere 2026 does not
# reliably auto-load the silent CEP bridge, so the launcher scans itself). ---
function Scan-CepExtensions {
  $roots = @(
    $(if ($env:APPDATA) { Join-Path $env:APPDATA "Adobe\CEP\extensions" }),
    $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "Common Files\Adobe\CEP\extensions" }),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Common Files\Adobe\CEP\extensions" })
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  $out = @(); $seen = @{}
  foreach ($root in $roots) {
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
    Write-Log ("CEP scan: {0}: {1} entries" -f $root, $dirs.Count)
    foreach ($folder in $dirs) {
      $mf = Join-Path $folder.FullName "CSXS\manifest.xml"
      if (-not (Test-Path -LiteralPath $mf)) { continue }
      $content = $null
      try { $content = Get-Content -LiteralPath $mf -Raw -ErrorAction Stop } catch { continue }
      if (-not $content) { continue }
      $id = ""
      if ($content -match '<Extension\s+Id="([^"]+)"') { $id = $Matches[1] }
      if (-not $id -or $seen[$id]) { continue }
      # Skip template manifests — Premiere resolves &toolName; / %CCX_... at runtime
      if ($id -match '[&%]') { continue }
      $seen[$id] = $true
      $name = ""
      if ($content -match 'ExtensionBundleName="([^"]*)"') { $name = $Matches[1] }
      if ($content -match '<Menu>([\s\S]*?)</Menu>') {
        $menuInner = ($Matches[1] -replace '<[^>]+>', '').Trim()
        if ($menuInner) { $name = $menuInner }
      }
      if (-not $name) { $name = $folder.Name }
      # Skip if name is still a template placeholder
      if ($name -match '^[&%]') { continue }
      $out += , @{ kind = "CEP"; id = $id; name = $name; version = ""; folder = $folder.FullName }
    }
  }
  Write-Log "CEP scan complete: $($out.Count) extensions found"
  return @($out | Sort-Object name)
}

# Bind a C# reflection helper so PowerShell ComboBox height can be forced.
$script:catScanDone = $false

# --- HTTP Listener ---
$port = 17364
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
try { $listener.Start() } catch {
  Write-Log "Failed to start HTTP listener on port $port : $_"
  exit
}
Write-Log "HTTP listener started on port $port."

$script:catalog = @{ cep = @(); uxp = @(); source = "scan" }
$script:uxpQueue = New-Object System.Collections.Queue
$script:catalogDirty = $false
$script:lastStatus = "Starting..."
$script:catalogReceived = $false
$script:DoOpen = $false
$script:formShown = $false

function Send-Json($ctx, $obj, $code = 200) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 8 -Compress))
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = "application/json; charset=utf-8"
  $ctx.Response.Headers.Add("Access-Control-Allow-Origin", "*")
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}

function Handle-Request($ctx) {
  try {
    $path = $ctx.Request.Url.AbsolutePath
    if ($ctx.Request.HttpMethod -eq "OPTIONS") { Send-Json $ctx @{ ok = $true }; return }
    if ($ctx.Request.HttpMethod -eq "POST") {
      $sr = New-Object IO.StreamReader($ctx.Request.InputStream)
      $body = $sr.ReadToEnd(); $obj = $body | ConvertFrom-Json
      if ($path -eq "/catalog/cep") {
        $newExts = @($obj.extensions) | Where-Object { $_.id -notmatch '[&%]' -and $_.name -notmatch '^[&%]' }
        Write-Log "CEP catalog received: $($newExts.Count) extensions"
        $script:catalog.cep = $newExts
        $script:catalogReceived = $true
        $script:catalogDirty = $true
      }
      elseif ($path -eq "/catalog/uxp") {
        $newExts = @($obj.extensions)
        Write-Log "UXP catalog received: $($newExts.Count) extensions"
        $script:catalog.uxp = $newExts
        $script:catalogReceived = $true
        $script:catalogDirty = $true
      }
      elseif ($path -eq "/uxp/result") {
        $script:lastStatus = if ($obj.ok) { "Opened UXP" } else { "UXP error: " + $obj.error }
        Write-Log "UXP result: $script:lastStatus"
      }
      Send-Json $ctx @{ ok = $true }; return
    }
    if ($path -eq "/health") {
      Send-Json $ctx @{ ok = $true; application = "Premiere Extension Launcher"; pid = $PID }
      return
    }
    if ($path -eq "/catalog") { Send-Json $ctx $script:catalog; return }
    if ($path -eq "/uxp/next") {
      if ($script:uxpQueue.Count -gt 0) { Send-Json $ctx $script:uxpQueue.Dequeue() }
      else { Send-Json $ctx @{ command = $false } }
      return
    }
    Send-Json $ctx @{ ok = $false; error = "not found" } 404
  } catch {
    Write-Log "Request error: $($_.Exception.Message)"
    Send-Json $ctx @{ ok = $false; error = $_.Exception.Message } 500
  }
}

# --- Timer for HTTP polling + UI refresh + Premiere monitoring ---
$script:premiereGoneSince = $null
$script:sawPremiere = $false
$graceSeconds = 10

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 100
Write-Log "Timer created."
$script:asyncResult = $null

function Begin-AcceptContext {
  if ($listener.IsListening -and $null -eq $script:asyncResult) {
    try { $script:asyncResult = $listener.BeginGetContext($null, $null) }
    catch { $script:asyncResult = $null }
  }
}

function Pump-Requests {
  while ($listener.IsListening) {
    if ($null -eq $script:asyncResult) {
      Begin-AcceptContext
      if ($null -eq $script:asyncResult) { break }
    }
    if (-not $script:asyncResult.IsCompleted) { break }
    try {
      $ctx = $listener.EndGetContext($script:asyncResult)
      $script:asyncResult = $null
      Handle-Request $ctx
    } catch {
      $script:asyncResult = $null
      break
    }
  }
}

$timer.Add_Tick({
  Pump-Requests
  if ($script:catalogDirty) {
    $script:catalogDirty = $false
    try { Refresh-List } catch { Write-Log "Refresh-List error: $($_.Exception.Message)" }
  }

  $premiereRunning = $false
  try {
    $procs = Get-Process -Name "Adobe Premiere Pro*" -ErrorAction SilentlyContinue
    if ($procs -and $procs.Count -gt 0) { $premiereRunning = $true }
  } catch {}

  if ($premiereRunning) {
    $script:sawPremiere = $true
    $script:premiereGoneSince = $null
  } else {
    if ($script:sawPremiere) {
      if ($null -eq $script:premiereGoneSince) {
        $script:premiereGoneSince = Get-Date
        Write-Log "Premiere closed. Starting grace period."
      } else {
        $elapsed = ((Get-Date) - $script:premiereGoneSince).TotalSeconds
        if ($elapsed -ge $graceSeconds) {
          Write-Log "Premiere absent for ${graceSeconds}s. Shutting down."
          try {
            $script:allowClose = $true
            [void][Win32]::UnregisterHotKey($form.Handle, 1)
            $tray.Visible = $false
            $listener.Stop()
            [Windows.Forms.Application]::Exit()
          } catch { Write-Log "Shutdown error: $_"; exit }
        }
      }
    }
  }
})
[void][System.Reflection.Assembly]::LoadWithPartialName("System.Net.Http")
Add-Type -AssemblyName System.Net.Http

# === FORM ===
$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = "None"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object Drawing.Size(760, 540)
$form.MinimumSize = New-Object Drawing.Size(520, 380)
$form.BackColor = [Drawing.Color]::FromArgb(30, 30, 34)
$form.TopMost = $false
$form.ShowInTaskbar = $false

# === ROOT LAYOUT: ONE DETERMINISTIC TableLayoutPanel (no nested Dock/Fill ambiguity) ===
$rootTlp = New-Object Windows.Forms.TableLayoutPanel
$rootTlp.Dock = [System.Windows.Forms.DockStyle]::Fill
$rootTlp.BackColor = [Drawing.Color]::FromArgb(30, 30, 34)
$rootTlp.ColumnCount = 1
$rootTlp.RowCount = 4
$rootTlp.ColumnStyles.Clear()
$rootTlp.RowStyles.Clear()
[void]$rootTlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$rootTlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 36)))   # title bar
[void]$rootTlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 48)))   # search row
[void]$rootTlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))   # results
[void]$rootTlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))   # status
$form.Controls.Add($rootTlp)

# === TITLE BAR (row 0,0) ===
$titleBar = New-Object Windows.Forms.Panel
$titleBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleBar.Margin = New-Object Windows.Forms.Padding(0)
$titleBar.BackColor = [Drawing.Color]::FromArgb(24, 24, 28)
$rootTlp.Controls.Add($titleBar, 0, 0)

$titleLabel = New-Object Windows.Forms.Label
$titleLabel.Text = "  Premiere Extension Launcher"
$titleLabel.Dock = "Left"
$titleLabel.ForeColor = [Drawing.Color]::FromArgb(200, 200, 200)
$titleLabel.Font = New-Object Drawing.Font("Segoe UI", 10)
$titleLabel.AutoSize = $true
$titleLabel.TextAlign = "MiddleLeft"
$titleLabel.BackColor = [Drawing.Color]::Transparent
$titleBar.Controls.Add($titleLabel)

$btnPanel = New-Object Windows.Forms.Panel
$btnPanel.Dock = "Right"
$btnPanel.Width = 168
$btnPanel.BackColor = [Drawing.Color]::Transparent
$titleBar.Controls.Add($btnPanel)

function Set-WindowButton($btn, $text, $backColor) {
  $btn.Text = $text
  $btn.FlatStyle = "Flat"
  $btn.FlatAppearance.BorderSize = 0
  $btn.BackColor = $backColor
  $btn.ForeColor = [Drawing.Color]::White
  $btn.Font = New-Object Drawing.Font("Segoe UI", 12)
  $btn.Size = New-Object Drawing.Size(56, 36)
  $btn.Dock = "Right"
  $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
  $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(60, 60, 64)
}

$btnClose = New-Object Windows.Forms.Button
Set-WindowButton $btnClose ([char]0x00D7) ([Drawing.Color]::FromArgb(24, 24, 28))
$btnClose.Add_Click({
  $hk.DisposeHotKey(1); $tray.Visible = $false; $listener.Stop()
  [Windows.Forms.Application]::Exit()
})
$btnPanel.Controls.Add($btnClose)

$btnMax = New-Object Windows.Forms.Button
Set-WindowButton $btnMax ([char]0x25A1) ([Drawing.Color]::FromArgb(24, 24, 28))
$btnMax.Add_Click({
  if ($form.WindowState -eq "Maximized") { $form.WindowState = "Normal"; $btnMax.Text = [char]0x25A1 }
  else { $form.WindowState = "Maximized"; $btnMax.Text = [char]0x2585 }
})
$btnPanel.Controls.Add($btnMax)

$btnMin = New-Object Windows.Forms.Button
Set-WindowButton $btnMin ([char]0x2013) ([Drawing.Color]::FromArgb(24, 24, 28))
$btnMin.Add_Click({ $form.WindowState = "Minimized" })
$btnPanel.Controls.Add($btnMin)

$titleBar.Add_MouseDown({
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    [Win32]::ReleaseCapture()
    [Win32]::SendMessage($form.Handle, [Win32]::WM_NCLBUTTONDOWN, [Win32]::HTCAPTION, 0)
  }
})

# === RESIZE GRIP (bottom-right corner for borderless form resizing) ===
$resizeGrip = New-Object Windows.Forms.Panel
$resizeGrip.Size = New-Object Drawing.Size(16, 16)
$resizeGrip.Anchor = "Bottom,Right"
$resizeGrip.BackColor = [Drawing.Color]::Transparent
$resizeGrip.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE
$resizeGrip.Add_MouseDown({
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    [Win32]::ReleaseCapture()
    [Win32]::SendMessage($form.Handle, [Win32]::WM_NCLBUTTONDOWN, [Win32]::HTBOTTOMRIGHT, 0)
  }
})
$form.Controls.Add($resizeGrip)

# === SEARCH ROW (row 0,1) ===
$searchCell = New-Object Windows.Forms.Panel
$searchCell.Dock = [System.Windows.Forms.DockStyle]::Fill
$searchCell.BackColor = [Drawing.Color]::FromArgb(30, 30, 34)
$searchCell.Margin = New-Object Windows.Forms.Padding(10, 6, 10, 4)
$rootTlp.Controls.Add($searchCell, 0, 1)

$combo = New-Object Windows.Forms.ComboBox
$combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$combo.Font = New-Object Drawing.Font("Segoe UI", 15)
$combo.BackColor = [Drawing.Color]::FromArgb(44, 44, 48)
$combo.ForeColor = [Drawing.Color]::White
$combo.FlatStyle = "Flat"
$combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::None
$combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
$combo.Dock = [System.Windows.Forms.DockStyle]::Fill
$searchCell.Controls.Add($combo)

# Watermark label (shown only while the search box is empty and unfocused)
$comboWatermark = New-Object Windows.Forms.Label
$comboWatermark.Text = "Search extensions..."
$comboWatermark.AutoSize = $false
$comboWatermark.Font = $combo.Font
$comboWatermark.ForeColor = [Drawing.Color]::FromArgb(120, 120, 120)
$comboWatermark.BackColor = [Drawing.Color]::FromArgb(44, 44, 48)
$comboWatermark.Dock = [System.Windows.Forms.DockStyle]::Fill
$comboWatermark.Padding = New-Object Windows.Forms.Padding(6, 0, 0, 0)
$comboWatermark.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$searchCell.Controls.Add($comboWatermark)
$comboWatermark.Enabled = $false
$comboWatermark.BringToFront()

# === RESULTS ROW (row 0,2) ===
$list = New-Object Windows.Forms.ListBox
$list.Dock = [System.Windows.Forms.DockStyle]::Fill
$list.Font = New-Object Drawing.Font("Segoe UI", 12)
$list.BackColor = [Drawing.Color]::FromArgb(36, 36, 40)
$list.ForeColor = [Drawing.Color]::White
$list.BorderStyle = "None"
$list.IntegralHeight = $false
$list.Margin = New-Object Windows.Forms.Padding(10, 4, 10, 4)
$rootTlp.Controls.Add($list, 0, 2)

# === STATUS ROW (row 0,3) ===
$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.ForeColor = [Drawing.Color]::FromArgb(120, 120, 120)
$statusLabel.Font = New-Object Drawing.Font("Segoe UI", 9)
$statusLabel.TextAlign = "MiddleLeft"
$statusLabel.Margin = New-Object Windows.Forms.Padding(10, 0, 10, 4)
$rootTlp.Controls.Add($statusLabel, 0, 3)

# --- CATALOG + FILTERING (shared scope) ---
$script:items = @()
function Refresh-List {
  $q = if ($combo.Focused -or $combo.Text -ne $comboWatermark.Text) { $combo.Text } else { "" }
  $q = ($q -replace '"', '').ToLowerInvariant()
  $list.Items.Clear()
  $script:items = @()
  $all = @()
  foreach ($x in @($script:catalog.cep)) { $all += , $x }
  foreach ($x in @($script:catalog.uxp)) { $all += , $x }
  $all = @($all | Sort-Object { $_.name })
  foreach ($x in $all) {
    $label = if ($x.kind -eq "UXP") { "[UXP] $($x.pluginName) - $($x.name)" } else { "[CEP] $($x.name)" }
    $hay = ("$($x.name) $($x.id) $($x.pluginName) $($x.entrypointId) $label").ToLowerInvariant()
    if ($q -eq "" -or $hay.Contains($q)) {
      [void]$list.Items.Add($label)
      $script:items += , $x
    }
  }
  if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

  # Set status text
  if (-not $script:catalogReceived -and $script:catalog.cep.Count -eq 0 -and $script:catalog.uxp.Count -eq 0) {
    $statusLabel.Text = "  Waiting for Premiere extension catalog..."
  } elseif (($script:catalog.cep.Count + $script:catalog.uxp.Count) -eq 0) {
    $statusLabel.Text = "  No extensions were detected."
  } else {
    $statusLabel.Text = "  $($script:items.Count) of $($script:catalog.cep.Count + $script:catalog.uxp.Count) extension(s) found"
  }

  # Refresh autocomplete suggestions from the catalog (Part 7)
  $suggestions = @()
  foreach ($x in $all) {
    $s = if ($x.kind -eq "UXP") { "$($x.pluginName) - $($x.name)" } else { $x.name }
    if ($s -and $suggestions -notcontains $s) { $suggestions += $s }
  }
  $prevText = $combo.Text
  $script:suppressRefresh = $true
  $combo.Items.Clear()
  foreach ($s in $suggestions) { [void]$combo.Items.Add($s) }
  $combo.Text = $prevText
  $combo.SelectionStart = $combo.Text.Length
  $combo.SelectionLength = 0
  $script:suppressRefresh = $false
}

# Seed catalog from filesystem scan (Part 1 + Part 10)
try {
  $scanned = @(Scan-CepExtensions)
  $script:catalog.cep = $scanned
  Write-Log "Launcher self-scan populated CEP catalog: $($script:catalog.cep.Count) extensions (no bridge required)"
} catch {
  Write-Log "Self-scan error: $($_.Exception.Message)"
}
$script:catalogDirty = $true

# === COMBOBOX EVENTS ===
$combo.Add_GotFocus({ $comboWatermark.Visible = $false })
$combo.Add_LostFocus({
  if ($combo.Text -eq "") { $comboWatermark.Visible = $true; Refresh-List }
})
$combo.Add_TextChanged({
  if (-not $script:suppressRefresh) {
    try { Refresh-List } catch { Write-Log "Refresh-List error in TextChanged: $($_.Exception.Message)" }
  }
})
$combo.Add_KeyDown({
  if ($_.KeyCode -eq "Down") {
    [void]$list.Focus()
    if ($list.Items.Count) { $list.SelectedIndex = [Math]::Min($list.SelectedIndex + 1, $list.Items.Count - 1) }
    $_.SuppressKeyPress = $true
  }
  elseif ($_.KeyCode -eq "Up") {
    [void]$list.Focus()
    if ($list.Items.Count -and $list.SelectedIndex -gt 0) { $list.SelectedIndex = $list.SelectedIndex - 1 }
    $_.SuppressKeyPress = $true
  }
  elseif ($_.KeyCode -eq "Escape") { $form.Hide() }
  elseif ($_.KeyCode -eq "Enter") { if ($list.SelectedIndex -ge 0) { Open-Selected } }
})

# === LISTBOX EVENTS ===
# Single click = select; double-click = run (standard behavior).
$list.Add_DoubleClick({
  $script:DoOpen = $true
  Write-DebugLog "ListBox double-click will open index $($list.SelectedIndex)"
})
$list.Add_MouseClick({
  Write-DebugLog "ListBox MouseClick: button=$($_.Button), index=$($list.IndexFromPoint($_.Location)), SelectedIndex=$($list.SelectedIndex)"
})
$list.Add_KeyDown({
  if ($_.KeyCode -eq "Enter") {
    $script:DoOpen = $true
    Write-DebugLog "ListBox Enter -> open"
    $_.SuppressKeyPress = $true
  }
  elseif ($_.KeyCode -eq "Escape") { Write-DebugLog "ListBox Escape -> hide"; $form.Hide() }
  elseif ($_.KeyCode -eq "Back") {
    [void][void]$combo.Focus()
    if ($combo.Text.Length) { $combo.Text = $combo.Text.Substring(0, $combo.Text.Length - 1) }
    $_.SuppressKeyPress = $true
  }
})

# === OPEN EXTENSION VIA PREMIERE NATIVE MENU API ===
# Uses Win32 menu API (GetMenu/GetSubMenu/GetMenuItemID/WM_COMMAND) to directly
# invoke the extension's menu command — no keyboard simulation, no timing issues,
# no risk of keystrokes bleeding into the timeline.
$csMenu = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class WinMenu {
  [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr hMenu, int uIDItem, StringBuilder lpString, int nMaxCount, int uFlag);
  [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);
  [DllImport("user32.dll")] public static extern int GetMenuItemID(IntPtr hMenu, int nPos);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
  public const int WM_COMMAND = 0x0111;
  public const int MF_BYPOSITION = 0x00000400;
}
"@
try {
  Add-Type $csMenu -ReferencedAssemblies System.Windows.Forms
  Write-Log "WinMenu types added successfully."
} catch {
  Write-Log "Failed to add WinMenu types: $($_.Exception.Message)"
}

function Open-ExtensionViaMenu {
  param([string]$extensionName)

  $proc = Get-Process -Name "Adobe Premiere Pro*" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
    Select-Object -First 1
  if (-not $proc) {
    Write-Log "OpenViaMenu: Premiere Pro not running or no window found"
    return $false
  }

  $hwnd = $proc.MainWindowHandle
  Write-DebugLog "OpenViaMenu: Premiere window handle=$hwnd"

  # Restore if minimized (don't un-maximize)
  $isMaximized = [Win32]::IsZoomed($hwnd)
  if (-not $isMaximized) {
    try { [Win32]::ShowWindow($hwnd, [Win32]::SW_RESTORE) | Out-Null } catch {}
    Start-Sleep -Milliseconds 100
  }
  [Win32]::SetForegroundWindow($hwnd) | Out-Null
  Start-Sleep -Milliseconds 200

  # Get menu bar
  $hMenu = [WinMenu]::GetMenu($hwnd)
  if ($hMenu -eq [IntPtr]::Zero) {
    Write-Log "OpenViaMenu: GetMenu returned null (no menu bar)"
    return $false
  }
  $menuCount = [WinMenu]::GetMenuItemCount($hMenu)
  Write-DebugLog "OpenViaMenu: top-level menu count=$menuCount"

  # 1) Locate the "Window" top-level menu by name
  $windowIndex = -1
  for ($i = 0; $i -lt $menuCount; $i++) {
    $sb = New-Object System.Text.StringBuilder(256)
    [WinMenu]::GetMenuString($hMenu, $i, $sb, 256, [WinMenu]::MF_BYPOSITION)
    $top = ($sb.ToString() -replace "&", "").Trim()
    Write-DebugLog "OpenViaMenu: TopMenu[$i]='$top'"
    if ($top -match "^Window$") { $windowIndex = $i; break }
  }
  if ($windowIndex -lt 0) {
    Write-Log "OpenViaMenu: 'Window' top-level menu not found"
    return $false
  }
  Write-DebugLog "OpenViaMenu: Window menu at index $windowIndex"

  # 2) Locate the "Extensions" submenu within the Window menu (it's a popup, id=-1)
  $hWindowMenu = [WinMenu]::GetSubMenu($hMenu, $windowIndex)
  if ($hWindowMenu -eq [IntPtr]::Zero) {
    Write-Log "OpenViaMenu: Window submenu is null"
    return $false
  }
  $extIndex = -1
  $winCount = [WinMenu]::GetMenuItemCount($hWindowMenu)
  for ($j = 0; $j -lt $winCount; $j++) {
    $sb2 = New-Object System.Text.StringBuilder(256)
    [WinMenu]::GetMenuString($hWindowMenu, $j, $sb2, 256, [WinMenu]::MF_BYPOSITION)
    $item = ($sb2.ToString() -replace "&", "").Trim()
    Write-DebugLog "OpenViaMenu: WindowMenu[$j]='$item'"
    if ($item -match "^Extensions$") { $extIndex = $j; break }
  }
  if ($extIndex -lt 0) {
    Write-Log "OpenViaMenu: 'Extensions' submenu not found in Window menu"
    return $false
  }
  Write-DebugLog "OpenViaMenu: Extensions submenu at WindowMenu[$extIndex]"

  # 3) Get the Extensions submenu handle
  $hExtensionsMenu = [WinMenu]::GetSubMenu($hWindowMenu, $extIndex)
  if ($hExtensionsMenu -eq [IntPtr]::Zero) {
    Write-Log "OpenViaMenu: Extensions submenu handle is null"
    return $false
  }

  # 4) Find the target extension by exact name
  $itemCount = [WinMenu]::GetMenuItemCount($hExtensionsMenu)
  Write-DebugLog "OpenViaMenu: Extensions submenu has $itemCount items"
  $extPos = -1
  for ($k = 0; $k -lt $itemCount; $k++) {
    $sb3 = New-Object System.Text.StringBuilder(256)
    [WinMenu]::GetMenuString($hExtensionsMenu, $k, $sb3, 256, [WinMenu]::MF_BYPOSITION)
    $name = ($sb3.ToString() -replace "&", "").Trim()
    Write-DebugLog "OpenViaMenu: ExtMenuItem[$k]='$name'"
    if ($name -eq $extensionName) { $extPos = $k; break }
  }
  if ($extPos -lt 0) {
    Write-Log "OpenViaMenu: Extension '$extensionName' not found in Extensions menu"
    return $false
  }

  # 5) Get command ID and invoke via WM_COMMAND
  $cmdId = [WinMenu]::GetMenuItemID($hExtensionsMenu, $extPos)
  Write-DebugLog "OpenViaMenu: Command ID for '$extensionName' = $cmdId"
  if ($cmdId -le 0) {
    Write-Log "OpenViaMenu: Command ID $cmdId is invalid (popup?) for '$extensionName'"
    return $false
  }

  [WinMenu]::PostMessage($hwnd, [WinMenu]::WM_COMMAND, $cmdId, 0) | Out-Null
  Write-Log "OpenViaMenu: Sent WM_COMMAND $cmdId for '$extensionName'"
  return $true
}

# === OPEN SELECTED EXTENSION ===
# Fire-and-forget via WebClient.DownloadStringAsync — never blocks UI, never crashes.
function Open-Selected {
  Write-DebugLog "Open-Selected called. SelectedIndex=$($list.SelectedIndex), items.Count=$($script:items.Count)"
  if ($list.SelectedIndex -lt 0) { Write-DebugLog "  abort: SelectedIndex < 0"; return }
  if ($list.SelectedIndex -ge $script:items.Count) { Write-DebugLog "  abort: SelectedIndex >= items.Count"; return }
  $x = $script:items[$list.SelectedIndex]
  Write-Log "Opening: [$($x.kind)] name='$($x.name)' id='$($x.id)'"
  if ($x.kind -eq "CEP") {
    $statusLabel.Text = "  Opening: $($x.name)..."
    $statusLabel.Refresh()
    # Open via Premiere's native menu system (proper dockable panel, not standalone window).
    # Falls back to bridge requestOpenExtension if menu automation fails.
    $menuOk = Open-ExtensionViaMenu -extensionName $x.name
    if ($menuOk) {
      Write-Log "CEP open via menu succeeded for '$($x.name)'."
      $script:lastStatus = "Opened: $($x.name)"
    } else {
      $openUrl = "http://127.0.0.1:17363/open?id=" + [Uri]::EscapeDataString($x.id)
      try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadStringAsync([Uri]$openUrl)
        Write-Log "CEP open via bridge (fallback) for '$($x.name)'."
        $script:lastStatus = "Opened: $($x.name)"
      } catch {
        Write-Log "CEP open FAILED for '$($x.name)': $($_.Exception.Message)"
        $script:lastStatus = "Bridge not reachable"
      }
    }
  } else {
    Write-DebugLog "  UXP branch: enqueuing command"
    $script:uxpQueue.Enqueue(@{ command = $true; pluginId = $x.pluginId; entrypointId = $x.entrypointId; entrypointType = $x.entrypointType })
    Write-Log "UXP command queued for '$($x.name)' (pluginId=$($x.pluginId) ep=$($x.entrypointId))."
    $script:lastStatus = "UXP command queued: $($x.name)"
  }
  Refresh-List
  Write-DebugLog "  Open-Selected done. Hiding form."
  $form.Hide()
}

$openTimer = New-Object Windows.Forms.Timer; $openTimer.Interval = 100
$openTimer.Add_Tick({ if ($script:DoOpen) { $script:DoOpen = $false; Open-Selected } })
$openTimer.Start()

[void]$combo.Focus()

# === HOTKEY: Ctrl+Shift+Alt+E ===
$hk = New-Object HotKeyWindow
$hotkeyId = 1
# 0x0007 = Ctrl+Alt+Shift, 0x45 = E
if (-not [Win32]::RegisterHotKey($hk.Handle, $hotkeyId, 0x0007, 0x45)) {
  Write-Log "Failed to register Ctrl+Shift+Alt+E hotkey. LastError=$([Win32]::GetLastError())"
  $script:lastStatus = "Could not register Ctrl+Shift+Alt+E"
} else {
  Write-Log "Hotkey registered: Ctrl+Shift+Alt+E"
}
$function:ShowLauncher = {
  if ($form.WindowState -eq "Minimized") { $form.WindowState = "Normal" }
  $form.Show()
  [void]$form.Activate()
  $form.BringToFront()
  $combo.Show()
  [void]$combo.Focus()
  $combo.SelectionStart = $combo.Text.Length; $combo.SelectionLength = 0
  Refresh-List
}
$hk.add_HotKeyPressed({ ShowLauncher | Out-Null; Write-Log "HOTKEY RECEIVED - launcher shown" })

# === TRAY ICON ===
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = [Drawing.SystemIcons]::Application
$tray.Visible = $true
$tray.Text = "Premiere Extension Launcher"
$menu = New-Object Windows.Forms.ContextMenuStrip
$mi = New-Object Windows.Forms.ToolStripMenuItem("Open launcher")
$mi.Add_Click({ ShowLauncher | Out-Null })
$menu.Items.Add($mi) | Out-Null
$quit = New-Object Windows.Forms.ToolStripMenuItem("Quit")
$quit.Add_Click({
  Write-Log "Quit requested from tray."
  $script:allowClose = $true
  $hk.DisposeHotKey($hotkeyid); $tray.Visible = $false; $listener.Stop()
  [Windows.Forms.Application]::Exit()
})
$menu.Items.Add($quit) | Out-Null
$tray.ContextMenuStrip = $menu

# === FORM EVENTS ===
$script:allowClose = $false
$form.Add_FormClosing({
  if (-not $script:allowClose) {
    Write-Log "Form close suppressed (not user-initiated)."
    $_.Cancel = $true
    return
  }
  Write-Log "Form closing."
  try { $hk.DisposeHotKey($hotkeyId); $tray.Visible = $false; $listener.Stop() } catch {}
})

$form.Add_Deactivate({
  if ($form.Visible) {
    Write-DebugLog "Form deactivated, hiding."
    $form.Hide()
  }
})

$form.Add_Shown({
  if (-not $script:formShown) {
    $script:formShown = $true
    [void]$combo.Focus()
    $combo.SelectionStart = 0; $combo.SelectionLength = $combo.Text.Length
    Refresh-List
    # Part 4: log actual control bounds after the first layout pass
    Start-Sleep -Milliseconds 200
    function FormClientTopOf($c) { $form.RectangleToClient($c.RectangleToScreen($c.ClientRectangle)).Top }
    $titleBarBottom = $titleBar.Height
    $comboTop = FormClientTopOf $combo
    Write-Log ("Layout(parent:Location): rootTlp={0}x{1}@({2},{3}) titleBar={4}x{5} h={6} searchCell.bounds={7}x{8}@({9},{10}) Combo.loc={11},{12} h={13} List.loc={14},{15} Status.loc={16},{17}" -f
      $rootTlp.Width, $rootTlp.Height, $rootTlp.Location.X, $rootTlp.Location.Y,
      $titleBar.Width, $titleBar.Height, $titleBar.Height,
      $searchCell.Width, $searchCell.Height, $searchCell.Location.X, $searchCell.Location.Y,
      $combo.Location.X, $combo.Location.Y, $combo.Height,
      $list.Location.X, $list.Location.Y,
      $statusLabel.Location.X, $statusLabel.Location.Y)
    Write-Log ("Layout check: Combo.formTop={0} >= TitleBar.bottom={1} ? {2} ; Combo height={3} (~36-44 required)" -f
      $comboTop, $titleBarBottom, ($comboTop -ge $titleBarBottom), $combo.Height)
    Write-Log "Form shown."
  }
})

# === START ===
Refresh-List
Write-Log "Entering application loop."
$timer.Start()
[Windows.Forms.Application]::Run($form)

try { $mutex.ReleaseMutex() } catch {}
$mutex.Dispose()
Write-Log "Launcher exited."