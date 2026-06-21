---
name: harness-gap
description: |
  Analyze your Claude Code harness (rules / skills / hooks / permissions / agents / MCP)
  against canonical best practices from Anthropic, OpenAI, Cursor, Cline, Devin docs.
  Produces a self-contained HTML report listing adopted / missing / not-needed dimensions,
  triggered gotchas (deprecated settings, oversized CLAUDE.md, ...), and the diff of
  upstream doc updates since the last run.

  Trigger phrases:
  - "/harness-gap"
  - "/harness-gap audit"
  - "/harness-gap update-sources"
  - "harness の gap を分析"
  - "claude code best practices と比較"
  - "ベストプラクティスから抜けがあるか見て"
argument-hint: "[audit|update-sources|analyze]"
allowed-tools: Bash Read Write WebFetch
---

# harness-gap (Claude Code Harness Gap Analyzer)

自分の Claude Code harness を、公式 / community の最新ベストプラクティスと突き合わせて
「採用済み / 抜け / 不要 / 未確認」に分類する。出力は self-contained HTML 1 枚。

ゴール = **「harness の盲点を機械的に潰す」**。memory や勘ではなく、外部 doc 由来の rubric で
「ここがまだ無い」「これはもう deprecated」を炙り出す。

## 目的

Claude Code の harness（rules / skills / hooks / permissions / agents / MCP / settings）は
公式 doc と community 知見の更新が速く、手で追うと必ず漏れる。
このスキルは harness を **read-only で inventory** し、**外部 doc を fetch** して rubric と突き合わせ、
**HTML で gap report** を出す。改修は提案までで、harness 自体は触らない。

## 設計

3 段パイプライン:

1. **inventory** — ローカルの `~/.claude/` と現在 repo の `.claude/` を走査して JSON 化
2. **fetch sources** — Anthropic 公式 + community の doc を WebFetch して cache に格納
3. **render report** — rubric YAML と inventory と sources を突き合わせて HTML 生成

各段は独立スクリプト。`analyze` は 1+3 のみ、`audit` は 1+2+3、`update-sources` は 2 のみ。

## 起動形態

| 呼び方 | やること | 所要 |
|---|---|---|
| `/harness-gap` (=analyze) | 既存の cache + inventory で report 再生成 | 速い (10s) |
| `/harness-gap audit` | fetch も含めたフルラン | 遅い (1-3 min) |
| `/harness-gap update-sources` | source の fetch のみ。report は出さない | 中 (1 min) |

引数で挙動を切り替え。デフォルトは `analyze`。

## 手順

### Step 1: inventory

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/inventory.sh
```

走査対象:
- `~/.claude/CLAUDE.md`、`~/.claude/rules/`、`~/.claude/skills/`、`~/.claude/settings.json`
- `$(git rev-parse --show-toplevel)/CLAUDE.md`、`<repo>/.claude/`
- インストール済み plugin（`~/.claude/plugins/`）
- MCP 設定（`~/.claude/mcp.json` など）

出力: `${CLAUDE_PLUGIN_DATA}/inventory-$(date +%Y%m%d).json`

### Step 2: fetch sources (audit のみ)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/fetch-sources.sh
```

`sources/anthropic.yaml` と `sources/community.yaml` に列挙された URL を WebFetch で取り、
ETag / Last-Modified を見て差分のみ更新。cache は `${CLAUDE_PLUGIN_DATA}/cache/` 配下。

`analyze` モードでは Step 2 を skip し、既存 cache を使う。

### Step 3: render report

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/render-report.py \
  --inventory ${CLAUDE_PLUGIN_DATA}/inventory-$(date +%Y%m%d).json \
  --cache ${CLAUDE_PLUGIN_DATA}/cache \
  --rubric ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/rubric/claude-code.yaml \
  --template ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/templates/report.html \
  --out tmp/harness-gap-$(date +%Y%m%d).html
