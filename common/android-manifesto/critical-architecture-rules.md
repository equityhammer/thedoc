[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Critical Architecture Rules (Learned the Hard Way)

New Android apps following this template should treat these as gospel:

1. `AlarmReceiver.onReceive()` must be synchronous: wake lock → `startForegroundService()` → `startActivity()`. Async work goes in `goAsync()` AFTER.
2. Never call `startForegroundService()` from a coroutine - loses the exact-alarm exemption.
3. Don't use `setRepeating()` - use `setExactAndAllowWhileIdle()` and reschedule in the receiver.
4. Don't advance the deadline date until the DEADLINE has passed, not the start time.
5. Don't use nested nav graphs for ViewModel sharing - use a repository singleton on the `Application`.
6. Show version from `PackageManager`, not `BuildConfig` (caches across debug builds).
7. Timer tick interval 250 ms, not 50 ms - 50 ms causes visible flickering on foldables.
8. `DatePicker` returns UTC midnight - parse with UTC `Calendar`, not local.

---

## Open questions for your template

Areas where existing implementations of this template diverge. Pick a default for your own apps and bake it in.

1. **Settings persistence:** DataStore vs SharedPreferences. DataStore is more modern/typed, SharedPreferences is simpler for tiny bag-of-flags. Reasonable default: **DataStore for connection config, SharedPreferences for app-internal toggles.**
2. **Cleartext config:** `usesCleartextTraffic="true"` vs `network_security_config.xml` IP whitelist. The latter is strictly safer. Reasonable default: **standardize on `network_security_config.xml`**.
3. **`debug` build type with `applicationIdSuffix = ".debug"`:** Lets debug + release coexist on the same device (used for "beta channel"). Useful when you want side-by-side beta + stable installs; otherwise omit.
4. **Version surface in UI:** Show version in TopAppBar (recommended for any user-facing app) vs only logging it (defensible for connection-only utility apps).
5. **Sprint loop scope:** The full sprint/feedback/Tailscale loop is high-overhead. Reasonable to skip for connection-only utilities; reasonable to demand for any app you actually iterate on.
6. **OkHttp vs `HttpURLConnection` for the crash reporter:** Use OkHttp for any app that already pulls it in for other reasons; `HttpURLConnection` only if the app would otherwise have no networking dep.
7. **`DebugLogger` periodic state dump:** Useful for any app where bugs are timing-dependent. Document as optional.
8. **Server-port allocation:** No central registry by default. Maintain a personal `~/PORTS.md` or similar so two apps don't collide.

---

