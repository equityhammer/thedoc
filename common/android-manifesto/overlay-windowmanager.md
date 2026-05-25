[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Overlay (WindowManager) patterns

For apps that draw outside their own activity — accessibility helpers, floating bubbles, on-screen guides — interactions on a `WindowManager.addView` overlay follow Android touch-dispatch rules, not Compose semantics. Two patterns recur.

### Drag handlers on the root view intercept child button taps

If you want the user to drag the bubble around, do NOT attach `setOnTouchListener` to the bubble's ROOT view. Returning `true` on `ACTION_DOWN` (which any "real" drag handler must do, to claim the gesture) consumes the event before child `Button` views ever see it — buttons silently stop firing their `onClick` listeners with no exception or logcat hint. Bind the drag listener to a **dedicated grip `View`** at the top of the bubble instead:

```xml
<!-- overlay_bubble.xml -->
<LinearLayout android:orientation="vertical" ...>

    <View
        android:id="@+id/overlay_drag_handle"
        android:layout_width="48dp"
        android:layout_height="6dp"
        android:layout_gravity="center_horizontal"
        android:layout_marginTop="4dp"
        android:background="@drawable/bg_drag_grip" />

    <!-- buttons, content, etc., below -->
    <Button android:id="@+id/overlay_btn_done" .../>
    <Button android:id="@+id/overlay_btn_skip" .../>
</LinearLayout>
```

```kotlin
// OverlayService.kt
private fun attachDragHandler(handle: View, params: WindowManager.LayoutParams) {
    handle.setOnTouchListener { _, event -> /* drag logic, returning true on DOWN */ }
}

// In addBubble():
val view = inflater.inflate(R.layout.overlay_bubble, null)
attachDragHandler(view.findViewById(R.id.overlay_drag_handle), params)
// Buttons elsewhere in the bubble dispatch normally — only the grip claims drag.
```

Bonus: the grip is also a visual affordance signalling "this is draggable" — users find drag interactions on otherwise-static panels confusing without one.

Originating change: Transfer Checklist `v1.0.72` (HOTFIX-01) — real-user complaint *"the bubble has a strange issue where not all the buttons work, so I can't hit Done or Skip, or I can only hit Done at this point."* Was passing internal QA because the bug only manifested after a touch-event regression in QA-003's drag implementation; integration-tested overlays should include a "tap every button while bubble is on screen" smoke test.

### Action buttons in a width-capped overlay need ellipsize + a density fallback

Overlays have hard width caps (drawn over arbitrary apps; cannot push their host around). When the action row holds 2-3 buttons whose labels are sized for English, longer-locale translations clip ("Schließen", "Закрыть"). Layer two defenses:

1. **Layout-level fallback:** every action `Button` in the overlay layout gets `android:singleLine="true"` + `android:ellipsize="end"`. The text always rendering as something, even if degraded.
2. **Density-aware label selection:** a small pure kernel returns three labels per action — COMFY (`Done` / `Skip` / `Close`), COMPACT (`OK` / `Skip` / `X`), ICON_ONLY (`✓` / `⏭` / `✕`). After `WindowManager.addView`, call `view.post { measureButtonsAndPickDensity() }` so width is known; pick the loosest density whose longest label fits each button.

```kotlin
object OverlayActionLabel {
    enum class Density { COMFY, COMPACT, ICON_ONLY }
    fun done(d: Density)  = when (d) { COMFY -> "Done"; COMPACT -> "OK";  ICON_ONLY -> "✓" }
    fun close(d: Density) = when (d) { COMFY -> "Close"; COMPACT -> "X"; ICON_ONLY -> "✕" }
    fun fitDensity(charsPerButton: Int): Density = when {
        charsPerButton >= 5 -> COMFY
        charsPerButton >= 4 -> COMPACT
        else -> ICON_ONLY
    }
}
```

Test the kernel exhaustively (label tables, threshold table, defensive zero/negative budget). The Android-coupled measurement code is glue — keep its surface narrow so the test surface stays small.

Originating change: Transfer Checklist `v1.0.77` (DESIGN-02). Layout-only ellipsize prevented the worst case but produced unintelligible 1-character buttons; layered density gave the row a readable degradation path.

### `WindowManager.LayoutParams.width` is authoritative — XML root `layout_width` is IGNORED

When a View is inflated to be the **root** of a `WindowManager.addView(view, params)` overlay, the `WindowManager.LayoutParams.width` value is authoritative. The inflated View's own `android:layout_width` from XML (or programmatic `view.layoutParams = ...`) is **IGNORED** for the root-of-window case. Setting `WindowManager.LayoutParams.WRAP_CONTENT` on an overlay whose XML root says `android:layout_width="280dp"` will NOT honor the 280dp — the WindowManager measures the root with `MeasureSpec(0, UNSPECIFIED)`, and the inner `match_parent` Row collapses (no parent width to match), and the `layout_width="0dp" + layout_weight="1"` buttons inside collapse to bare `minWidth` because there's nothing to distribute.

```kotlin
// WRONG — XML root's 280dp is IGNORED; inner buttons collapse to thin glyphs
// even though the layout XML looks correct.
val params = WindowManager.LayoutParams(
    WindowManager.LayoutParams.WRAP_CONTENT,        // ← authoritative; XML width discarded
    WindowManager.LayoutParams.WRAP_CONTENT,
    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
    ...
)
wm.addView(inflatedRoot, params)
```

```kotlin
// RIGHT — compute the SAME pixel width the XML root intended + pass it
// as the WindowManager.LayoutParams.width.
val bubbleWidthPx = TypedValue.applyDimension(
    TypedValue.COMPLEX_UNIT_DIP, 280f, resources.displayMetrics
).toInt()
val params = WindowManager.LayoutParams(
    bubbleWidthPx,                                  // ← honors the XML intent
    WindowManager.LayoutParams.WRAP_CONTENT,
    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
    ...
)
wm.addView(inflatedRoot, params)
```

**Why standard Roborazzi snapshot tests don't catch this:** the typical Roborazzi pattern is `LayoutInflater.inflate(R.layout.overlay_bubble, container, false)` into a `FrameLayout(activity)` with `MATCH_PARENT × MATCH_PARENT`. Activity FrameLayout children DO honor the inflated View's `layout_width`, so the snapshot renders the bubble at the intended 280dp + the test passes. The bug surfaces only at runtime on the real `WindowManager` rendering path.

**To extend Roborazzi to catch this regression class:** add a test variant that simulates WindowManager's authoritative-width behavior by manually overriding the inflated root's `LayoutParams` before adding to the parent container.

```kotlin
val bubbleWidthPx = TypedValue.applyDimension(
    TypedValue.COMPLEX_UNIT_DIP, 280f, activity.resources.displayMetrics
).toInt()
val view = LayoutInflater.from(activity).inflate(R.layout.overlay_bubble, container, false)
// Override to simulate WindowManager.LayoutParams behavior.
view.layoutParams = ViewGroup.LayoutParams(
    bubbleWidthPx,
    ViewGroup.LayoutParams.WRAP_CONTENT
)
container.addView(view)
```

Companion JUnit tripwire catches deliberate-but-wrong refactors that look right but violate the invariant:

```kotlin
@Test
fun overlay_width_dp_resolves_to_positive_pixel_value() {
    val widthPx = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, 280f, ctx.resources.displayMetrics
    ).toInt()
    // WRAP_CONTENT = -2; MATCH_PARENT = -1. Correct is a positive pixel value.
    assertTrue("280dp must resolve to positive px; got $widthPx", widthPx > 200)
}
```

**General rule for Android WindowManager overlay work:** when the rendered output looks "compressed" or "child layout collapsed" despite XML that looks correct, check the `WindowManager.LayoutParams.width/height` BEFORE checking the inflated View's XML `LayoutParams`. WindowManager's params win for root-of-window inflations.

Originating change: Transfer Checklist `v1.0.97` (BUBBLE-07) — Will's real-device Debug FAB screenshot on Z Fold 5 showed the bubble's 3 action buttons rendering as thin vertical lines + the "Steps" label wrapping "Trans/fers" because the overlay window was sized via WRAP_CONTENT in `WindowManager.LayoutParams`. 3rd layer of the BUBBLE-05/06/07 chain — see `### Verify ALL layers, not just the one the spec names` for the broader audit discipline that surfaced it after BUBBLE-05's kernel audit + BUBBLE-06's XML audit both came back clean.

### Auto-launch the next app via `PackageManager.getLaunchIntentForPackage` from a foreground overlay service

When an overlay drives a per-app walkthrough flow (per-app onboarding, per-app permission setup, per-app backup workflow), the bubble's natural payoff is to auto-foreground the next target app on each "advance" tap — manual launcher navigation between apps wastes the user's intent. There is **no need for an `AccessibilityService` for this** despite common documentation drift suggesting otherwise (verify by grep before relying on any claim). `PackageManager.getLaunchIntentForPackage(pkg) + startActivity(intent.addFlags(NEW_TASK))` from the foreground OverlayService is sufficient + doesn't require additional permissions.

```kotlin
private fun launchAppByPackage(pkg: String?, source: String) {
    if (pkg.isNullOrBlank()) return
    val launchIntent = packageManager.getLaunchIntentForPackage(pkg)
        ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    if (launchIntent == null) {
        Log.w(TAG, "[BENIGN] $source: no launcher activity for $pkg (uninstalled or service-only app); launch skipped")
        return
    }
    try {
        startActivity(launchIntent)
    } catch (t: Throwable) {
        Log.w(TAG, "[BENIGN] $source: launch $pkg failed: ${t.javaClass.simpleName}: ${t.message}")
    }
}
```

**Four call sites to wire (Transfer Checklist UX-46/47/48/50 trilogy):**

| Call site | When it fires | Source tag |
|---|---|---|
| `OverlayService.onCreate` (after `observeState`) | Bubble service start → auto-launch FIRST queued app | "UX-47 first-app on service start" |
| `OverlayService.advance(DONE/SKIPPED)` | Action button tap → auto-launch NEXT queued app | "UX-46 advance(...) auto-launch" |
| Same, `else` branch (`after.nextEntry == null`) | Last app's Done → auto-launch SELF (own MainActivity) | "UX-48 last-Done return-home" |
| `iconView.setOnClickListener` + `labelView.setOnClickListener` | Manual tap on bubble icon/title | "UX-50 icon/title tap" |

Together these four paths automate the entire flow: tap FAB → bubble appears + first app foregrounds → Done → next app foregrounds → ... → last Done → MainActivity celebration screen. Zero manual context-switches.

**Defensive considerations:**

- `getLaunchIntentForPackage` returns `null` for packages with no launcher activity (service-only apps, certain system components) OR packages uninstalled between queue-load + tap. Null → safe no-op + `[BENIGN]` log.
- `startActivity` may throw `ActivityNotFoundException` (uninstalled mid-flow) / `SecurityException` (non-exported launcher) / OEM-specific background-launch denials. Wrap in `try { ... } catch (t: Throwable) { ... }` + log as `[BENIGN]` so the failure is visible in the dist Monitor without taking down the OverlayService thread.
- **Android 14+ background-launch restrictions don't apply** because the OverlayService is a foreground service AND the click event is treated as user-initiated.
- Add a MANUAL launch affordance (icon tap + title tap) IN ADDITION TO the auto-launch trilogy, so users can re-foreground the current app if they backed out, OR if the silent-no-op case fires for one of their queued apps.

**CLAUDE.md / AGENTS.md drift warning:** before relying on any documentation claim about overlay behavior ("auto-opens via AccessibilityService", etc.), verify by grep against the actual codebase. The Transfer Checklist project's CLAUDE.md described the bubble as "auto-opens via an AccessibilityService" for MONTHS but the AccessibilityService never existed + no Intent launch existed anywhere. Caught Sprint 34 UX-46 via discovery-first grep; see `### Verify ALL layers, not just the one the spec names` for the broader pattern.

Originating change: Transfer Checklist `v1.0.96` UX-46/47/48 (auto-launch trilogy) + `v1.0.98` UX-50 (manual icon/title tap fallback). All four routes refactored to share one `launchAppByPackage(pkg, source)` helper with one set of try/catch/log discipline.

### `view.announceForAccessibility(...)` for mid-touch state changes

When the user taps a button on a `WindowManager`-hosted overlay and the action mutates the bubble's own text/state (advance to next app, hide a banner, switch a mode), TalkBack does NOT automatically narrate the change — it only fires on focus traversal, content-description-changed events, or LIVE_REGION updates. The user hears nothing. Manually call `view.announceForAccessibility(message)` after the mutation so the screen reader speaks the new state aloud.

```kotlin
// OverlayService.advance(status)
private fun advance(status: ChecklistStatus) {
    val before = currentSession()
    val targetEntry = before.nextEntry ?: return
    val targetName = labelLookup.labelFor(targetEntry.packageName, targetEntry.displayName)
    ChecklistRepository.setStatus(targetEntry.packageName, status)

    val after = currentSession()
    val nextName = after.nextEntry?.let { labelLookup.labelFor(it.packageName, it.displayName) }

    // Compose the announcement via a pure kernel so the copy is testable.
    val message = OverlayAdvanceAnnouncement.format(status, targetName, nextName)
    if (message != null) view?.announceForAccessibility(message)
}
```

**The announcement string belongs in a pure kernel.** The four-status × null-next × blank-input combinatorial space deserves JUnit pinning — don't bury the rules in Android-coupled glue.

```kotlin
object OverlayAdvanceAnnouncement {
    fun format(status: ChecklistStatus, doneAppName: String, nextAppName: String?): String? {
        if (nextAppName == null) return null   // queue empty post-advance — silent "all done"
        val safeDone = doneAppName.trim().ifEmpty { "this app" }
        val safeNext = nextAppName.trim().ifEmpty { "the next app" }
        val prefix = when (status) {
            ChecklistStatus.DONE -> "Marked $safeDone done"
            ChecklistStatus.SKIPPED -> "Skipped $safeDone"
            ChecklistStatus.IGNORED -> "Marked $safeDone as ignored"
            ChecklistStatus.NEEDS_ATTENTION -> return null
        }
        return "$prefix. Next: $safeNext."
    }
}
```

**Key contract points:**
- `announceForAccessibility` is a no-op when no accessibility service is active — safe to call unconditionally when the formatter returns non-null.
- Skip the announcement when the post-advance state is terminal (empty queue / completion) so the silent "all done" UI speaks for itself rather than yelling "Marked Foo done. Next: " with nothing to say.
- Capture the previous label BEFORE the mutation; resolve the next label AFTER. Both via the same `labelLookup` the bubble uses for its visible label so the screen reader hears the same name the bubble was visually showing at tap time.
- The announcement is the user-facing "what just happened?" — keep it one sentence pair, no preamble. Material's `Snackbar` equivalent for non-overlay screens would be a regular `Snackbar` with the same text.

**Related:** for state changes the user did NOT initiate (background tickers, watcher events) prefer `accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE` on the changing TextView — TalkBack auto-announces on text change without the manual call. Use `announceForAccessibility` for *user-initiated* state changes where you control the call site.

Originating change: Transfer Checklist `v1.0.79` (UX-16) — bubble Done/Skip taps previously updated the visible label silently; screen-reader users got no audible confirmation. New pure `OverlayAdvanceAnnouncement` kernel + per-tap `view.announceForAccessibility` close the loop. 11 JUnit tests pin every status × null-next × blank-input branch.

### LIVE_REGION_POLITE on live overlay containers + severity-prefixed contentDescription

For background-driven state changes — risk banners that appear when battery drops, status pills that pop in mid-render — `announceForAccessibility` is the wrong tool because there's no user-initiated call site to hook. Use `accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE` on the *container* instead: Android auto-fires the appropriate announcement when its descendants change, without interrupting an in-progress utterance (`ASSERTIVE` interrupts and is reserved for actual emergencies).

When the items inside the container carry *severity* — CRITICAL vs WARNING vs INFO — TalkBack hears the text alone but loses the visual urgency cue (often encoded as background colour). Prefix each item's `contentDescription` with a verbal urgency tag:

```kotlin
// OverlayService.renderRiskBanners
container.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
rendered.forEach { r ->
    val tv = TextView(ctx).apply {
        text = r.text
        contentDescription = r.contentDescription   // ← severity-prefixed
        setTextColor(r.textColor)
        setBackgroundColor(r.backgroundColor)
    }
    container.addView(tv, layoutParams)
}
```

```kotlin
// Pure kernel, JVM-testable
object OverlayRiskRenderer {
    fun accessibilityPrefixFor(severity: Severity): String = when (severity) {
        Severity.CRITICAL -> "Critical: "
        Severity.WARNING  -> "Warning: "
        Severity.INFO     -> "FYI: "
    }
    fun contentDescriptionFor(severity: Severity, text: String): String {
        val t = text.trim()
        if (t.isEmpty()) return ""   // no prefix-only utterances
        return accessibilityPrefixFor(severity) + t
    }
}
```

**Key invariants:**
- Set LIVE_REGION on the *container* (e.g. the `LinearLayout` that hosts banner TextViews), not on each child. Container fires once per addView/removeView wave; per-child would fire per item.
- Idempotent: setting per-render is fine, the property only re-broadcasts on actual state change.
- Empty-text banners produce empty contentDescription — no point announcing a bare "Critical: ".
- POLITE is the default-correct choice. Only escalate to ASSERTIVE for state changes the user must hear immediately even if it interrupts other speech (full-screen alarms, etc.).

Originating change: Transfer Checklist `v1.0.80` (ACCESS-03) — the overlay's `RiskAdvisor` banners had severity-coded colours but indistinguishable TalkBack output; new contentDescription + LIVE_REGION_POLITE close the gap. 8 new JUnit tests pin the prefix mapping + composition + empty-text suppression.

### TextView marquee tripod: ellipsize + singleLine + isSelected

When a TextView with constrained width (an overlay label, a notification subtitle, a row title in a fixed-width chip) needs to show a string that exceeds its rendered width, `ellipsize="end"` truncates — losing the suffix. Marquee (auto-scroll) is built into TextView but requires **all three** of these working together; miss any one and marquee silently doesn't fire:

1. `android:ellipsize="marquee"` (or `setEllipsize(TextUtils.TruncateAt.MARQUEE)`)
2. `android:singleLine="true"` (the older API; `maxLines="1"` alone does NOT trigger marquee — known Android quirk)
3. `textView.isSelected = true` (from Kotlin, after the view is attached)

```xml
<!-- overlay_bubble.xml -->
<TextView
    android:id="@+id/overlay_app_label"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:ellipsize="marquee"
    android:singleLine="true"
    android:marqueeRepeatLimit="marquee_forever"
    android:textColor="#FFFFFF"
    android:textSize="15sp" />
```

```kotlin
// In the render path that sets the text
val labelView = root.findViewById<TextView>(R.id.overlay_app_label)
labelView.text = label
labelView.isSelected = true   // ← the third leg of the tripod
```

**Notes:**
- Width must be bounded — `wrap_content` won't trigger marquee because the text simply expands to fit. Use `match_parent` (or a fixed width / `layout_weight`) so the view has a finite measured width to scroll within.
- Short strings (text fits) render normally; marquee is a no-op. No special-case needed for short content.
- TalkBack hearing is unaffected — `contentDescription` already speaks the full string regardless of visible marquee state. Marquee is purely sighted-user polish.
- Idempotent: calling `isSelected = true` per render is fine.

Originating change: Transfer Checklist `v1.0.80` (UX-17) — long real app labels ("Microsoft Authenticator", "Bank of America Mobile") ellipsized inside the 280dp-capped bubble; marquee exposes the full string after layout. ACCESS-01's contentDescription already covered the screen-reader path.

### Override `Service.onConfigurationChanged` to re-clamp overlay position on rotation

Overlays drawn via `WindowManager.addView` survive screen rotation in process (unlike Activities, which tear down + rebuild) — the service stays alive, the view stays attached, but the user's viewport just got a new shape. If the user dragged the bubble against the right edge in landscape (`params.x = 1800` on a 1920×1080 viewport) and rotates to portrait, the new viewport is 1080×1920 and `params.x = 1800` is now off-screen to the right. The bubble is invisible until the user slides-from-edge to recover it — non-discoverable.

Override `Service.onConfigurationChanged` to re-clamp the bubble's position into the new viewport. Service receives this callback automatically when the device configuration changes — **no `android:configChanges` manifest declaration needed** (different from Activity, where you must declare which changes you'll handle yourself or the Activity is destroyed and recreated).

