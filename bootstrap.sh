#!/usr/bin/env bash
# thedoc bootstrap - one-liner installer
# bash <(curl -fsSL https://raw.githubusercontent.com/equityhammer/thedoc/main/bootstrap.sh)
set -euo pipefail

case "${1:-}" in
    "")
        # No args - normal curl-piped invocation. Fall through.
        :
        ;;
    --help|-h|help)
        cat <<'EOF'
thedoc bootstrap

Usage:
  bash <(curl -fsSL https://raw.githubusercontent.com/equityhammer/thedoc/main/bootstrap.sh)

What it does:
  1. Clones the thedoc repo to a temp directory.
  2. Runs setup.sh from there. The wizard moves the repo to
     wherever you point it at (typically ~/GitHub/thedoc).
  3. Adds thedoc to your PATH and sources ~/.secrets in your
     shell rc, so 'thedoc' just works in new terminals.

Requirements:
  - git on PATH
  - bash 3.2+ (macOS default; any modern Linux is 4+/5+)

Manual install (no curl pipe):
  git clone https://github.com/equityhammer/thedoc.git ~/GitHub/thedoc
  echo 'export PATH="$HOME/GitHub/thedoc:$PATH"' >> ~/.bashrc
  echo '[ -f "$HOME/.secrets" ] && source "$HOME/.secrets"' >> ~/.bashrc
  source ~/.bashrc
  thedoc
EOF
        exit 0
        ;;
    *)
        # Reject unknown args (mirrors setup.sh iter 261). Curl-piped
        # invocation passes no args, so this only fires on
        # `bash bootstrap.sh <typo>` from a manual run.
        echo "" >&2
        echo "  Unknown argument: $1" >&2
        echo "  Run 'bootstrap.sh --help' for usage." >&2
        echo "" >&2
        exit 1
        ;;
esac

REPO="https://github.com/equityhammer/thedoc.git"

# Preflight BEFORE mktemp so a missing git doesn't leave an orphaned
# /tmp/tmp.XXXXXX/ directory behind. (Minor on a single host, but
# bootstrap is the most-curl-piped script in the repo - errors here
# repeat at scale.)
if ! command -v git &>/dev/null; then
    echo ""
    echo "  git is required but not installed."
    echo "  Install it via your package manager and re-run."
    echo ""
    exit 1
fi

# Clone into the mktemp dir directly (no `/thedoc` subdir). git clone
# accepts an existing empty dir as destination, and using mktemp's
# output as the clone root means setup.sh's `mv $TMP_DIR $THEDOC_FINAL`
# renames the entire tempdir away in one syscall - no leftover empty
# parent dir like /tmp/tmp.XXXXXX/ orphaned after a successful install.
TMP_DIR="$(mktemp -d)"

# Clone to temp. Wrap with a friendly framing - without this the user
# would see raw 'fatal: Could not resolve host' / 'fatal: unable to
# access' from git stderr with no context on what bootstrap was doing.
# mktemp the stderr capture so two concurrent bootstraps don't clobber
# each other's error log.
# Bare mktemp is portable across GNU and BSD (macOS). The -t flag has
# different semantics on each (GNU: template; BSD: prefix), so dodge it.
CLONE_ERR=$(mktemp)
echo ""
echo "  Downloading thedoc..."
if ! git clone --quiet "$REPO" "$TMP_DIR" 2>"$CLONE_ERR"; then
    echo ""
    echo "  Clone failed. git said:"
    sed 's/^/      /' "$CLONE_ERR"
    rm -f "$CLONE_ERR"
    echo ""
    echo "  Common causes:"
    echo "    - no network connectivity"
    echo "    - corporate proxy or firewall blocking github.com"
    echo "    - $REPO has moved or is unreachable"
    echo ""
    exit 1
fi
rm -f "$CLONE_ERR"
echo "  Done."
echo ""

# Hand off to setup.sh which handles everything
export THEDOC_BOOTSTRAP_DIR="$TMP_DIR"
exec "$TMP_DIR/setup.sh"
