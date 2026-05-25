[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## New-app checklist (do these before writing any feature code)

1. **Scaffold the Compose + Room + Navigation skeleton** with the standard `gradle/libs.versions.toml` block (see "Standard dependencies").
2. **Use `applicationVariants.all { outputs }`** in `app/build.gradle.kts` to rename APK output to `<app-slug>-${versionName}-${buildType}.apk`. Required so `dist/serve_<app>.py` can pick "newest APK" by mtime and serve it.
3. **Create a `dist/` folder** with:
   - `serve_<app>.py` - the per-app local HTTP server. See "`dist/serve_<app>.py` requirements" below.
   - `sprint.md` seeded with `## Next Version (0/5 implemented)` plus 5 numbered slots.
   - `crashes/` (gitignored).
   - `.gitignore`: `crashes/` and `*.apk`.
4. **Pick a unique port** for the per-app local server. Maintain a small registry (e.g. a `~/PORTS.md` file) so two apps don't collide on the same port.
5. **Wire `CrashReporter.install(this)` as the FIRST line in `Application.onCreate()`**, before the DI container, before Room, before any other init. The crash handler must capture init crashes that happen before the rest of the app boots.
6. **Create three notification channels** in `Application.onCreate()` (or whichever subset you use): regular reminders (HIGH), full-screen alarms (MAX, bypass DND), app updates (DEFAULT). Use stable IDs as `companion object` constants on the `Application` class.
7. **Add an in-app feedback / debug-log FAB or menu item** that calls `CrashReporter.sendLogManually(context, userMessage) { ... }`. This is the channel through which sprint items get collected.
8. **Show the version number in the top app bar of the home screen.** Tappable. Tap → changelog dialog. If a newer version is available, replace it with "v{current} - tap to update to v{next}" linking to the APK download URL.
9. **Configure `network_security_config.xml`** to allow cleartext to your Tailscale IP (or set `usesCleartextTraffic="true"` for the whole app - the former is stricter).
10. **Add a CLAUDE.md** to the repo root with project overview + tech stack + key impl notes (see "README/docs conventions" below).
11. **For any app that's more than a glorified one-screen demo**, add a `SPEC.md` (vision/scope) and a `REFACTOR.md` (anti-patterns / lessons learned).
12. **Launch the sprint server under `Monitor` inside the active Claude Code session** (not in a separate terminal). See § "Running the sprint server in-session" below. This is what wires the in-app debug-log FAB to Claude Code's chat in real time.

---

## Always-on requirements (every Android app should do these)

| # | Requirement | Why |
|---|---|---|
| 1 | **Show app version in UI** (typically TopAppBar subtitle on home screen) | Sideload distribution: nobody knows which build a phone has |
| 2 | **Read version from `PackageManager`, not `BuildConfig` directly** | `BuildConfig` caches across debug builds and lies to you |
| 3 | **In-app debug log / feedback channel** that POSTs to a sideload server, **reachable from every screen** (not just Home). Convention: global debug FAB at `BottomStart`, per-screen FABs (add buttons, etc.) at `BottomEnd` - no overlap, no stacking. Hoist into a `DebugFabHost` composable that wraps the NavHost so a single instance overlays all routes. | Bugs surface anywhere in the UI, so the FAB must be everywhere too. This is how sprint items get collected - type the feedback into the app, server stores it. |
| 4 | **Auto-installed `Thread.setDefaultUncaughtExceptionHandler`** that writes to disk and POSTs on next launch | Crashes during init never reach you otherwise. `CrashReporter.install()` should be line 1 of `Application.onCreate`. |
| 5 | **Offline crash queue** (base64-line file, drained on next launch) | Tailscale server is sometimes asleep; reports must not be lost |
| 6 | **Update banner** polling `/version` every 30 s, replacing version subtitle when newer build is available | Sideload distro means there's no Play Store autoupdate |
| 7 | **Sprint indicator** ("v0.10.8 - sprint 3/5"), tappable for the planned-items list | The UI itself is the sprint dashboard |
| 8 | **Notification when sprint hits X/X and a newer APK is on the server** | Pushes the "ready to test" signal without app being open |
| 9 | **Consistent renamed APK output** (`<app>-<version>-<buildType>.apk`) | The dist server picks newest by mtime/glob |
| 10 | **Same Tailscale IP** as `serverUrl` default across all apps | One Tailscale net, predictable across apps |
| 11 | **Ship a `CHANGELOG.md` asset** at `app/src/main/assets/CHANGELOG.md`. The Home screen's "tap version" affordance loads it via `context.assets.open("CHANGELOG.md")` and renders it in a scrollable monospace dialog. **Update the file in the same diff that bumps `versionName`** - every sprint ship adds a new top-level section. | Without this the user has no way to find out what changed between two installed builds. `sprint.md` is dev-server-only; `CHANGELOG.md` ships with the APK. |

---

