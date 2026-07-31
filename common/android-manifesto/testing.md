[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Testing patterns

### Fake the Android boundary, not the pure code

To JVM-test an Android persistence chain (SharedPreferences read/write, SensorManager listen, ContentResolver query, asset stream read) end-to-end without Robolectric or instrumentation, stub ONLY the Android-coupled boundary with a minimum-surface fake; leave every layer ABOVE that boundary as the real production code. The test exercises the real serializer, the real repository, the real observer wiring; only the actual syscall is replaced.

```kotlin
class ChecklistRepositoryPersistenceRoundTripTest {

    // 12-line fake: the ONLY Android-coupled surface.
    // var String? blob is the entire production-side state of
    // SharedPreferences.getString / .edit().putString() for this key.
    private class FakeStore {
        private var blob: String? = null
        fun save(snapshot: Map<String, ChecklistStatus>) {
            blob = ChecklistStatusSerializer.serialize(snapshot)   // REAL serializer
        }
        fun load(): Map<String, ChecklistStatus> {
            val text = blob ?: return emptyMap()
            return ChecklistStatusSerializer.parse(text)            // REAL parser
        }
        fun corruptWith(text: String?) { blob = text }              // tests use this to inject garbage
    }

    @After fun reset() = ChecklistRepository.reset()                // singleton hygiene

    @Test fun round_trip_via_fake_store() {
        val store = FakeStore()
        ChecklistRepository.setStatus("com.foo", DONE)
        store.save(ChecklistRepository.snapshot())                  // real repository → real serializer → fake blob
        ChecklistRepository.reset()
        ChecklistRepository.restore(store.load())                   // fake blob → real parser → real repository
        assertEquals(DONE, ChecklistRepository.statusOf("com.foo"))
    }

    @Test fun malformed_json_yields_empty_map() {
        val store = FakeStore().also { it.corruptWith("{garbage") }
        ChecklistRepository.restore(store.load())                   // real parser drops garbage cleanly
        assertEquals(0, ChecklistRepository.snapshot().size)
    }
}
```

**Why this beats mocking the repository or running under Robolectric:**
- The real serializer is exercised → catches schema drift the unit-level serializer tests would have missed.
- The real repository is exercised → catches singleton-reset bugs, observer-notification ordering, mid-restore writes.
- The fake is tiny (`var String? blob`): no Mockito, no PowerMock, no Robolectric. Plain JUnit + `org.json` JVM dep already in `libs.versions.toml`.
- Test runs in <100ms per case; full suite stays in the standard `./gradlew testDebugUnitTest` envelope.

**Where the boundary lives (per surface):**

| Android boundary | Production API | Fake surface |
|---|---|---|
| Key/value persistence | `SharedPreferences.getString` / `.edit().putString()` | `var String? blob` (or `var Map<String, String>` for multi-key) |
| Sensor stream | `SensorManager.registerListener` | `fun emit(event: SensorEvent)` the test calls directly |
| Content provider | `ContentResolver.query` | `var Cursor? cursor` returning a `MatrixCursor`-equivalent |
| Asset stream | `AssetManager.open(name)` | `var String? contents` |
| Battery sticky-broadcast read | `registerReceiver(null, IntentFilter(ACTION_BATTERY_CHANGED))` | `var Intent? sticky` |

**Don't:**
- Mock the repository itself: defeats the purpose; the production path doesn't run.
- Use Robolectric for what a 12-line fake can replace: Robolectric startup adds seconds to every test run and brings its own emulation bugs (sensor quirks, package-manager stubs that differ from production).
- Mock the serializer: keep it real so test failures point at actual schema mismatches, not mock-config errors.

**When Robolectric IS the right tool:** WindowManager / Service lifecycle tests, activity-result contract tests, anything where the Android-side state machine itself is what you're testing. A pure persistence / sensor-stream chain is NOT one of those.

Originating change: Transfer Checklist `v1.0.85` (TEST-COV-05). New `ChecklistRepositoryPersistenceRoundTripTest` exercises the full DEBT-14 chain (`setStatus → serialize → persist → hydrate → parse → restore`) end-to-end. 7 tests cover the happy path, NEEDS_ATTENTION-strip semantic, malformed JSON, null blob, unknown enum tokens dropped silently, bulk-restore via the import path, and accumulated-snapshot growth across successive writes. Pattern captured as memory `feedback-fake-the-android-boundary-not-the-pure-code`.

### Test-then-assert on platform parser behavior

For ANY parser you do NOT own (`org.json.JSONArray` / `JSONObject`, regex, `SimpleDateFormat`, `Uri.parse`, the CSV / XML / HTML parsers from the platform), write the test FIRST in a "what does the parser actually do?" mode, then write the assertion to match observed behavior. Don't write the assertion from spec; the spec is the promise, the behavior is the contract.

```kotlin
// WRONG: assertion written from JSON-spec strictness assumption
@Test fun trailing_commas_in_json_are_rejected() {
    val raw = """[{"a":1},]"""
    val result = AppListImporter.parse(raw)
    assertFalse(result.ok)   // FAILS: Android's org.json is LENIENT
}

// RIGHT: assertion written from observed behavior
@Test fun trailing_commas_in_json_are_tolerated_by_lenient_parser() {
    val raw = """[{"a":1},]"""
    val result = AppListImporter.parse(raw)
    assertTrue(result.ok)
    assertEquals(1, result.entries.size)   // the trailing-comma slot is JSONObject.NULL → skipped
}
```

**Why:** Android's `org.json` is descended from the original Crockford reference implementation and tolerates trailing commas, single-quoted strings, unquoted keys, and comments, all behaviors that strict JSON validators reject. `SimpleDateFormat` is locale-dependent and silently parses partial matches. `Uri.parse` accepts almost anything. Regex flavors differ on whether `.` matches newlines by default. Asserting from spec produces tests that pass against your mental model but fail against the actual runtime.

**Workflow:** run the test BEFORE writing assertions when you don't already know how the parser handles edge cases. Use `println(result)` or a temporary `fail("got: $result")` to observe; then commit the test with the assertion matching the observation. The committed test pins the runtime contract: if a future Android version (or a library swap) changes the parser, the test fails loudly with a clear diff.

Originating change: Transfer Checklist `v1.0.82` (TEST-COV-03). Initial assertion that JSON trailing commas would reject was written from strict-spec memory; actual `org.json.JSONArray` parsed the array with the trailing slot becoming `JSONObject.NULL`, which the row parser drops silently. Renamed the test + flipped the assertions to match observed behavior. Pattern captured as memory `feedback-test-then-assert-platform-parser-behavior`.

### Cross-singleton integration tests + defense-in-depth @Before reset

When the app has multiple process-scoped singletons that callers commonly mutate together (`ActiveAppList` + `ChecklistRepository` + `SkipReasonRepository` for a queue-management app, etc.), the unit tests per-singleton don't catch one critical class of bug: **destructive operations on one singleton silently clobbering siblings.** Add an integration test class that exercises the system-level contract: operation on target singleton, assert siblings UNTOUCHED.

```kotlin
class ResetUndoCrossSingletonIntegrationTest {

    @Before fun isolateState() {
        // Defense in depth: don't trust prior test classes' @After to have
        // cleaned everything. Reset all three singletons we touch.
        ActiveAppList.restoreFromSnapshot(ActiveAppList.Snapshot(entries = emptyList(), imported = false))
        ChecklistRepository.restore(emptyMap())
        SkipReasonRepository.restore(emptyMap())
    }

    @After fun cleanState() {
        ActiveAppList.restoreFromSnapshot(ActiveAppList.Snapshot(entries = emptyList(), imported = false))
        ChecklistRepository.restore(emptyMap())
        SkipReasonRepository.restore(emptyMap())
    }

    @Test fun reset_only_touches_ActiveAppList_leaves_sibling_singletons_intact() {
        // Build non-trivial cross-singleton state.
        ActiveAppList.setImported(listOf(entry("com.a"), entry("com.b")))
        ChecklistRepository.setStatus("com.a", ChecklistStatus.DONE)
        SkipReasonRepository.setReason("com.a", "waiting on 2FA")

        val captured = ActiveAppList.current()
        ActiveAppList.setPreloaded(listOf(entry("com.bundled")))   // destructive Reset

        // Sibling singletons MUST be untouched; this is the tripwire.
        assertEquals(1, ChecklistRepository.snapshot().size)
        assertEquals(ChecklistStatus.DONE, ChecklistRepository.statusFor("com.a"))
        assertEquals("waiting on 2FA", SkipReasonRepository.reasonFor("com.a"))

        // Undo restores ActiveAppList; siblings STILL untouched.
        ActiveAppList.restoreFromSnapshot(captured)
        assertEquals(captured.entries, ActiveAppList.current().entries)
        assertEquals(1, ChecklistRepository.snapshot().size)
    }
}
```

**Key invariants:**
- **`@Before` resets all related singletons, not just the one this class tests.** Even if your `@After` is meticulous, a prior test class's `@After` might have a gap (see "Fake the Android boundary, not the pure code" + the general lesson about singleton hygiene). Defense in depth = `@Before` does the reset too.
- **The tripwire assertion is "siblings UNTOUCHED."** Each `assertEquals` on a sibling's snapshot AFTER the destructive op + AFTER the undo is the load-bearing line: a future "fuller" implementation that wired the destructive op to also wipe siblings would fail loudly, forcing the change to be a conscious UX decision rather than a silent regression.
- **The integration test class lives ALONGSIDE the unit tests, not replacing them.** Unit tests cover the kernel in isolation (snapshot round-trip, idempotence, edge cases). The integration test covers the system-level contract (cross-singleton scope of each operation). Both are needed.
- **Pin the @Before/@After contract itself with a meta-test.** Add a test like `cross_singleton_state_isolated_between_test_invocations` that asserts all three singletons are empty at test entry, direct evidence that the lifecycle hooks fire correctly.

Originating change: Transfer Checklist Sprint 26 (TEST-COV-07). `ResetUndoCrossSingletonIntegrationTest` covers the Reset → Snackbar-Undo → restoreFromSnapshot chain across `ActiveAppList` + `ChecklistRepository` + `SkipReasonRepository`. The bug class it prevents: a future "fuller" Reset that also wiped statuses/reasons would silently destroy in-flight user work without the test catching it. The `@Before`-resets-all-three contract complements the per-class `@After` hygiene fix introduced in Sprint 25 UX-27 (see memory `feedback-singleton-after-hygiene-gaps`).

### Tripwire tests for structurally-impossible spec premises

Sometimes a sprint spec describes a problem the kernel has already prevented, usually because earlier work fixed the underlying class of issue under a different item name. When you discover the premise is wrong, do NOT silently fix it to fit the spec (would be a no-op edit at best, regression at worst). **Ship a named tripwire test that pins the invariant the kernel already enforces**, with a comment naming the spec's original concern + the failure message telling the next reader what to do if they ever break it.

```kotlin
@Test fun ok_true_implies_entries_not_empty_contract_invariant() {
    // SPEC-XYZ (Sprint N) proposed wiring Snackbar-Undo for the "user pastes
    // [] → commits an empty import → queue wiped" case. The scenario is
    // STRUCTURALLY IMPOSSIBLE today: `Result.ok = error == null &&
    // entries.isNotEmpty()` (AppListImporter.kt:59), and ImportListDialog's
    // Confirm button is gated on `result?.ok == true`, so a successful-parse-
    // with-empty-entries can never be committed via the UI.
    //
    // This test pins the invariant exhaustively. If any future refactor
    // relaxes `ok`'s definition (a "force commit" path, ok-on-empty-entries),
    // this test fails loudly + the failure message tells the next reader to
    // ALSO wire the Snackbar-Undo per SPEC-XYZ's original spec in the SAME
    // diff; no silent regression possible.
    val emptyAndOkScenarios = listOf(
        "[]", """{"schemaVersion":1,"entries":[]}""",
        "package\n", "package,name\n", ""
    )
    emptyAndOkScenarios.forEach { input ->
        val r = AppListImporter.parse(input)
        assertFalse(
            "Contract violation: parse(\"$input\") yielded ok=true with empty entries. " +
                "If this is intentional, ImportListDialog gating + onImport must also handle " +
                "the empty-commit case (Snackbar-Undo per SPEC-XYZ's original spec). " +
                "Don't relax ok's definition without wiring the rest.",
            r.ok && r.entries.isEmpty()
        )
    }
}
```

**Why ship the tripwire instead of skipping the item:**
- The original spec captured a REAL concern (someone might wire empty-commit-without-Undo someday). The tripwire keeps that concern visible: a future reader who DOES want to ship empty-commit support hits the test, reads the failure message, and either updates the test + adds Undo OR backs out their change.
- Without the tripwire, the spec's concern is lost in the closeout note. The next time someone audits the importer, they have to re-discover the invariant + decide whether it's load-bearing all over again.
- The test costs ~10 lines + 0 production code. The cost of catching one accidental regression years later is much higher than the cost of the test.

**When to apply this pattern:**
- Audit step (verifying spec premise against current code) reveals the kernel already enforces what the spec was trying to add.
- The invariant matters, i.e., a future change relaxing it would have user-visible consequences (data loss, UI confusion, lost recovery affordance).
- The invariant is in a kernel you control. (For platform invariants you don't control, use the [test-then-assert on platform parser behavior] pattern instead: pin observed behavior, not your assumed contract.)

**When NOT to apply:**
- The "impossible" scenario is impossible because of UNRELATED code that could change at any time. The tripwire would protect against the wrong thing.
- The spec's concern is purely cosmetic (visual tweaks, copy edits): there's no invariant to pin.

**Closeout discipline:** when shipping a tripwire instead of the spec's literal ask, the closeout note must call out (a) the spec premise check that revealed the impossibility, (b) what was shipped instead, and (c) the originating memory ([[feedback-verify-spec-premise-against-current-code]]) so the pattern keeps accumulating reinforcement evidence.

Originating changes: this is a recurring pattern in Transfer Checklist, three instances in three sprints:
- `v1.0.87` Sprint 25 BUBBLE-05: spec claimed `OverlayActionLabel.fitDensity(<= 0)` returns COMFY; actually returned ICON_ONLY since TEST-COV-01 (v1.0.78). Shipped `extreme_narrow_button_width_picks_ICON_ONLY_not_COMFY_xml_default` tripwire.
- `v1.0.89` Sprint 27 DOC-11: spec premise of "3 of 4 singletons unpersisted" was based on a pre-DEBT-14 mental model; actual count was 2 of 5. Shipped a 152-line audit doc correcting the count + cataloguing the real state.
- `v1.0.90` Sprint 28 EXPORT-10: spec described "user pastes [] → queue wiped without Undo"; `Result.ok` contract makes this structurally impossible. Shipped `ok_true_implies_entries_not_empty_contract_invariant` tripwire.

The pattern earns its place in this manifesto by recurring 3x: each time, the spec-vs-reality check caught wasted work OR active regression and redirected to a test that pins the right invariant.

### Verify ALL layers, not just the one the spec names

When a spec describes a real-device visual / UX issue and you audit the layer the spec names (a kernel, formatter, decision rule), **don't stop there.** If the named layer is correct, push the audit to OTHER layers that could produce the same user-visible symptom (layout XML, density code, drawable sizing, gravity, padding, parent container measurement). A "no change needed" verdict on the named layer alone ships an unfixed bug when the user's real complaint was about a different layer.

```kotlin
// Spec: "the action buttons render as bars instead of glyphs at narrow widths"
//       proposed fix: tighten the kernel's < 0 branch
//
// Audit step 1: KERNEL.
//   OverlayActionLabel.fitDensity(<= 0) → already returns ICON_ONLY ✓
//   "Kernel is correct, ship a tripwire test, call it done?" NO.
//
// Audit step 2: LAYOUT.
//   overlay_bubble.xml: action buttons have minWidth="0dp" + paddingHorizontal="8dp"
//   → at narrow widths, 16dp padding consumes the whole ~17dp button
//   → glyph has ~1dp to render in → glyph collapses to a thin bar
//   ↑ THIS is the actual bug.
//
// Fix the LAYOUT (the layer the user was actually complaining about,
// not the layer the spec's text named):
//   <Button minWidth="44dp" paddingHorizontal="4dp" gravity="center" />
```

**Apply when:**
- Audit step (verifying spec premise against current code, per the previous subsection) reveals the kernel/formatter the spec named IS correct, but the user-visible symptom is REAL.
- Spec describes a "rendering" / "layout" / "looks wrong" symptom + names a specific composable / function as the cause.
- Real-device feedback uses the word "still" ("still squished", "still cut off", "still not working"), and a 3-sprint-stale "still" means the previous closeout audited the wrong layer.

**Layers to consider for visual symptoms:**
1. Kernel / decision rule (what the spec usually names)
2. Layout XML / Compose layout (size constraints, padding, gravity, weight distribution)
3. Drawable rendering (density-dependent vectors, asset scaling)
4. Parent container (CardDefaults.minHeight, LazyColumn item slot, overlay window LayoutParams)
5. Theme / font (Material 3 default sizing, accessibility-scaled font)
6. Animation (mid-tween states, recomposition timing)
7. Window-level constraints (WindowManager.LayoutParams, IME insets, FLAG_NOT_FOCUSABLE)

**Closeout discipline:** when you DO push the audit deeper + find the real layer, the closeout note must call out (a) the spec's narrower premise, (b) the broader audit you actually did, (c) the layer where the fix landed. This makes the pattern visible for future readers: they learn to push their own audits deeper.

Originating change: Transfer Checklist `v1.0.91` Sprint 29 BUBBLE-06. BUBBLE-05 (Sprint 25) had audited only the kernel + concluded "no change needed" + shipped a tripwire test. 3 sprints later a Debug FAB report of `still squished.` arrived from a foldable cover display: same complaint, kernel still correct, but the LAYOUT (`overlay_bubble.xml` button padding) was where the bug actually lived. Fixed in BUBBLE-06 with a 3-line XML change; pattern captured as memory `feedback-verify-all-layers-not-just-the-named-one`. Sibling of [verify spec premise against current code] in the previous subsection, same family of "don't trust claims about current state, audit", different axis (named-layer-vs-actual-buggy-layer instead of named-condition-vs-actual-code-state).

---

