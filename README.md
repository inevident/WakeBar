# WakeBar for Windows

A quiet, local sleep guard for long-running coding agents on Windows.

Keep the PC awake while agents work. Restore normal sleep when they finish.

This is a Windows port of [inevident/WakeBar](https://github.com/inevident/WakeBar). The OFF / AUTO / ON model, 90-second safety window, and agent-detection strategy match the macOS app; the power and process APIs are native Windows ones.

## What it does

| Mode | Behavior |
| --- | --- |
| **OFF** | Normal Windows sleep. Active agents stay visible and are marked unprotected. |
| **AUTO** | Blocks sleep when local agent work starts, then releases it 90 seconds after the last task finishes. |
| **ON** | Continuously blocks system sleep until you choose OFF or AUTO. |

Detection covers Codex, Claude Code, Cursor, and named agent CLIs (OpenCode, Copilot CLI, Gemini CLI, Aider, Goose, Amp, and others). Scans are local only — no accounts, telemetry, or prompt access.

## Requirements

- Windows 10 or later
- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) to build from source

## Build and run

```powershell
dotnet build WakeBar.sln
dotnet run --project src/WakeBar.App
```

The app lives in the system tray. On Windows 11, new icons often start in the overflow (`^`) — drag WakeBar onto the taskbar if you want it always visible.

Quit from the popover footer, or end `WakeBar.App` in Task Manager. Quitting always restores normal sleep (the wake request is process-owned).

## How sleep blocking works on Windows

- **Idle sleep** is blocked with a `PowerCreateRequest` / `PowerSetRequest` system power request. No administrator approval is required.
- **Lid close** is different: closing a laptop lid still sleeps by default even with a power request held. On machines that expose a lid-close setting, WakeBar can set that action to “Do nothing” (this may need elevation). Desktops without a lid report that feature as unsupported.
- The tray icon is drawn at runtime. Windows has no menu-bar text, so agent count is baked into the icon bitmap.

## Diagnose detection without the UI

```powershell
dotnet run --project tools/WakeBar.Scan
dotnet run --project tools/WakeBar.Scan -- --watch
```

Prints each scan’s agents, evidence type, and whether the scan was conclusive.

## Tests

```powershell
dotnet test WakeBar.sln
```

Tests inject fake power and process providers and never change host power settings.

## Project layout

| Project | Role |
| --- | --- |
| `src/WakeBar.Core` | State machine, domain types, agent detection (cross-platform `net10.0`) |
| `src/WakeBar.Platform.Windows` | WMI process snapshot provider |
| `src/WakeBar.App` | WPF tray app, power service, lid sensor |
| `Tests/WakeBar.Core.Tests` | xUnit suite |
| `tools/WakeBar.Scan` | CLI diagnostics |

Upstream macOS Swift sources remain under `Sources/` for reference while this fork is developed.

## Privacy

WakeBar makes no network requests. The popover only shows transient metadata: runtime name, optional project folder basename, process ID, and lifecycle state. Mode and lifetime wake-session count are stored under `HKCU\Software\WakeBar`.

## License

MIT — see [LICENSE](LICENSE).
