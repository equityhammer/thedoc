[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Visual regression testing (Roborazzi)

JVM-side Compose + XML-layout screenshot testing for layouts you can iterate on without an emulator or real device. Catches the bug class that unit tests miss: "did this Composable's RENDERED OUTPUT change?" Particularly valuable for:
- Pre-shipping visual verification on devices you don't physically have (foldables, tablets, locale variations)
- Regression detection when changes ripple through `MaterialTheme` / `LocalDensity` / parent container sizing
- Surfacing existing layout issues that whole-screen captures hide in the noise (4-button rows that vertically wrap at smaller widths, icons that drift out of alignment with 3-line columns, etc.)

### Setup (Roborazzi 1.30.x + Robolectric 4.13)

Add the gradle plugin at the project root (`build.gradle.kts`):

```kotlin
plugins {
    // ... existing plugins ...
    id("io.github.takahirom.roborazzi") version "1.30.1" apply false
}
```

Apply the plugin per-module in `app/build.gradle.kts` + add the testImplementation deps:

```kotlin
plugins {
    // ... existing plugins ...
    id("io.github.takahirom.roborazzi")
}

android {
    // ... existing android block ...

    // Robolectric needs Android resources accessible from JVM tests
    // so layouts/themes/drawables resolve like they would on-device.
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }
}

dependencies {
    // ... existing deps ...

    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    testImplementation(composeBom)
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("org.robolectric:robolectric:4.13")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.30.1")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.30.1")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-junit-rule:1.30.1")
    testImplementation("androidx.test.ext:junit:1.1.5")
}
```

Run with `-Proborazzi.test.record=true` to BUILD baselines; subsequent runs without the flag COMPARE against baselines + fail the build on diff.

```bash
./gradlew :app:testDebugUnitTest -Proborazzi.test.record=true   # record baselines
./gradlew :app:testDebugUnitTest                                 # diff against baselines
ls app/build/outputs/roborazzi/                                  # the PNGs
```

### Compose snapshot test pattern

```kotlin
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w412dp-h915dp-xxhdpi")
class HomeScreenSnapshotTest {
    @get:Rule val composeTestRule = createComposeRule()

    @Test fun renders_at_pixel7_portrait() {
        composeTestRule.setContent {
            AppTheme {
                MyScreen(state = sampleState(), onClick = {})
            }
        }
        composeTestRule.onRoot().captureRoboImage()
    }
}
```

### Five gotchas

**1. `View.captureRoboImage()` needs an Activity.** Free-floating inflated Views fail with `"View should have Activity"` because Roborazzi traces up the View hierarchy to find an Activity for rendering context. For non-Compose XML layouts:

```kotlin
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w360dp-h850dp-xxhdpi")
class XmlLayoutSnapshotTest {
    @Test fun render_my_layout() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        activity.setTheme(R.style.Theme_MyApp)
        val container = FrameLayout(activity).apply {
            layoutParams = ViewGroup.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            setBackgroundColor(Color.BLACK)   // visual contrast around the layout
        }
        val view = LayoutInflater.from(activity).inflate(R.layout.my_layout, container, false)
        // ... mutate view contents as needed ...
        container.addView(view)
        activity.setContentView(container)
        activity.window.decorView.captureRoboImage()   // works
    }
}
```

Compose's `createComposeRule()` handles the Activity attachment internally; only the XML / `LayoutInflater.inflate` path needs the manual setup.

**2. `captureRoboImage()` on a Compose root captures only the visible viewport.** For a `LazyColumn` or vertical-scroll container, content below the fold isn't composed → doesn't appear in the PNG. Three workable strategies, ranked by usefulness for visual regression baselines:

- **Subtree captures via `Modifier.testTag(...)`**: best for regression baselines. Add a tag to each major section in your screen + capture each independently:
  ```kotlin
  // In MyScreen Composable:
  Box(modifier = Modifier.testTag("hero")) { HeroSection() }
  Box(modifier = Modifier.testTag("manual-queue")) { AppListSection(...) }
  // In the test:
  composeTestRule.onNodeWithTag("manual-queue").captureRoboImage()
  ```
  Smaller PNGs, actionable diffs (`"manual-queue regressed"` not `"the screen changed by 0.0001%"`). Also surfaces latent issues (wrapping a 4-button Row at narrow widths, drifting icon alignment in 3-line columns, etc.) that get lost in the noise of a full-screen capture.

- **Taller test qualifier**: simplest for first baseline. `@Config(qualifiers = "w412dp-h2400dp-xxhdpi")` makes the LazyColumn compose every section in one viewport. Tradeoff: relative proportions don't match a real device, but pixel-diff regression detection doesn't care about proportions.

- **Per-scroll-position capture** is the most accurate to real usage and the most code: render, capture, programmatically scroll, capture again. Useful for catching scroll-position-specific layout bugs.

```kotlin
// ANTI-PATTERN: captures only what fits in the test qualifier's viewport
composeTestRule.setContent { MyScrollableScreen() }
composeTestRule.onRoot().captureRoboImage()   // only top sections appear in PNG
```

**3. `captureRoboImage()` is a SILENT NO-OP without `-Proborazzi.test.{record,verify}=true`.** Without one of those Gradle flags (or invoking `recordRoborazziDebug` / `verifyRoborazziDebug` directly), capture calls succeed but write nothing to disk + do no comparison. Tests pass green AFTER an intentional visual change. Diagnostic signature: `BUILD SUCCESSFUL` returns after a UI change you KNOW altered the visual output; `app/build/outputs/roborazzi/` is empty; `Task :app:finalizeTestRoborazziDebug SKIPPED` in the gradle log.

**Fix (2-step):**

```kotlin
// app/build.gradle.kts: pin outputDir to a source-controlled location.
roborazzi {
    outputDir.set(file("src/test/snapshots/roborazzi"))
}

// Optional but recommended: wire verify into the standard test loop with a
// presence-check gate so fresh checkouts don't fail with "no baseline found".
tasks.whenTaskAdded {
    if (name == "testDebugUnitTest") {
        val snapshotDir = file("src/test/snapshots/roborazzi")
        tasks.findByName("verifyRoborazziDebug")?.let { verify ->
            verify.onlyIf {
                snapshotDir.isDirectory &&
                    snapshotDir.listFiles { f -> f.extension == "png" }?.isNotEmpty() == true
            }
            finalizedBy("verifyRoborazziDebug")
        }
    }
}
```

```bash
# dist/record_snapshots.sh: one-command record wrapper. Discoverable + no
# Gradle-flag memorization required.
./gradlew :app:recordRoborazziDebug
# After: list newly-written PNGs + print the dist server URL for browser review.
```

**4. Material 3 AlertDialog body containing OutlinedTextField hangs `setContent` itself with 193K+ idle attempts.** Cause: AlertDialog creates a separate Dialog window whose composition root `RobolectricIdlingStrategy` doesn't track; the TextField's cursor + IME animations keep the dialog window recomposing but the test's idling tracker never sees idle. `mainClock.autoAdvance = false` doesn't help because the hang is INSIDE `setContent`, before the test can drive the clock.

```kotlin
// WRONG: hangs at setContent with AppNotIdleException after 60s.
@Composable
private fun MyHarness() {
    AlertDialog(
        onDismissRequest = { },
        text = {
            OutlinedTextField(value = "", onValueChange = { }, label = { Text("Input") })
        },
        confirmButton = { TextButton(onClick = { }) { Text("OK") } }
    )
}

// RIGHT: inline the dialog body as a non-Dialog Column.
@Composable
private fun MyHarness() {
    Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { _ ->
        Column {
            OutlinedTextField(value = "", onValueChange = { }, label = { Text("Input") })
            TextButton(onClick = { }) { Text("OK") }
        }
    }
}
```

Trade-off: lose AlertDialog modal behavior coverage (scrim, tap-outside dismiss, A11y modal semantics). Those are Material 3 component responsibilities; smoke-test them via Roborazzi snapshot tests separately (which use a different rendering path that handles dialog windows correctly via `Robolectric.buildActivity`).

**Decision rule:**
- AlertDialog body is static `Text` only → wrap in AlertDialog in the harness, same as production.
- AlertDialog body has TextField, scrollable content, or anything that drives an `InfiniteAnimationSpec` → inline the body, no AlertDialog wrapper. Add a maintenance note in the harness's docstring pointing at MainActivity's dialog wiring.

**5. Two Compose UI Test interaction gotchas.**

**5a. Sibling Composables in a Scaffold body lambda render at (0,0) and overlap.** Multiple sibling Composables WITHOUT a Layout-providing parent (`Column` / `Row` / stacked `Box`) overlap. `performClick` on the covered sibling is ambiguous in Compose UI Test: the click may dispatch to the topmost sibling instead. Symptom: tests that interact with the FIRST-declared Composable fail with "expected:<[X]> but was:<[]>" while tests interacting with the LAST-declared Composable pass.

```kotlin
// WRONG: Add and Ignore overlap.
Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { _ ->
    Button(onClick = { /* add */ }) { Text("Add") }
    Button(onClick = { /* ignore */ }) { Text("Ignore") }
}

// RIGHT: Column gives each Button unique bounds.
Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { _ ->
    Column {
        Button(onClick = { /* add */ }) { Text("Add") }
        Button(onClick = { /* ignore */ }) { Text("Ignore") }
    }
}
```

**5b. Snackbar's dismiss X uses `contentDescription = "Dismiss"`, NOT displayed text.** When `withDismissAction = true` renders the X icon, finding it via `onNodeWithText("Dismiss")` returns NO match and `.performClick()` throws `AssertionError: Failed to inject touch input`. Use `onNodeWithContentDescription("Dismiss").performClick()` instead. The displayed "Undo" actionLabel button DOES use Text; `onNodeWithText("Undo")` works for that. General rule for Compose UI Test node-finder choice:

- Plain Text Composables, Button labels, OutlinedTextField placeholders → `onNodeWithText`
- IconButton tap targets, Image semantics, anything with `contentDescription = "..."` → `onNodeWithContentDescription`
- Either when you need a strict node match → add `Modifier.testTag("...")` and use `onNodeWithTag`

### Per-device qualifiers worth pinning

| Device class | Qualifier | Notes |
|---|---|---|
| Pixel 7 portrait (reference phone) | `w412dp-h915dp-xxhdpi` | Default "normal phone" baseline |
| Foldable cover (folded) | `w360dp-h850dp-xxhdpi` | Narrowest realistic Android viewport |
| Foldable inner (unfolded) | `w673dp-h841dp-xxhdpi` | Foldable inner display |
| Pixel C / 10" tablet | `w800dp-h1280dp-xhdpi` | Large-tablet sanity baseline |
| Full-content sentinel | `w412dp-h2400dp-xxhdpi` | Tall-viewport version of phone width, forces full LazyColumn to compose for regression baselines |

**Rule of thumb:** pin one "narrow" qualifier (a foldable cover display or smaller) and one "reference" qualifier (Pixel 7 portrait) per significant Composable. Add the full-content sentinel ONLY for screens with substantial LazyColumn content.

### Visual regression as a tool for SURFACING latent issues

The most underappreciated value of snapshot testing isn't catching FUTURE regressions: it's surfacing EXISTING layout bugs that whole-screen review misses. On first baseline capture of `TransferChecklistScreen` at Pixel 7 width, the `subtree_app_list_section.png` immediately showed a 4-button Row in CompletionBanner wrapping "Share as CSV" vertically (1 char per line) at 412dp. The bug had existed since UX-25 + UX-26 + UX-29 + EXPORT-08 each added a button to the Row without testing the combined width. Roborazzi caught it on the first run, before any user reported it.

**Implication:** when you add a Compose UI section that takes user inputs (button rows, chip rows, multi-action surfaces), write the subtree snapshot test in the same PR; you'll catch combined-width issues you wouldn't have thought to check manually.

Originating changes:
- `v1.0.91` Sprint 29 TEST-COV-10: initial Roborazzi infra installed via a `/loop` cron from the user; pinned the BUBBLE-06 fix at the foldable cover qualifier before sideload (visually verified the fix at the EXACT device dimensions the user reported the bug on, BEFORE re-shipping the APK).
- `v1.0.92` Sprint 30 TEST-COV-11: full-content home-screen baselines using the tall-viewport strategy.
- Sprint 31 TEST-COV-12: 8 `Modifier.testTag` wraps in `TransferChecklistScreen.kt` + 7 per-section snapshot tests for actionable diffs; surfaced the CompletionBanner 4-button-Row overflow as a latent bug on first run.
- Two memories crystallised in the process: `feedback-roborazzi-captureRoboImage-needs-activity` (View-needs-Activity gotcha) + `feedback-roborazzi-captures-visible-viewport-only` (visible-viewport-only gotcha + the 3 capture strategies).

---

