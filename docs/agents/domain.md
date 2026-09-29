# Domain Docs

This is a single-context repo. Engineering skills read domain documentation when exploring the codebase.

## Before exploring

- Read root `CONTEXT.md` when it exists.
- Read relevant decisions in `docs/adr/` when that directory exists.

Proceed when either is absent. `/domain-modeling` creates these documents when terms or decisions are resolved.

## Layout

- `CONTEXT.md`: the repository's domain vocabulary.
- `docs/adr/`: decisions that apply to the repository.

Use the vocabulary in `CONTEXT.md` for issues, proposals, hypotheses, and tests. Surface any conflict with an existing ADR explicitly.
