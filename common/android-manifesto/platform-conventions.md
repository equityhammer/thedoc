[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Notification patterns

- **Channels are created in `Application.onCreate`**, not lazily. IDs as `companion object` constants.
- **Channel taxonomy:**
  - `<feature>_reminders` - `IMPORTANCE_HIGH`, regular reminders
  - `<feature>_alarms` - `IMPORTANCE_MAX`, vibrate, alarm sound, `setBypassDnd(true)` for full-screen alarm experiences
  - `app_updates` - `IMPORTANCE_DEFAULT`, fired by `UpdateNotifier` when a sprint completes and a new APK is available
  - `<feature>_connection` - `IMPORTANCE_LOW`, `setShowBadge(false)` for foreground-service status notifications
- **`POST_NOTIFICATIONS` permission** is requested in `MainActivity.onCreate` only when `SDK_INT >= TIRAMISU` (33). Result is intentionally ignored - users can grant later. Or use a permission banner.
- **`smallIcon` always references `R.drawable.ic_notification`** (vector). Always present.
- **`PendingIntent.FLAG_IMMUTABLE` is mandatory** on Android 12+.
- **If you bump a channel's importance**, you MUST rename the channel ID. Android won't raise importance on existing channels.

---

## Background-work patterns

- **Foreground service** is the universal answer. Both event-driven and persistent-connection apps benefit from one.
- **No WorkManager required.** Could be added; not necessary for the patterns described here.
- **AlarmManager:** `setExactAndAllowWhileIdle()` with manual reschedule in the receiver. **Never `setRepeating()`.**
- **`AlarmReceiver.onReceive` must be synchronous:** wake lock → `startForegroundService()` → `startActivity()`. Async work in `goAsync()` AFTER. Calling `startForegroundService` from a coroutine **loses the exact-alarm exemption.**
- **`BootReceiver`** for `BOOT_COMPLETED` re-registers all scheduled alarms.
- **`USE_FULL_SCREEN_INTENT` + `SYSTEM_ALERT_WINDOW`** + `singleInstance` activity with `setShowWhenLocked` / `setTurnScreenOn` for full-screen alarm takeover.

---

## Networking conventions

- **OkHttp** is the standard. No Retrofit, no Ktor.
- **One `OkHttpClient` per app process.** Configured at construction with timeouts.
- **Auth:** Bearer token in `Authorization` header. Token stored in DataStore. UI hides it behind a password field with a `show/hide` toggle.
- **Default base URL** is the Tailscale IP `http://<tailscale-ip>:<port>`.
- **`network_security_config.xml`** with `<domain><tailscale-ip></domain>` cleartext exception is preferred over app-wide `usesCleartextTraffic="true"`.
- **WebSocket reconnect:** owned by a foreground service. Never reconnect from a Composable.
- **Polling pattern:** 30 s `LaunchedEffect(Unit) { while (true) { ...; delay(30_000) } }`. Pair with a `LifecycleEventObserver` ON_RESUME re-poll so foregrounding is snappy.

---

## Permissions UX

- **Recheck on resume** with a `LifecycleEventObserver` so the user sees the banner clear immediately after they return from system settings.
- **Single "Setup required" card** linking to a permission screen - not stacking three banners.
- **Standard runtime permissions to plan for:** `POST_NOTIFICATIONS` (Tiramisu+), `RECORD_AUDIO`, `USE_EXACT_ALARM` (33+) / `SCHEDULE_EXACT_ALARM` (31+), `SYSTEM_ALERT_WINDOW`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- **`MainActivity.onCreate` requests `POST_NOTIFICATIONS` once**, ignores answer; users can grant later from settings.

---

