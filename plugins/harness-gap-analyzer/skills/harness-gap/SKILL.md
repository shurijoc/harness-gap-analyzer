---
name: harness-gap
description: |
  Analyze your Claude Code harness (rules / skills / hooks / permissions / agents / MCP)
  against canonical best practices from Anthropic, OpenAI, Cursor, Cline, and Devin docs.
  Produces a self-contained HTML report listing adopted / missing / not-needed dimensions,
  triggered gotchas (deprecated settings, oversized CLAUDE.md, ...), and the diff of
  upstream doc updates since the last run.

  Trigger phrases (en):
  - "/harness-gap"
  - "/harness-gap audit"
  - "/harness-gap update-sources"
  - "audit my harness"
  - "compare against Claude Code best practices"
  - "find harness gaps"

  トリガー語 (ja):
  - "/harness-gap"
  - "harness の gap を分析"
  - "claude code best practices と比較"
  - "ベストプラクティスから抜けがあるか見て"
argument-hint: "[audit|update-sources|analyze]"
allowed-tools: Bash Read Write WebFetch
---

# harness-gap (Claude Code Harness Gap Analyzer)

Japanese version: [SKILL.ja.md](./SKILL.ja.md)

Cross-check your Claude Code harness against the latest official / community best practices
and classify each dimension as `adopted / missing / not-needed / unknown`. Output is a
single self-contained HTML file.

Goal: **mechanically eliminate harness blind spots**. Instead of relying on memory or gut,
use an externally-sourced rubric to surface "this is still missing" and "this is now deprecated".

## Purpose

The Claude Code harness (rules / skills / hooks / permissions / agents / MCP / settings)
evolves quickly across official docs and community knowledge — tracking it by hand always
leaks. This skill **inventories the harness read-only**, **fetches external docs**, cross-checks
them against a rubric, and **emits an HTML gap report**. Remediation is proposal-only; the
harness itself is never modified.

## Design

A three-stage pipeline:

1. **inventory** — scan local `~/.claude/` and the current repo's `.claude/`, emit JSON
2. **fetch sources** — WebFetch Anthropic official + community docs into a cache
3. **render report** — cross-check rubric YAML, inventory, and sources, then generate HTML

Each stage is an independent script. `analyze` runs 1+3 only, `audit` runs 1+2+3,
`update-sources` runs 2 only.

## Invocation

| Form | Action | Cost |
|---|---|---|
| `/harness-gap` (=analyze) | Regenerate report from existing cache + inventory | Fast (10s) |
| `/harness-gap audit` | Full run including fetch | Slow (1-3 min) |
| `/harness-gap update-sources` | Fetch sources only; no report | Medium (1 min) |

Behavior is switched by argument. Default is `analyze`.

## Steps

### Step 1: inventory

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/inventory.sh
```

Scan targets:
- `~/.claude/CLAUDE.md`, `~/.claude/rules/`, `~/.claude/skills/`, `~/.claude/settings.json`
- `$(git rev-parse --show-toplevel)/CLAUDE.md`, `<repo>/.claude/`
- Installed plugins (`~/.claude/plugins/`)
- MCP config (`~/.claude/mcp.json`, etc.)

Output: `${CLAUDE_PLUGIN_DATA}/inventory-$(date +%Y%m%d).json`

### Step 2: fetch sources (audit only)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/fetch-sources.sh
```

WebFetch URLs listed in `sources/anthropic.yaml` and `sources/community.yaml`, updating
only the diff based on ETag / Last-Modified. Cache lives under `${CLAUDE_PLUGIN_DATA}/cache/`.

`analyze` mode skips Step 2 and uses the existing cache.

### Step 3: render report

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/render-report.py \
  --inventory ${CLAUDE_PLUGIN_DATA}/inventory-$(date +%Y%m%d).json \
  --cache ${CLAUDE_PLUGIN_DATA}/cache \
  --rubric ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/rubric/claude-code.yaml \
  --template ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/templates/report.html \
  --out tmp/harness-gap-$(date +%Y%m%d).html
