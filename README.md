# Premiere Pro Extension Launcher — Windows 11 / Premiere 26.3

This is a hybrid launcher for the two extension systems present in Premiere 26.x.

## What it does

Press **Ctrl+Shift+Alt+E** anywhere while Premiere is running:

1. A small search window appears.
2. Type an extension name.
3. CEP entries are opened through Premiere's **native menu system** (Window > Extensions > name), invoked via the Win32 menu API (`GetMenu`/`GetSubMenu`/`GetMenuItemID`/`WM_COMMAND`). This produces proper dockable panels — not the standalone OS windows that `requestOpenExtension` creates.
4. UXP entries are sent to the hidden UXP bridge, which uses Adobe's official `pluginManager` IPC APIs to show panels or invoke commands.

This replaces Premiere's built-in (large, hard to browse) Window > Extensions menu with a fast searchable launcher.

## Lifecycle

The launcher's lifecycle depends on how you start it:

**Fully automatic (recommended, zero idle memory):** run `Install-AutoStart.ps1` once. It creates a scheduled task that fires the moment a Premiere Pro process starts (via Windows Security Event 4688) and launches the launcher automatically. The launcher then exits on its own ~10 seconds after Premiere closes — so when Premiere is not running, **no launcher process exists at all** (0 MB).

```
Install-AutoStart.ps1 (once)
  → enables process-creation auditing + creates scheduled task
Premiere starts
  → Task Scheduler fires → launcher auto-starts → hotkey ready
Premiere closes
  → Launcher detects Premiere was running, then exits after a grace period
```

**Manual (no admin needed):** double-click the **"Premiere Extension Launcher"** desktop shortcut created by the installer, or run `launcher\Launch.cmd`. The launcher does **not** start at Windows login unless you add it to Startup yourself.

## Install

### 1. CEP bridge

Run PowerShell as your normal user:

`Set-ExecutionPolicy -Scope Process Bypass`

then:

`.\Install-CEP-Bridge.ps1`

Restart Premiere.

The CEP bridge is invisible and starts on Premiere activation. Note: Premiere Pro 2026 no longer reliably auto-loads silent CEP extensions, so it is kept for catalog scanning; the launcher itself is started manually.

### 2. Desktop launcher

The launcher uses Windows PowerShell/.NET WinForms, so no Python or third-party runtime is required.

The installer creates a **"Premiere Extension Launcher"** desktop shortcut. Double-click it (or run `launcher\Launch.cmd`):

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launcher\launcher.ps1`

The launcher registers the `Ctrl+Shift+Alt+E` global hotkey and stays alive until Premiere closes.

### 3. Automatic start (optional)

To have the launcher start by itself whenever Premiere launches (zero idle memory — no process exists while Premiere is closed):

`.\Install-AutoStart.ps1`

Notes:
- Requires **administrator** rights once (a UAC prompt appears) to enable the Windows "Audit Process Creation" event that the trigger uses.
- Creates a scheduled task `Premiere Extension Launcher AutoStart` that fires on Event 4688 only when an installed `Adobe Premiere Pro.exe` (2025 or 2026) starts, then runs the hidden launcher.
- The launcher still self-exits ~10 s after Premiere closes.
- Undo: `.\Install-AutoStart.ps1 -Remove` (deletes the task and disables the audit).

### 4. UXP bridge

Premiere 26.3 supports UXP. Install/load `uxp-bridge\manifest.json` with Adobe UXP Developer Tool.

In Premiere, enable:
Settings > Plugins > Enable developer mode.

Then in UXP Developer Tool:
Add Plugin -> select `uxp-bridge\manifest.json` -> Load.

The UXP bridge is configured with `hideFromMenu:true`, so it is intended to be resident rather than a visible panel.

## Architecture

| Component | Role | Port |
|-----------|------|------|
| Desktop launcher | WinForms UI, hotkey, HTTP server, native CEP filesystem scan, native menu API opener | 17364 |
| CEP bridge | Scans CEP extensions, reports catalog; fallback opener (requestOpenExtension) | 17363 |
| UXP bridge | Scans UXP extensions, shows panels/commands | — |

### Endpoints (launcher)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Health check (returns `{ok:true, application:"...", pid:N}`) |
| `/catalog` | GET | Returns current CEP+UXP extension catalog |
| `/catalog/cep` | POST | Receives CEP catalog from CEP bridge |
| `/catalog/uxp` | POST | Receives UXP catalog from UXP bridge |
| `/uxp/next` | GET | UXP bridge polls for next command to execute |
| `/uxp/result` | POST | UXP bridge reports command result |

### Endpoints (CEP bridge)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/ping` | GET | Health check |
| `/extensions` | GET | Returns scanned CEP extensions |
| `/open?id=...` | GET | Opens a CEP extension by ID (fallback path; see below) |

## Hotkey

**Ctrl+Shift+Alt+E** — global, works anywhere while Premiere is running.

The launcher also provides a system tray icon with "Open launcher" and "Quit" options.

## Important

The UXP bridge needs the local network permission because UXP is a client-only network environment. It polls the local launcher service and sends commands back to the launcher.

The first release deliberately does not alter any existing extension files or Premiere preferences.

## Logs

Launcher logs are written to:

`%LOCALAPPDATA%\PremiereExtensionLauncher\logs\launcher.log`

CEP bridge logs are written to:

`%LOCALAPPDATA%\PremiereExtensionLauncher\logs\cep-bridge.log`

## Current limitations

- CEP discovery is done by the launcher itself (native filesystem scan of the three CEP extension roots), so the list is populated without needing the CEP bridge.
- CEP panels are opened via Premiere's native menu system (Window > Extensions > name) using the Win32 menu API. This produces true dockable panels. The CEP bridge `requestOpenExtension` HTTP endpoint is only a fallback if the menu lookup fails, and that path produces standalone (dockless) OS windows.
- UXP: automatic discovery + panel/command launch once the UXP bridge is loaded (requires registration; Premiere 2026 does not pick up dropped-in PluginsStorage folders reliably).
- A global Ctrl+Shift+Alt+E hotkey is provided by the Windows desktop launcher.
- Premiere does not currently expose UXP command entrypoints to Edit > Keyboard Shortcuts, so an external global hotkey is used instead.
