[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Logging, telemetry, and crash reporting conventions

### Crash reporter contract

- Lives in `util/CrashReporter.kt`.
- `install(context)` is called as the FIRST line of `Application.onCreate`, before any DI / Room / DataStore.
- Captures: timestamp, device manufacturer/model, Android version, app version, build type, package name, thread name, full stack trace, recent log file contents.
- Writes the report to disk synchronously (cache or external files dir).
- Posts to `<server>/crash` on a self-owned `SupervisorJob` scope (independent of the rest of the app).
- On `install`, drains any queued reports from previous sessions.
- Hardcoded fallback URLs (Tailscale relay + sideload server). Optional configured override resolved at upload time.
- `sendLogManually(context, userMessage, onResult)` is the API that the in-app feedback FAB calls.
- Compares versions with naive `split(".").mapNotNull { it.toIntOrNull() }`-style comparator. Good enough.

### Two valid implementations - pick one per app

| | Style A (no-deps) | Style B (OkHttp app) |
|---|---|---|
| HTTP client | `HttpURLConnection` (zero deps) | OkHttp (already needed for WebSocket) |
| Queue format | base64-line file in external files dir | Log files in `cacheDir/crashes/` |
| URL config | Hardcoded constants | Hardcoded fallback list + DataStore override |

**Recommendation:** Style B if you're already pulling in OkHttp; Style A if the app would otherwise have no networking dep.

### Style-A reference decomposition: `CrashReporter` / `CrashQueue` / `CrashPayload` / `CrashReport`

The proven Style-A shape splits the reporter into four single-responsibility files in
a `crash/` package. The decomposition is what makes the report path unit-testable (the
formatter and the queue are pure / filesystem-only, with no network and no Android UI) and is
the structure to copy:

- **`CrashReport`**: immutable data class: timestamp, versionName/Code, package,
  buildType, device manufacturer/model, `androidSdk`, thread, optional `userMessage`,
  optional `stackTrace`, optional `attachmentBase64` + `attachmentFilename`.
- **`CrashPayload`**: pure `format(report): String`. Key-value header lines, then
  `--- user message ---` / `--- stack trace ---` / attachment marker blocks. No I/O.
- **`CrashQueue`**: on-disk queue under `<cacheDir>/crashes/` with `add` / `list` /
  `drain(send)`. Every method swallows IO failures and degrades to a no-op.
- **`CrashReporter`**: the `object` that wires it together: `install(app)`, the
  uncaught handler, `sendLogManually(...)`, and the private `postSync`.

**Queue filenames: `crash_<millis>_<uuid8>.log`.** The leading epoch-millis keeps a
lexical sort ≈ chronological; the 8-char UUID suffix guarantees uniqueness when two
reports land in the same millisecond (an uncaught throw racing an in-flight manual
send). A bare-timestamp filename silently overwrites one of the two, so the UUID is not
cosmetic.

**Never crash the crash handler.** Inside `Thread.setDefaultUncaughtExceptionHandler`,
wrap everything in `try { … } catch (_: Throwable) {}` and **always call the previous
default handler afterward** so the OS still kills the process and the original
exception still surfaces. A failure in the crash path must never mask the bug it was
reporting. Likewise `CrashQueue`'s write/read/delete all swallow IO, so a full disk or
revoked permission can't turn a reportable crash into a crash-loop.

**Why this is the loop's payoff:** because `install()` is line 1 of `onCreate` and the
queue drains on next launch, a real-device crash POSTs to `/crash`, lands in the dist
server's `Monitor` stream as a `[CRASH POST]` block, and gets triaged + fixed, often
the same hour. Validated repeatedly in the wild (e.g. Transfer Checklist `v1.0.110`:
three `[CRASH POST]` events from a foldable test device on Android 16 → root-caused + shipped in
one session).

### Optional: `DebugLogger` for state-machine apps

For apps with non-trivial scheduled / async behaviour, ship a `DebugLogger` that, when enabled from a Settings toggle, posts a 5-second-cadence state dump (alarm registration, scheduled times, permissions) to the server.

### Debug FAB feedback dialog with screenshot attach

When the in-app feedback FAB collects user reports, optionally accept a screenshot: pictures are dramatically more useful than text for UI bugs, and the modern Android picker needs no runtime permissions.

1. **Dialog UI:** a single "Attach screenshot" `TextButton` that launches `rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia())` with `PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)`. On result, hold the `Uri?` alongside the text draft. Show a ~56dp thumbnail with a Remove button when set. Disable both during in-flight Send to prevent double-fire.
2. **Payload encoding:** extend `CrashReport` with `screenshotBase64: String? = null`. On Send, read the picked Uri via `context.contentResolver.openInputStream(uri)?.use { it.readBytes() }`, base64-encode with `Base64.NO_WRAP`, set the field. `CrashPayload.format` appends a marker block AFTER any stack trace:
   ```
   --- screenshot (base64, PNG) ---
   <base64 string>
   ```
3. **Server decode:** `dist/serve_<app>.py`'s `do_POST` scans the body for the literal marker, base64-decodes the trailing block (terminate at `\n--- ` for the next section or EOF), writes bytes to `crashes/crash_<ts>_screenshot.png`, and **replaces the base64 block in the saved `.log` file with a small `(saved to <name>, <N> bytes)` note** so the log stays human-readable when grepped. Print `[SCREENSHOT] <path>` to stdout so the Monitor surfaces where the image landed.
4. **Permissions:** `PickVisualMedia` is the Android 13+ photo picker; it works back to API 19 via Play services fallback and requires NO runtime permissions for arbitrary images. Do NOT add `READ_EXTERNAL_STORAGE`.
5. **Trade-offs:** base64 inflates ~4/3×; a 5MB screenshot becomes ~6.7MB POST. Fine over Tailscale loopback, may want compression before transit on cellular. Skip downscaling in v1; revisit if the dist server starts logging timeouts.

Originating change: Transfer Checklist `v1.0.73` (FEAT-01), a request to be able to send in screenshots by attaching a photo to items in debug mode, with the capability documented in the manifesto. Validated in the wild end-to-end when a 424KB screenshot landed cleanly + surfaced concrete layout bugs (DESIGN-01) the same hour.

**FEAT-02 generalization (Transfer Checklist `v1.0.98`):** the same byte path now carries ANY file, not just PNG screenshots. The follow-up requirement was to send regular files, not just images, through the monitor debug button. Useful for PDFs, .log dumps, .json state captures, .csv exports, anything the user can already share via the system file picker. Drop-in changes:

1. **Picker:** swap `ActivityResultContracts.PickVisualMedia()` → `ActivityResultContracts.OpenDocument()`. `pickFile.launch(arrayOf("*/*"))` accepts ANY MIME type. (Note: when writing the docstring that describes this, watch out for `*/` inside a `/** */` KDoc block, since it closes the block early. Phrase as "any MIME type" or escape.)
2. **Filename + size:** query via `ContentResolver` + `OpenableColumns.DISPLAY_NAME` + `OpenableColumns.SIZE` for the picked URI. Preserves the user-meaningful filename + extension that PickVisualMedia never exposed:
   ```kotlin
   context.contentResolver.query(uri,
       arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
       null, null, null
   )?.use { c ->
       if (c.moveToFirst()) {
           displayName = c.getString(c.getColumnIndex(OpenableColumns.DISPLAY_NAME))
           size = c.getLong(c.getColumnIndex(OpenableColumns.SIZE))
       }
   }
   ```
3. **Preview branch:** check `contentResolver.getType(uri)?.startsWith("image/")`. If true, render the existing thumbnail. Otherwise render a generic "📎 filename · N B" label so the user can confirm what they're about to attach.
4. **Payload encoding:** add `attachmentFilename: String?` to `CrashReport` (alongside the existing base64 bytes; rename `screenshotBase64` → `attachmentBase64` if you want consistency). New marker: `\n--- attachment <safe_filename> (base64) ---\n`. Sanitize the filename via `[^A-Za-z0-9._-] → "_"` (matches the path-traversal regex on the server side) + length-bound to ≤120 chars. When `attachmentFilename` is null, fall back to the FEAT-01 `--- screenshot (base64, PNG) ---` marker, for back-compat with older APKs.
5. **Server decode (`dist/serve_<app>.py`):** parse BOTH markers in `do_POST`. Try the FEAT-02 attachment marker first (via `re.search(r"\n--- attachment ([A-Za-z0-9._-]+) \(base64\) ---\n", body)`), fall back to the FEAT-01 screenshot marker. FEAT-02 saves as `crash_<ts>_<safe_filename>` preserving the extension; FEAT-01 saves as `crash_<ts>_screenshot.png` (back-compat). Banner now reads `[ATTACHMENT] <path>` instead of `[SCREENSHOT] <path>` since the file may be any type; the filename in the path makes the extension immediately visible in the Monitor stream.

**Rule for when to use which:** if your dev FAB only ever needs screenshots, FEAT-01's `PickVisualMedia.ImageOnly` is simpler (no MIME branching, no filename sanitization). If you might ever need to surface a PDF, log file, JSON state dump, etc., ship FEAT-02 from the start. The cost is small (one extra ContentResolver query + one parser branch) and the upside is large (no future "we need to also send PDFs" refactor).

---

