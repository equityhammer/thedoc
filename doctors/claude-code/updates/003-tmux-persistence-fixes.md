# Update 003: tmux session persistence actually saves and restores claude

**Shipped:** 2026-09-22
**Touches:** `common/templates/tmux.conf`, `common/templates/tmux-resurrect-pane-command.sh` (new)

## What changed

The persistence block in the tmux template (tmux-resurrect + tmux-continuum)
had two silent failures. Both are fixed.

1. **Continuum never auto-saved when a second tmux server was running.**
   Continuum only adds its auto-save hook to `status-right` when it is the
   only tmux server. OpenClaw runs its own server on a separate socket
   (`tmux -S ~/.openclaw/codeclaw.sock`), so on any machine with OpenClaw
   the auto-save never ran. Nothing reported the failure. The template now
   adds the hook itself.

   The block is also wrapped in `%if "#{==:#{b:socket_path},default}"`, so
   only the default tmux server loads the plugins. Without that guard the
   OpenClaw server would restore the user's sessions into itself on startup
   and overwrite the same save files.

2. **Restore never relaunched claude in `cc-*` windows.** The `cc-*` aliases
   start claude as the pane's own process, not under a shell. Resurrect's
   stock `ps` save strategy records the pane process's *child*. For a claude
   pane that child is `caffeinate -i -t 300`, so the save file held
   `caffeinate`, and `@resurrect-processes '"~claude"'` never matched. After a
   restore the windows came back as bare shells. The new
   `tmux-resurrect-pane-command.sh` save strategy records the pane process
   itself (`claude --dangerously-skip-permissions --continue`). When the pane
   process is a shell it falls back to the stock behavior.

## How to apply

1. Copy `<framework>/common/templates/tmux-resurrect-pane-command.sh` to
   `~/.tmux/resurrect-pane-command.sh` and `chmod +x` it.
2. Replace the persistence block in `~/.tmux.conf` with the template's,
   from `# -- Session persistence` to the end of the file. If the user loads
   the plugins with `run-shell` instead of TPM, keep their loader lines and
   carry over the `%if` guard, the `@resurrect-save-command-strategy` line
   and the `status-right` hook. The hook must come before continuum loads
   and use `$HOME` rather than `~`, so the path matches continuum's own.
   Otherwise, when no other server is running, continuum adds a second copy.
3. `tmux source-file ~/.tmux.conf`, then check:
   - `tmux show -g status-right` contains `continuum_save.sh` exactly once
   - `~/.tmux/plugins/tmux-resurrect/scripts/save.sh quiet`, then the `pane`
     lines in `~/.tmux/resurrect/last` end in a `claude ...` command for
     claude windows, not `caffeinate`

## When NOT to apply

- The user has no claude panes and no second tmux server. Nothing is
  broken for them, though the change is harmless.
