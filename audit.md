# Premiere Extension Launcher — Full Audit

## Project Overview

A hybrid launcher for Premiere Pro 26.x extensions that supports both **CEP** (Adobe's legacy Common Extensibility Platform) and **UXP** (Unified Extensibility Platform) extensions via a single global hotkey interface.

The system consists of three main components:

1. **Desktop launcher** (`launcher/launcher.ps1`) — A Windows Forms application that provides the search UI, registers the global hotkey, serves the local HTTP API, and monitors the Premiere lifecycle.
2. **CEP bridge** (`cep-bridge/`) — A CEP extension that scans installed CEP extensions, starts the desktop launcher, and communicates via HTTP. Opening CEP panels is now done by the desktop launcher via Premiere's native menu API; the bridge's `/open` endpoint remains only as a fallback.
3. **UXP bridge** (`uxp-bridge/`) — A UXP plugin that discovers installed UXP plugins and communicates via HTTP.

## Lifecycle

- Manual launch: the user runs the desktop shortcut or `Launch.cmd`. The CEP bridge *attempts* to auto-start it when it loads under Premiere, but Premiere Pro 2026 does not reliably auto-load the silent CEP bridge, so manual launch is the primary path.
- Optional auto-start: `Install-AutoStart.ps1` creates a scheduled task that fires on Windows Security Event 4688 (process creation, audit enabled by the script) when an `Adobe Premiere Pro.exe` starts, auto-launching the launcher. Zero idle memory — no process when Premiere is closed.
- The launcher exits **automatically when Premiere closes** (monitors the "Adobe Premiere Pro" process with a 10-second grace period).
- The launcher does **not** start at Windows login. No Startup shortcut, Registry Run entry, or Scheduled Task is created.

## Component Audit

### 1. Desktop Launcher (`launcher/launcher.ps1`)

**Purpose:** Provides the search UI, the global hotkey, the local HTTP API, and lifecycle monitoring.

- Uses **Windows Forms** (`System.Windows.Forms`) for the UI — no Python or third-party runtime required.
- Single-instance protection via a named mutex (`Local\PremiereExtensionLauncher`).
- Listens on `http://127.0.0.1:17364` via `HttpListener` for catalog data from both CEP and UXP bridges.
- **Opens CEP extensions via Premiere's native menu system** (Window → Extensions → name) using the Win32 menu API: `GetMenu` → `GetSubMenu` → `GetMenuItemID` → `PostMessage(WM_COMMAND)`. This is the primary path and produces proper dockable panels.
- Registers **Ctrl+Shift+Alt+E** as a global hotkey via P/Invoke `RegisterHotKey` (user32.dll):
  - Modifier: `0x0007` (Ctrl+Alt+Shift)
  - Virtual Key: `0x45` (E)
  - Hotkey ID: `1`
- UI features (refactored to a docked layout, no fixed coordinates):
  - Custom borderless title bar with standard window symbols: minimize `−`, maximize `□` (restore `❐`), close `×`, grouped on the right.
  - Window dragging via the standard Win32 mechanism (`ReleaseCapture()` + `SendMessage(WM_NCLBUTTONDOWN, HTCAPTION)`).
  - Wide, horizontally-docked, editable **search ComboBox** (`DropDownStyle = DropDown`).
  - Results ListBox filling the remaining space.
  - Keyboard navigation: Down/Up arrowselections, Esc hides the form, Enter opens the selection, Back returns to editing.
  - Double-click on a result also opens it.
- HTTP endpoints:
  - `GET /health` → `{ok:true, application:"Premiere Extension Launcher", pid:N}`
  - `POST /catalog/cep`, `POST /catalog/uxp` — receive catalogs; mark the UI dirty so the list refreshes immediately.
  - `GET /catalog` — returns the current catalog.
  - `GET /uxp/next` — UXP bridge polls for the next command.
  - `POST /uxp/result` — UXP bridge reports command results.
- Tray icon provides "Open launcher" and "Quit" actions.
- Logs to `%LOCALAPPDATA%\PremiereExtensionLauncher\logs\launcher.log`.

**Hotkey:**
```powershell
[Win32]::RegisterHotKey($hk.Handle, $hotkeyId, 0x0007, 0x45)
```
- `0x0007` = Ctrl+Alt+Shift modifier flag in Windows `RegisterHotKey`.
- `0x45` = Virtual key code for E.

---

### 2. CEP Bridge (`cep-bridge/js/bridge.js`)

**Purpose:** Starts the desktop launcher, scans the filesystem for installed CEP extensions, and communicates with the launcher.

- Reads CEP manifest.xml files from three possible roots:
  - `%APPDATA%\Adobe\CEP\extensions`
  - `%ProgramFiles%\Common Files\Adobe\CEP\extensions`
  - `%ProgramFiles(x86)%\Common Files\Adobe\CEP\extensions`
- Parses `<Extension Id="...">`, `ExtensionBundleName`, and `ExtensionBundleVersion` from each manifest.
- **Starts the desktop launcher** if it is not already running (checks `GET /health`, then launches `launcher.ps1` via PowerShell hidden).
- Posts the catalog to the launcher via POST to `http://127.0.0.1:17364/catalog/cep`.
- Also serves a local HTTP server on `127.0.0.1:17363` with endpoints:
  - `/ping` — returns `{ok:true,source:"cep"}`
  - `/extensions` — returns the scanned extensions.
  - `/open?id=<id>` — calls `csInterface.requestOpenExtension(id)` to open a CEP extension (fallback path only).
- Auto-reports catalog every 5 seconds (`setInterval(tellCatalog,5000)`) after a 2-second initial delay.
- Logs to `%LOCALAPPDATA%\PremiereExtensionLauncher\logs\cep-bridge.log`.

**Trusted source verification:** The CEP manifest parsing pattern (`<Extension Id="...">`, `ExtensionBundleName`, `ExtensionBundleVersion`) is the standard Adobe CEP manifest format documented by Adobe. The `CSInterface.requestOpenExtension()` method is the official Adobe API, but since Premiere Pro 2026 opens unplaced panels via `requestOpenExtension` as standalone dockless OS windows, the launcher's primary open path invokes Premiere's own native menu command (`Window → Extensions → <name>`) via the Win32 menu API, which yields proper dockable panels. The bridge's `/open` endpoint is retained as a fallback.

---

### 3. UXP Bridge (`uxp-bridge/index.js`)

**Purpose:** Discovers installed UXP plugins and communicates with the launcher.

- Uses Adobe's UXP `pluginManager` API to enumerate plugins.
- Filters out its own plugin (`com.premiere.extensionlauncher.uxpbridge`).
- Builds a catalog from plugin manifests' `entrypoints` array.
- Posts catalog to launcher via POST to `http://127.0.0.1:17364/catalog/uxp`.
- Every 250ms, checks for pending commands from the launcher at `http://127.0.0.1:17364/uxp/next`.
- When a command is available, it executes the corresponding plugin:
  - `panel` type → `p.showPanel(entrypointId)`
  - other types → `p.invokeCommand(entrypointId)`
- Reports result back at `http://127.0.0.1:17364/uxp/result`.

**Trusted source verification:** The UXP `pluginManager` API is the official Adobe UXP API for plugin discovery and command invocation. The `hideFromMenu: true` configuration in `manifest.json` is a valid UXP manifest setting to hide a plugin from the Extensions menu, which aligns with the project's intent of using a resident bridge rather than a visible panel.

**Network permission:** The manifest requests `network.domains` for `http://127.0.0.1:17364`, which is the minimal required scope for local IPC with the launcher.

---

### 4. Installation (`Install-CEP-Bridge.ps1`)

**Purpose:** Installs all components. Does **not** create any Windows Startup mechanism.

- Copies CEP bridge files to `%APPDATA%\Adobe\CEP\extensions\com.premiere.extensionlauncher.cepbridge`
- Copies launcher to `%LOCALAPPDATA%\PremiereExtensionLauncher\`
- Attempts to install the UXP bridge via Adobe UPIA (Unified Plugin Installer Agent) if found.
- **Removes** the old Startup shortcut (`Premiere Extension Launcher.cmd`) if present from a previous installation.
- **Removes** any old Registry Run entry (`PremiereExtensionLauncher`) if present.
- Reports the hotkey as **Ctrl+Shift+Alt+E**.

---

## Keyboard Shortcut

- **Ctrl+Shift+Alt+E** is the global hotkey that activates the launcher search window.
- `launcher/launcher.ps1` - `RegisterHotKey($hk.Handle, $hotkeyId, 0x0007, 0x45)`
- **Can it be changed?** Yes. The modifier (`0x0007` = Ctrl+Alt+Shift) and key code (`0x45` = E) are parameters to the `RegisterHotKey` function. Change them in the launcher script and relaunch.

## Summary

| Component | Technology | Hotkey | Catalog Source | Starts/Exits |
|---|---|---|---|---|
| Desktop launcher | WinForms + P/Invoke | **Ctrl+Shift+Alt+E** (0x0007, 0x45) | Native filesystem scan of CEP roots (+ ingests bridge POSTs) | Started manually; exits when Premiere closes |
| CEP bridge | CEP + JS + HTTP | N/A | Filesystem scan of CEP extension roots | Loads with Premiere (2026 does NOT auto-load silent CEP) |
| UXP bridge | UXP + JS + HTTP | N/A | `pluginManager.plugins` enumeration | Requires load in Premiere |

The project is structured around the Adobe-documented patterns for both CEP and UXP. Because Premiere Pro 2026 no longer reliably auto-loads silent CEP extensions (confirmed by the `cep-bridge.log` never being created, even while Premiere 26.3 runs), the launcher now populates its catalog itself via a native PowerShell scan of the three CEP extension roots, and the launcher is started manually: the user double-clicks the "Premiere Extension Launcher" desktop shortcut (or runs `Launch.cmd`). Once running, the launcher registers the `Ctrl+Shift+Alt+E` global hotkey and exits when Premiere closes.

CEP panels are opened through Premiere's native Window → Extensions menu using the Win32 menu API (`GetMenu`/`GetSubMenu`/`GetMenuItemID`/`PostMessage(WM_COMMAND)`). This directly invokes the same command as clicking the menu item, producing proper dockable panels with no keyboard simulation. The CEP bridge's `requestOpenExtension` HTTP endpoint is retained as a fallback if the menu lookup were to fail (that fallback produces standalone dockless OS windows, so it is not the preferred path).
