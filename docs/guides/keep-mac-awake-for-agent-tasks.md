# Keep a Mac awake for Claude Code or Codex tasks

Caff prevents idle system sleep while you work. Use a manual timer for a known
job duration, or agent activity hooks when an interactive agent stays open
between turns. Display sleep is a separate, optional setting.

[Install Caff](../../README.md#install) first. This guide uses the installed app's
executable, so it does not depend on a `caff` alias being on your shell's `PATH`:

```bash
CAFF_BIN="/Applications/Caff.app/Contents/MacOS/Caff"
open -a Caff
"$CAFF_BIN" status
```

If you installed to another Applications folder, use that app bundle's executable
path instead. The source checkout's bundle is `dist/Caff.app/Contents/MacOS/Caff`.

## Keep the system awake while allowing the display to sleep

Leave **Keep display awake** off. For a 30-minute job:

```bash
"$CAFF_BIN" start --minutes 30 --reason "Agent task"
"$CAFF_BIN" status
```

Read `running`, `assertions`, `displayAwake`, and `error` in the status snapshot.
`displayAwake: false` means display-awake control is off; it does not mean the
system's idle-sleep assertion is off. A command being sent is not proof that the
app accepted the requested session: inspect the status and control window.

When finished:

```bash
"$CAFF_BIN" stop
"$CAFF_BIN" status
```

A successful stop should leave no active Caff session. If status or the control
window reports an error, keep that evidence when requesting support.

## Keep awake while an interactive agent is active

For a one-time activity event:

```bash
"$CAFF_BIN" agent-touch --source codex --cooldown-seconds 1800
"$CAFF_BIN" status
```

Each touch refreshes the last-activity cooldown. It does not wait for the agent
process to exit. With the default 1,800 seconds, Caff allows sleep after 30 minutes
without another touch, subject to the session and power safety policy.

For repeated activity, install hooks for the tool you actually use:

```bash
"$CAFF_BIN" install-hooks --target codex --cooldown-seconds 1800
# For Claude Code instead:
# "$CAFF_BIN" install-hooks --target claude --cooldown-seconds 1800
```

This changes that agent's hook configuration. Review the installed entries and
[the supported hook events and examples](../../README.md#agent-activity-hooks).
After real agent activity, inspect `agentLastTouchSource`, `agentLastTouchAt`, and
`agentCooldownUntil` in `status`; an idle, open agent terminal alone is not a touch.

To remove only Caff's hooks for the selected tool:

```bash
"$CAFF_BIN" remove-hooks --target codex
```

## Why did a session stop or fail to start?

- **Long session on battery:** by default, sessions of 60 minutes or more require
  confirmed AC power. Use a shorter timer, connect power, or review the explicit
  long-battery setting in Caff. Unknown power state is also refused for long sessions.
- **Four-hour limit:** manual sessions are capped at four hours, including
  **Indefinitely**. Choose a duration that fits the task and inspect the end time.
- **No hook event:** check the selected agent's configuration and the last-touch
  fields; return to manual mode while investigating the integration.
- **App or assertion error:** preserve the status error and reproduce with a
  short manual session. Do not assume a submitted command succeeded.

## Can I close the MacBook lid or prevent screen locking?

Caff does not promise reliable lid-closed operation on every MacBook setup, and
keeping the system awake does not change the system's lock-screen policy. Start
with the lid open and validate your own hardware/power/display setup separately.

For a plain timed keep-awake utility, [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake)
documents a menu-bar wrapper around `caffeinate`. Caff's workflow here uses explicit
agent events and an app status snapshot; this is not a performance comparison.

[Back to README](../../README.md) · [Release notes](../../CHANGELOG.md) ·
[Report a reproducible issue](https://github.com/majiayu000/caff/issues/new?template=bug_report.yml)
