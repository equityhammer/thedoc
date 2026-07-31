# thedoc bootstrap (PowerShell)
# One-liner installer for native Windows PowerShell 7+ users.
#
# Usage:
#   irm https://raw.githubusercontent.com/equityhammer/thedoc/main/bootstrap.ps1 | iex
#
# This is the Windows-native counterpart to bootstrap.sh. Linux/macOS/WSL/Git
# Bash users should use the bash one-liner from the README instead.

$ErrorActionPreference = 'Stop'

# ── --help short-circuit (mirrors bootstrap.sh) ──────────────────────
# Uses $args directly to dodge PS parameter-binding of '--help' as a
# -help parameter name. See setup.ps1 for the longer rationale.
if ($args.Count -gt 0 -and $args[0] -in @('--help', '-h', 'help', '/?', '-?')) {
    @'
thedoc bootstrap (PowerShell)

Usage:
  irm https://raw.githubusercontent.com/equityhammer/thedoc/main/bootstrap.ps1 | iex

What it does:
  1. Clones the thedoc repo to a temp directory.
  2. Runs setup.ps1 from there. The wizard moves the repo to
     wherever you point it at (typically $HOME\GitHub\thedoc) and
     adds it to your User PATH.
  3. Wires ~/.secrets.ps1 into your PowerShell profile so
     llm-secrets.ps1 env vars auto-load in new sessions.

Requirements:
  - git on PATH (Git for Windows or any PowerShell-accessible git)
  - PowerShell 7+ (pwsh, not Windows PowerShell 5.1)

Manual install (no irm | iex):
  git clone https://github.com/equityhammer/thedoc.git $HOME\GitHub\thedoc
  $env:PATH = "$HOME\GitHub\thedoc;$env:PATH"
  Add-Content $PROFILE.CurrentUserAllHosts 'if (Test-Path "$HOME/.secrets.ps1") { try { . "$HOME/.secrets.ps1" } catch { Write-Host "~/.secrets.ps1: $($_.Exception.Message)" -ForegroundColor Yellow } }'
  .\thedoc.ps1
'@
    exit 0
}

# Reject unknown args explicitly (mirrors setup.ps1 iter 261 and
# bootstrap.sh's case statement). irm | iex passes no args so this
# only fires when a user runs `pwsh -File bootstrap.ps1 <typo>`.
if ($args.Count -gt 0) {
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine("  Unknown argument: $($args[0])")
    [Console]::Error.WriteLine("  Run 'bootstrap.ps1 --help' for usage.")
    [Console]::Error.WriteLine('')
    exit 1
}

$Repo   = 'https://github.com/equityhammer/thedoc.git'
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "thedoc-$([guid]::NewGuid())"

# ── Preflight ────────────────────────────────────────────────────────
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  thedoc needs git but it isn't on your PATH."
    Write-Host "  Install Git for Windows: https://git-scm.com/download/win"
    Write-Host ""
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  thedoc PowerShell scripts target PowerShell 7+. You're on $($PSVersionTable.PSVersion)."
    Write-Host "  Install PowerShell 7: https://github.com/PowerShell/PowerShell/releases"
    Write-Host ""
    exit 1
}

# ── Clone to temp ────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Downloading thedoc..."
# Capture stderr so we can show it under our framing. Without this the user
# sees raw 'fatal: Could not resolve host' from git mixed into the install
# output with no context on what bootstrap was doing.
$cloneErr = & git clone --quiet $Repo $TmpDir 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  Clone failed. git said:"
    $cloneErr | ForEach-Object { Write-Host "      $_" }
    Write-Host ""
    Write-Host "  Common causes:"
    Write-Host "    - no network connectivity"
    Write-Host "    - corporate proxy or firewall blocking github.com"
    Write-Host "    - $Repo has moved or is unreachable"
    Write-Host ""
    exit 1
}
Write-Host "  Done."
Write-Host ""

# ── Hand off to setup.ps1 ─────────────────────────────────────────────
# Propagate setup.ps1's exit code. Without this, a setup-preflight
# failure (e.g. PS version too old) prints an error and exits 1, but
# bootstrap.ps1 then exits 0 - a caller using `pwsh -File bootstrap.ps1`
# (or any wrapper that reads $LASTEXITCODE) would think the install
# succeeded. Doesn't matter for `irm | iex` since iex evaluates in the
# current scope and exit-statement terminates the pipeline directly,
# but `-File` invocations are the more common scripted entry point.
$env:THEDOC_BOOTSTRAP_DIR = $TmpDir
& (Join-Path $TmpDir 'setup.ps1')
exit $LASTEXITCODE
