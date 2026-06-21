# Harness Gap Analyzer

Find the gaps in your Claude Code harness before they bite you.

A skill plugin that inventories your local Claude Code setup (rules, skills, hooks, permissions, agents, MCP servers) and compares it against canonical best practices from Anthropic and the wider agent-coding community (Cursor, Cline, Devin, Aider, OpenAI, AGENTS.md). Output is a single self-contained HTML report you can keep open while you fix things.

## What it does

- Walks `~/.claude/` and the current repo's `.claude/` to enumerate every rule file, skill, hook, permission, agent, and MCP entry
- Fetches the latest official docs (Anthropic Claude Code docs, engineering blog, GitHub README) and a curated list of community sources
- Diffs the harness against a YAML-driven rubric of best-practice dimensions
- Surfaces "gotchas" the docs flag as anti-patterns (oversized `CLAUDE.md`, deprecated settings keys, over-broad permission globs, missing trigger phrases in skill descriptions, ...)
- Tracks what changed in upstream docs since the last run so you notice deprecations early
- Renders a single self-contained HTML report (no external CSS / JS) and opens it

It does not edit your harness. It only tells you what's missing.

## Install

```
/plugin marketplace add shurijoc/harness-gap-analyzer
/plugin install harness-gap-analyzer@harness-gap-analyzer
```

After install, restart Claude Code or run `/plugin reload` so the `harness-gap` skill is picked up.

## Usage

| Command | What it does |
|---|---|
| `/harness-gap` | Re-render the report using the existing source cache and a fresh inventory. Fast (~10s). |
| `/harness-gap audit` | Full run: refresh inventory, fetch all sources, render report. Slower (1-3 min). |
| `/harness-gap update-sources` | Only refresh the source cache. No report. Good for nightly cron. |

Trigger phrases like "harness の gap を分析", "claude code best practices と比較", "ベストプラクティスから抜けがあるか見て" also fire the skill.

## What gets analyzed

The rubric is split into 16 categories. Each rubric entry is checked against the inventory and labeled `adopted` / `missing-required` / `missing-recommended` / `not-needed` / `unknown`.

| # | Category | One-line check |
|---|---|---|
| 1 | `claude_md.global` | `~/.claude/CLAUDE.md` exists, under 500 lines, has style guidance |
| 2 | `claude_md.repo` | repo `CLAUDE.md` exists and references project specifics |
| 3 | `rules.split` | global rules are split into `~/.claude/rules/*.md` per topic, not one mega-file |
| 4 | `skills.discipline` | each `SKILL.md` has frontmatter, trigger phrases, under 500 lines |
| 5 | `skills.scripts` | skills run heavy work in `scripts/` not inline in SKILL.md |
| 6 | `hooks.pretooluse` | `PreToolUse` hooks present for destructive ops |
| 7 | `hooks.posttooluse` | `PostToolUse` hooks for lint / fmt after edits |
| 8 | `hooks.stop` | `Stop` hook present for session-end notifications |
| 9 | `permissions.allowlist` | explicit allow rules instead of prompting on every npm/git/gh call |
| 10 | `permissions.deny` | dangerous commands explicitly denied (`rm -rf /`, force push to main) |
| 11 | `agents.subagents` | custom subagents defined with `model:` pinned |
| 12 | `mcp.servers` | MCP server config present and not using deprecated schema |
| 13 | `mcp.scope` | MCP scope (`local` / `project` / `user`) chosen deliberately |
| 14 | `output_styles` | output style configured if user prefers terse / structured replies |
| 15 | `statusline` | `statusLine` configured (model, branch, token budget, ...) |
| 16 | `memory.discipline` | `MEMORY.md` exists, not bloated, no secrets |

Override any entry to `not-needed` via `~/.claude/.harness-gap-overrides.yaml`.

## What gets fetched

Source list is YAML-driven in `skills/harness-gap/sources/`. Add entries by editing the YAMLs and re-running `/harness-gap update-sources`.

| Source group | Examples |
|---|---|
| Anthropic official docs | `docs.claude.com/en/docs/claude-code/*` |
| Anthropic engineering blog | `anthropic.com/engineering/claude-code-best-practices` |
| Anthropic GitHub | `github.com/anthropics/claude-code` README + RELEASE_NOTES |
| Agent-coding peers | Cursor docs, Cline docs, Devin docs, Aider docs |
| OpenAI / spec docs | Codex CLI docs, `agents.md` spec |
| Community curation | hand-picked blog posts / talks linked from `community.yaml` |

Cache uses ETag / Last-Modified so repeat runs are cheap.

## Output

A single HTML at `tmp/harness-gap-YYYYMMDD.html` (or `${CLAUDE_PLUGIN_DATA}/...` if no `tmp/`). It contains:

- **Summary stats** — counts per label, latest run timestamp
- **What changed since last run** — diff of upstream docs (new / removed / updated URLs)
- **Adopted** — green table of harness items that match a rubric dimension, with file paths
- **Missing (required)** — red table with the dimension, rubric source URL, and a suggested next step
- **Missing (recommended)** — amber table, same shape as required
- **Not needed** — gray table with the user-provided reason
- **Unknown** — blue table of dimensions the inventory could not auto-judge
- **Triggered gotchas** — separate panel for anti-patterns (oversized files, deprecated keys, ...)
- **Source index** — per-source last-fetched timestamp and any fetch errors

All inline. No CDN. Open it offline.

## Continuous mode

Combine with the `/schedule` skill:

```
/schedule "0 8 * * *"   "/harness-gap update-sources"
/schedule "0 9 * * MON" "/harness-gap audit"
```

Nightly source refresh + weekly full audit. The "What changed since last run" panel turns into a passive notification stream for upstream doc updates.

## Custom insights

If you have your own internal harness notes (CWC slides, team conventions, accumulated postmortems), point the renderer at them:

```
/harness-gap audit --local-insights ~/notes/cwc-claude-tips/
```

Each `*.md` in that dir with frontmatter

```yaml
---
dimension: rules.terseness
category: rules
priority: required
---
```

is merged into the rubric for that run. Lets you grow your own rubric without forking the plugin.

## What it does NOT do

- Does not modify your harness. No edits to `~/.claude/`, repo `.claude/`, or `settings.json`. Apply fixes manually (or via `/cc-fb`).
- Does not exfiltrate your harness. Only outbound traffic is `WebFetch` against the source URLs declared in `sources/*.yaml`. Your `CLAUDE.md`, hooks, and permissions stay local.
- Does not auto-grade quality. It checks structural / presence-based dimensions and surfaces docs to read. Final judgment is yours.
- Does not replace `claude doctor` or `claude --version` checks. It is complementary.

## License

MIT. See `LICENSE`.

## Contributing

Two easy ways to contribute without writing code:

1. **New rubric dimension** — open a PR adding an entry to `skills/harness-gap/rubric/claude-code.yaml`. Include the source URL that motivates it.
2. **New source** — open a PR adding a URL + category to `skills/harness-gap/sources/anthropic.yaml` or `community.yaml`.

Code contributions for new gotcha detectors are welcome too. Each detector is a small function in `scripts/render-report.py`; keep them pure and add a test fixture under `tests/`.
