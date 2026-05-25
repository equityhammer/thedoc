[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## The sprint-feedback-Tailscale loop

The signature workflow every iterating app should adopt.

### Files involved

- `app/src/main/java/.../util/CrashReporter.kt` - crash capture + offline queue + manual log send + `/version` poll + `/sprint` poll + `/sprint/items` fetch
- `app/src/main/java/.../util/UpdateNotifier.kt` - notification at sprint-complete + APK-ready
- `app/src/main/java/.../ui/screen/HomeScreen.kt` - TopAppBar subtitle, sprint dialog, debug-log FAB/menu item
- `dist/serve_<app>.py` - local Python HTTP server (stdlib only, no deps)
- `dist/sprint.md` - markdown of current sprint items
- `dist/crashes/` - incoming crash reports

### Running the sprint server in-session

The server **must run inside the active Claude Code session** (the one driving the sprint), not in some other terminal. Launch it with the `Monitor` tool, `persistent: true`, so each `[CRASH …]` block the server prints arrives in chat as a notification the moment it lands. That is the entire point of the loop - without it the FAB → server → Claude Code feedback path becomes a "remember to look at the crashes directory" chore.

Invocation pattern:

```text
Monitor(
  description: "<app> sprint server (port <PORT>)",
  command: "cd <repo> && python3 dist/serve_<app>.py",
  persistent: true,
  timeout_ms: 3600000,
)
```

Why `Monitor` and not `Bash run_in_background`:
- The server's `print(..., flush=True)` calls are **already** line-oriented events - no `tail -f`, no `grep` filter is needed. Each crash POST emits a single block ending in a flush. Each line becomes one chat notification.
- Background Bash buffers stdout to a file. You'd have to poll it; events don't surface in real time.
- The Monitor tool's "silence is not success" rule is satisfied because the server prints the startup banner (`<app> server on http://0.0.0.0:<port>`) on launch, prints each crash, and exits noisily on port-conflict / IO errors. Any failure mode produces output.

Lifecycle:
- Start the monitor at the beginning of a sprint (or whenever resuming work).
- Leave it running for the lifetime of the session - the `persistent: true` flag means it won't time out at 5 minutes.
- Use `TaskStop` to kill it when bumping versionCode/versionName so the rebuilt APK gets picked up cleanly by `find_newest_apk()`. (`find_newest_apk` reads from disk, not the running server, so technically a restart isn't required - but stopping + restarting is the cleanest signal that "we're now on the next sprint.")
- If the session ends or compacts, restart the monitor on the next turn. Do **not** keep multiple servers running on the same port across sessions.

Avoid:
- Running the server outside the session ("I'll start it in another tmux pane"). Crash reports still land in `dist/crashes/` but Claude Code never sees them, so triaging into `sprint.md` becomes manual.
- Wrapping the script in `tail -f` or `grep --line-buffered`. The server already emits exactly the lines you want; piping just adds buffer-flush risk.
- Setting a low `timeout_ms`. Sprints last hours; use the 1-hour max (3600000) and re-arm on the next turn if needed, or accept the limit and restart.

### How it loops

1. **User notices something while using the app** → taps debug-log icon (FAB or menu item) → types one-line message → `CrashReporter.sendLogManually` POSTs the message + recent logs + crash log + queued reports to `http://<tailscale-ip>:<port>/crash`.
2. **Sideload server writes the report** to `dist/crashes/crash_YYYYMMDD_HHMMSS.log` AND prints it to stdout. Because the server is running under `Monitor` inside this Claude Code session (see § "Running the sprint server in-session"), the printed block arrives as a chat notification the moment it lands - Claude Code reads it and triages without you having to point at the file.
3. **Claude Code session triages the report**:
   - Bug → fix immediately and ship as a single-item sprint.
   - Feature request → add a numbered item to `dist/sprint.md` under `## Next Version` AND **start implementing it right away.** The cadence is "implement as items arrive," not "queue 5 then build all 5." The line format is the user's verbatim quote first, then a one-paragraph implementation summary; once the work lands in code, prefix the title with `✅ **Title**` so the item is visually marked done.
4. **App polls `/sprint`** every 30 s; when `X/Y` increments (because a new item just got its `✅`), the home-screen subtitle updates: `v0.10.8 - sprint 3/5`. The X count grows incrementally during the sprint as work lands.
5. **At 5/5 - DO NOT push yet.** First do two passes:
   1. **Code review pass** - look for unused imports, orphaned dead code from earlier items, hard-coded strings that should be resources, missing null-checks, accidentally-broken existing tests. Treat it as a self-review of the sprint's combined diff.
   2. **Conflict review pass** - items implemented in isolation often break each other (classic example: two items both writing to the same store and ghosting each other). Walk every implemented item against every other; resolve any cross-talk before building.

   Only after both passes pass: bump `versionCode`+`versionName`, build with `./gradlew assembleDebug`, and the renamed APK lands in `app/build/outputs/apk/debug/`.
6. **Server's `find_newest_apk()` picks it up by mtime.** `/version` now returns `0.10.9|<app>-0.10.9-debug.apk`.
7. **App's update poller sees the new version** → `UpdateNotifier.maybeNotifySprintComplete` fires a notification: "Sprint 5/5 complete - v0.10.9 ready to install. Tap to download." Tap → opens download URL in browser → user installs.
8. **`sprint.md` rotates**: `## Next Version` becomes `## Previous Sprint (v0.10.9)`, a new empty `## Next Version (0/5 implemented)` is added.

### Server endpoints (all stdlib HTTP, no deps)

| Method | Path | Returns |
|---|---|---|
| `GET` | `/version` | `0.10.8\|<app>-0.10.8-debug.apk` |
| `GET` | `/version/beta` | same as above (beta-channel alias) |
| `GET` | `/sprint` | `3/5` |
| `GET` | `/sprint/items` | The `## Next Version` section of `sprint.md` as plain text |
| `POST` | `/crash` | Writes body to `crashes/crash_<ts>.log` and prints it; returns `OK` |
| `GET` | `/` | HTML download page with the latest beta APK |
| `GET` | `/<app>-<version>.apk` | The APK with `Content-Type: application/vnd.android.package-archive` |

### Critical sprint-loop conventions

- **Every sprint item starts with the user's verbatim quote and a timestamp.** Format: `User (May 1 16:24): "..."` then a one-paragraph fix description. Never paraphrase the complaint.
- **Implement items as they arrive, not in a batch at the end.** The 5/5 trigger is for the *build/push* step, not the implementation work. By the time the 5th item lands the previous four should already be in `✅` state - so the only fresh work at 5/5 is finishing the last item, then the two review passes, then the build.
- **Mark done items with `✅ **Title**`** prefix so the file's progress is visible at a glance and the `/sprint` count parser stays accurate (it counts ✅).
- **At 5/5, do code review THEN conflict review BEFORE building.** Two distinct passes, in that order. Code review looks at the diff per-item; conflict review walks pairs of items for cross-talk. Items often break each other when implemented in isolation.
- **Critical bugs ship immediately as a single-item sprint.** Treat them as one-line hotfixes shipped same-day.
- **Wrong-sprint-size detection:** if you ever ship a single non-critical item, retroactively note "should have queued" in `sprint.md` so the next sprint absorbs more.

---

