# Caff

Caff is a small macOS menu bar app that keeps the machine awake while long-running agent tasks are active. It can be driven manually, by watched processes, by workspace activity, by agent hook events, or by CLI/URL commands.

It uses the official IOKit power assertion API:

- `PreventUserIdleSystemSleep` keeps macOS from sleeping because the user is idle.
- `NoDisplaySleepAssertion` is optional and keeps the display awake when enabled.

## Quick Start

Most users only need the manual controls:

1. Build and open the app:

   ```bash
   ./scripts/build_app.sh
   open dist/Caff.app
   ```

2. Click `30 Minutes`, `1 Hour`, or `4 Hours`.
3. Leave `Keep display awake` off unless the screen itself must stay on.
4. When your task is done, click `Stop` from the control window or the `CAFF` menu bar item.

To install it like a normal Mac app:

```bash
ditto dist/Caff.app /Applications/Caff.app
open -a Caff
```

When Caff is running, look for `CAFF` in the macOS menu bar.

## Which Mode Should I Use?

| Need | Use |
| --- | --- |
| Keep the Mac awake for a known amount of time | Manual buttons: `30 Minutes`, `1 Hour`, `4 Hours` |
| Keep the display on too | Turn on `Keep display awake` before starting |
| Keep awake while Codex or Claude activity is happening | `agent-touch` hooks |
| Coarse automatic detection by running process name | Process Trigger |
| Project-specific activity based on file changes | Workspace Trigger |
| Start, stop, or inspect Caff from scripts | CLI or `caff://` URLs |

Start with manual mode. Turn on automation only when manual sessions are not enough.

## What Caff Is Not

Caff is not an agent launcher, terminal replacement, or job runner. Run Codex, Claude, tests, and scripts in your normal terminal or editor. Use Caff to keep the Mac awake while that work is active.

## Current Scope

This MVP implements an idle-sleep/display-sleep assertion controller, a menu bar item, a light Aqua control window, local history, and CLI/URL control. It does not claim reliable lid-closed operation on every MacBook setup. Lid-close behavior depends on hardware, power, external display state, and macOS policy, so it should be validated separately before treating it as production behavior.

## Control Window

The app opens a scrollable control window with:

- a hero status card for the current wake-lock state
- live macOS assertion proof
- manual wake-lock duration controls
- process, workspace, and agent-activity automation status
- notification and local history controls

## Safety Policy

Caff keeps display sleep prevention opt-in and applies a visible safety policy before starting sessions:

- manual sessions are capped at 4 hours, including the "Indefinitely" action
- trigger-driven stop behavior has a 60 second grace-period setting
- long sessions are blocked while on battery unless the user explicitly enables them
- assertion and policy failures stay visible in the menu bar, menu, and control window

## Process Trigger

Caff can watch a configurable comma-separated list of process names or bundle identifiers.
The default list is `codex, claude, node, python, cargo, swift`.
When a matching process exists, Caff starts a process-sourced keep-awake session and shows the triggering process in the status proof.
When no match remains, Caff keeps the session alive for the configured grace period before stopping it.

## Workspace Trigger

Caff can watch configured workspace paths for deterministic activity signals:

- `.git/index.lock`
- recently modified regular files

Workspace triggers are opt-in and require explicit paths. When activity stops, Caff keeps the session alive for the configured grace period before stopping it.

## Notifications and History

Notifications are opt-in. When enabled, Caff can notify on session start, stop, timeout, policy stop, and errors.
Local history is stored in Application Support and records source, reason, duration, assertion kinds, timestamps, and result.
History starts empty and can be cleared from the menu or control window.

## Settings

Caff persists menu bar density and launch behavior. The menu bar can show icon-only, `CAFF`, compact countdown, or source labels, and the control window can be disabled on launch.

## CLI and URL Control

The same executable accepts `start`, `stop`, `status`, and `agent-touch` commands. `start` supports `--minutes`, `--reason`, `--display-awake`, and `--source`; `status` prints proof fields including source, assertions, reason, timestamps, display-awake state, agent cooldown state, and errors. The app bundle registers URL commands for equivalent control:

- `caff://start?minutes=30&reason=agent`
- `caff://stop`
- `caff://agent-touch?source=codex&cooldownSeconds=1800`

For long-running interactive agent CLIs, `agent-touch` refreshes a last-activity cooldown without relying on the `codex` or `claude` process exiting:

```bash
caff agent-touch --source codex --cooldown-seconds 1800
```

Hook `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `Stop` to run that command. Caff keeps the Mac awake until 30 minutes after the latest agent event, then releases the assertion so macOS can follow its normal sleep policy.

If you run from the generated app bundle, the executable path is:

```bash
dist/Caff.app/Contents/MacOS/Caff agent-touch --source codex --cooldown-seconds 1800
```

## Agent Activity Hooks

Use this mode when a long-running interactive agent may stay open after it has finished answering. Process detection alone cannot reliably tell whether a session is still active.

Configure your agent hooks to run:

```bash
/Applications/Caff.app/Contents/MacOS/Caff agent-touch --source codex --cooldown-seconds 1800
```

Run it on these events when available:

- user prompt submitted
- before tool use
- after tool use
- stop or completion

Each event refreshes the cooldown. If no new event arrives for 30 minutes, Caff releases the wake assertion.

## Run

```bash
swift run caff
```

## Build an App Bundle

```bash
./scripts/build_app.sh
open dist/Caff.app
```

The generated app opens the control window and also keeps a `CAFF` menu bar item.
The menu includes `Show Caff` if the window is closed.

## Install and Open

Caff does not require an installer. After building the app bundle, either run it from `dist`:

```bash
open dist/Caff.app
```

or copy it to Applications and open it like a normal Mac app:

```bash
ditto dist/Caff.app /Applications/Caff.app
open -a Caff
```

When Caff is running, look for `CAFF` in the macOS menu bar. Use the menu bar item to open `Show Caff`, start or stop a wake session, change menu bar display mode, or quit the app.

## Status Proof

When a wake session is active, Caff shows:

- session source: `Manual`, `Process`, `Workspace`, `Agent`, `CLI`, or `URL`
- active assertion types
- assertion reason
- start time
- remaining time for timed sessions
- agent activity summary and cooldown end time in CLI status

## Naming

`Caff` is intentionally short and CLI-friendly. It keeps the connection to macOS `caffeinate` without using the generic name `Cafe`.

## Verify

```bash
swift test
swift build
swift run caff-core-checks
./scripts/build_app.sh
```
