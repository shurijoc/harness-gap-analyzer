言語: [English](README.md) | **日本語**

# Harness Gap Analyzer

自分の Claude Code harness の穴を、痛い目に遭う前に見つけるためのプラグイン。

ローカルの Claude Code 設定（rules / skills / hooks / permissions / agents / MCP servers）を棚卸しし、Anthropic 公式と広いエージェントコーディングコミュニティ（Cursor / Cline / Devin / Aider / OpenAI / AGENTS.md）のベストプラクティスと突き合わせる skill plugin。出力は単一の self-contained HTML レポート 1 枚で、修正作業中ずっと開いておける形。

## できること

- `~/.claude/` と現在の repo の `.claude/` を走査して、rule ファイル・skill・hook・permission・agent・MCP エントリを全て列挙する
- 最新の公式ドキュメント（Anthropic Claude Code docs、engineering blog、GitHub README）と厳選コミュニティソースを fetch する
- harness を YAML 駆動のベストプラクティス rubric と diff する
- ドキュメントが anti-pattern と明記している「gotcha」を炙り出す（肥大化した `CLAUDE.md`、deprecated な settings key、広すぎる permission glob、skill description のトリガーフレーズ欠落 など）
- 前回 run 以降の upstream ドキュメントの変化を追跡するので、deprecation に早く気付ける
- 外部 CSS / JS なしの単一 HTML レポートをレンダして開く

harness を編集はしない。何が足りていないかを教えるだけ。

## インストール

```
/plugin marketplace add shurijoc/harness-gap-analyzer
/plugin install harness-gap-analyzer@harness-gap-analyzer
```

インストール後、Claude Code を再起動するか `/plugin reload` を叩いて `harness-gap` skill を認識させる。

## 使い方

| コマンド | 動作 |
|---|---|
| `/harness-gap` | 既存の source cache と新しい inventory でレポートを再レンダ。速い（〜10秒） |
| `/harness-gap audit` | フル run: inventory 更新 + 全 source fetch + レポート再描画。遅め（1〜3分） |
| `/harness-gap update-sources` | source cache のみ更新。レポートは作らない。夜間 cron 向け |

「harness の gap を分析」「claude code best practices と比較」「ベストプラクティスから抜けがあるか見て」などのトリガーフレーズでも起動する。

## 分析対象

rubric は 16 カテゴリに分かれる。各エントリは inventory と突き合わされ `adopted` / `missing-required` / `missing-recommended` / `not-needed` / `unknown` のいずれかに分類される。

| # | カテゴリ | 一行チェック内容 |
|---|---|---|
| 1 | `claude_md.global` | `~/.claude/CLAUDE.md` が存在、500行未満、話し方ガイドあり |
| 2 | `claude_md.repo` | repo の `CLAUDE.md` が存在し、プロジェクト固有情報を参照 |
| 3 | `rules.split` | global rules がトピック別に `~/.claude/rules/*.md` に分割（1 mega ファイルでない） |
| 4 | `skills.discipline` | 各 `SKILL.md` に frontmatter とトリガーフレーズあり、500行未満 |
| 5 | `skills.scripts` | skill の重い処理は SKILL.md inline ではなく `scripts/` で実行 |
| 6 | `hooks.pretooluse` | 破壊的操作向けの `PreToolUse` hook あり |
| 7 | `hooks.posttooluse` | edit 後の lint / fmt 用 `PostToolUse` hook あり |
| 8 | `hooks.stop` | セッション終了通知の `Stop` hook あり |
| 9 | `permissions.allowlist` | npm/git/gh の毎回 prompt ではなく明示的な allow rule |
| 10 | `permissions.deny` | 危険コマンドが明示的に deny（`rm -rf /`、main への force push 等） |
| 11 | `agents.subagents` | カスタム subagent が `model:` 固定で定義済み |
| 12 | `mcp.servers` | MCP server 設定があり、deprecated schema を使っていない |
| 13 | `mcp.scope` | MCP scope（`local` / `project` / `user`）が意図的に選択されている |
| 14 | `output_styles` | terse / structured 返答を好むなら output style が設定済み |
| 15 | `statusline` | `statusLine` が設定済み（model / branch / token budget 等） |
| 16 | `memory.discipline` | `MEMORY.md` が存在、肥大化していない、秘匿情報なし |

