# WakeBar

WakeBar is a native macOS menu-bar sleep guard for long-running coding agents.
It keeps a Mac awake only when you want it to, including while the lid is
closed, without sending activity data anywhere or asking you to sign in.

## Three modes

- **OFF** restores normal macOS system sleep with
  `/usr/bin/pmset -a disablesleep 0`. OFF is a manual override; when local
  agents are active, WakeBar marks them as unprotected and offers **Use AUTO**.
- **AUTO** watches local agent activity every five seconds. It blocks sleep as
  soon as work starts, then restores normal sleep 90 seconds after the final
  active agent finishes.
- **ON** continuously blocks system sleep with
  `/usr/bin/pmset -a disablesleep 1`.

The selected mode is persistent and distinct from the verified physical sleep
lock. WakeBar re-checks the real `SleepDisabled` state every 20 seconds and
repairs drift caused by an outside command or OS state change.

AUTO fails safe: an interrupted or inconclusive scan never releases an active
sleep lock. Positive activity can still engage the lock while a secondary
signal is temporarily unavailable.

## Local agent detection

WakeBar uses local process and lifecycle evidence only. It makes no network
requests and needs no Codex, Claude, Cursor, GitHub, or provider login.

- **Codex**: correlates exact Codex processes with their writable local rollout
  files and reads only lifecycle envelopes such as task started, completed, or
  aborted. Persistent `app-server` processes and completed threads do not count.
- **Cursor**: correlates the exact running Cursor app, its agent-loop sleep
  assertion, transcript lifecycle, and `AwaitShell` identifiers with verified
  live terminal manifests. A long-running tool extends only the thread that
  owns it; `turn_ended` stops protection even if Cursor leaves that shell
  running in the background.
- **Claude Code**: validates each live PID against Claude’s local session
  registry and process start time. `busy` and `shell` protect work; an idle
  prompt or a session waiting for user input does not. Exact-session transcript
  lifecycle is used only as a compatibility fallback.
- **OpenCode, Copilot CLI, Gemini CLI, Aider, Goose, Amp, Kiro,
  Factory Droid, Codebuff, Qoder, Cline, Kilo Code, Crush, Antigravity CLI, and
  other named CLIs**: use exact executable identity and process liveness.
- **Antigravity IDE**: also recognizes an actively working local language-server
  process without treating the always-open app as agent work.

DeepSeek, MiniMax, and Groq are often models selected inside another runtime,
such as Cursor or OpenCode. In that case WakeBar protects the work by detecting
the host runtime. It also recognizes standalone `deepseek-code`, `minimax-code`,
and `groq-build` style CLIs when installed under those names.

WakeBar never reads prompt text or response text. It retains only a transient
runtime name, optional project-folder basename, process ID, and lifecycle state
for display in the popover. Nothing is uploaded or written to a WakeBar log.

The detector architecture was informed by the MIT-licensed local session work
in [steipete/CodexBar](https://github.com/steipete/CodexBar). WakeBar implements
its own detector and does not require CodexBar to be installed. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## One-time prompt-free setup

`pmset` requires root privileges. Selecting AUTO or clicking **Set Up** asks for
administrator approval once and installs a root-owned, mode `0440` rule at:

```text
/private/etc/sudoers.d/zzzz_wakebar_<numeric-user-id>
```

The rule permits the current macOS user to run only these two fixed commands
without a password:

```text
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

It does not authorize a shell, arbitrary `pmset` arguments, environment
preservation, or any other root command. Runtime changes use non-interactive
`sudo` and fail closed instead of displaying another password prompt. macOS
handles the one-time password dialog; WakeBar never sees or stores the password.

Any process running as the same macOS user can invoke those two exact commands.
This is a pragmatic design for a personal, locally built utility. A broadly
distributed release should use a Developer ID-signed and notarized privileged
helper instead.

The gear menu can repair or remove instant switching. Removal asks for approval,
turns the sleep lock off, verifies the exact receipt, and removes only that file.

## Safety and behavior

Blocking system sleep can consume substantial power. Connect power for long
runs and keep a closed Mac uncovered on a hard, ventilated surface—never in a
bag or sleeve.

WakeBar prevents system sleep; it cannot protect work from battery exhaustion,
shutdowns, restarts, software updates, thermal protection, network loss, or an
agent process exiting. Apple does not document `disablesleep` in the `pmset` man
page, so verify lid-closed behavior on the Mac and macOS release you rely on.

AUTO requires WakeBar to remain running so it can observe transitions. If the
app quits while the physical sleep lock is enabled, that system-wide setting
persists; WakeBar warns before quitting and offers to turn it off first.

## Build and run

Requirements: macOS 13 or later and Swift 6 / Xcode command-line tools.

```sh
./Scripts/build-app.sh
open ./dist/WakeBar.app
```

The build script creates an ad-hoc-signed local app at `dist/WakeBar.app`. For
distribution to other Macs, sign it with a Developer ID certificate and
notarize it.

## Test

```sh
swift test -Xswiftc -warnings-as-errors
```

The suite validates agent process filtering, Codex, Claude, and Cursor lifecycle
parsing, Cursor power assertions and terminal manifests, custom runtime homes,
degraded scans, OFF/AUTO/ON transitions, grace timing, external-state repair,
exact privileged arguments, sudoers safety, authorization retry behavior, and
verification failures. Tests use injected actors and never modify the host
Mac’s power or sudoers settings.

For a read-only snapshot of what the local detector currently sees:

```sh
swiftc -parse-as-library -warnings-as-errors \
  Scripts/diagnose-agents.swift \
  Sources/WakeBar/AgentActivityDetector.swift \
  Sources/WakeBar/PMSetService.swift \
  -o .build/WakeBarAgentDiagnostics -framework AppKit
.build/WakeBarAgentDiagnostics
```
