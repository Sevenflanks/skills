# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repo root.
- `docs/adr/` entries that touch the area about to be changed.

If either location does not exist, proceed silently. `/domain-modeling` creates domain documentation lazily when terms or decisions are resolved.

## File structure

This repo uses a single context:

```text
/
|-- CONTEXT.md
|-- docs/
|   `-- adr/
`-- skills/
```

## Use the glossary's vocabulary

When output names a domain concept in a spec, issue, test, review, or skill, use the term defined in `CONTEXT.md`. Do not drift to synonyms the glossary explicitly avoids.

If a needed concept is absent, reconsider whether the work is inventing language or whether `/domain-modeling` should record a real gap.

## Flag ADR conflicts

If output contradicts an existing ADR, surface the conflict instead of silently overriding it.
