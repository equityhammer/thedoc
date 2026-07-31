# Android Manifesto

> Conventions for sideloaded, single-developer Android apps that iterate via a
> sprint-feedback loop over Tailscale. Adopt what fits; ignore what doesn't.

This is the **single source of truth** for Android development across these apps.
It is stored in `thedoc/common/android-manifesto/` (version-controlled in thedoc,
shared by both Claude Code and Jarvis) and symlinked at `~/GitHub/android-manifesto`
so it opens via the `cc-android-manifesto` alias.

> **History:** Split on 2026-05-24 from the former single-file
> `doctors/claude-code/MASTER_TEMPLATE_FOR_ANDROID_APPS.md` (2,538 lines) into the
> topic files below. No content was changed in the split, only reorganized.

---

## Start here

- **[getting-started.md](./getting-started.md)**: the new-app checklist (do these
  before any feature code) + the always-on requirements every app must satisfy.

## The iteration loop

- **[sprint-feedback-loop.md](./sprint-feedback-loop.md)**: the signature
  sprint-feedback-Tailscale workflow: 5-item sprints, verbatim-quote items,
  ✅ marking, code-review + conflict-review passes, running the server under `Monitor`.
- **[dist-server.md](./dist-server.md)**: `dist/serve_<app>.py` requirements
  (stdlib-only) + the `dist/sprint.md` template.
- **[PORTS.md](./PORTS.md)**: the per-app local-server port registry. Claim a port
  here before standing up a new `dist/` server so two apps never collide.

## Build & architecture

- **[build-and-structure.md](./build-and-structure.md)**: recommended project
  structure, the `gradle/libs.versions.toml` standard dependency block, the
  `app/build.gradle.kts` skeleton, and build/release conventions (always `clean`
  for sprint ships, `CHANGELOG.md` in the same diff).
- **[compose-and-theming.md](./compose-and-theming.md)**: Material 3, single-activity
  + Navigation, settings/preferences UI, and the hard-won Compose patterns
  (hoist `remember`, `navigationBarsPadding()` on FABs, `key()` on reshaping lists,
  accessibility/TalkBack, `LocalUriHandler`, freshness ticker, pull-to-refresh).

## Crash, telemetry & platform

- **[crash-and-telemetry.md](./crash-and-telemetry.md)**: the `CrashReporter`
  contract, offline queue, `UpdateNotifier`, debug FAB, screenshot/file attach.
- **[platform-conventions.md](./platform-conventions.md)**: notifications,
  background work, networking, permissions UX.
- **[overlay-windowmanager.md](./overlay-windowmanager.md)**: floating-bubble /
  overlay patterns for apps that draw outside their own activity.
- **[packagemanager-metadata.md](./packagemanager-metadata.md)**: read installed-app
  labels + icons from `PackageManager` (not bundled JSON), memoize, cache.

## State & UI quality

- **[persistence.md](./persistence.md)**: state holders surviving process death,
  the three-LaunchedEffect hydrated-gate template, `schemaVersion` tolerance, and
  the schema-versioned cross-version export envelope.
- **[ui-affordances.md](./ui-affordances.md)**: every dead-end state needs recovery, via
  confirmation gates, destructive-action weighting, overflow handling, importer
  error states, Snackbar-Undo.

## Testing

- **[testing.md](./testing.md)**: fake the Android boundary not the pure code,
  test-then-assert on platform behavior, cross-singleton integration, tripwire tests.
- **[visual-regression-roborazzi.md](./visual-regression-roborazzi.md)**: Roborazzi
  + Robolectric setup, snapshot test pattern, gotchas, per-device qualifiers.

## Reference

- **[docs-conventions.md](./docs-conventions.md)**: `CLAUDE.md` / `SPEC.md` /
  `REFACTOR.md` / `dist/*_audit.md` conventions.
- **[critical-architecture-rules.md](./critical-architecture-rules.md)**: the rules
  learned the hard way (NMTB) + open questions for the template.

---

## Adding new patterns

When a real bug or request in one app produces a generalizable pattern, promote it
into the relevant topic file above. Conventions for a good manifesto entry:

1. **Lead with the user's verbatim quote + the originating app version**, e.g.
   *Originating change: Transfer Checklist `v1.0.81` (ACCESS-04): "..."*. That quote
   is the audit trail back to the transcript/changelog that motivated the rule.
2. **State the wrong way and the right way** with a minimal code delta.
3. **Give the audit trigger**: when a future edit should re-check this rule.
4. File it under the matching topic doc; if it's a brand-new topic, add a file here
   and link it from this index.

Keep each entry tight. The manifesto is a set of decisions already made, not a
tutorial; every paragraph should change what the next build does.
