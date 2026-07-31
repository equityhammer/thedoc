[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Displaying installed-app metadata (icons + labels)

Apps that surface a list of *other* installed apps (launchers, transfer tools, app-management utilities) hit a triple of related traps. None are individually fatal; together they make a list scroll feel sluggish and look broken.

### Read labels + icons from `PackageManager`, not bundled JSON

A bundled JSON catalog of "popular Android apps" almost certainly carries an empty `name` field for half its entries; original sources don't always populate display names. Rendering `entry.name.ifEmpty { entry.packageName }` then produces rows like "com.whatsapp" and "com.teslacoilsw.launcher" in the UI. The fix: at render time, consult the device's own `PackageManager`:

```kotlin
fun PackageManager.appLabelFor(pkg: String, fallback: String = ""): String =
    try {
        getApplicationLabel(getApplicationInfo(pkg, 0)).toString()
    } catch (_: PackageManager.NameNotFoundException) {
        fallback.ifBlank { pkg }
    }

fun PackageManager.appIconFor(pkg: String): Drawable? =
    try { getApplicationIcon(pkg) }
    catch (_: PackageManager.NameNotFoundException) { null }
```

Define a fallback ladder: system label → bundled name → package id → `(unknown)`. The system label is always the best available identity: it's the same string the user sees in their launcher.

### Memoize PackageManager calls

`PackageManager.getApplicationIcon` and `getApplicationLabel` are IPC calls to `system_server`. Calling them on every recomposition or every render tick will be noticeable in profiler traces and on low-end devices. Wrap them in a single generic cache:

```kotlin
class AppIconCache<T>(private val loader: (String) -> T?) {
    private val cache = mutableMapOf<String, T?>()
    fun get(pkg: String): T? =
        if (cache.containsKey(pkg)) cache[pkg]
        else loader(pkg).also { cache[pkg] = it }   // cache nulls too
    fun clear() = cache.clear()
}
```

Two key invariants: (a) **cache `null` too**: for uninstalled packages there's no answer, and you don't want to keep retrying every render; (b) **one cache instance per consumer surface**: a Compose `LocalAppIconCache` for in-app rows, a separate cache field on the overlay `Service` for the overlay surface. Different lifetimes, different invalidation semantics.

### Foreground services with periodic tickers MUST go through the cache too

If your app has a foreground service that re-renders an overlay or notification every N seconds, that service is a hidden second consumer of PackageManager. A 30-second ticker that calls `packageManager.getApplicationIcon(currentPkg)` per render does 2 IPC/min × hours-long sessions = many wasted lookups. Inject (or instantiate) an `AppIconCache<Drawable>` in `onCreate` and route every icon lookup through it; the rate drops to "once per package per session."

```kotlin
class OverlayService : Service() {
    private lateinit var iconCache: AppIconCache<Drawable>

    override fun onCreate() {
        super.onCreate()
        iconCache = AppIconCache { pkg ->
            try { packageManager.getApplicationIcon(pkg) }
            catch (_: Throwable) { null }
        }
    }

    private fun renderAppIcon(pkg: String, into: ImageView) {
        iconCache.get(pkg)?.let { into.setImageDrawable(it) }
            ?: into.setImageResource(R.drawable.ic_app_placeholder)
    }
}
```

Originating changes: Transfer Checklist `v1.0.75` (ICON-01) added the `AppLabelLookup` + `AppIcon` Composables + `AppIconCache` kernel in the in-app surface after a real-device screenshot showed `com.whatsapp` rendered as display text. `v1.0.77` (PERF-01) extended the same cache pattern to `OverlayService` after a sprint-close audit caught the service-side `renderAppIcon` bypassing the cache.

---