```kotlin
class OverlayService : Service() {

    private var wm: WindowManager? = null
    private var view: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private lateinit var persistence: BubblePositionPersistence

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val params = layoutParams ?: return
        val v = view ?: return
        val bubbleW = v.width
        val bubbleH = v.height
        if (bubbleW <= 0 || bubbleH <= 0) return  // not laid out yet — pure kernel would no-op anyway
        val dm = resources.displayMetrics                // reflects the NEW config synchronously
        val current = BubblePosition(params.x, params.y)
        val clamped = current.coerceInBounds(bubbleW, bubbleH, dm.widthPixels, dm.heightPixels)
        if (clamped.x != params.x || clamped.y != params.y) {
            params.x = clamped.x
            params.y = clamped.y
            try { wm?.updateViewLayout(v, params) } catch (_: Throwable) {}
            persistence.save(clamped)                    // next service restart picks up the clamped value too
        }
    }
}
```

**Key invariants:**
- **Reuse the same clamp kernel `addBubble` uses on the initial-load path.** If you have a `BubblePosition.coerceInBounds(width, height, screenWidth, screenHeight)` pure kernel for the saved-position-restore path (the standard "what if the saved position is off-screen?" defense), wire that SAME kernel into `onConfigurationChanged`. Two implementations diverge silently.
- **`resources.displayMetrics` is the source of truth for the new viewport** — it updates synchronously when `onConfigurationChanged` fires. Don't use cached display metrics from `onCreate`; they're stale post-rotation.
- **Defensive early-return when `view.width / view.height ≤ 0`** — the view may not be laid out yet (rare but possible during fast config-change cascades). The kernel would no-op anyway (any sensible `coerceInBounds` short-circuits on non-positive inputs), but the explicit guard documents the boundary.
- **Persist the clamped value** so the next service restart (sticky restart, manual stop+start) picks up the new safe spot instead of the now-off-screen saved value.

