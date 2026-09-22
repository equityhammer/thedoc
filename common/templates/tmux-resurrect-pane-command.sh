#!/usr/bin/env bash
# tmux-resurrect save strategy. Install to ~/.tmux/resurrect-pane-command.sh. cc-* aliases run claude as the pane's own process, not
# under a shell, so the stock "ps" strategy (children of the pane pid) records claude's
# child (caffeinate) and the ~claude restore never fires. Use the pane process itself
# unless it is a shell, then fall back to its first child like the stock strategy.
PANE_PID="$1"
[ -n "$PANE_PID" ] || exit 0
own=$(ps -o args= -p "$PANE_PID")
case "$(basename -- "${own%% *}")" in
    -*|bash|zsh|sh|fish|login) ps -ao "ppid,args" | sed "s/^ *//" | grep "^${PANE_PID} " | head -n 1 | cut -d' ' -f2- ;;
    *) printf '%s\n' "$own" ;;
esac