`~/.claude/.harness-gap-overrides.yaml` で任意のエントリを `not-needed` に上書きできる。

## fetch 対象

source list は `skills/harness-gap/sources/` の YAML で管理。YAML を編集して `/harness-gap update-sources` を再実行すればエントリを追加できる。

| ソースグループ | 例 |
|---|---|
| Anthropic 公式 docs | `docs.claude.com/en/docs/claude-code/*` |
| Anthropic engineering blog | `anthropic.com/engineering/claude-code-best-practices` |
| Anthropic GitHub | `github.com/anthropics/claude-code` の README + RELEASE_NOTES |
| エージェントコーディング同業 | Cursor / Cline / Devin / Aider の docs |
| OpenAI / spec docs | Codex CLI docs、`agents.md` spec |
| コミュニティ厳選 | `community.yaml` にリンクされた手選びの blog / talk |

cache は ETag / Last-Modified を使うので、繰り返し run のコストは安い。

## 出力

`tmp/harness-gap-YYYYMMDD.html`（`tmp/` がなければ `${CLAUDE_PLUGIN_DATA}/...`）に単一 HTML を出す。中身:

- **Summary stats** — ラベル別カウント、最新 run の timestamp
- **What changed since last run** — upstream docs の diff（new / removed / updated URL）
- **Adopted** — rubric dimension にマッチした harness item の緑テーブル（ファイルパス付き）
- **Missing (required)** — dimension・rubric source URL・推奨アクションの赤テーブル
- **Missing (recommended)** — required と同じ形の amber テーブル
- **Not needed** — ユーザー記入の理由付きグレーテーブル
- **Unknown** — inventory が自動判定できなかった dimension の青テーブル
- **Triggered gotchas** — anti-pattern 専用パネル（肥大化ファイル、deprecated key 等）
- **Source index** — source 毎の last-fetched timestamp と fetch エラー

全て inline。CDN なし。オフラインで開ける。

## 継続運用モード

`/schedule` skill と組み合わせる:

```
/schedule "0 8 * * *"   "/harness-gap update-sources"
/schedule "0 9 * * MON" "/harness-gap audit"
```

夜間に source を refresh、月曜朝にフル audit。「What changed since last run」パネルが upstream ドキュメント更新の受動的な通知ストリームになる。

## カスタム insight

社内 harness メモ（CWC スライド、チーム規約、蓄積された postmortem 等）がある場合、レンダラに食わせられる:

```
/harness-gap audit --local-insights ~/notes/cwc-claude-tips/
```

そのディレクトリ配下の以下 frontmatter 付き `*.md` は、その run の rubric にマージされる:

```yaml
---
dimension: rules.terseness
category: rules
priority: required
---
```

plugin を fork せずに自分の rubric を育てられる仕組み。

## やらないこと

- harness を改変しない。`~/.claude/` / repo の `.claude/` / `settings.json` に edit を入れない。修正は手動（あるいは `/cc-fb` 経由）
- harness を外に持ち出さない。outbound は `sources/*.yaml` 宣言済み URL への `WebFetch` のみ。`CLAUDE.md` / hook / permission はローカルに留まる
- 品質を自動採点しない。構造的・存在ベースの dimension をチェックして読むべきドキュメントを提示するだけ。最終判断はユーザー
- `claude doctor` や `claude --version` の代替ではない。補完関係

## ライセンス

MIT。`LICENSE` 参照。

## コントリビュート

コードを書かずに貢献できる経路が 2 つある:

1. **新しい rubric dimension** — `skills/harness-gap/rubric/claude-code.yaml` にエントリ追加の PR。根拠になった source URL を必ず添える
2. **新しい source** — `skills/harness-gap/sources/anthropic.yaml` か `community.yaml` に URL + category 追加の PR

新しい gotcha detector のコード貢献も歓迎。各 detector は `scripts/render-report.py` の小さな関数。pure に保ち、`tests/` 配下に fixture を 1 つ追加する。
