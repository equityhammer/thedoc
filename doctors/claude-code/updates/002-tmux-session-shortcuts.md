# Update 002: t<name> tmux session shortcuts

**Shipped:** 2026-07-24
**Touches:** `common/templates/tmux-session-shortcuts.sh` (new)

## What changed

A new template gives every tmux session a one-word jump command, with no
per-session alias to declare:

```
t              list sessions
t <name>       attach to session <name>, creating it if it doesn't exist
t<name>        same thing with no space: twebsite, tlogo, tvideo
```

Three behaviors worth knowing:

1. **Prefix matching, case-insensitive.** `tsunday` reaches a session named
   `sundaySchoolEscapeRoom`; `tvideo` reaches `video-editing`. An exact name
   always wins over a prefix hit. When a prefix matches two or more sessions
   the function lists them and does nothing, rather than guessing.

2. **Create on miss.** An unmatched name creates a detached session of that
   name and attaches to it, so `tclientwork` works before that session
   exists.

3. **No alias per session.** The no-space form is implemented by hooking the
   shell's unknown-command handler (`command_not_found_handle` in bash,
   `command_not_found_handler` in zsh) rather than by declaring `twebsite`,
   `tlogo`, and so on. Whatever handler was already installed - Ubuntu's
   command-not-found package, typically - is saved and still runs for
   everything that isn't a `t<name>`.

Inside tmux it uses `switch-client` instead of `attach-session`, so it moves
the current client rather than nesting an attach. Targets are passed as
`=name` so tmux does exact matching instead of applying its own prefix rule
on top of ours.

## How this relates to generate-cc-aliases

They operate at different levels and compose rather than compete:

| | Level | Shortcut |
|---|---|---|
| `generate-cc-aliases` | windows inside one `claude` session | `cc-<project>`, `dcc-<project>` |
| `tmux-session-shortcuts.sh` | whole sessions | `t<name>` |

Use `cc-*`/`dcc-*` to open a project in a claude window. Use `t<name>` to hop
between sessions the user created by hand. Neither touches the other's file.

## When to apply

- User runs more than one long-lived tmux session and switches between them
  by typing `tmux attach -t <name>` or hunting through `tmux ls`.
- Sessions have names that are awkward to type in full
  (`sundaySchoolEscapeRoom`), where prefix matching earns its keep.

## How to apply

1. Copy `<framework>/common/templates/tmux-session-shortcuts.sh` to
   `~/.tmux-session-shortcuts.sh`.
2. Source it from their shell rc. If they already have a `~/.bash_aliases`
   sourced by `.bashrc`, add it there:

   ```bash
   [ -f ~/.tmux-session-shortcuts.sh ] && . ~/.tmux-session-shortcuts.sh
   ```

   zsh users: same line in `~/.zshrc`.
3. Have them open a new shell (or source the file) and run `t` with no
   arguments to confirm it lists their sessions.
4. Point out the session-name tradeoff: short distinct names make better
   shortcuts. This is a good moment to rename anything vague. Renaming is
   `tmux rename-session -t <old> <new>` and is safe on a live session.

## When NOT to apply

- User is bothered by an unknown command being interpreted rather than
  erroring. A typo starting with `t` that isn't a real command creates a
  session instead of failing - `tre` when they meant `tree` and tree isn't
  installed. The function announces what it did and
  `tmux kill-session -t =re` reverses it, but if that trade is unwelcome,
  install the file and skip the handler hook: they still get `t <name>` with
  a space, which has no such ambiguity.
- User already has a `command_not_found_handle` doing something meaningful
  and custom. The template chains to it, but diff it with them first rather
  than assuming.

## Portability notes

The `t()` function deliberately avoids `mapfile`, bash arrays, and
`shopt -s nocasematch` so it runs under bash 3.2 (macOS default) and zsh
unchanged. Case-insensitive comparison goes through `tr` instead. Verified
under bash 5 on WSL2; the zsh handler branch follows zsh's documented
`functions[...]` assignment form but has not been exercised on a zsh box, so
confirm it on the first zsh install.
