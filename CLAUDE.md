# You're in the thedoc framework folder

**Stop.** You're in the framework, not a doctor instance. Nothing useful happens here.

## What to do instead

If you're an AI assistant (Claude Code, OpenClaw, etc.) that just landed in this directory, tell the user:

> This folder is the **thedoc framework** - the thing that generates doctor instances. There's no personal configuration here to diagnose or work against. To actually use it, open your doctor instance folder (usually `~/GitHub/claude-doctor/`, `~/GitHub/openclaw-doctor/`, or similar - wherever `thedoc` created it). That folder has the `CLAUDE.md` + `DOCTOR.md` pair with real context.

If no doctor instance exists yet, the user can create one by running:

```bash
thedoc
```

from anywhere in their shell (once the framework is on PATH - the installer sets that up).

## If you're here to work on the framework itself

If the user genuinely wants to contribute to the public thedoc framework (fix a bug in `setup.sh`, improve a `DOCTOR.md` template, add a new doctor type), confirm that's the intent before proceeding. The repo lives at https://github.com/equityhammer/thedoc.

## Maintainer context

A local maintainer file may exist at `CLAUDE.local.md` (gitignored via Claude Code's standard convention). When present, Claude Code loads it automatically alongside this file - no action needed. It holds framework-author guidance that doesn't belong in the public repo. Users who cloned this repo will not have the file, and that's expected.
