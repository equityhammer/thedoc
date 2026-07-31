[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Cross-version handoff: schema-versioned export envelope

Any hand-rolled JSON / CSV export the app produces (for share intents, cross-device handoff, debug dumps the user might paste between versions) should be wrapped in a `schemaVersion` envelope from day 1, with the importer accepting both the wrapped shape AND the legacy bare-array shape for back-compat. The cost is one extra field on output + one extra route on input; the payoff is that you can evolve the entry shape later without breaking the importer on a phone running last month's version.

```kotlin
// Exporter: wrap entries in versioned envelope
object MyExporter {
    const val SCHEMA_VERSION: Int = 1   // bump on non-additive changes only

    fun toJson(entries: List<Entry>, …): String {
        val arr = JSONArray().apply { entries.forEach { put(it.toJsonObject(…)) } }
        val envelope = JSONObject()
            .put("schemaVersion", SCHEMA_VERSION)
            .put("entries", arr)
        return envelope.toString(2)
    }
}

// Importer: accept BOTH wrapped (v1) and bare-array (v0) shapes
fun parse(rawText: String): Result {
    val cleaned = rawText.trim()
    return when (cleaned.firstOrNull()) {
        '[' -> parseBareArray(cleaned)        // legacy v0
        '{' -> parseWrappedEnvelope(cleaned)  // v1+
        else -> parseCsv(cleaned)
    }
}

private fun parseWrappedEnvelope(text: String): Result {
    val obj = JSONObject(text)
    if (!obj.has("entries")) return failure("got a single object")  // misuse
    val arr = obj.optJSONArray("entries") ?: return failure("'entries' must be an array")
    val warnings = mutableListOf<String>()
    val declared = obj.optInt("schemaVersion", -1)
    when {
        declared < 0 -> warnings += "Handoff missing schemaVersion, assuming v$SCHEMA_VERSION"
        declared > SCHEMA_VERSION ->
            warnings += "Handoff schema v$declared > supported v$SCHEMA_VERSION; some fields may be ignored"
    }
    return parseEntries(arr, warnings)
}
```

**Bump semantics:**
- **Additive changes** (new optional field, e.g. `lifeline` added to existing per-row shape): keep `SCHEMA_VERSION` unchanged. Old importers ignore unknown keys; new importers populate the new field.
- **Non-additive changes** (renamed token, restructured fields, removed required key): bump `SCHEMA_VERSION`. Importer warns when reading a newer version it doesn't understand and degrades gracefully.

**Tripwire test:** pin `SCHEMA_VERSION` value in a single tripwire assertion (`assertEquals(1, MyExporter.SCHEMA_VERSION)`) so anyone bumping it is forced to update the assertion + cascade through every consumer / parser / downstream tool in the same diff.

**Single-object misuse:** if the user pastes `{"package":"com.foo"}` (one row instead of an array), the missing `entries` key returns the same failure as before. Single-object JSON without `entries` is NOT an envelope; treat it as a misuse + reject.

**Round-trip test:** every sprint that touches the export shape should run a `exporter.toJson(...) → importer.parse(result) → assert fields restored` integration test. Catches schema drift the unit tests miss.

Originating change: Transfer Checklist `v1.0.82` (EXPORT-05). Wrapped `ChecklistExporter.toJson` output in `{schemaVersion: 1, entries: [...]}`; `AppListImporter.parse` routes `{` → `parseWrappedJson` (extracts entries + reads version + warns) while `[` still routes to the legacy bare-array path for back-compat with devices on v1.0.80-. Bumping the const broke 8 existing test fixtures that did `JSONArray(text)` directly on the output, captured via a `entriesOf(text)` helper that does `JSONObject(text).getJSONArray("entries")`. 8 new tests pin: envelope shape, only-two-keys, v1-wrapped round-trip, legacy-bare-array back-compat, future-version warn, missing-version warn, single-object rejected, plus the SCHEMA_VERSION tripwire.

---

## Persistence patterns (state holders surviving process death)

For state holders that must survive process death (checklist statuses, user-curated queues, preference toggles, drag-position values, dismissed-tip sets), wrap each in a small `*Persistence` class backed by `SharedPreferences`. The pattern shipped + refined across multiple Transfer Checklist sprints is consistent enough to template here.

### The three-LaunchedEffect-with-hydrated-gate template

Each persistence wrapper in MainActivity follows the same shape: **one boolean `xHydrated` flag + three `LaunchedEffect`s**. Splitting them keeps each concern isolated; combining them either over-saves (re-fires on the hydrated transition) or under-saves (misses emissions between combined keys changing).

```kotlin
@Composable
fun MainScreen() {
    // (1) The state holder + the persistence wrapper, both remembered.
    val xPersistence = remember(context) { XPersistence(context) }
    var xHydrated by remember { mutableStateOf(false) }
    val xState by X.state.collectAsStateWithLifecycle()

    // (1) Hydrate from disk on first composition. Sets xHydrated = true.
    LaunchedEffect(xPersistence) {
        val loaded = xPersistence.load()
        if (loaded.isNotEmpty()) X.restore(loaded)
        xHydrated = true   // ← gate flips
    }

    // (2) Default-init fallback: ONLY fires after hydration. Without the
    // gate, this races the hydrate effect + can overwrite a real persisted
    // value with the bundled default. See "the race" section below.
    LaunchedEffect(xHydrated) {
        if (!xHydrated) return@LaunchedEffect
        if (X.current().isEmpty) {
            X.setPreloaded(DefaultLoader.load(context))
        }
    }

    // (3) Auto-save on each emission post-hydration. The xHydrated gate is
    // load-bearing: collectAsStateWithLifecycle() fires an initial empty
    // emission BEFORE the hydrate effect completes; without the gate, that
    // empty emission saves an empty blob, clobbering the persisted snapshot.
    LaunchedEffect(xHydrated, xState) {
        if (xHydrated) xPersistence.save(xState)
    }
}
```

The persistence wrapper itself is ~15 lines of glue over a pure serializer:

```kotlin
class XPersistence(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun load(): X.Snapshot {
        val text = prefs.getString(KEY, null) ?: return X.Snapshot.EMPTY
        return XSerializer.parse(text)   // corruption fallback lives in the serializer
    }
    fun save(snapshot: X.Snapshot) {
        prefs.edit().putString(KEY, XSerializer.serialize(snapshot)).apply()
    }
    companion object {
        private const val PREFS = "x_state"
        private const val KEY = "snapshot"
    }
}
```

The pure serializer handles malformed/blank input by returning an empty Snapshot; corruption never blocks app launch:

```kotlin
object XSerializer {
    fun serialize(snapshot: X.Snapshot): String = /* JSON */
    fun parse(text: String): X.Snapshot {
        if (text.isBlank()) return X.Snapshot.EMPTY
        val obj = try { JSONObject(text) } catch (_: JSONException) { return X.Snapshot.EMPTY }
        // ... defensive field extraction ...
    }
}
```

### The race when ADDING persistence to a previously-transient state holder

When you add persistence to a state holder that already had a "load default if empty" initializer in MainActivity, that pre-existing initializer becomes a race source. The default-loader can win the race + overwrite a real persisted value with the bundled default. Symptom: user customized state → kill app → reopen → see bundled default instead of customizations.

```kotlin
// BEFORE adding persistence: this works fine because X is always empty on launch:
LaunchedEffect(context) {
    if (X.current().isEmpty) X.setPreloaded(DefaultLoader.load(context))
}

// AFTER adding persistence WITHOUT the gate: these two LaunchedEffects race:
LaunchedEffect(xPersistence) { /* load + restore + xHydrated = true */ }
LaunchedEffect(context)      { /* reads X.current() while it might be pre-hydrate empty */ }
//                             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                             RACE: fires concurrently with hydrate;
//                             may overwrite a persisted snapshot with bundled default.
```

**Fix:** re-key the default-init effect on `xHydrated` (not `context`) so it only fires AFTER hydration completes. The three-effect template above already shows this. The rule is: any LaunchedEffect that READS the state holder's current value must gate on `xHydrated`.

**Audit trigger:** any time you add a `*Persistence` wrapper to an existing state holder, grep MainActivity for `LaunchedEffect(context) { ... X.current() ... }` (or any LaunchedEffect that reads from the same singleton). Each one is a potential race source. Re-key on the new hydrated flag.

### `schemaVersion` for per-device persistence: tolerate future, never silently wipe

Per-device persistence isn't a cross-version handoff surface (that's the previous "Cross-version handoff: schema-versioned export envelope" section). But the same `schemaVersion: N` envelope idea applies. Wrap the persisted blob so future additive fields don't need a schema bump, AND so a downgrade can read what it recognizes instead of crashing.

