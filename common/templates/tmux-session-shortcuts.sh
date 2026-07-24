# tmux session shortcuts - source this from ~/.bashrc or ~/.zshrc
#
#   t              list sessions
#   t <name>       attach to session <name>, creating it if it doesn't exist
#   t<name>        same thing with no space: twebsite, tlogo, tvideo
#
# <name> is matched case-insensitively as a prefix, so `tsunday` reaches a
# session called sundaySchoolEscapeRoom and `tvideo` reaches video-editing.
# You never have to declare a per-session alias: any t<word> works, and an
# unmatched word creates a session of that name.
#
# This is the SESSION-level companion to generate-cc-aliases, which works at
# the WINDOW level inside a single "claude" session. Use cc-*/dcc-* to open a
# project in a claude window; use t<name> to hop between whole sessions you
# created by hand.
#
# Portability: the t() function is plain POSIX-ish shell (no arrays, no
# mapfile, no shopt) so it works in bash 3.2 (macOS default) and zsh. The
# no-space t<name> form hooks the shell's unknown-command handler, which is
# named differently per shell - both are wired up below.

t() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo "t: tmux is not installed" >&2
        return 127
    fi

    if [ -z "$1" ]; then
        tmux list-sessions 2>/dev/null || echo "t: no tmux sessions"
        return
    fi

    local name=$1
    shift

    local sessions lname s lower_s exact= matches= count=0
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    lname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

    # Exact match wins outright; otherwise collect case-insensitive prefix hits.
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if [ "$s" = "$name" ]; then
            exact=$s
            break
        fi
        lower_s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
        case $lower_s in
            "$lname"*)
                matches="${matches}${s}
"
                count=$((count + 1))
                ;;
        esac
    done <<EOF
$sessions
EOF

    local target
    if [ -n "$exact" ]; then
        target=$exact
    elif [ "$count" -eq 1 ]; then
        target=$(printf '%s' "$matches" | head -n 1)
    elif [ "$count" -gt 1 ]; then
        # Ambiguous: list the candidates rather than guessing one.
        printf 't: "%s" matches %d sessions: %s\n' \
            "$name" "$count" "$(printf '%s' "$matches" | tr '\n' ' ')" >&2
        return 1
    else
        printf 't: no session matching "%s", creating it\n' "$name" >&2
        tmux new-session -d -s "$name" "$@" || return $?
        target=$name
    fi

    # "=name" forces an exact target so tmux doesn't prefix-match on its own.
    if [ -n "$TMUX" ]; then
        tmux switch-client -t "=$target"
    else
        tmux attach-session -t "=$target"
    fi
}

# --- no-space t<name> form -------------------------------------------------
#
# Both shells call a hook when a command isn't found. We intercept names that
# look like t<something> and hand everything else to whatever handler was
# already installed (Ubuntu's command-not-found package, for instance), so
# genuine typos still get their normal treatment.
#
# Trade-off: a mistyped command starting with t that isn't a real command
# will create a session instead of erroring, e.g. `tre` for `tree` when tree
# isn't installed. The function prints what it's doing, and
# `tmux kill-session -t =re` undoes it.

__t_dispatch_unknown() {
    # Sets __t_handled=1 when it claimed the command, and returns t()'s own
    # exit status so an ambiguous match still reports failure to the shell.
    __t_handled=0
    case $1 in
        t?*)
            case $1 in
                */*) return 1 ;;   # a path, not a shortcut
            esac
            __t_handled=1
            local name=${1#t}
            shift
            t "$name" "$@"
            return $?
            ;;
    esac
    return 1
}

if [ -n "$BASH_VERSION" ]; then
    # Save the existing handler once, so re-sourcing this file doesn't make
    # the wrapper call itself.
    if ! declare -f __t_cnf_fallback >/dev/null 2>&1; then
        if declare -f command_not_found_handle >/dev/null 2>&1; then
            eval "__t_cnf_fallback() $(declare -f command_not_found_handle | tail -n +2)"
        else
            __t_cnf_fallback() { printf '%s: command not found\n' "$1" >&2; return 127; }
        fi
    fi

    command_not_found_handle() {
        local __status
        __t_dispatch_unknown "$@"
        __status=$?
        [ "$__t_handled" = 1 ] && return $__status
        __t_cnf_fallback "$@"
    }

elif [ -n "$ZSH_VERSION" ]; then
    if ! (( ${+functions[__t_cnf_fallback]} )); then
        if (( ${+functions[command_not_found_handler]} )); then
            functions[__t_cnf_fallback]=$functions[command_not_found_handler]
        else
            __t_cnf_fallback() { printf '%s: command not found\n' "$1" >&2; return 127; }
        fi
    fi

    command_not_found_handler() {
        local __status
        __t_dispatch_unknown "$@"
        __status=$?
        [ "$__t_handled" = 1 ] && return $__status
        __t_cnf_fallback "$@"
    }
fi