```

If `tmp/` does not exist in cwd, fall back to `${CLAUDE_PLUGIN_DATA}/harness-gap-$(date +%Y%m%d).html`.

### Step 4: final report and open

Emit the following and `open` the HTML:

```
=== STATUS ===
Report: tmp/harness-gap-YYYYMMDD.html
Adopted: N / Missing (required): M / Missing (recommended): K / Not needed: L / Unknown: U
Next action: harness-ify missing-required items via /cc-fb
```

## I/O paths

| Kind | Path |
|---|---|
| Inventory | `${CLAUDE_PLUGIN_DATA}/inventory-$(date +%Y%m%d).json` |
| Source cache | `${CLAUDE_PLUGIN_DATA}/cache/` |
| Cache index (ETag, etc.) | `${CLAUDE_PLUGIN_DATA}/cache/index.json` |
| Report (primary) | `tmp/harness-gap-$(date +%Y%m%d).html` |
| Report (fallback) | `${CLAUDE_PLUGIN_DATA}/harness-gap-$(date +%Y%m%d).html` |
| Rubric | `${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/rubric/claude-code.yaml` |
| Sources | `${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/sources/*.yaml` |

## Rubric semantics

Each dimension in the report is classified with one of five labels:

| Label | Meaning | UI color |
|---|---|---|
| `adopted` | Adopted, with path to the relevant file / setting | green |
| `missing-required` | Item the official docs deem required / strongly recommended, but absent | red |
| `missing-recommended` | Nice-to-have, commonly adopted | amber |
| `not-needed` | Explicitly marked as unnecessary for this operation | gray |
| `unknown` | Cannot be determined from inventory; manual review required | blue |

`not-needed` can be marked per-item via `~/.claude/.harness-gap-overrides.yaml`.

### Gotcha detection

Separately from the rubric, the following antipatterns are listed as triggered gotchas:

- `CLAUDE.md` over 500 lines → recommend splitting
- A `SKILL.md` over 500 lines → recommend splitting
- Deprecated keys in `settings.json` (old `mcpServers` schema, etc.)
- Overly broad globs in `permissions.allow` (`**`, lone `*`)
- Duplicate `PreToolUse` matchers in hooks
- Skill descriptions missing trigger phrases

## Sources

Managed under `sources/anthropic.yaml` and `sources/community.yaml`. Examples:

| Category | URL example |
|---|---|
| Anthropic official docs | `https://docs.claude.com/en/docs/claude-code/overview` |
| Anthropic engineering blog | `https://www.anthropic.com/engineering/claude-code-best-practices` |
| Anthropic GitHub | `https://github.com/anthropics/claude-code` |
| Cursor docs | `https://docs.cursor.com/` |
| Cline docs | `https://docs.cline.bot/` |
| Devin docs | `https://docs.devin.ai/` |
| AGENTS.md spec | `https://agents.md/` |
| OpenAI Codex / Aider, etc. community | listed in community.yaml |

To add a source, append the URL and `category` to the YAML. The report lays out panels
per category.

## Scheduled use

Combine with the `/schedule` skill to fetch daily and audit weekly:

```bash
# Pull source updates every morning at 08:00 JST so the diff accumulates
/schedule "0 8 * * *" "/harness-gap update-sources"

# Full audit + report every Monday at 09:00 JST
/schedule "0 9 * * MON" "/harness-gap audit"
```

The update diff appears in the report's "What changed since last run" panel at the top.
Settings that go deprecated in official docs surface here early.

## Extensions

### `--local-insights <dir>` adds your own rubric entries

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/render-report.py \
  --local-insights ~/notes/cwc-claude-tips/ \
  ...
```

Markdown files under `<dir>` are appended to the rubric based on their frontmatter
`dimension:` `category:` `priority:`. Team operations docs / conference talk notes /
personal operations notes can all be rubric-ized.

### Suppressing individual dimensions

`~/.claude/.harness-gap-overrides.yaml`:

```yaml
not_needed:
  - dimension: mcp.github
    reason: "gh CLI is sufficient for GitHub"
  - dimension: hooks.notification
    reason: "A separate daemon handles notifications"
```

These appear in the `not-needed` column with the marked reason and are dropped from
`missing-required`.

## Constraints

- Harness is **read-only**. Neither `~/.claude/` nor `<repo>/.claude/` are modified
- Writes only to `${CLAUDE_PLUGIN_DATA}/` and cwd's `tmp/`
- Network access is limited to WebFetch against source URLs — inventory / harness contents
  are never sent outside
- Post-detection remediation is **proposal only**. Actual harness changes go through `/cc-fb`
- Official docs / community docs are treated as the latest best practice but with no
  guarantee. Final judgment stays with the human
