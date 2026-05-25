[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## README / docs conventions

Every app has at minimum:

- **`README.md`**: 1-2 paragraph what-this-is, tech stack list, build/run commands, project layout (sometimes ASCII tree).
- **`CLAUDE.md`**: Project overview, project status, build/run commands, tech stack as bullets, architecture summary, data model, key impl details, "What is NOT in MVP" section.
- **`SPEC.md`** (non-trivial apps): vision, app flow per screen, "Alternatives considered and rejected" section, "Do NOT copy" list when referencing other apps as templates.
- **`REFACTOR.md`** (mature apps): "What's working", "What's broken (root causes)", phased refactor plan with Files Touched / Risk table, "What NOT to change", "Critical Architecture Rules (Learned the Hard Way)".

Tone: terse, technical, second-person occasional.

### `dist/state_persistence_audit.md` for apps with multiple persistence wrappers

Once an app accumulates 3+ `*Persistence` wrappers (per the [Persistence patterns] section), add `dist/state_persistence_audit.md` as a catalogue of every stateful singleton + its persistence story. The audit's value is twofold:

1. **A new reader can answer "what survives process death today?" by reading the top of this file** — no SPEC.md spelunking, no grep for `SharedPreferences` across the codebase.
2. **A future build that regresses persistence is visible to a reviewer** — the catalogue table's "before vs. after" diff makes the change explicit instead of silent.

Recommended structure:

```markdown
# State persistence audit

## Catalogue: stateful singletons + persistence story

Legend: 🟢 persisted (survives process death) · 🔴 in-memory only (lost) · 🟡 transient-by-design

| Singleton | State held | Persistence wrapper | Storage | Originating | Status |
|---|---|---|---|---|---|
| `ChecklistRepository` | `Map<String, ChecklistStatus>` | `ChecklistStatusPersistence` | SharedPreferences | DEBT-14 (v1.0.82) | 🟢 |
| ...one row per singleton... |

## What the user loses on process death (today)
**Surviving:** ...
**LOST:** ...
**User-visible UX impact:** ...

## Upgrade path for in-memory-only singletons
(copy-paste-ready *Persistence template + per-singleton upgrade plan)

## Cross-cutting edge cases
(how destructive ops interact with siblings — Reset wipes X but not Y, etc.)

## Maintenance
(when to update this audit)
```

A Mermaid `sequenceDiagram` of the canonical hydrate-on-startup chain (the three-LaunchedEffect-with-hydrated-gate template) goes well in this file too — readers learn the pattern by example.

Originating change: Transfer Checklist `v1.0.89` (DOC-11). The audit doc was created at exactly the inflection point where adding 1 more `*Persistence` wrapper made the manual-tracking story break — `ChecklistStatusPersistence` + `BubblePositionPersistence` + `PanicModePersistence` + `OnboardingTipsPersistence` was already 4 wrappers + people were forgetting which singletons were persisted vs. transient. The catalogue ended the confusion + surfaced the gap (`ActiveAppList` + `SkipReasonRepository` unpersisted) as queueable work, which then shipped in Sprint 28 as PERSIST-01 + PERSIST-02.

---