**Don't:** assume `Service.onConfigurationChanged` requires manifest configuration. It doesn't. (`Activity.onConfigurationChanged` requires declaring the changes via `android:configChanges` — Service doesn't.)

Originating change: Transfer Checklist `v1.0.87` (BUBBLE-04). The bubble's `BubblePosition.coerceInBounds` kernel had existed since QA-003's initial drag-position-persistence work but was only wired into the saved-position-restore path; rotation off-screen was silently broken until BUBBLE-04 wired the same kernel into `onConfigurationChanged`. Tested via 2 JUnit tests pinning landscape→portrait + portrait→landscape re-clamp scenarios on the pure kernel.

### Keyboard-aware overlay positioning (best-effort given FLAG_NOT_FOCUSABLE)

When the user taps a text field in the app underneath an overlay bubble, the soft keyboard (IME) slides up + reduces the visible viewport. `resources.displayMetrics.heightPixels` keeps reporting the FULL screen — the existing rotation re-clamp (above) leaves the bubble in the now-IME-occluded lower half of the screen, partially-obscured but not actually off-screen.

The naive fix — `ViewCompat.setOnApplyWindowInsetsListener(bubbleView) { _, insets -> ... }` — only works if the overlay window receives IME insets, and **overlays with `WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE` may NOT receive them reliably across Android versions / OEMs.** IME insets are typically tied to the focused window, and you set FLAG_NOT_FOCUSABLE precisely to AVOID stealing focus from the underlying app (the load-bearing "overlay doesn't intercept input" contract).

The fix is "ship a pure clamp kernel + a best-effort listener + accept that it may no-op on some devices":

```kotlin
// Pure kernel — JVM-testable, works regardless of whether the listener fires.
object KeyboardAwareOverlayClamp {
    fun effectiveScreenHeight(rawScreenH: Int, imeBottomInsetPx: Int): Int {
        if (rawScreenH <= 0) return 0
        if (imeBottomInsetPx <= 0) return rawScreenH
        return (rawScreenH - imeBottomInsetPx).coerceAtLeast(0)
    }
}

// Best-effort Android wiring in OverlayService.addBubble(), after addView:
ViewCompat.setOnApplyWindowInsetsListener(bubbleView) { _, insets ->
    val imeBottomPx = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
    reClampForIme(imeBottomPx)
    insets   // pass through unchanged so other listeners still work
}

private fun reClampForIme(imeBottomPx: Int) {
    val params = layoutParams ?: return
    val v = view ?: return
    if (v.width <= 0 || v.height <= 0) return
    val dm = resources.displayMetrics
    val effectiveScreenH = KeyboardAwareOverlayClamp.effectiveScreenHeight(dm.heightPixels, imeBottomPx)
    if (effectiveScreenH <= v.height) return   // degenerate (IME bigger than viewport) — leave alone
    val clamped = BubblePosition(params.x, params.y)
        .coerceInBounds(v.width, v.height, dm.widthPixels, effectiveScreenH)
    if (clamped.x != params.x || clamped.y != params.y) {
        params.x = clamped.x
        params.y = clamped.y
        try { wm?.updateViewLayout(v, params) } catch (_: Throwable) {}
        // Do NOT persist this clamp — it's a temporary IME-driven reposition.
        // When IME hides, the user's last-dragged position (persisted via the
        // drag-end / onConfigurationChanged paths) is what should restore.
    }
}
```

**Key invariants:**
- **Don't change window flags to "fix" inset reception.** Removing FLAG_NOT_FOCUSABLE would let the bubble steal input from the underlying app — a much worse regression than "bubble doesn't auto-reposition for IME on some devices."
- **The pure kernel is the load-bearing testable piece.** The Android wiring is glue that may or may not fire; the kernel's math is always correct on devices where it DOES fire.
- **Reuse the same clamp kernel** (`BubblePosition.coerceInBounds` here) the rotation re-clamp uses — single math implementation, multiple trigger sources.
- **Don't persist the IME-driven clamp.** It's a temporary reposition. When the IME hides, the user's last-DRAG-saved position should restore, not the IME-shoved-up value.
- **Document the constraint inline.** A future reader looking at the listener wondering "why doesn't this fire?" should find the answer in a comment block, not in a Stack Overflow search.

Originating change: Transfer Checklist `v1.0.89` (UX-31). Pure kernel + 7 JUnit tests (no-IME / realistic-IME / negative-IME / IME-bigger-than-screen / non-positive-screen / IME-exactly-equal-to-screen / realistic-Pixel-7-portrait). Android wiring is best-effort — works on devices that propagate IME insets to non-focusable overlays; silently no-ops elsewhere with no regression vs. pre-UX-31 behavior.

---

### Inflate overlay views through a `ContextThemeWrapper` when their XML uses `?attr/` theme references

A `WindowManager` overlay inflated from the bare `Service` context crashes on newer
Android when its layout references theme attributes (`?attr/...`). The `Service`'s own
theme is the OS default, which doesn't define app-theme attrs like
`?attr/selectableItemBackground` / `?attr/selectableItemBackgroundBorderless`. Through
Android 14 (SDK 34) the inflater tolerated the unresolved attr (null-background
fallback); **Android 16 (SDK 36) tightened the inflation pipeline and throws
`InflateException` instead → `OverlayService.onCreate` crashes → the bubble never
starts.** The bug is latent: it ships fine, passes on your `targetSdk` test devices,
and only detonates on a phone whose firmware enforces the stricter path.

```kotlin
// WRONG — bare Service context; ?attr/ in overlay_bubble.xml is undefined here
val view = LayoutInflater.from(this).inflate(R.layout.overlay_bubble, null)

// RIGHT — wrap with a context carrying your app theme so ?attr/ resolves
val themed = ContextThemeWrapper(this, R.style.Theme_TransferChecklist)
val view = LayoutInflater.from(themed).inflate(R.layout.overlay_bubble, null)
```

The app theme (here `Theme.Material3.DayNight.NoActionBar`-derived) defines the
`selectableItemBackground*` attrs. Zero behavioral change — the ripple still fires; it
just resolves at inflation time on every SDK level.

**Audit trigger:** any time a view inflated *outside an `Activity`* — overlay,
notification `RemoteViews`, custom toast — gains a `?attr/...` reference (ripple
backgrounds, themed colors, text appearances). `Activity`-hosted views get the app
theme for free; `Service`/overlay-hosted views do not. Grep overlay XML for `?attr/`
and confirm the inflater uses a themed context. Roborazzi can't catch this — it
inflates inside an `Activity` `FrameLayout`, which DOES carry the theme — so it only
surfaces on a real device with strict-inflation firmware.

Originating change: Transfer Checklist `v1.0.110` (BUBBLE-10) — three `[CRASH POST]`
events from Will's Z Fold 5 (Android 16 / SDK 36) where the v1.0.100 (UX-50) ripple
attrs added to `overlay_bubble.xml` threw `InflateException` in
`OverlayService.onCreate`, blocking the entire bubble UX. Caught and fixed the same
hour through the crash-reporting loop.

---