The key contract difference vs. cross-version handoff: **per-device persistence must NEVER silently wipe the user's data on an unknown schemaVersion.** A user installing a newer version + then downgrading should keep their data intact (minus the new fields the older version doesn't know about). Silently treating an unknown schemaVersion as "corrupt, start fresh" would lose all their state.

```kotlin
object XSerializer {
    const val SCHEMA_VERSION: Int = 1   // bump on truly-breaking changes only

    fun parse(text: String): X.Snapshot {
        if (text.isBlank()) return X.Snapshot.EMPTY
        val obj = try { JSONObject(text) } catch (_: JSONException) { return X.Snapshot.EMPTY }
        // schemaVersion check: READ but DON'T fail on unknown future versions.
        // User-facing impact would be the state silently clearing on downgrade,
        // which is worse than tolerating a future schema we don't fully
        // understand (we'd read what we recognize + skip the rest).
        val declared = obj.optInt("schemaVersion", SCHEMA_VERSION)   // missing → assume current
        // No warning surface: user isn't doing the importing, persistence is automatic.
        val entries = obj.optJSONArray("entries") ?: JSONArray()
        // ... extract known fields, skip unknowns ...
        return X.Snapshot(entries = parseEntries(entries), /* ... */)
    }
}
```

**Bump rules** (different from cross-version handoff):
- **Additive change** (new optional field): keep `SCHEMA_VERSION` unchanged. Older readers ignore the new field.
- **Restructured / renamed field**: bump SCHEMA_VERSION. Older readers degrade gracefully (skip unrecognized fields). Older versions of the app don't see the renamed data, equivalent to "the user's customizations to that specific field reset on downgrade"; call that out in the release notes if it matters.
- **Removed field**: bump SCHEMA_VERSION. The field is gone from the blob; older versions that look for it find nothing + use their default.

