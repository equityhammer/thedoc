[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## UI affordances: every dead-end state needs recovery

When auditing screens, walk every `if (isEmpty()) { ... }` branch and every error / permission-denied surface. For each one, ask: **"if a user lands here, what is the next tap?"** If the answer is "scroll back, find a menu, hope," add a recovery affordance directly into that state.

The minimum set:

- **Permission denied** → `Button("Grant <permission>")` that calls the existing request callback.
- **Empty list because no data is loaded** → `Button("Refresh")` + (where applicable) `OutlinedButton("Import")`.
- **Empty list because filter is too narrow** → already recoverable IF the filter chips / tabs are visible directly above; otherwise add `OutlinedButton("Clear filter")`.
- **Modal / dialog / banner** → at least one of: explicit X close icon, scrim-dismissable + a Cancel button, or an inline dismiss `IconButton(Icons.Filled.Close)` for stacking surfaces (risk banners, tip cards).
- **Generic informational empty state** ("nothing to do") → still needs an exit, even if just a `TextButton("Back")`.

Banner dismiss state lives where it matches the affordance:
- **Per-recomposition `mutableStateOf<Set<String>>`** if banners should re-arm on app restart (transient warnings that re-evaluate from fresh inputs).
- **`rememberSaveable`** if the user dismissing should outlive process death (notes / advice the user has consciously acknowledged).
- Key the dismissed set by a stable identity (banner title or stable ID) — when the underlying condition changes (e.g., title flips from "Battery at 35%" to "Low battery (15%)"), the new key isn't in the set so the banner reappears.

Originating changes: Transfer Checklist `v1.0.76` (DISMISS-01) added per-banner `IconButton(Close)` to `RiskBannersSection` after a full modal-dismiss audit. `v1.0.77` (UX-AUDIT-2) extended the rule to empty-state branches — three of five `isEmpty()` paths in the home screen turned out to be dead-ends. Will's verbatim direction: *"if there's not a dismiss button we should add a dismiss button basically I need you to read between the lines about what will make this more user friendly."*

### Asymmetric confirmation gates: confirm activation, not deactivation

When a UI toggle has a visibly destructive consequence on activation (reorder rows, replace a list, expand a section that dominates the screen), gate ACTIVATION behind a confirmation dialog. Deactivation should stay one-tap — undoing chaos shouldn't require a confirmation. The decision belongs in a pure kernel so the rule is JVM-testable and explicit, not buried in a callback's `if`.

```kotlin
// Pure decision kernel — JVM-testable, exhaustive coverage of the (activating × contextSize) matrix.
object ToggleGate {
    /**
     * @param activating true when the user is turning the toggle ON (false for OFF).
     *   Deactivation is always one-tap.
     * @param contextSize how many visible items the toggle's effect will reorder /
     *   replace. An empty context means no visible change → no confirmation needed.
     */
    fun shouldConfirm(activating: Boolean, contextSize: Int): Boolean {
        if (!activating) return false   // never confirm deactivation
        return contextSize > 0          // confirm only when there's something to disturb
    }
}

// At the callback site:
onToggle = { newValue ->
    if (ToggleGate.shouldConfirm(activating = newValue, contextSize = currentQueueSize)) {
        confirmDialogVisible = true                   // open AlertDialog, fire setter on Confirm
    } else {
        ToggleState.setEnabled(newValue)              // fire immediately
        toggleStatePersistence.persist(newValue)
    }
}
```

**Why asymmetric:**
- **Activation is the surprise.** The user taps a small chip; their whole list reorders. Without a gate they wonder "what just happened?" — even if the reorder is correct, the surprise erodes trust.
- **Deactivation is the recovery.** If the user got into the destructive state by accident, getting OUT must be friction-free. Adding a confirmation on deactivation would punish the very recovery path the user needs.
- **Empty-context activation is silent.** No visible reorder means no surprise to gate. The toggle is still tappable (for discoverability), but the confirmation would be friction-without-purpose.

**Pure kernel + 4-corner tests:**

```kotlin
@Test fun activating_with_non_empty_context_requires_confirm() {
    assertTrue(ToggleGate.shouldConfirm(activating = true, contextSize = 1))
    assertTrue(ToggleGate.shouldConfirm(activating = true, contextSize = 999))
}
@Test fun activating_with_empty_context_skips_confirm() {
    assertFalse(ToggleGate.shouldConfirm(activating = true, contextSize = 0))
}
@Test fun deactivating_never_requires_confirm_regardless_of_context() {
    assertFalse(ToggleGate.shouldConfirm(activating = false, contextSize = 0))
    assertFalse(ToggleGate.shouldConfirm(activating = false, contextSize = 999))
}
@Test fun negative_context_size_treated_as_empty() {
    // Defensive tripwire: a future refactor to `>= 0` would fail loudly.
    assertFalse(ToggleGate.shouldConfirm(activating = true, contextSize = -1))
}
```

### Visual weight of already-gated destructive actions

When a destructive action is ALREADY gated by an AlertDialog (per the previous subsection, or for confirm-before-Reset patterns), making the button itself "loud" is overkill. Material 3's standard advice for destructive actions ("Button with `errorContainer` background, `onErrorContainer` content") is for UNGATED destructive triggers — when the gate exists, the loud button + dialog is double-counting the warning.

```kotlin
// WRONG for already-gated destructive — double-counts the warning
Button(
    onClick = { confirmDialogVisible = true },
    colors = ButtonDefaults.buttonColors(
        containerColor = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer
    )
) { Text("Reset") }

// RIGHT — subtle button visually marked as destructive, deemphasized because dialog-gated
TextButton(
    onClick = { confirmDialogVisible = true },
    colors = ButtonDefaults.textButtonColors(
        contentColor = MaterialTheme.colorScheme.error
    )
) { Text("Reset") }
```

**Rule:** match the button's visual weight to how much help the user needs reading the row. `TextButton` + error color is the right choice when the user has TWO safety mechanisms (the dialog gate + the Snackbar Undo) — the button itself is the entry point, not the warning. Reserve the loud `Button` + `errorContainer` styling for truly UNGATED destructive triggers where the button click commits without further confirmation.

**Don't:** "for consistency" upgrade all destructive buttons to loud Buttons. The visual weight should encode the actual risk surface, which differs by gate state.

Originating changes: Transfer Checklist `v1.0.87` (UX-28) shipped the asymmetric confirmation pattern via a pure `PanicModeGate.shouldConfirm` kernel — Panic mode's queue-reorder gets a confirmation dialog on activation when the queue has ≥1 entry; deactivation stays one-tap. Sprint 26 UX-29 then established the visual-weight rule when auditing the already-gated Reset button from UX-27 (v1.0.87): spec recommended escalating Reset to a loud destructive Button, but UX-27 had already gated Reset behind an AlertDialog + Snackbar Undo; downgrading the recommendation to TextButton + error color avoided double-counting the warning.

### FlowRow for action button rows that risk overflow at narrow widths

When an action button row has 3+ buttons + their labels are user-meaningful (not just icons), the combined label width can exceed the available horizontal space at narrow viewports (Pixel 7 portrait at 412dp; Z Fold 5 cover at 360dp). A plain `Row(horizontalArrangement = Arrangement.spacedBy(...))` doesn't know how to wrap — Compose will let the LAST button's Text ellipsize OR vertically wrap to 1-char-per-line (uglier than ellipsizing because it can't fit even one char-width). Either failure mode is invisible until someone actually screenshot-tests the screen at a narrow qualifier.

```kotlin
// WRONG — at 412dp with 4 buttons, "Share as CSV" wraps vertically (1 char per line)
Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    TextButton(onClick = onExport)         { Text("Export progress so far") }
    TextButton(onClick = onShareHandoff)   { Text("Share handoff") }
    TextButton(onClick = onShareCsv)       { Text("Share as CSV") }
    IconButton(onClick = onCopyHandoff)    { Icon(Icons.Filled.ContentCopy, ...) }
}

// RIGHT — FlowRow auto-wraps to a second line when needed
@OptIn(ExperimentalLayoutApi::class)
FlowRow(
    horizontalArrangement = Arrangement.spacedBy(8.dp),
    verticalArrangement = Arrangement.spacedBy(4.dp)   // inter-line gap when wrapping kicks in
) {
    TextButton(onClick = onExport)         { Text("Export progress so far") }
    TextButton(onClick = onShareHandoff)   { Text("Share handoff") }
    TextButton(onClick = onShareCsv)       { Text("Share as CSV") }
    IconButton(onClick = onCopyHandoff)    { Icon(Icons.Filled.ContentCopy, ...) }
}
```

`FlowRow` lives in `androidx.compose.foundation.layout` and is **still `@ExperimentalLayoutApi`** in compose-foundation 1.7 — annotate the calling Composable with `@OptIn(ExperimentalLayoutApi::class)`. Don't reach for `LazyHorizontalGrid` or custom Layout — FlowRow's API is the right level for a 3-5 button action row.

**When to keep plain Row anyway:** a row with 2 buttons whose combined label-width fits comfortably even at 320dp — FlowRow adds no value and the explicit `Row(Modifier.fillMaxWidth())` + `Spacer(weight=1f)` pattern from the destructive-action subsection above gives you stronger alignment control.

**How to discover the overflow:** snapshot-test the parent subtree at your narrow-width qualifier (`w412dp-h2400dp-xxhdpi` for Pixel 7 portrait; `w360dp-h850dp-xxhdpi` for Z Fold 5 cover). Per the "Visual regression as a tool for SURFACING latent issues" subsection later in this file — Roborazzi subtree captures will show the vertical-wrap-to-1-char failure mode immediately, BEFORE any user sees it.

Originating change: Transfer Checklist `v1.0.93` Sprint 31 UX-37 — `subtree_app_list_section.png` (TEST-COV-12) caught the CompletionBanner 4-button Row overflowing at 412dp. The bug had existed across 4 sprints (UX-25 + UX-26 + UX-29 + EXPORT-08 each added a button without testing combined width). FlowRow swap fixed it in one line of layout change.

### Consolidate semantically-related buttons under a Material 3 DropdownMenu

When an action row's button count has grown to ≥3 buttons that all serve the SAME semantic intent (e.g., "get the handoff payload to a receiver" — share-as-JSON, share-as-CSV, copy-to-clipboard), the right fix isn't always to FlowRow-wrap the row — collapse the semantically-equivalent buttons into a single `TextButton` + `Icons.Outlined.ArrowDropDown` that opens a Material 3 `DropdownMenu` with one menu item per variant. This recovers row real estate AND signals the relationship visually (the chevron indicates "more options inside").

```kotlin
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown

var shareMenuExpanded by remember { mutableStateOf(false) }
FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    // Semantically-DISTINCT actions stay as standalone buttons.
    TextButton(onClick = onExportSummary) { Text("Export summary") }

    // Semantically-RELATED actions consolidated under one chevron-marked button.
    Box {
        TextButton(onClick = { shareMenuExpanded = true }) {
            Text("Share")
            Icon(Icons.Outlined.ArrowDropDown, contentDescription = null, modifier = Modifier.size(20.dp))
        }
        DropdownMenu(
            expanded = shareMenuExpanded,
            onDismissRequest = { shareMenuExpanded = false }
        ) {
            DropdownMenuItem(
                text = { Text("Share as JSON") },
                onClick = { shareMenuExpanded = false; onShareJson() }
            )
            DropdownMenuItem(
                text = { Text("Share as CSV") },
                onClick = { shareMenuExpanded = false; onShareCsv() }
            )
            DropdownMenuItem(
                text = { Text("Copy to clipboard") },
                leadingIcon = { Icon(Icons.Filled.ContentCopy, contentDescription = null) },
                onClick = { shareMenuExpanded = false; onCopy() }
            )
        }
    }
}
```

**When to consolidate vs keep separate:**

- **Consolidate** when 3+ buttons share the same SEMANTIC INTENT (different formats / channels for the same logical action) — share-as-X variants, "send to Y / send to Z" variants, "delete this row / delete this row + history" variants.
- **Keep separate** when the actions are SEMANTICALLY DISTINCT even if visually similar — "Save" vs "Share" don't go in the same menu even though both have happy-path connotations; "Export progress" vs "Share handoff" stay separate because one is about YOUR notes and the other is about THE PAYLOAD.

**Trade-off:** consolidation costs one extra tap to discover the variants. Worth it when the row was visibly crowded; over-engineering when the row already fit comfortably. Use Roborazzi snapshots to confirm the new shape fits at your narrow-width qualifier; the icon-marked single button should leave room for sibling actions.

**Defense-in-depth:** keep FlowRow as the outer container even after the consolidation reduces button count from 4 → 2. Narrow-width devices (Z Fold 5 cover at 360dp, split-screen modes) can still benefit from wrap-on-overflow as a safety net.

Originating change: Transfer Checklist `v1.0.94` Sprint 32 UX-39 — CompletionBanner's 4-button row (Export-summary + Share-handoff-JSON + Share-as-CSV + Copy-to-clipboard IconButton) consolidated 3 of the 4 (the share/copy variants — semantically "get the payload to a receiver") under a single "Share ▾" button. Export-summary stayed standalone because it's semantically distinct (your progress notes, not the handoff payload). Net: 4 buttons → 2 buttons in the row.

### Distinguish "parsed-but-empty" from "parse error" in importer dialogs

Importer dialogs (paste-JSON, paste-CSV, paste-key-value, etc.) typically branch on two states: "parse succeeded with N entries" and "parse failed with error message E". A THIRD state is structurally easy to overlook: **"parsed successfully but the input contained zero entries"** (the user pasted `[]`, or a CSV header with no data rows, or a JSON envelope with empty inner array). Pre-fix, both the "true parse error" and "parsed but empty" cases often share the same `else` branch + render the same generic "No apps recognised" / "Couldn't parse input" copy. The user can't distinguish "your input is malformed (fix the syntax)" from "your input is valid but useless (add entries)".

```kotlin
// Pure kernel — JVM-testable, no Android deps.
object ImportResultMessage {
    fun format(result: AppListImporter.Result): String = when {
        result.error != null -> result.error                   // user's input failed to parse
        result.ok            -> buildOkMessage(result)         // N entries ready to import
        result.empty         -> EMPTY_BUT_PARSED               // PARSED OK BUT EMPTY — NEW
        else                 -> "No entries recognised"        // structurally-unreachable fallback
    }

    const val EMPTY_BUT_PARSED: String =
        "No entries in your input (parsed cleanly, but the array was empty)."
    // The parenthetical makes the success-of-a-sort explicit: the parser
    // understood your input, it just had nothing to import.
}
```

**Color is also part of the disambiguation.** Map the 3 user-actionable states to 3 distinct Material 3 colors:

- `result.error != null` → `MaterialTheme.colorScheme.error` (red) — your input needs fixing.
- `result.ok`            → `MaterialTheme.colorScheme.primary` — proceed.
- `result.empty`         → `MaterialTheme.colorScheme.onSurfaceVariant` (neutral) — not an error, just nothing to do.

```kotlin
val color = when {
    result.error != null -> MaterialTheme.colorScheme.error
    result.ok            -> MaterialTheme.colorScheme.primary
    else                 -> MaterialTheme.colorScheme.onSurfaceVariant
}
```

**Why a pure kernel + Composable thin-renderer:** the 4-branch when is JVM-testable as-is. Compose-side branching of the same logic loses JUnit coverage of the message text + opens the door to future drift between display string + post-import Snackbar. Test each branch verbatim (`assertEquals(EMPTY_BUT_PARSED, ImportResultMessage.format(emptyResult))`) so any future copy edit forces a deliberate test update.

**The Confirm button stays disabled on the empty state.** `confirmButton = TextButton(enabled = result?.ok == true, ...)` — ok is `error == null && entries.isNotEmpty()`, so the empty-but-parsed case has `ok = false` and the user CAN'T accidentally commit a no-op import. The disambiguation is purely about the explanatory copy + color; the gate behavior is correct by construction.

Originating change: Transfer Checklist `v1.0.91` Sprint 29 UX-35 — ImportListDialog's pre-UX-35 ResultSummary rendered "No apps recognised" for both `result.error != null` AND `result.entries.isEmpty()` cases; users pasting `[]` got the same copy as users pasting `"hello world"`. Pure kernel extraction (`ImportResultMessage.format` + `EMPTY_BUT_PARSED` const) + 4-branch when in the Composable color logic disambiguated cleanly. Roborazzi baselines (TEST-COV-16, Sprint 32) pin the 4 distinct visual states.

### Snackbar Undo for reversible mutations

Any tap that directly mutates state (Add, Ignore, Delete, Toggle, Skip) AND has a clean inverse should expose `actionLabel = "Undo"` on its success Snackbar and reverse the mutation on `SnackbarResult.ActionPerformed`. Fat-finger taps on dense list rows happen constantly; without Undo the user has to scroll back, re-find the row in its new state (now in the queue / now ignored), and reverse by hand. With Undo, recovery is one tap.

```kotlin
// MainActivity onAddUsageRow handler
coroutineScope.launch {
    val result = snackbarHostState.showSnackbar(
        message = "Added $appName to queue",
        actionLabel = "Undo",
        withDismissAction = true
    )
    if (result == SnackbarResult.ActionPerformed) {
        ActiveAppList.removeEntry(packageName)  // pure data-layer inverse
    }
}
```

**Bucket every Snackbar call site before deciding:**
- **Mutating + reversible** (Add, Ignore, Delete, Toggle, Skip) → MUST get Undo.
- **Mutating + irreversible** (share intent sent, posted to a remote server, completed an external side effect) → NO Undo. The Snackbar would be lying.
- **Pure feedback / acknowledgement** ("Copied to clipboard", "Saved", "Synced") → NO Undo. Nothing to reverse; user can re-copy themselves. **BUT — see "Pure-ack Snackbars still need a dismiss X" below.**

**The inverse must exist as a pure data-layer function.** Don't reach into Compose state from the action lambda — add an `undoX()` or `removeX()` to your repository / state holder first. The reversal also stays silent — don't fire a second "Undone" Snackbar; Material 3's Snackbar already auto-dismisses on action tap.

**Naming:** the action label should be one shared named constant ("Undo") so every call site reads identically. A const on a `*Snackbar` formatter object is the natural home (`UsageActionSnackbar.UNDO_LABEL = "Undo"`).

Originating change: Transfer Checklist `v1.0.78` (UX-AUDIT-3) — walked all 3 Snackbar fire sites in `MainActivity.kt`. Two (Add + Ignore on Usage spotlight rows) were reversible and got Undo wired through a new `ActiveAppList.removeEntry` + the existing `unignore`. The third (debug-log copied to clipboard) is pure acknowledgement — kept silent. Driven by Will's standing direction: *"if there's not a dismiss button we should add a dismiss button basically I need you to read between the lines about what will make this more user friendly."*

### Pure-ack Snackbars still need a dismiss X — `withDismissAction = true`

The "no Undo for pure-acknowledgement" rule above is correct, but **pure-ack Snackbars still need the dismiss X**. Snackbars called via the 1-arg form `snackbarHostState.showSnackbar(message)` have NO dismiss affordance — the user must wait through the full `SnackbarDuration.Short` (≈4 seconds) before the toast disappears. Material 3's two visual affordances are **independent**:

- `actionLabel: String?` → "Undo" button (left of dismiss area). Setting it changes default duration to `Indefinite`.
- `withDismissAction: Boolean = false` → X icon (right edge). Independent of `actionLabel`. When true, X renders + tap dismisses immediately.

So pure-ack Snackbars (clipboard copy, network-post-completed, log-line-emitted) can keep `actionLabel = null` AND still have a user-tappable dismiss:

```kotlin
// WRONG — pure-ack Snackbar with no dismiss X. User waits 4s, no early-out.
snackbarHostState.showSnackbar("Handoff copied to clipboard")

// RIGHT — pure-ack Snackbar with dismiss X but NO Undo (irreversible action).
snackbarHostState.showSnackbar(
    message = "Handoff copied to clipboard",
    withDismissAction = true
)
```

**Why this matters:**

- Real users tap-to-acknowledge. The Snackbar lingering after they've understood it = wasted screen real estate.
- A11y users may rely on dismissal actions to clear screen-reader announcement queues.
- If multiple actions fire back-to-back (e.g., Copy log → Send test crash → Copy handoff), Snackbars queue up. With no X, the user waits 4 × N seconds with no exit; with X, each is one tap away.

**Audit rule for the cron loop:** when reviewing a codebase for "places where dismiss is missing" (e.g., per Will's standing direction), the obvious surfaces (AlertDialogs, OnboardingTipCards, banner cards) are usually fine — they typically have Cancel buttons, X icons, or tap-outside-scrim already. THE NON-OBVIOUS GAP is pure-ack Snackbars. Grep for `showSnackbar\(` callsites; for each, check that EITHER `actionLabel = ...` (Undo case — `withDismissAction = true` is conventionally also set) OR `withDismissAction = true` explicitly (pure-ack case). The 1-arg `showSnackbar(message)` form is the smell.

Originating change: Transfer Checklist `v1.0.95` (UX-40) — 3 pure-ack Snackbars in `MainActivity.kt` (Handoff copied to clipboard, Copied 24h debug log to clipboard, Test payload posted to /crash) all used the 1-arg form + were missing the dismiss X. Caught during a 4-dialog dismiss-affordance audit that initially targeted `OnboardingTipCard` (already had the X — 7th consecutive wrong-spec-premise case).

### Snackbar Undo for destructive BULK-REPLACE via snapshot capture

The Undo pattern above covers single-row mutations (Add, Ignore, Delete, Toggle, Skip) — the inverse is a single targeted operation (`removeEntry(pkg)` / `unignore(pkg)`) that's straightforward to write. Destructive **bulk-replace** operations (Reset whole queue to default, Import replacing the queue + statuses + reasons across multiple singletons) need a different shape: capture a SNAPSHOT of the full pre-operation state, then on Undo `restore(...)` the captured snapshot.

```kotlin
// Single-singleton bulk-replace (Reset list):
// In your AlertDialog's confirm-button onClick:
val prevSnapshot = ActiveAppList.current()                   // FULL snapshot — entries + flags + ignored set
ActiveAppList.setPreloaded(WillsListLoader.load(context))    // destructive replace
dialogVisible = false
coroutineScope.launch {
    val result = snackbarHostState.showSnackbar(
        message = "List reset (${prevSnapshot.entries.size} entries cleared)",
        actionLabel = "Undo",
        withDismissAction = true
    )
    if (result == SnackbarResult.ActionPerformed) {
        ActiveAppList.restoreFromSnapshot(prevSnapshot)       // single call restores all sub-fields
    }
}
```

```kotlin
// Multi-singleton bulk-replace (Import — replaces queue + statuses + reasons):
val prevList = ActiveAppList.current()
val prevStatuses = ChecklistRepository.snapshot()
val prevReasons = SkipReasonRepository.snapshot()
ActiveAppList.setImported(result.entries)
if (result.statuses.isNotEmpty()) ChecklistRepository.restore(result.statuses)
if (result.reasons.isNotEmpty()) SkipReasonRepository.restore(result.reasons)
coroutineScope.launch {
    val undoResult = snackbarHostState.showSnackbar(
        message = ImportResultSummary.format(result),
        actionLabel = "Undo",
        withDismissAction = true
    )
    if (undoResult == SnackbarResult.ActionPerformed) {
        ActiveAppList.restoreFromSnapshot(prevList)
        ChecklistRepository.restore(prevStatuses)
        SkipReasonRepository.restore(prevReasons)
    }
}
```

**Key invariants:**
- **Capture BEFORE the destructive call, not inside the Undo lambda.** The Undo lambda fires later; by then the singleton's current state IS the post-destructive state. Local-val capture pins the pre-state.
- **Each singleton needs a `snapshot(): T` getter AND a `restore(snapshot: T)` setter** with symmetric semantics — `restore(snapshot())` must round-trip cleanly. If the setter applies filters (e.g., drops `NEEDS_ATTENTION` entries on restore because they're implicit), the getter must never produce values that hit those filters. Pin the round-trip with a JUnit test.
- **Captured snapshots must be immutable by reference.** Kotlin `Map` is immutable; if your singleton's state is a `Map<String, X>` reassigned via `+`/`-` operators (which produce new maps, not in-place mutations), captures are naturally independent of subsequent state writes. If the singleton uses an in-place mutable type (`MutableMap`, `ArrayList`), the snapshot must be a defensive copy.
- **Add a tripwire test** that proves capture-then-mutate doesn't corrupt the capture: `capture = snapshot(); mutate(); assertEquals(originalValues, capture)`. This catches future refactors that accidentally swap the data layer to a mutable reference type.
- **In-place inverses (`removeEntry`, `unignore`) and snapshot inverses (`restoreFromSnapshot`) coexist.** Use the simpler in-place inverse for single-row mutations; use snapshots only when the operation replaces multiple fields or multiple singletons at once.

**Don't:** capture the snapshot ASYNCHRONOUSLY (inside the coroutine that fires the Snackbar). The user can tap Undo within the Snackbar timeout, but if the capture happens after the dialog confirm + the destructive call, the captured "pre-state" is actually the post-state.

Originating changes: Transfer Checklist `v1.0.87` (UX-27) added `ActiveAppList.restoreFromSnapshot` + the single-singleton Reset Undo path. Sprint 26 EXPORT-09 extended the pattern with multi-singleton snapshot capture for Import (`ChecklistRepository.snapshot()` + `SkipReasonRepository.snapshot()` symmetric with their existing `restore()` setters). The asymmetry between in-place inverses and snapshot inverses is documented at the SPEC level in Transfer Checklist's DOC-09 sequence diagram.

---

