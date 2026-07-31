[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Settings / preferences conventions

Two valid choices:

- **DataStore preferences** - preferred for typed, observed, suspend-edited config like `serverUrl + token`.
- **SharedPreferences** - fine for small bag-of-flags state, especially when you also want a `compositionLocalOf<Boolean>` so any composable can read it without prop-drilling.

**Settings screen UI conventions:**
- Always a separate screen (not a dialog) for connection-type settings; an `AlertDialog` is fine for app-internal toggles.
- Show "saved" inline next to the Save button after edit.
- Include a "How to find these:" footer with literal commands when settings reference an external system (Tailscale IP, server token, etc.).

---

## Theming / Compose conventions

- **Material 3 only.** `androidx.compose.material3.*`. No Material 2.
- **Single-activity** (`ComponentActivity`) + Compose Navigation. Each top-level destination is a route in one `NavGraph` Composable.
- **Theme structure:** `ui/theme/{Theme,Color,Type}.kt`. The Composable is named `<Slug>Theme`.
- **`enableEdgeToEdge()`** in `MainActivity.onCreate`.
- **`collectAsStateWithLifecycle`**, not `collectAsState`. ViewModels expose `StateFlow`.
- **No nested NavGraphs for ViewModel sharing.** Use a repository singleton on the Application.
- **`Companion object` MutableStateFlow as shared state is an anti-pattern.** Use a Container-owned repository instead.

### Compose state lifecycle: don't put `remember` inside conditional branches

When a dialog / sheet / collapsible section holds user-editable state (text input, picked Uri, validated form values), declare the `remember { mutableStateOf(...) }` calls in the **SAME composition scope as the visibility flag**, NOT inside the `if (visible) { ... }` block.

```kotlin
// WRONG: drafts vanish every time the dialog closes
@Composable
fun MyHost() {
    var dialogOpen by remember { mutableStateOf(false) }
    if (dialogOpen) {
        var draftText by remember { mutableStateOf("") }  // gone on dismiss
        AlertDialog(/* … */)
    }
}

// RIGHT: drafts persist across open/close cycles
@Composable
fun MyHost() {
    var dialogOpen by remember { mutableStateOf(false) }
    var draftText by remember { mutableStateOf("") }      // outer scope
    if (dialogOpen) {
        AlertDialog(/* … */)
    }
}
```

When the `if (visible) {}` branch leaves composition, every `remember` inside it is destroyed; reopening rebuilds them as defaults. The user types a message, accidentally dismisses, reopens, and everything is gone. The fix is to hoist the state to the outer scope so it survives. Only explicit "Send success" or "Clear" actions should wipe drafts.

Originating change: Transfer Checklist `v1.0.74` (HOTFIX-02), from a real-user complaint: *"Things that I type inside the feedback window should not be deleted unless sent or deleted. If the modal closes, it should still be there when I open it back up."* This bug class is silent (no exception, no logcat hint) so it must be caught at code-review time; capture the pattern with an inline comment near hoisted state so future edits don't regress.

### `.navigationBarsPadding()` on FABs over edge-to-edge content

Once you call `enableEdgeToEdge()` in `MainActivity.onCreate`, the system gesture-navigation strip overlaps the bottom of your `Scaffold`. Any FloatingActionButton positioned at `BottomStart` / `BottomEnd` will sit underneath it and become hard or impossible to tap: the user's tap lands on the system nav instead. The fix is one modifier per FAB:

```kotlin
import androidx.compose.foundation.layout.navigationBarsPadding

SmallFloatingActionButton(
    onClick = onDebugClick,
    modifier = Modifier
        .align(Alignment.BottomStart)
        .padding(16.dp)
        .navigationBarsPadding(),    // <-- lift above gesture strip
) { /* ... */ }

ExtendedFloatingActionButton(
    onClick = onStart,
    modifier = Modifier
        .align(Alignment.BottomEnd)
        .padding(16.dp)
        .navigationBarsPadding(),
    text = { Text("Start") },
    icon = { Icon(Icons.Default.PlayArrow, null) },
)
```

Apply to BOTH the global Debug FAB (in `DebugFabHost`) and any per-screen FABs (in their `Scaffold`). `navigationBarsPadding` is from `androidx.compose.foundation.layout`, so no extra dep. If the FAB is inside a `Scaffold` that uses `contentPadding`, the modifier composes with it cleanly. Verify on a phone with 3-button navigation off (gesture nav on): that's where the regression bites; on tablets / 3-button devices the bug is invisible.

Originating change: Transfer Checklist `v1.0.76` (FAB-01), from a real-user complaint: *"The report error bug bubble thing needs to make sure that it's a little higher on the page for when there's a transparent menu on the bottom of the page, so that it's always clickable."* Surfaced after edge-to-edge became the Compose default; pre-edge-to-edge apps were accidentally protected by the opaque nav bar inset.

### Override Compose semantics when Material 3 defaults mis-frame stateful controls

Material 3 components carry default TalkBack semantics built around their *visual* identity (a FilterChip is a "checkbox", a Button is a "button") rather than their *interaction* semantics (a Panic-mode toggle is really a Switch; a four-way exclusive selector is really four RadioButtons). When the defaults are wrong, override them via `Modifier.semantics(mergeDescendants = true)`: TalkBack will then announce role + state correctly.

```kotlin
// Stateful toggle that visually uses FilterChip but is conceptually a Switch
FilterChip(
    selected = panicMode,
    onClick = { onPanicModeToggle(!panicMode) },
    label = { Text("Panic mode") },
    modifier = Modifier.semantics(mergeDescendants = true) {
        role = Role.Switch
        toggleableState = if (panicMode) ToggleableState.On else ToggleableState.Off
    }
)
// TalkBack reads: "Panic mode, switch, on/off"  (was: "Panic mode, checkbox, checked")

// One-of-N exclusive selector rendered as alternating button styles
@Composable
fun StatusButton(label: String, selected: Boolean, onClick: () -> Unit) {
    val a11y = Modifier.semantics(mergeDescendants = true) {
        role = Role.RadioButton
        this.selected = selected
    }
    if (selected) FilledTonalButton(onClick, modifier = a11y) { Text(label) }
    else          OutlinedButton(onClick,   modifier = a11y) { Text(label) }
}
// TalkBack reads: "Done, selected, radio button"  (was: "Done, button")
```

**When to override (vs accept the default):**
- If the visual control type lies about the interaction model (Chip-as-Switch, Button-as-Radio), override.
- If the selected state has no audible signal (only visual differentiation via fill vs outline), override.
- If your control set is a mutually-exclusive group, set `Role.RadioButton` on EACH and toggle `selected = true` on the chosen one; TalkBack groups them and announces "1 of 4" navigation.

**When NOT to override:**
- A genuine `Checkbox` rendering a multi-select item: Material 3's default is correct.
- An `IconButton` with `contentDescription` set: already speaks correctly via the description.
- A non-stateful `Button` whose label text already tells the user what it does.

**Imports:** `androidx.compose.ui.semantics.{semantics, role, selected, toggleableState}`, `androidx.compose.ui.state.ToggleableState`, `androidx.compose.ui.semantics.Role`. No new deps.

This pattern is fundamentally untestable at the JVM unit level (Compose semantics live in the runtime tree). Verify with a real TalkBack focus walk on every interactable on the screen at sprint-close. Listen for "checkbox" on a stateful toggle or silence on a selection change, both signs the default is wrong.

Originating change: Transfer Checklist `v1.0.79` (ACCESS-02). A TalkBack focus walk caught Panic Mode being announced as "checkbox, checked" and ChecklistRow's four-way status buttons (Done / Skip / Ignored / Needs attention) announcing as undifferentiated "button" with no selection cue. Two targeted overrides closed both gaps.

### Toast text is silent to TalkBack on Android 11+: dual-track with `announceForAccessibility`

Android 11 (API 30) stopped auto-narrating Toast text to TalkBack for security/clutter reasons. Sighted users still see the toast; screen-reader users hear silence. Anywhere you fire `Toast.makeText(...).show()` to communicate state to the user, also fire `view.announceForAccessibility(message)` so the same text reaches accessibility services.

```kotlin
@Composable
fun MyRow(reason: String) {
    val rowContext = LocalContext.current
    val rowView = LocalView.current  // Compose's hook for the host View
    IconButton(onClick = {
        Toast.makeText(rowContext, reason, Toast.LENGTH_LONG).show()
        rowView.announceForAccessibility(reason)   // ← TalkBack hears this
    }) {
        Icon(Icons.Outlined.Info, contentDescription = "Why is this here?")
    }
}
```

**When to use the dual-track:** every Toast that conveys *state* or an *explanation* (not just a brief acknowledgement). The dual fire is safe: `announceForAccessibility` is a no-op when no accessibility service is active, so sighted-only sessions pay nothing.

**When Snackbar is a better fit:** if you're in a `Scaffold` with a `SnackbarHost`, prefer `snackbarHostState.showSnackbar(...)` over Toast; Snackbar narrates to TalkBack on every API level AND surfaces an `actionLabel` (see the Snackbar Undo section). Toast survives where Snackbar can't reach (overlays, services, pre-Scaffold screens).

**Don't substitute one for the other.** Toast is rendered by the system at a fixed position, immune to layout. Snackbar lives inside your `Scaffold`. `announceForAccessibility` is the only path that always reaches the screen reader regardless of host context.

Originating change: Transfer Checklist `v1.0.81` (ACCESS-04). UX-10's per-row info button fired only Toast; screen-reader users heard nothing on Android 11+. Dual-tracked with `LocalView.current.announceForAccessibility(reason)` so both paths now speak.

### Tappable text URLs via `LocalUriHandler`, NOT plain `Text` with onSurfaceVariant color

When a Compose surface displays a reference URL (`https://...`), help-link, or any tappable destination, do NOT render it as plain `Text(...)` in `MaterialTheme.colorScheme.onSurfaceVariant`. Three reasons:

1. **Not tappable at all** unless wrapped in `Modifier.clickable { ... }`.
2. **Not visually obvious as a link**: onSurfaceVariant looks like caption text. Users won't know they can interact.
3. **Not even copy-paste-able**: Material 3 `Text` doesn't support text selection without a `SelectionContainer` wrapper, so users wanting to follow the link have to MEMORIZE + retype it.

The Compose-idiomatic fix is `LocalUriHandler`, which uses `Intent.ACTION_VIEW` internally, opens the system browser, and requires no `INTERNET` permission for the launching app:

```kotlin
import androidx.compose.ui.platform.LocalUriHandler

val uriHandler = LocalUriHandler.current
Text(
    text = "Reference: ${instructions.link}",
    style = MaterialTheme.typography.labelSmall,
    color = MaterialTheme.colorScheme.primary,    // primary = it's a link
    modifier = Modifier
        .clickable {
            try { uriHandler.openUri(instructions.link) } catch (_: Throwable) { /* silent */ }
        }
        .semantics {
            role = Role.Button
            contentDescription = "Open reference: ${instructions.link}"
        }
)
```

**Defensive try/catch:** even vetted reference URLs can fail on devices with no browser installed OR with malformed URLs that slip through validation. Silently swallowing leaves the text visible as a fallback (user can long-press → "Share" out of context if needed). Don't surface error Snackbars for these: the error is so niche that the noise outweighs the signal.

**Pair with `Role.Button` semantics + a descriptive `contentDescription`** so TalkBack announces the action clearly ("Open reference: https://example.com, Button"), not just the visual text.

Originating change: Transfer Checklist `v1.0.96` (UX-44). The HowTo dialog's `Reference: <url>` line rendered as plain `Text(... color = onSurfaceVariant)`. Indistinguishable from caption text + not tappable + not even selectable for copy/paste. One-tap browser open recovered the user value.

### Freshness caption via pure kernel + LaunchedEffect 60s ticker

For any UI that surfaces data from a periodic snapshot (Usage Stats, sensor poll, last-sync time), show the user when the data was last refreshed. The pattern is two parts:

1. **A pure kernel that formats relative time**: JVM-testable, every threshold edge pinned (just-now, 1 min, N min, 1 hr, N hr, 1 day, N days):

```kotlin
object FreshnessAgo {
    fun format(collectedAt: Long, now: Long): String {
        if (collectedAt <= 0L) return ""   // no snapshot yet → suppress entirely
        val deltaMs = (now - collectedAt).coerceAtLeast(0L)  // clock-skew defensive
        val deltaMin = deltaMs / 60_000L
        val deltaHr = deltaMin / 60L
        val deltaDay = deltaHr / 24L
        return when {
            deltaMs < 60_000L -> "Updated just now"
            deltaMin == 1L    -> "Updated 1 min ago"
            deltaMin < 60L    -> "Updated $deltaMin min ago"
            deltaHr == 1L     -> "Updated 1 hr ago"
            deltaHr < 24L     -> "Updated $deltaHr hr ago"
            deltaDay == 1L    -> "Updated 1 day ago"
            else              -> "Updated $deltaDay days ago"
        }
    }
}
```

2. **A LaunchedEffect-driven ticker that bumps a `now` state every 60s** without forcing a full repaint of the surrounding row list:

```kotlin
val collectedAt = snapshot.collectedAt
var now by remember(collectedAt) { mutableStateOf(System.currentTimeMillis()) }
LaunchedEffect(collectedAt) {
    while (true) {
        delay(60_000L)
        now = System.currentTimeMillis()
    }
}
val caption = remember(collectedAt, now) { FreshnessAgo.format(collectedAt, now) }
if (caption.isNotEmpty()) {
    Text(caption, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
```

**Key invariants:**
- The `LaunchedEffect` keys on `collectedAt`, NOT `Unit`; when a new snapshot arrives the ticker resets to start counting from the fresh poll. `Unit` would carry stale millis across reloads.
- The `var now by remember(collectedAt)` ALSO keys on `collectedAt` so the initial value resets to wall-clock-now on each new snapshot (not the prior snapshot's drift).
- The `remember(collectedAt, now)` cache on the format call means recomposition only happens when one of those two values actually changes; every other recomposition reuses the cached string.
- Empty caption suppresses the Text entirely (no `Spacer`, no padding), which avoids a blank gap on pre-first-snapshot states.

**Don't:** use `System.currentTimeMillis()` directly in a `derivedStateOf` or in the body of a `Composable` without the ticker: Compose has no way to know wall-clock moved, so the caption would stay frozen until something else triggers recomposition.

Originating change: Transfer Checklist `v1.0.81` (UX-19). The Usage spotlight previously gave no indication whether the 24h-window data was 30 seconds old or 30 minutes old. New `UsageUpdatedAgo` kernel + 60s ticker in `UsageSummary`. 12 JUnit tests pin every threshold.

### Compose `key()` on dynamic list iterations to prevent silent state-bleed

Any `list.forEach { … }` in a Compose body where the list can RESHAPE (filter, sort, search, hide-toggle, panic-hoist) MUST wrap each iteration body in `key(<stable id>) { … }`. Without this, Compose matches preserved per-row state positionally: when row 0 drops out of the visible list, every remaining row's `remember`s (text field drafts, dialog visibility flags, animation state) silently re-bind to a DIFFERENT row's data. The bug is silent: no exception, no logcat hint, just a dialog that suddenly belongs to the wrong app.

```kotlin
// WRONG: Compose matches positionally; state bleeds on reshape
visible.forEach { entry ->
    ChecklistRow(
        entry = entry,
        // ChecklistRow internally has `var skipDialogVisible by remember { ... }`
        // + `var skipDraftText by remember { ... }` (hoisted per the
        // "Compose state lifecycle" section above).
        // After a search filter drops the top row, the SECOND visible row
        // gets the FIRST row's skipDialogVisible value.
    )
}

// RIGHT: key by package id; state pins to identity, not position
import androidx.compose.runtime.key

visible.forEach { entry -> key(entry.packageName) {
    ChecklistRow(entry = entry, …)
} }
```

**Key invariants:**
- Use a **domain ID** (package name, primary key, stable string identity), NOT the list index, which IS the position you're trying to escape.
- Include any `Spacer` between rows INSIDE the `key` block so the row + its spacer move together as a unit when the list reshapes.
- For long lists, `LazyColumn`'s `items(list, key = { it.packageName })` parameter is the equivalent and also enables Material 3 item animations on insert/remove. Use the lazy API when the list exceeds the viewport; `forEach { key(…) { … } }` is fine for short bounded lists (≤30 rows).
- Banners, dialogs, and chip rows in dynamic lists also benefit: if the surface has dismiss state keyed by item identity (a `Set<String>` of dismissed banner titles, for example), `key()` should match that identity.

**Audit trigger:** any time you add a filter / sort / search affordance that reshapes a list the user can interact with mid-render. Grep for `forEach` in your Compose code; for each, ask "can this list reshape between recompositions?" If yes and the iterated Composable has internal `remember` state, add `key()`.

**Why this is silent:** per-row `remember`s scoped to a Composable invocation are matched by SLOT TABLE POSITION. `key()` overrides slot matching with an identity-based key. Compose has no way to detect that "row at position 0 is now a different domain object" without a key; it just sees the slot survives recomposition.

Originating change: Transfer Checklist `v1.0.83` (PERF-02). Audited three `visible.forEach` sites in `TransferChecklistScreen.kt`; the highest-value gap was the manual queue (UX-12 highlight + UX-20 hide + UX-21 search all reshape the list) where `skipDialogVisible` + `skipDraftText` per-row state would have silently bound to the wrong package after any search-narrowing. Pattern captured as memory `feedback-compose-key-on-dynamic-list-iterations`.

### 3-line row layouts: align icons Top, not Center

When a `Row` has a leading icon (typically 40dp) next to a `Column` with 3 or more lines of text (title + reason caption + meta line, for example), the default `Alignment.CenterVertically` geometrically centers the icon against the FULL column height, leaving the icon drifting visibly low relative to line 1 (the title it represents). Switch to `Alignment.Top` so the icon sticks next to the first line; the lower lines flow alongside the icon's lower half. This matches Material 3 `ListItem`'s 3-line `leadingContent` convention.

```kotlin
// WRONG for 3-line layouts: icon drifts low, paired visually with line 2-ish
Row(verticalAlignment = Alignment.CenterVertically) {
    Icon(/* 40dp */)
    Column {
        Text("App Name",            style = MaterialTheme.typography.titleMedium)
        Text("Why this row exists", style = MaterialTheme.typography.bodySmall)
        Text("com.example.app",     style = MaterialTheme.typography.bodySmall)
    }
}

// RIGHT: icon anchors at the title; lines 2-3 flow alongside the icon's lower half
Row(verticalAlignment = Alignment.Top) {
    Icon(/* 40dp */)
    Column { /* same 3 lines */ }
}
```

**Decision rule:** match the icon's vertical anchor to the column's PRIMARY (first) line. For 1-line and 2-line layouts, `CenterVertically` is correct because the icon stays visually paired with the label. For 3+ lines, `Top` is correct.

**Audit trigger:** any time a row layout grows a third line (a new caption between label and meta, a status pill above the title, a reason hint), re-evaluate the icon-row's `verticalAlignment`. Captions added later are the most common regression vector because the layout LOOKED fine at 2 lines and silently degrades when the third arrives.

**Don't:** use `replace_all` on `Alignment.CenterVertically` to "fix" this across a file: the same modifier on a 2-line row IS still correct, and other Rows in the same file (button rows, chip rows, header rows) legitimately need vertical centering. Target only the rows that grew a third line.

Originating change: Transfer Checklist `v1.0.80` (DEBT-15). UX-11 + TEST-COV-02 added a one-line reason caption to `UsageRow` + `ChecklistRow`, turning the original 2-line layout (title + package id) into 3 lines (title + reason + package id). Icons drifted visibly low until both row sites switched `verticalAlignment` from `Alignment.CenterVertically` to `Alignment.Top`; the change touched only the two icon-row sites, leaving the other 7 `Alignment.CenterVertically` occurrences in the file alone per memory `feedback-replace-all-short-tokens`.

### Pull-to-refresh at the screen-level LazyColumn, not per-section

Material 3 1.3+ ships a stable `PullToRefreshBox` for the swipe-down-to-refresh gesture. Pulling-to-refresh "the spotlight rows" or "the populated section" by wrapping those rows inline inside their `item { }` block does NOT work: `PullToRefreshBox` needs a scrollable child to consume the pull gesture, and the outer `LazyColumn`'s `item { }` is not itself a scroller. Wrap the OUTER `LazyColumn` (the screen-level scrollable), even if conceptually you "only" want to refresh one section.

```kotlin
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MyScreen(state: ScreenState, onRefresh: () -> Unit) {
    PullToRefreshBox(
        isRefreshing = state.isRefreshing,
        onRefresh = onRefresh,                 // same callback the explicit Refresh button uses
        modifier = Modifier.fillMaxSize()
    ) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item { HeroSection() }
            item { UsageSpotlight(state.snapshot) }
            item { ManualQueue(state.queue) }
            // ...
        }
        // PullToRefreshBox is a BoxScope, so any overlay (LockedOverlay, etc.)
        // still composes here. It does NOT need to scroll itself.
        if (!state.permissionGranted) LockedOverlay()
    }
}
```

**Key invariants:**
- **`isRefreshing` drives the indicator.** Reuse the same `state.isRefreshing` flag that already feeds your explicit Refresh button's `enabled = !isRefreshing`: same source of truth, no risk of the spinner and the button disagreeing about "is a refresh in flight."
- **`onRefresh` is the same callback the explicit Refresh button uses.** Pull-to-refresh is an alternative gesture for the same action, not a parallel code path. If you find yourself writing a `onPullRefresh` distinct from `onClickRefresh`, you've duplicated work.
- **Requires `@OptIn(ExperimentalMaterial3Api::class)`** on the enclosing Composable as of M3 1.3 (the wrapper is stable behavior but still experimental in the API surface).
- **Side benefit:** wrapping the screen-level LazyColumn means pull-to-refresh works ANYWHERE on the screen, including over a permission-locked state (LockedOverlay). A user who grants the missing permission via Settings can return + pull-to-refresh to re-check the permission state immediately, without scrolling to find the explicit Refresh button.

**Don't:** try to wrap a nested non-scrolling region (`Card`, `Column`, `Box` inside a `LazyColumn item { }`) in `PullToRefreshBox` hoping to scope the gesture. The gesture comes from a scrollable child's scroll delta; non-scrollable children produce no gesture signal. Wrap the outermost scroller instead.

Originating change: Transfer Checklist `v1.0.86` (UX-26). Spec asked for "pull-to-refresh on the spotlight rows" (one section among ~6 in the LazyColumn). Wrapped at the screen-level LazyColumn instead, which works canonically. The "Updated N min ago" caption (UX-19's freshness caption) updates as soon as the refresh completes, providing the visible feedback that scoping the gesture to the spotlight would have provided more directly.

---

