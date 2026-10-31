# Update Guard

Manage Windows Update and Microsoft Store app auto-updates on Windows 10 / 11.

Ships in two forms: **a single PowerShell script (recommended)** and a **standalone GUI executable**
(Win11 style, zero dependencies).

**English** | [简体中文](README.zh-CN.md)

![GUI](docs/gui.png)

---

## Download

**Recommended: the script build** — [`tools/Disable-WindowsUpdate.ps1`](tools/Disable-WindowsUpdate.ps1) (~38 KB, plain text)

1. Download the repository (**Code → Download ZIP**) and extract it
2. Double-click **`tools\Run.bat`** → accept the UAC prompt

> Do not double-click the `.ps1` directly. A script extracted from a ZIP carries the
> "came from the internet" mark, so Windows blocks it as unsigned unless the execution
> policy is bypassed. `Run.bat` does exactly that for that one process and changes
> nothing system-wide.

The GUI build is attached to [Releases](../../releases) — it is not kept in the repository.

---

## Two builds

| | Script (recommended) | GUI |
|---|---|---|
| File | `tools/Disable-WindowsUpdate.ps1` | `dist/UpdateGuard.exe` (Releases) |
| Size | 38 KB of plain text | ~125 KB single file |
| Requires | Windows PowerShell 5.1 | .NET Framework 4.8 (bundled with Windows 10/11) |
| Elevation | Requests UAC on start | Requests UAC when you click an action |

Both share the same data directory, so you can switch between them at any time.

---

## What it changes

| Location | Value |
|---|---|
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `WUServer` / `WUStatusServer` = `http://127.0.0.1:8530` (a server that does not exist), `DoNotConnectToWindowsUpdateInternetLocations` = 1 |
| `...\WindowsUpdate\AU` | `NoAutoUpdate` = 1, `UseWUServer` = 1 |
| `HKLM\SOFTWARE\Policies\Microsoft\WindowsStore` | `AutoDownload` = 2 (disables Store app auto-update) |
| Services | `wuauserv`, `usosvc`, `WaaSMedicSvc`, `bits` → set to Disabled and stopped |
| Scheduled tasks | everything under `\Microsoft\Windows\{UpdateOrchestrator, WaaSMedic, WindowsUpdate, InstallService}\` → disabled |

Protected tasks reject the Task Scheduler API, so their XML is edited directly
(`Settings/Enabled`), and the Task Scheduler service is reloaded by temporarily granting
Administrators the `SERVICE_STOP` right on `Schedule` (reverted immediately afterwards).

Restore reverses every step: re-enable services from the recorded baseline, delete the policies,
restore the backed-up task XML, then run `gpupdate /force`.

---

## Features

- Disable / restore Windows Update (policies + 4 services + all tasks in 4 folders)
- Toggle Microsoft Store app auto-updates
- `dosvc` (Delivery Optimization) is intentionally left alone: the SCM refuses to change its start type, and it plays no part in policy blocking
- Live status view — service start types are read from the Service Control Manager (`sc qc`),
  so a locked-down registry key cannot produce a false reading
- Progress bar with the per-step log collapsed by default; it expands automatically on failure
  (`-Detail` forces it open)
- Fully reversible: task XML and the original service start types are backed up before any change

---

## Build

Only the compiler bundled with Windows is needed — no Visual Studio, no .NET SDK:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Output: `dist\UpdateGuard.exe`.

The build script takes care of a few Windows-specific gotchas:

- the bundled `csc.exe` is the legacy compiler and only understands **C# 5**
  (no string interpolation, `?.`, `nameof`, tuples)
- sources are UTF-8 and must be compiled with `/codepage:65001`, otherwise string literals are mangled
- `build\app.ico` is generated during the build and is not tracked

### Signing (optional)

```powershell
.\sign.ps1
```

Signs `dist\UpdateGuard.exe` with a self-signed certificate and exports `dist\UpdateGuard.cer`.
Recipients must run `tools\trust-cert.bat` once to trust it; that only removes the
"Unknown publisher" text from the UAC prompt. A self-signed certificate will never satisfy
SmartScreen.

---

## Usage

### Script (recommended)

```powershell
# Interactive menu (simplest: right-click -> Run with PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Disable-WindowsUpdate.ps1

# Non-interactive
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto disable
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto restore
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto status    # does not need elevation

# Show every step instead of just the progress bar
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto disable -Detail
```

> The script file must stay **UTF-8 with BOM**. Windows PowerShell 5.1 reads BOM-less files as ANSI,
> which turns every non-ASCII string into mojibake and produces syntax errors.

![Script progress bar](docs/ps_progress_bar.png)

### GUI

Double-click `UpdateGuard.exe` → click **Disable updates** → **click again to confirm**
(within 5 seconds, a guard against misclicks) → accept UAC.

---

## Repository layout

```
.
├─ src/                      C# sources
│  ├─ Program.cs             entry point / crash log / --selftest
│  ├─ MainForm.cs            window and interaction
│  ├─ Theme.cs               Win11 Fluent theme and button control
│  ├─ WuCore.cs              disable / restore / status logic
│  ├─ Native.cs              DWM rounded corners, window dragging
│  └─ AssemblyInfo.cs
├─ build/app.manifest        asInvoker + DPI awareness
├─ tools/
│  ├─ Run.bat                    launcher (double-click this)
│  ├─ Disable-WindowsUpdate.ps1  PowerShell build
│  ├─ trust-cert.ps1             install the self-signed certificate machine-wide
│  └─ trust-cert.bat             batch wrapper for the above
├─ docs/                     screenshots
├─ build.ps1                 build (generates the icon, runs csc)
├─ sign.ps1                  sign and export the .cer
└─ LICENSE
```

## Data directory

`C:\ProgramData\UpdateGuard\`

| File | Purpose |
|---|---|
| `log.txt` | run log (shared by both builds) |
| `services.txt` | service start type baseline, used when restoring |
| `tasks\*.xml` | original XML of every protected task |
| `error.log` | crash log |

Uninstalling is just deleting the executable and this folder.

---

## Known limitations

- **Unsigned builds** may be blocked by SmartScreen (More info → Run anyway), and some antivirus
  products flag the executable because it does modify service start types and scheduled tasks.
- **Windows may revert parts of the configuration.** Service start types and scheduled tasks can be
  reset by the servicing stack; the policies are not affected. If updates come back, check `log.txt`
  and run the tool again.
- **Policies do not stop a manual check.** Pressing "Check for updates" in Settings can still trigger
  a scan, but it will be pointed at a server that does not exist.
- This is not a substitute for installing security patches. Evaluate the risk before disabling updates
  long-term.

## License

[MIT](LICENSE)
