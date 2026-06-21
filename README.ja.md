言語: [English](README.md) | **日本語**

# harness-gap-analyzer

> harness-gap-analyzer のプラグインマーケットプレイス。Claude Code 設定を Anthropic 公式 + コミュニティのベストプラクティスと継続的に突き合わせる。

**インストール**

```
/plugin marketplace add shurijoc/harness-gap-analyzer
/plugin install harness-gap-analyzer@harness-gap-analyzer
```

**得られるもの**

- プラグイン 1 本、MIT ライセンス、`sources/*.yaml` 宣言済み公式 doc 以外への通信なし
- 単一 self-contained HTML レポート — JS なし、外部 CSS なし、オフラインで開ける
- EN/JA 両方のドキュメントとレポート出力

<details>
<summary>詳細</summary>

![status](https://img.shields.io/badge/status-alpha-orange)

## TL;DR

Claude Code の harness（`settings.json`、hooks、permissions、skills、rules）は時間とともに drift する。一方で Anthropic とコミュニティは新しいベストプラクティスを出し続ける。誰もそのギャップに気づかず、何かが壊れて初めて発覚する。

このマーケットプレイスは `harness-gap-analyzer` というプラグイン 1 本を提供する。ローカル harness を棚卸しし、正典となるベストプラクティスのソースを取得し、具体的な修正案つきの差分レポートを並べて表示する。

インストール後、任意の Claude Code セッションで `/harness-gap` を実行する。

## このマーケットプレイスの中身

| Plugin | 説明 |
|---|---|
| `harness-gap-analyzer` | Claude Code の harness を正典ベストプラクティスと突き合わせて監査する。ローカル設定の棚卸し、Anthropic / コミュニティソースの取得、self-contained な HTML ギャップレポートのレンダリングを行う。 |

将来的にプラグインが増える可能性はあるが、マーケットプレイスは意図的に狭く保つ。1 つの仕事をきちんとやる構成。

## なぜ作るか

- **harness 設定は drift する。** 1 プロジェクトに hook を入れて、他に展開し忘れ、3 ヶ月後にはルールが全体的にズレている
- **ベストプラクティスは更新される。** Anthropic は新しい SDK 機能を出し、コミュニティは新しい rubric を公開し続けるのに、`settings.json` は 2024 年当時の形のまま
- **誰も気づかない。** 「自分の harness は今の Claude Code 推奨と合っているか」を見る CI は存在しない
- **既存ツールは片側しか監査しない。** ローカル設定 or 上流ドキュメントのどちらか。このプラグインは **両方** を監査し、差分を出す

ゴールは「週 1 回流せる skill 1 本」。どこが遅れているか、最小の patch で埋めるには何をすればよいかを 1 枚で出す。

## 仕組み

プラグイン内の `harness-gap` skill が以下の 3 ステップを実行する。

1. **Inventory（棚卸し）** — ローカル repo と `~/.claude/` を歩き、効いている設定面を全部集める。`settings.json`、`settings.local.json`、hooks、permissions、skills（`.claude/skills/`）、rules（`.claude/rules/`）、CLAUDE.md。出力は「今この harness が *実際に* やっていること」の正規化された JSON スナップショット
2. **Fetch（取得）** — `sources/anthropic.yaml` と `sources/community.yaml` に定義した正典ソースを取得する。ローカルにキャッシュするので再実行は安い。出力は「この harness が *あるべき姿* で何をすべきか」を citations 付きで持つ rubric
3. **Render（描画）** — `rubric/claude-code.yaml` を使って inventory と rubric を diff し、self-contained な HTML レポート（JS なし、外部 CSS なし）を `tmp/harness-gap-report.html` に書き出す。各ギャップには severity、ソース citation、コピペ可能な fix が紐づく

## ディスクからインストール

このリポジトリをローカルに clone してディスクからインストールする場合:

```
/plugin marketplace add /absolute/path/to/harness-gap-analyzer
/plugin install harness-gap-analyzer@harness-gap-analyzer
```

インストール後、skill を起動する:

```
/harness-gap
```

レンダリングが終わるとブラウザで自動的にレポートが開く。

## ローカル開発

マーケットプレイス経由のインストールを介さずに開発したい場合:

```
claude --plugin-dir ./plugins/harness-gap-analyzer
```

これで作業ツリーから直接プラグインを読み込むので、`skills/harness-gap/SKILL.md`、`scripts/*`、`rubric/*.yaml`、`templates/report.html` への編集が次回起動時に反映される。

PR を出す前、もしくは新バージョンを公開する前にプラグイン manifest を検証すること:

```
claude plugin validate ./plugins/harness-gap-analyzer
```

これで SKILL.md の frontmatter、rubric YAML のスキーマ、skill が参照する script のエントリポイントをまとめてチェックできる。

## Contributing

PR は歓迎。特に以下のものは大歓迎:

- **新しい rubric 項目** — `plugins/harness-gap-analyzer/skills/harness-gap/rubric/claude-code.yaml` を開き、citation 付きで check を追加する。項目は atomic（1 設定面 = 1 項目）にし、`fix` フィールドに具体的な patch を入れる
- **新しいソース** — `sources/anthropic.yaml`（公式ドキュメント）または `sources/community.yaml`（ブログ記事、メンテされている repo）にエントリを追加する。`url`、`fetched_at` プレースホルダ、短い `summary` の 3 つが必須
- **レンダリング改善** — `templates/report.html` は意図的にシンプル。self-contained（JS なし、外部アセットなし）を保ったまま改善する PR は特に大歓迎

PR を出す前に以下を実行する:

```
claude plugin validate ./plugins/harness-gap-analyzer
python3 -c "import json; json.load(open('.claude-plugin/marketplace.json'))"
```

両方とも警告なしで通ること。

## claude-community への提出

プラグインが安定したら、公式 Claude プラグインディレクトリに提出する予定: https://platform.claude.com/plugins/submit

fork して自分用の variant を提出するのは構わない。名前の衝突を避けるため、`.claude-plugin/marketplace.json` と `plugins/harness-gap-analyzer/.claude-plugin/plugin.json` の `name` フィールドだけは必ず変更すること。

## License

MIT。[LICENSE](./LICENSE) を参照。

</details>
