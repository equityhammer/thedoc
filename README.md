# thedoc

[![smoke-test](https://github.com/equityhammer/thedoc/actions/workflows/test.yml/badge.svg)](https://github.com/equityhammer/thedoc/actions/workflows/test.yml)

**Emergency Medical Hologram for your LLM/CLI harnesses.**

A framework for creating dedicated "doctor" instances that diagnose, configure, and maintain your AI tool installations. Powered by Claude Code (with more engines coming).

> "Please state the nature of the CLI emergency."

## Table of Contents

- [Quick Start](#quick-start)
- [The Doctor Framework](#the-doctor-framework)
- [llm-secrets - Secure Secret Storage](#llm-secrets---secure-secret-storage)
- [Included Templates](#included-templates)
- [Architecture](#architecture)
- [Why "The Doc"?](#why-the-doc)
- [Contributing](#contributing)
- [License](#license)

## Quick Start

One command. It asks where your projects live, clones thedoc there, sets up your PATH, and launches the doctor.

**Linux / macOS / WSL2 / Git Bash**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/equityhammer/thedoc/main/bootstrap.sh)
```

**Windows (PowerShell 7)**

```powershell
irm https://raw.githubusercontent.com/equityhammer/thedoc/main/bootstrap.ps1 | iex
```

> The PowerShell port is new. If something goes sideways, fall back to
> Git Bash or WSL (the bash one-liner above) and please open an issue.

**Manual install** (if you prefer not to pipe to bash):

```bash
git clone https://github.com/equityhammer/thedoc.git ~/GitHub/thedoc
echo 'export PATH="$HOME/GitHub/thedoc:$PATH"' >> ~/.bashrc
echo '[ -f "$HOME/.secrets" ] && source "$HOME/.secrets"' >> ~/.bashrc
source ~/.bashrc
thedoc
```

**Manual install (PowerShell)**:

```powershell
git clone https://github.com/equityhammer/thedoc.git $HOME\GitHub\thedoc
# Add to PATH for current session
$env:PATH = "$HOME\GitHub\thedoc;$env:PATH"
# Persist across sessions:
[Environment]::SetEnvironmentVariable('PATH', "$HOME\GitHub\thedoc;$([Environment]::GetEnvironmentVariable('PATH', 'User'))", 'User')
# Wire llm-secrets into your PowerShell profile (loads env vars on new shells):
Add-Content $PROFILE.CurrentUserAllHosts 'if (Test-Path "$HOME/.secrets.ps1") { try { . "$HOME/.secrets.ps1" } catch { Write-Host "~/.secrets.ps1: $($_.Exception.Message)" -ForegroundColor Yellow } }'
thedoc
```

> A `thedoc.cmd` shim ships next to `thedoc.ps1` so the bare command
> `thedoc` works from cmd.exe and PowerShell (PATHEXT doesn't include
> `.PS1` by default on Windows). The shim prefers pwsh and falls back
> to Windows PowerShell 5.1 if pwsh isn't installed.

## The Doctor Framework

You run `thedoc`, answer a few questions, and get a dedicated AI-powered doctor for your specific setup. The doctor knows how to:

- **Diagnose** issues with your AI tool configuration
- **Configure** settings, permissions, shell integrations, and SSH shortcuts
- **Maintain** health over time with an update mechanism that walks you through changes
- **Teach** you how your setup works so you can self-diagnose simple issues

### Supported Doctor Types

| Type | Status |
|------|--------|
| Claude Code | Supported |
| OpenClaw | Supported |
| Gemini CLI | Coming soon |

### Supported Engines (what powers the doctor)

| Engine | Status |
|--------|--------|
| Claude Code | Supported |
| OpenClaw | Coming soon |
| Gemini CLI | Coming soon |

### Usage

```
thedoc              # Create a new doctor instance (or open setup)
thedoc setup        # Same as above
thedoc list         # List existing doctor instances
thedoc open <name>  # Open an existing instance directly
thedoc test         # Run wrapper + smoke test suites (mirrors CI)
thedoc version      # Show framework version (git commit)
thedoc update       # Pull the latest framework (git pull --ff-only)
thedoc help         # Show help
```

### The Setup Flow

```
$ thedoc

  +==========================================+
  |   Emergency CLI Hologram activated       |
  +==========================================+

  Please state the nature of the CLI emergency.

  ...

  No emergency? Just a checkup? That's fine too.
  Contrary to my name, I handle everything from routine
  configuration to catastrophic meltdowns.

  What is this doctor for? (which LLM harness are you looking to configure or fix?)

  > Claude Code
    OpenClaw
    Gemini CLI (not yet supported)

  Arrow keys to move, Enter to select

  Which LLM engine will power this doctor?

  > Claude Code
    OpenClaw (not yet supported)
    Gemini CLI (not yet supported)

  Setup mode?

  > Quick - generate a starter config, refine later
    Full - interactive audit of your current setup
```

### What Gets Created

Running setup creates a new **instance folder** in your projects directory:

```
~/GitHub/claude-code-doctor/   # Your doctor instance (default name)
  CLAUDE.md                    # Personal config (your OS, known issues, etc.)
  DOCTOR.md                    # Shared brain (diagnostic logic, personality)
  .framework-updates           # Link to thedoc framework for updates
  .applied-updates             # Tracks which updates you've processed
  .gitignore                   # Keeps .framework-updates etc. out of git
```

### Staying Up To Date

```bash
thedoc update                # git pull the framework, with friendly preflight
```

Or re-paste the install one-liner - the bootstrap will update an existing
install in place instead of orphaning a new clone in `$TMPDIR`.

Next time you open your doctor instance, it checks for new updates and walks you through each one:

> "There's a new update about tmux copy/paste on WSL2. Here's what your
> current config looks like vs. what the update recommends. Want me to apply it?"

No merge conflicts. Your personal config (`CLAUDE.md`) is never touched by upstream.

## llm-secrets - Secure Secret Storage

AI coding assistants (Claude Code, Gemini CLI, etc.) can see everything - your env vars, your files, your command output. There's no built-in way to store a secret that your AI tool can **use** without **seeing**.

`llm-secrets` fills that gap. It stores secrets in a separate chmod 600 file that your AI tool has no reason to read, and loads them as standard environment variables.

```
$ llm-secrets
What's the secret for? my github pat
Variable name: MY_GITHUB_PAT
Paste secret value: ****************************************

Saved! Your variable is: $MY_GITHUB_PAT
(already in your clipboard)
```

### Why This Matters

Without `llm-secrets`, every approach leaks your token:
- Put it in `.bashrc`? AI tools see file diffs.
- Put it in `.env`? AI tools grep and read files.
- Type it in the chat? It's in the conversation history.
- Use the `!` prefix? Output still shows up.

With `llm-secrets`:
- Secrets live in `~/.secrets` (bash, chmod 600) or `~/.secrets.ps1` (PowerShell, ACL'd to the user) - never monitored
- Your shell sources it on startup - standard env vars
- AI tools can use `$MY_GITHUB_PAT` in commands without seeing the value
- Hidden input - characters never display (bash uses silent read; PS uses SecureString with `*` per character)
- Copies the variable reference to your clipboard on save (or tells you it couldn't on headless / minimal-install systems)

### Install (standalone)

If you only want `llm-secrets`, no doctor framework needed:

**Bash (Linux/macOS/WSL/Git Bash)**

```bash
mkdir -p ~/.local/bin
curl -o ~/.local/bin/llm-secrets https://raw.githubusercontent.com/equityhammer/thedoc/main/llm-secrets
chmod +x ~/.local/bin/llm-secrets
echo '[ -f "$HOME/.secrets" ] && source "$HOME/.secrets"' >> ~/.bashrc
source ~/.bashrc
```

**PowerShell 7 (Windows)**

```powershell
# Download
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/equityhammer/thedoc/main/llm-secrets.ps1" -OutFile "$HOME\llm-secrets.ps1"

# Add to your profile (run: notepad $PROFILE)
if (Test-Path "$HOME\.secrets.ps1") { try { . "$HOME\.secrets.ps1" } catch { Write-Host "~/.secrets.ps1: $($_.Exception.Message)" -ForegroundColor Yellow } }
function llm-secrets { & "$HOME\llm-secrets.ps1" @args }

# Reload
. $PROFILE
```

### llm-secrets Usage

```
llm-secrets                       # Interactive (prompts for everything)
llm-secrets set                   # Same as above
llm-secrets set 'my github pat'  # Auto-converts to MY_GITHUB_PAT
llm-secrets set MY_VAR_NAME      # Exact name also works
llm-secrets my openai key         # Shorthand - skips "set" (bash port only)
llm-secrets list                  # List secret names (not values)
llm-secrets remove VAR_NAME      # Remove a secret
llm-secrets help                  # Show help
```

**Scripted use** (CI, dotfiles bootstrap, automation): pipe the value
into `set` so the prompt doesn't block waiting for keyboard input.
Both bash and PowerShell ports accept piped stdin:

```bash
echo "$GITHUB_TOKEN" | llm-secrets set GITHUB_TOKEN          # bash
```

```powershell
"$env:GITHUB_TOKEN" | llm-secrets.ps1 set GITHUB_TOKEN       # PowerShell
```

## Included Templates

The framework ships with battle-tested templates in `common/templates/`:

- **tmux.conf** - Windows/WSL2-friendly config with OSC 52 clipboard, working scroll, drag-to-copy, right-click paste, double/triple-click selection, and a cheat sheet status bar
- **generate-cc-aliases** - Auto-generates project shortcuts (`cc-*`, `cn-*`, `dcc-*`, `dcn-*`) for every folder in your projects directory
- **tmux-session-shortcuts.sh** - Jump to any tmux session by typing `t<name>` (`twebsite`, `tlogo`), matched on a case-insensitive prefix and created on the fly if it doesn't exist yet. No per-session alias to declare
- **ssh-config-examples** - SSH shortcut patterns for quick access to remote machines

## Architecture

```
thedoc/                          # The framework (this repo)
  bootstrap.sh                   # One-liner installer (bash)
  bootstrap.ps1                  # One-liner installer (PowerShell)
  thedoc                         # Main command (bash)
  thedoc.ps1                     # Main command (PowerShell)
  thedoc.cmd                     # cmd.exe shim for thedoc.ps1
  setup.sh                       # Interactive setup wizard (bash)
  setup.ps1                      # Interactive setup wizard (PowerShell)
  llm-secrets                    # Secret storage (bash)
  llm-secrets.ps1                # Secret storage (PowerShell)
  doctors/
    claude-code/DOCTOR.md        # Claude Code doctor brain
    openclaw/DOCTOR.md           # OpenClaw doctor brain
    gemini/DOCTOR.md             # Stub
  engines/
    claude-code.{sh,ps1}         # Launches Claude Code (cross-platform)
    openclaw.{sh,ps1}            # Stub
    gemini.{sh,ps1}              # Stub
  common/
    templates/                   # Config templates
    skills/                      # Reusable skills

~/GitHub/claude-code-doctor/     # An instance (created by setup)
~/GitHub/openclaw-doctor/        # Another instance
```

The framework and instances are separate. You `thedoc update` the framework, your instances pick up updates through DOCTOR.md instructions. No conflicts.

## Why "The Doc"?

Named after the Emergency Medical Hologram from Star Trek: Voyager - an AI doctor activated in emergencies to diagnose and fix problems. Brilliant, occasionally exasperated, and always gets the job done.

Never seen it? [This clip explains everything.](https://youtu.be/Rn1QP9oL5V0?si=0PWFr6UhoIO_APdt)

## Contributing

Want to add support for a new doctor type or engine? The framework is designed to be extended:

- **New doctor type:** Add a `DOCTOR.md` to `doctors/<your-type>/`
- **New engine:** Add a launcher script to `engines/<your-engine>.{sh,ps1}`
- **New templates:** Add to `common/templates/`

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on portability rules
(this code runs on macOS too - no GNU-only flags), the stub-marker
convention, and how to add a smoke test scenario.

PRs welcome.

## License

[MIT](LICENSE)
