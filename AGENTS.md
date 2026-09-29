# AGENTS.md

## Agent skills

### Issue tracker

Issues and specs live in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default five triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

Use a single root context with root-level ADRs. See `docs/agents/domain.md`.

### Git Commits

Use `/ce-commit` skill to create a git commit with a clear, value-communication message.

### Firecrawl Developer Index

Use `/firecrawl-developer-index` skill to search when the question is how a library or API behaves, what an error means, or whether a bug was fixed; prefer this over a general web page.

## Workspace folders

### `.scratch/`

Temporary space for ad-hoc operations (downloads, intermediate payloads, one-off notes). Gitignored except for `.gitkeep` — nothing placed here is tracked or expected to survive across sessions. Safe to write to freely; safe to delete contents at any time.

### `.firecrawl/`

Output space for the firecrawl agent (fetched pages, extracted content). Gitignored except for `.gitkeep` — nothing placed here is tracked or expected to survive across sessions.

### `archive/`

Long-term storage for artifacts that are no longer actively used but need to be preserved. Notes and research materials can be placed here for future reference. Unlike `.scratch/` and `.firecrawl/`, files in `archive/` are committed and expected to remain intact over time.