**Tripwire test:** pin SCHEMA_VERSION value in a single assertion (`assertEquals(1, XSerializer.SCHEMA_VERSION)`) so anyone bumping it is forced to update the assertion + the codebase's consumers in the same diff.

### Don't persist metadata about transient state

When a spec asks you to persist metadata ABOUT some state ("when was X last loaded?", "how many cache hits for Y?", "what version was on disk last?"), verify that the underlying state X is itself persisted at the same lifetime BEFORE wiring metadata persistence. **Persisting metadata about in-memory-only state creates stale-claim UI lies after process restart:** the metadata survives + speaks confidently, but the thing it describes is gone.

```kotlin
// WRONG: persists metadata about transient state
class XImportProvenancePersistence(ctx: Context) {
    fun save(provenance: Provenance) { prefs.edit().putLong("importedAt", provenance.collectedAt).apply() }
    fun load(): Long? = prefs.getLong("importedAt", -1L).takeIf { it > 0 }
}
// → After process restart: prefs.getLong returns 2-day-old timestamp; in-memory X is empty.
// → UI renders "Imported 2 days ago" on a card showing the BUNDLED default. UI lie.

// RIGHT: metadata lives at the data's lifetime
data class Snapshot(
    val entries: List<Entry>,
    val imported: Boolean,
    val importedAt: Long? = null,   // same lifetime as the entries themselves
)
fun setImported(entries: List<Entry>, importedAt: Long = System.currentTimeMillis()) {
    _state.value = _state.value.copy(entries = entries, imported = true, importedAt = importedAt)
}
fun setPreloaded(entries: List<Entry>) {
    _state.value = _state.value.copy(entries = entries, imported = false, importedAt = null)   // clear together
}
```

**Apply:** for any spec asking "persist metadata to SharedPreferences / DataStore", trace what the metadata describes. Is THAT persisted? At what lifetime? If they don't match, surface the asymmetry; usually the right fix is to tie the metadata to the data's lifetime (either both in-memory or both on disk), not to persist metadata at a different cadence than the data it describes.

Originating changes: Transfer Checklist's persistence pattern emerged across multiple sprints:
- `v1.0.82` (DEBT-14): first `*Persistence` wrapper, established the three-LaunchedEffect template for ChecklistRepository.
- `v1.0.89` (UX-33): the don't-persist-metadata-about-transient-state lesson. Spec asked to SharedPreferences-persist an `importedAt` timestamp for an imported app list that itself was in-memory-only, which would have produced a stale-claim caption after process restart. Fix: tied `importedAt` to the in-memory `Snapshot` lifetime. Captured as memory `feedback-dont-persist-metadata-about-transient-state`.
- `v1.0.90` (PERSIST-01, PERSIST-02): closed the in-memory-only gap for two more state holders + discovered the race-on-adding-persistence pattern in PERSIST-02's wiring audit. Pattern captured as memory `feedback-gate-default-init-on-hydration`.
- `v1.0.90` (DOC-12): Mermaid sequenceDiagram of the full hydrate-on-startup chain in `dist/state_persistence_audit.md`.

---

