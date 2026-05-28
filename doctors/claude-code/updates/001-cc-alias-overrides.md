# Update 001: cc-alias suffix overrides + collision detection

**Shipped:** 2026-05-13
**Touches:** `common/templates/generate-cc-aliases`
**Inspired by:** Laura Land's `claude-alias-system.md` spec (2026-05-28)

## What changed

The `generate-cc-aliases` script that produces `~/.cc-project-aliases`
now supports:

1. **A user override file at `~/.cc-suffix-overrides`** that lets the
   user pin custom suffixes for specific folders. This resolves
   collisions and lets the user pick shorter / more memorable
   abbreviations when the default initials-of-hyphenated-parts rule
   produces something awkward.

   Format (it's a bash file, sourced by the generator):

   ```bash
   # ~/.cc-suffix-overrides
   declare -A SUFFIX_OVERRIDES
   SUFFIX_OVERRIDES[openclaw-doctor]=ocd
   SUFFIX_OVERRIDES[claude-doctor]=cld
   ```

2. **Collision detection.** When two folders compute (or claim, via
   overrides) the same suffix, the first one wins; the second is
   logged to `/tmp/cc-aliases.err.log` and skipped. The generator also
   prints the warning inline when it finishes, so the user sees it
   immediately.

3. **Bash 4+ requirement at generator runtime.** Associative arrays
   need bash 4 (macOS ships bash 3.2). The check at the top of the
   script emits a friendly "brew install bash" hint instead of
   crashing on `declare -A`. The OUTPUT alias file still uses only
   plain `alias` statements that work in any bash 3.2+ or zsh.

## When to apply

- Existing user already has `generate-cc-aliases` installed at
  `~/.local/bin/generate-cc-aliases` (per the original alias setup
  step in DOCTOR.md).
- They've seen at least one folder-naming collision OR they've
  manually edited the generator script to pin a suffix.

## How to apply

1. Diff the user's current `~/.local/bin/generate-cc-aliases` against
   the new template at `<framework>/common/templates/generate-cc-aliases`.
   Show what's different.
2. If they accept the update, copy the new template over their
   installed copy. Their `~/.cc-project-aliases` will be regenerated
   the next time they run the generator.
3. Offer to create an empty `~/.cc-suffix-overrides` with a comment
   explaining the format, so they have a discoverable spot to add
   pins when collisions appear.
4. Run the generator once so the warnings (if any) surface
   immediately.

## When NOT to apply

- User is on macOS default bash 3.2 and has no plan to install a
  newer bash. The new generator will refuse to run. In that case
  leave the previous version in place - it works in bash 3.2 - and
  note this update as deferred until they upgrade bash.

## Credit

The override-file idea, the collision-logging pattern, and the
naming conventions all come from Laura Land's claude-alias-system
spec (dated 2026-05-28). thedoc's version keeps the always-wrap-in-
tmux philosophy from the original `generate-cc-aliases`, so the
output alias matrix is the same four verbs (cc-*/cn-*/dcc-*/dcn-*)
rather than Laura's richer eight verbs - that fits thedoc's
"persistence by default" stance.