```

cwd に `tmp/` が無ければ `${CLAUDE_PLUGIN_DATA}/harness-gap-$(date +%Y%m%d).html` にフォールバック。

### Step 4: 末尾報告と open

最後に以下を出力し、HTML を `open` する:

```
=== STATUS ===
Report: tmp/harness-gap-YYYYMMDD.html
採用済み: N / 抜け(必須): M / 抜け(推奨): K / 不要: L / 未確認: U
次アクション: 抜け(必須) を /cc-fb で harness 化
```

## 入出力 path

| 種類 | path |
|---|---|
| Inventory | `${CLAUDE_PLUGIN_DATA}/inventory-$(date +%Y%m%d).json` |
| Source cache | `${CLAUDE_PLUGIN_DATA}/cache/` |
| Cache index (ETag 等) | `${CLAUDE_PLUGIN_DATA}/cache/index.json` |
| Report (primary) | `tmp/harness-gap-$(date +%Y%m%d).html` |
| Report (fallback) | `${CLAUDE_PLUGIN_DATA}/harness-gap-$(date +%Y%m%d).html` |
| Rubric | `${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/rubric/claude-code.yaml` |
| Sources | `${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/sources/*.yaml` |

## rubric の見方

report の各 dimension は 5 つのラベルで分類される:

| ラベル | 意味 | UI 色 |
|---|---|---|
| `adopted` | 採用済み。該当ファイル / 設定の path 付き | green |
| `missing-required` | 公式が「必須 / 強く推奨」している項目で抜けている | red |
| `missing-recommended` | あると便利、入れている人が多い | amber |
| `not-needed` | 自分の運用には不要と明示的にマークしたもの | gray |
| `unknown` | inventory からは判定不能。手動確認が要る | blue |

`not-needed` は `~/.claude/.harness-gap-overrides.yaml` で項目ごとにマークできる。

### gotcha 検知

rubric とは別に、以下の「アンチパターン」を triggered gotchas として並べる:

- `CLAUDE.md` が 500 行超 → 分割推奨
- skill SKILL.md が 500 行超 → 分割推奨
- `settings.json` に deprecated key（旧 `mcpServers` 配下の旧 schema 等）
- `permissions.allow` に過剰広範な glob（`**`, `*` 単独）
- hooks に `PreToolUse` 同一 matcher の重複
- skill description に trigger phrase が無い

## 情報源

`sources/anthropic.yaml` と `sources/community.yaml` で管理。代表例:

| カテゴリ | URL 例 |
|---|---|
| Anthropic 公式 doc | `https://docs.claude.com/en/docs/claude-code/overview` |
| Anthropic engineering blog | `https://www.anthropic.com/engineering/claude-code-best-practices` |
| Anthropic GitHub | `https://github.com/anthropics/claude-code` |
| Cursor docs | `https://docs.cursor.com/` |
| Cline docs | `https://docs.cline.bot/` |
| Devin docs | `https://docs.devin.ai/` |
| AGENTS.md spec | `https://agents.md/` |
| OpenAI Codex / Aider 等 community | community.yaml に列挙 |

source を増やしたい場合は yaml に URL と `category` を追加するだけ。
report 上は category 別 panel で並ぶ。

## 定期実行

`/schedule` skill と組み合わせて、毎日 fetch / 週 1 audit を回す:

```bash
# 毎朝 08:00 JST に source 更新だけ走らせて差分を貯める
/schedule "0 8 * * *" "/harness-gap update-sources"

# 毎週月曜 09:00 JST に full audit + report 生成
/schedule "0 9 * * MON" "/harness-gap audit"
```

更新差分は report 上部の "What changed since last run" panel に出る。
公式 doc 側で deprecated 化された設定がここで早期検知される想定。

## 拡張

### `--local-insights <dir>` で自前の rubric を足す

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/scripts/render-report.py \
  --local-insights ~/notes/cwc-claude-tips/ \
  ...
```

`<dir>` 配下の `*.md` は frontmatter の `dimension:` `category:` `priority:` を見て
rubric に追加される。自分の team の運用 doc / カンファレンス talk のメモ / 個人の運用 note を rubric 化できる。

### 個別 dimension の suppress

`~/.claude/.harness-gap-overrides.yaml`:

```yaml
not_needed:
  - dimension: mcp.github
    reason: "GitHub は gh CLI で十分"
  - dimension: hooks.notification
    reason: "通知は別 daemon が処理"
```

`not-needed` 列に明示マーク付きで並ぶ。`missing-required` から外れる。

## 制約

- harness は **read-only**。`~/.claude/` も `<repo>/.claude/` も書き換えない
- 書き込み先は `${CLAUDE_PLUGIN_DATA}/` と cwd の `tmp/` のみ
- ネットワークは WebFetch で source URL を取りに行くのみ。inventory / harness の中身を外に送らない
- gap 検出後の改修は **提案のみ**。実際の harness 反映は `/cc-fb` 経由で別途行う
- 公式 doc / community doc を最新ベストプラクティスとみなすが、保証はしない。最終判断は人間
