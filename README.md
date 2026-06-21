# harness-gap-analyzer

> Continuous harness gap analyzer for Claude Code — compare your local config against Anthropic + community best practices, and surface what's missing.

![status](https://img.shields.io/badge/status-alpha-orange)

## TL;DR

Your Claude Code harness (settings.json, hooks, permissions, skills, rules) drifts over time. Meanwhile, Anthropic and the community keep publishing new best practices. Nobody notices the gap until something breaks. This marketplace ships a single plugin — `harness-gap-analyzer` — that inventories your local harness, fetches canonical best-practice sources, and renders a side-by-side gap report with concrete fix suggestions.

Install:

```
/plugin marketplace add shurijoc/harness-gap-analyzer
/plugin install harness-gap-analyzer@harness-gap-analyzer
```

## What's inside this marketplace

| Plugin | Description |
|---|---|
| `harness-gap-analyzer` | Audit your Claude Code harness against canonical best practices. Inventories local config, fetches Anthropic + community sources, and renders an HTML gap report. |

## Why

- Harness configs drift. You add a hook for one project, forget to propagate it, and three months later the rule is wrong everywhere.
- Best practices update. Anthropic ships new SDK features, the community publishes new rubrics, and your `settings.json` keeps using the 2024 shape.
- No one notices. There's no CI for "is your harness still aligned with what Claude Code currently recommends?"
- Most existing tools audit *one* side — either your local config or the upstream docs. This plugin audits **both** and shows the delta.

The goal is a single skill you can run weekly: "where is my harness lagging, and what's the smallest patch to close the gap?"

## How it works

Three steps, run by the `harness-gap` skill inside the plugin:

1. **Inventory** — walk the local repo + `~/.claude/` and collect every config surface that matters: `settings.json`, `settings.local.json`, hooks, permissions, skills (`.claude/skills/`), rules (`.claude/rules/`), CLAUDE.md files. Output: a normalized JSON snapshot of what your harness *currently* does.
2. **Fetch** — pull canonical best-practice sources defined in `sources/anthropic.yaml` and `sources/community.yaml`. Cached locally so re-runs are cheap. Output: a rubric of what your harness *should* do, with citations.
3. **Render** — diff inventory vs. rubric using `rubric/claude-code.yaml`, then render a self-contained HTML report (no JS, no external CSS) into `tmp/harness-gap-report.html`. Each gap has a severity, a citation to the source, and a copy-pasteable fix.

## Install

From any Claude Code session:

```
/plugin marketplace add shurijoc/harness-gap-analyzer
/plugin install harness-gap-analyzer@harness-gap-analyzer
```

If you cloned this repo locally and want to install from disk:

```
/plugin marketplace add /absolute/path/to/harness-gap-analyzer
/plugin install harness-gap-analyzer@harness-gap-analyzer
```

After install, invoke the skill:

```
/harness-gap
```

The report opens in your browser when rendering completes.

## Local development

Iterate without going through the marketplace install flow:

```
claude --plugin-dir ./plugins/harness-gap-analyzer
```

This loads the plugin directly from the working tree, so edits to `skills/harness-gap/SKILL.md`, `scripts/*`, `rubric/*.yaml`, and `templates/report.html` take effect on the next invocation.

Before submitting a PR or publishing a new version, validate the plugin manifest:

```
claude plugin validate ./plugins/harness-gap-analyzer
```

This checks the SKILL.md frontmatter, the rubric YAML schema, and the script entry points referenced by the skill.

## Contributing

PRs welcome, especially:

- **New rubric items** — open `plugins/harness-gap-analyzer/skills/harness-gap/rubric/claude-code.yaml` and add a check with a citation. Keep items atomic (one config surface per item) and include a `fix` field with a concrete patch.
- **New sources** — add an entry to `sources/anthropic.yaml` (official docs) or `sources/community.yaml` (blog posts, well-maintained repos). Each source needs a `url`, `fetched_at` placeholder, and a short `summary`.
- **Better rendering** — `templates/report.html` is intentionally simple. Improvements that keep it self-contained (no JS, no external assets) are very welcome.

Before opening a PR, run `claude plugin validate ./plugins/harness-gap-analyzer` and make sure `python3 -c "import json; json.load(open('.claude-plugin/marketplace.json'))"` passes.

## Submitting to claude-community

Once this plugin stabilizes, the plan is to submit it to the official Claude plugin directory: https://platform.claude.com/plugins/submit

If you want to fork and submit your own variant, that's fine — just change the `name` field in `.claude-plugin/marketplace.json` and `plugins/harness-gap-analyzer/.claude-plugin/plugin.json` to avoid a name collision.

## License

MIT. See [LICENSE](./LICENSE).
