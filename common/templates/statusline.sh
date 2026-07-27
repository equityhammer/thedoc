#!/usr/bin/env bash
# thedoc/common/templates/statusline.sh
# A portable Claude Code status line.
#
# Line 1: <folder> | <branch> | <model> | <ctx%>
# Line 2: $<cost> spent | +<added> -<removed> lines | <duration> session
#
# Reads Claude Code's statusLine JSON from stdin.
# Schema: https://code.claude.com/docs/en/statusline
#
# Install:
#   cp statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
# Then add to ~/.claude/settings.json:
#   { "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" } }

set -euo pipefail

input=$(cat)

# Parse all fields in one jq invocation for efficiency
parsed=$(echo "$input" | jq -r '
    [
        (.workspace.current_dir // .cwd // ""),
        (.model.display_name // "?"),
        (.context_window.context_window_size // 0),
        (.context_window.used_percentage // 0),
        (.cost.total_cost_usd // 0),
        (.cost.total_lines_added // 0),
        (.cost.total_lines_removed // 0),
        (.cost.total_duration_ms // 0)
    ] | @tsv
')

IFS=$'\t' read -r DIR MODEL CTX_SIZE PCT COST ADDED REMOVED DURATION_MS <<< "$parsed"

# Folder: just the basename
FOLDER="${DIR##*/}"
[ -z "$FOLDER" ] && FOLDER="?"

# Truncate context % to integer
PCT="${PCT%.*}"
[ -z "$PCT" ] && PCT="0"

# Model label - add context size suffix when extended
MODEL_LABEL="$MODEL"
if [ "$CTX_SIZE" -ge 1000000 ] 2>/dev/null; then
    MODEL_LABEL="$MODEL (1M context)"
elif [ "$CTX_SIZE" -gt 200000 ] 2>/dev/null; then
    K=$((CTX_SIZE / 1000))
    MODEL_LABEL="$MODEL (${K}k context)"
fi

# Git branch (only if cwd is in a repo)
BRANCH=""
if [ -n "$DIR" ] && [ -d "$DIR" ]; then
    BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null || true)
fi

# Format cost as $X.XX (skip if zero)
COST_FMT=""
if [ -n "$COST" ] && [ "$(printf '%.2f' "$COST" 2>/dev/null || echo 0.00)" != "0.00" ]; then
    COST_FMT="$(printf '$%.2f' "$COST")"
fi

# Format duration as Xs / Xm / XhYm
DUR_FMT=""
if [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
    SECS=$((DURATION_MS / 1000))
    if [ "$SECS" -lt 60 ]; then
        DUR_FMT="${SECS}s"
    elif [ "$SECS" -lt 3600 ]; then
        DUR_FMT="$((SECS / 60))m"
    else
        H=$((SECS / 3600))
        M=$(( (SECS % 3600) / 60 ))
        DUR_FMT="${H}h${M}m"
    fi
fi

# Compose line 1: folder | branch? | model | ctx%
line1="$FOLDER"
[ -n "$BRANCH" ] && line1="$line1 | $BRANCH"
line1="$line1 | $MODEL_LABEL | ${PCT}% ctx"
echo "$line1"

# Compose line 2 (only if any data is present)
parts2=()
[ -n "$COST_FMT" ] && parts2+=("$COST_FMT spent")
if { [ "$ADDED" -gt 0 ] 2>/dev/null; } || { [ "$REMOVED" -gt 0 ] 2>/dev/null; }; then
    parts2+=("+$ADDED -$REMOVED lines")
fi
[ -n "$DUR_FMT" ] && parts2+=("$DUR_FMT session")

if [ ${#parts2[@]} -gt 0 ]; then
    line2="${parts2[0]}"
    for p in "${parts2[@]:1}"; do
        line2="$line2 | $p"
    done
    echo "$line2"
fi

# Line 3: Tailscale link for THIS project (per-folder), falling back to a global default.
# Search order: walk up from the session's cwd looking for a `.tailscale-link.txt`
# in the project (or any parent up to, but not including, $HOME). If none is found,
# use the global pointer file at ~/.claude/tailscale-link.txt.
LINK=""
d="$DIR"
while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
    if [ -f "$d/.tailscale-link.txt" ]; then
        LINK=$(head -1 "$d/.tailscale-link.txt" 2>/dev/null || true)
        break
    fi
    d="${d%/*}"
done
if [ -z "$LINK" ] && [ -f "$HOME/.claude/tailscale-link.txt" ]; then
    LINK=$(head -1 "$HOME/.claude/tailscale-link.txt" 2>/dev/null || true)
fi
[ -n "$LINK" ] && printf '\xF0\x9F\x94\x97 %s\n' "$LINK"
