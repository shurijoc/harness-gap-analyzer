#!/usr/bin/env python3
"""
render-report.py — Claude Code Harness Gap Report renderer.

Takes:
  - harness inventory JSON  (--inventory)
  - rubric YAML             (--rubric)
  - source-fetch manifest   (--manifest, optional)
  - HTML template           (--template, default skill templates/report.html)

Emits a self-contained HTML report at --output.

Template injection strategy:
  The template ships without placeholder comments. On first render we ensure
  a sentinel comment "<!-- HARNESS_GAP_CONTENT -->" exists *inside* the main
  container (<main><div class="container"> ... </div></main>). If the sentinel
  is missing we rewrite the inner-HTML of that container to a single sentinel
  line in the template file itself (one-time, idempotent migration). At render
  time we replace the sentinel with the generated sections HTML, and rewrite
  <title>, header h1 and syslabel via simple str.replace on known unique
  snippets.

Only stdlib + PyYAML are required.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    sys.stderr.write("ERROR: PyYAML is required. Install with `pip install pyyaml`.\n")
    sys.exit(2)


SENTINEL = "<!-- HARNESS_GAP_CONTENT -->"


# ----------------------------- i18n strings -----------------------------

STRINGS: dict[str, dict[str, str]] = {
    "en": {
        "lead": (
            "Cross-checking the harness inventory against the rubric. "
            "The top three actions are above; full evidence is below."
        ),
        "section_hero": "Status",
        "section_top_actions": "Top 3 next actions",
        "section_summary": "Summary",
        "section_adopted": "Adopted",
        "section_missing": "Missing (required / recommended)",
        "section_not_needed": "Not needed (optional fails)",
        "section_unknown": "Undetermined",
        "section_gotchas": "Gotchas triggered",
        "section_sources": "Source updates",
        "section_next": "Next actions",
        "collapsed_not_needed": "Not needed (optional fail)",
        "collapsed_unknown": "Undetermined",
        "empty_adopted": "No adopted items.",
        "empty_missing": "No missing items.",
        "empty_collapsed": "None.",
        "empty_gotchas": "No triggers.",
        "empty_manifest": "No manifest.",
        "empty_sources": "No source records.",
        "empty_next": "No missing required items — no next action needed.",
        "empty_top_actions": "Looking solid — nothing to act on right now.",
        "table_id": "id",
        "table_category": "category",
        "table_title": "title",
        "table_detect": "detect",
        "table_importance": "importance",
        "table_source": "source",
        "table_last_fetched": "last fetched",
        "table_status": "status",
        "table_why": "why it matters",
        "stat_adoption": "adoption (req+rec)",
        "stat_missing_req": "missing required",
        "stat_gotchas": "gotchas triggered",
        "hero_verdict_clean": "Looking solid — no required items missing and no gotchas triggered.",
        "hero_verdict_action_needed": "{n} actions needed — see the top 3 below.",
        "fix_hint_label": "Fix",
        "source_link_label": "Source",
        "changed_tag": "↻ changed",
        "sources_tracking_line": "{n} sources tracked · {m} changed in last run",
    },
    "ja": {
        "lead": (
            "harness inventory と rubric の突き合わせ結果。"
            "優先アクションは上に、根拠は下にまとめた。"
        ),
        "section_hero": "現況",
        "section_top_actions": "Top 3 次の一手",
        "section_summary": "概要",
        "section_adopted": "採用済み",
        "section_missing": "未採用 (required / recommended)",
        "section_not_needed": "不要扱い (optional の fail)",
        "section_unknown": "判定不能",
        "section_gotchas": "Gotchas triggered",
        "section_sources": "情報源の更新",
        "section_next": "次の一手",
        "collapsed_not_needed": "不要扱い (optional fail)",
        "collapsed_unknown": "判定不能",
        "empty_adopted": "採用済みなし。",
        "empty_missing": "未採用なし。",
        "empty_collapsed": "なし。",
        "empty_gotchas": "trigger なし。",
        "empty_manifest": "manifest なし。",
        "empty_sources": "情報源の記録なし。",
        "empty_next": "missing required なし — 次の一手は不要。",
        "empty_top_actions": "概ね OK — 今すぐ手を打つ項目なし。",
        "table_id": "id",
        "table_category": "category",
        "table_title": "title",
        "table_detect": "detect",
        "table_importance": "importance",
        "table_source": "source",
        "table_last_fetched": "last fetched",
        "table_status": "status",
        "table_why": "why it matters",
        "stat_adoption": "adoption (req+rec)",
        "stat_missing_req": "missing required",
        "stat_gotchas": "gotchas triggered",
        "hero_verdict_clean": "概ね OK — required 未対応なし、gotchas trigger なし。",
        "hero_verdict_action_needed": "{n} 件の対応が必要 — Top 3 を下に示す。",
        "fix_hint_label": "対応",
        "source_link_label": "出典",
        "changed_tag": "↻ 更新",
        "sources_tracking_line": "ソース {n} 件監視 · 前回 {m} 件更新",
    },
}


# ----------------------------- helpers -----------------------------


def esc(s: Any) -> str:
    """HTML-escape for safe injection."""
    if s is None:
        return ""
    return html.escape(str(s), quote=True)


def load_json(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    p = Path(path)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        sys.stderr.write(f"WARN: failed to parse JSON {path}: {e}\n")
        return {}


def load_yaml(path: str) -> dict[str, Any]:
    p = Path(path)
    if not p.exists():
        sys.stderr.write(f"ERROR: rubric not found at {path}\n")
        sys.exit(2)
    try:
        return yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except Exception as e:
        sys.stderr.write(f"ERROR: failed to parse YAML {path}: {e}\n")
        sys.exit(2)


# ----------------------------- inventory walking -----------------------------


def normalize_inventory(raw: dict[str, Any]) -> dict[str, Any]:
    """Flatten the inventory.sh nested output into a {files, dirs, json_blobs} shape
    that the rubric detectors can target via simple paths.

    Both scopes are projected:
      - global -> paths under '.claude/...' (the rubric speaks in relative terms)
      - repo   -> paths under '.claude/...' too; later wins, so global is base and repo overrides

    Output schema:
      {
        'files': [{'path', 'size', 'lines', 'frontmatter', 'json'?, 'top_keys'?}],
        'dirs':  ['.claude/skills', '.claude/agents', ...],
        '_scopes': {'global': {...}, 'repo': {...}},
        '_settings_keys': {'global': [...], 'repo': [...]}
      }
    """
    files: list[dict[str, Any]] = []
    dirs: set[str] = set()

    def project_scope(scope: dict[str, Any]) -> None:
        if not isinstance(scope, dict) or not scope.get("root"):
            return
        base = ".claude"

        cm = scope.get("claude_md") or {}
        if cm.get("exists"):
            files.append({
                "path": "CLAUDE.md",
                "size": cm.get("size_bytes"),
                "lines": cm.get("line_count"),
                "sha256": cm.get("sha256", ""),
            })
            files.append({
                "path": f"{base}/CLAUDE.md",
                "size": cm.get("size_bytes"),
                "lines": cm.get("line_count"),
                "sha256": cm.get("sha256", ""),
            })

        rules = scope.get("rules") or {}
        if rules.get("exists"):
            dirs.add(f"{base}/rules")
            for r in rules.get("files") or []:
                files.append({
                    "path": f"{base}/rules/{r.get('name')}",
                    "size": r.get("size"),
                    "lines": r.get("lines"),
                })

        skills = scope.get("skills") or {}
        if skills.get("exists"):
            dirs.add(f"{base}/skills")
            for sk in skills.get("skills") or []:
                name = sk.get("name") or ""
                if not name:
                    continue
                dirs.add(f"{base}/skills/{name}")
                if sk.get("has_skill_md"):
                    fm = sk.get("frontmatter") or {}
                    norm_fm = {k: v for k, v in fm.items() if v not in ("", None)}
                    if fm.get("when_to_use_present"):
                        norm_fm.setdefault("when_to_use", "present")
                    files.append({
                        "path": f"{base}/skills/{name}/SKILL.md",
                        "lines": sk.get("body_lines"),
                        "frontmatter": norm_fm,
                    })
                if sk.get("has_references_dir"):
                    dirs.add(f"{base}/skills/{name}/references")
                if sk.get("has_templates_dir"):
                    dirs.add(f"{base}/skills/{name}/templates")

        agents = scope.get("agents") or {}
        if agents.get("exists"):
            dirs.add(f"{base}/agents")
            for a in agents.get("files") or []:
                files.append({
                    "path": f"{base}/agents/{a.get('name')}",
                    "size": a.get("size"),
                    "lines": a.get("lines"),
                    "frontmatter": a.get("frontmatter") or {},
                })

        commands = scope.get("commands") or {}
        if commands.get("exists"):
            dirs.add(f"{base}/commands")
            for c in commands.get("files") or []:
                files.append({
                    "path": f"{base}/commands/{c.get('name')}",
                    "size": c.get("size"),
                    "lines": c.get("lines"),
                })

        hooks = scope.get("hooks") or {}
        if hooks.get("scripts_dir_exists"):
            dirs.add(f"{base}/hooks")
            for h in hooks.get("files") or []:
                files.append({"path": f"{base}/hooks/{h.get('name')}"})

        settings = scope.get("settings") or {}
        if settings.get("exists"):
            entry: dict[str, Any] = {
                "path": f"{base}/settings.json",
                "top_keys": settings.get("top_keys") or [],
                "json": {},
            }
            json_blob = entry["json"]
            for k in entry["top_keys"]:
                json_blob[k] = True
            perms = settings.get("permissions") or {}
            if perms:
                json_blob["permissions"] = {
                    "allow": [None] * (perms.get("allow_count") or 0),
                    "deny": [None] * (perms.get("deny_count") or 0),
                    "ask": [None] * (perms.get("ask_count") or 0),
                    "defaultMode": perms.get("default_mode"),
                    "additionalDirectories": (
                        [None] if perms.get("has_additional_dirs") else []
                    ),
                }
            hook_events = hooks.get("events_in_settings") or []
            if hook_events:
                if not isinstance(json_blob.get("hooks"), dict):
                    json_blob["hooks"] = {}
                for ev in hook_events:
                    json_blob["hooks"][ev] = True
            files.append(entry)

        settings_local = scope.get("settings_local") or {}
        if settings_local.get("exists"):
            files.append({
                "path": f"{base}/settings.local.json",
                "top_keys": settings_local.get("top_keys") or [],
                "json": {k: True for k in settings_local.get("top_keys") or []},
            })

        kb = scope.get("keybindings") or {}
        if kb.get("exists"):
            files.append({
                "path": f"{base}/keybindings.json",
                "json": {"_binding_count": kb.get("binding_count")},
            })

        mem = scope.get("memory") or {}
        if mem.get("exists"):
            dirs.add(f"{base}/memory")

        plugins = scope.get("plugins") or {}
        if plugins.get("enabled_count", 0) > 0:
            dirs.add(f"{base}/plugins")

    global_scope = raw.get("global") or {}
    repo_scope = raw.get("repo") or {}
    project_scope(global_scope)
    if repo_scope.get("exists") is not False:
        project_scope(repo_scope)

    seen: dict[str, dict[str, Any]] = {}
    for f in files:
        p = f.get("path") or ""
        if not p:
            continue
        if p in seen:
            base_entry = seen[p]
            for k, v in f.items():
                if v not in (None, "", [], {}):
                    base_entry[k] = v
        else:
            seen[p] = dict(f)
    flat_files = list(seen.values())

    return {
        "files": flat_files,
        "dirs": sorted(dirs),
        "_scopes": {"global": global_scope, "repo": repo_scope},
        "metrics": raw.get("metrics") or {},
    }


def inv_files(inventory: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a flat list of file entries from inventory.

    Inventory shape is permissive — we look for common keys:
      - inventory['files']: list of {path, lines?, frontmatter?, ...}
      - inventory['tree']:  list of paths
      - inventory['paths']: list of paths
    """
    out: list[dict[str, Any]] = []
    if isinstance(inventory.get("files"), list):
        for f in inventory["files"]:
            if isinstance(f, dict) and "path" in f:
                out.append(f)
            elif isinstance(f, str):
                out.append({"path": f})
    for k in ("tree", "paths"):
        v = inventory.get(k)
        if isinstance(v, list):
            for f in v:
                if isinstance(f, str):
                    out.append({"path": f})
    return out


def inv_dirs(inventory: dict[str, Any]) -> set[str]:
    """Set of directory paths known in inventory."""
    dirs: set[str] = set()
    if isinstance(inventory.get("dirs"), list):
        for d in inventory["dirs"]:
            if isinstance(d, str):
                dirs.add(d.rstrip("/"))
    # Derive parents from files
    for f in inv_files(inventory):
        p = f.get("path", "")
        parts = p.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    return dirs


def glob_to_regex(glob: str) -> re.Pattern:
    """Translate a simple glob (with * and **) to a regex."""
    # Escape regex specials except * which we handle.
    parts = []
    i = 0
    while i < len(glob):
        c = glob[i]
        if c == "*":
            if i + 1 < len(glob) and glob[i + 1] == "*":
                parts.append(".*")
                i += 2
                if i < len(glob) and glob[i] == "/":
                    i += 1
                continue
            parts.append("[^/]*")
            i += 1
            continue
        if c == "?":
            parts.append("[^/]")
            i += 1
            continue
        parts.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(parts) + "$")


def expand_target(target: str, inventory: dict[str, Any]) -> list[str]:
    """Expand a target glob against the inventory paths.

    target may contain '::' for nested-key access; we only expand the path part.
    """
    path_part = target.split("::", 1)[0]
    files = [f.get("path", "") for f in inv_files(inventory)]
    if "*" in path_part or "?" in path_part:
        rx = glob_to_regex(path_part)
        return [p for p in files if rx.match(p)]
    # Exact match
    return [p for p in files if p == path_part]


def file_entry(inventory: dict[str, Any], path: str) -> dict[str, Any] | None:
    for f in inv_files(inventory):
        if f.get("path") == path:
            return f
    return None


def get_nested(obj: Any, dotted: str) -> Any:
    """Walk a dotted.path through dicts. Returns sentinel `__MISSING__` if absent."""
    MISSING = "__MISSING__"
    cur = obj
    for key in dotted.split("."):
        if isinstance(cur, dict) and key in cur:
            cur = cur[key]
        else:
            return MISSING
    return cur


# ----------------------------- detector -----------------------------


def detect(dim: dict[str, Any], inventory: dict[str, Any]) -> str:
    """Return 'pass', 'fail', or 'unknown' for a rubric dimension."""
    det = dim.get("detect") or {}
    dtype = det.get("type")
    target = det.get("target", "")
    expected = det.get("expected", None)

    if not dtype or not target:
        return "unknown"

    try:
        if dtype == "file_exists":
            matches = expand_target(target, inventory)
            return "pass" if matches else "fail"

        if dtype == "dir_exists":
            dirs = inv_dirs(inventory)
            t = target.rstrip("/")
            return "pass" if t in dirs else "fail"

        if dtype == "dir_file_count":
            # Count files whose path begins with target dir
            t = target.rstrip("/")
            files = [f.get("path", "") for f in inv_files(inventory)]
            count = sum(1 for p in files if p.startswith(t + "/"))
            return _compare(count, expected)

        if dtype == "line_count_under":
            files = expand_target(target, inventory)
            if not files:
                return "unknown"
            try:
                maxv = int(expected)
            except Exception:
                return "unknown"
            ok = True
            any_known = False
            for p in files:
                fe = file_entry(inventory, p) or {}
                lines = fe.get("lines")
                if lines is None:
                    continue
                any_known = True
                if int(lines) > maxv:
                    ok = False
                    break
            if not any_known:
                return "unknown"
            return "pass" if ok else "fail"

        if dtype == "line_count_over":
            # Used by gotchas — a "pass" here is bad
            files = expand_target(target, inventory)
            if not files:
                return "fail"  # no file -> no trigger
            try:
                minv = int(expected)
            except Exception:
                return "unknown"
            for p in files:
                fe = file_entry(inventory, p) or {}
                lines = fe.get("lines")
                if lines is None:
                    continue
                if int(lines) > minv:
                    return "pass"
            return "fail"

        if dtype in ("json_key_present", "json_key_value", "json_key_absent"):
            if "::" not in target:
                return "unknown"
            path_part, key_part = target.split("::", 1)
            files = expand_target(path_part, inventory)
            if not files:
                # If file itself missing, key is absent
                if dtype == "json_key_absent":
                    return "pass"
                return "fail"
            for fp in files:
                fe = file_entry(inventory, fp) or {}
                # Look for parsed content under known keys
                content = (
                    fe.get("json")
                    or fe.get("content")
                    or fe.get("parsed")
                    or {}
                )
                # Some inventories store 'top_keys' as a list of top-level keys only.
                top_keys = fe.get("top_keys")
                val = get_nested(content, key_part)
                present = val != "__MISSING__"
                if not present and top_keys is not None and "." not in key_part:
                    present = key_part in top_keys
                if dtype == "json_key_present":
                    if present:
                        return "pass"
                elif dtype == "json_key_value":
                    if present and _value_matches(val, expected):
                        return "pass"
                elif dtype == "json_key_absent":
                    if present:
                        return "fail"
            if dtype == "json_key_absent":
                return "pass"
            return "fail"

        if dtype == "yaml_frontmatter_key":
            if "::" not in target:
                return "unknown"
            path_part, key_part = target.split("::", 1)
            files = expand_target(path_part, inventory)
            if not files:
                return "fail"
            for fp in files:
                fe = file_entry(inventory, fp) or {}
                fm = fe.get("frontmatter") or {}
                val = get_nested(fm, key_part)
                present = val != "__MISSING__"
                if present:
                    if expected in (None, "present"):
                        return "pass"
                    if _value_matches(val, expected):
                        return "pass"
            return "fail"

        if dtype == "regex_match":
            files = expand_target(target, inventory)
            if not files:
                # treat dir target as a dir of files
                t = target.rstrip("/")
                files = [
                    f.get("path", "")
                    for f in inv_files(inventory)
                    if f.get("path", "").startswith(t + "/")
                ]
            if not files:
                return "unknown"
            try:
                rx = re.compile(expected)
            except Exception:
                return "unknown"
            any_content = False
            for p in files:
                fe = file_entry(inventory, p) or {}
                content = fe.get("text") or fe.get("body") or fe.get("content")
                if content is None:
                    continue
                if not isinstance(content, str):
                    continue
                any_content = True
                if rx.search(content):
                    return "pass"
            return "unknown" if not any_content else "fail"

        if dtype == "regex_absent":
            files = expand_target(target, inventory)
            if not files:
                t = target.rstrip("/")
                files = [
                    f.get("path", "")
                    for f in inv_files(inventory)
                    if f.get("path", "").startswith(t + "/")
                ]
            if not files:
                return "pass"  # vacuous
            try:
                rx = re.compile(expected)
            except Exception:
                return "unknown"
            for p in files:
                fe = file_entry(inventory, p) or {}
                content = fe.get("text") or fe.get("body") or fe.get("content")
                if not isinstance(content, str):
                    continue
                if rx.search(content):
                    return "fail"
            return "pass"

    except Exception as e:
        sys.stderr.write(f"WARN: detector {dtype} on {target} crashed: {e}\n")
        return "unknown"

    return "unknown"


def _compare(actual: int, expected: Any) -> str:
    """Compare actual vs expected like '>0', '>=1', '==3', or int."""
    if expected is None:
        return "pass" if actual > 0 else "fail"
    if isinstance(expected, int):
        return "pass" if actual == expected else "fail"
    s = str(expected).strip()
    m = re.match(r"^(>=|<=|==|>|<)\s*(-?\d+)$", s)
    if not m:
        try:
            return "pass" if actual == int(s) else "fail"
        except Exception:
            return "unknown"
    op, num = m.group(1), int(m.group(2))
    ok = {
        ">": actual > num,
        ">=": actual >= num,
        "<": actual < num,
        "<=": actual <= num,
        "==": actual == num,
    }[op]
    return "pass" if ok else "fail"


def _value_matches(val: Any, expected: Any) -> bool:
    if expected is None or expected == "present":
        return True
    if isinstance(expected, bool) or isinstance(expected, (int, float)):
        return val == expected
    s = str(expected)
    if isinstance(val, bool):
        return s.lower() == str(val).lower()
    if str(val) == s:
        return True
    try:
        return bool(re.search(s, str(val)))
    except Exception:
        return False


# ----------------------------- bucketing -----------------------------


def bucket(dim: dict[str, Any], status: str) -> str:
    importance = (dim.get("importance") or "").lower()
    if status == "pass":
        return "adopted"
    if status == "unknown":
        return "unknown"
    # status == fail
    if importance == "optional":
        return "not-needed"
    return "missing"


# ----------------------------- HTML sections -----------------------------


def render_stats(summary: dict[str, int], adoption_pct: float, lang: str) -> str:
    # Stats labels are intentionally English regardless of lang.
    return f"""
<div class="stats">
  <div class="stat">
    <div class="num">{summary['total']}</div>
    <div class="label">total dimensions</div>
  </div>
  <div class="stat">
    <div class="num">{adoption_pct:.0f}<span class="unit">%</span></div>
    <div class="label">adoption (req+rec)</div>
  </div>
  <div class="stat">
    <div class="num">{summary['missing_required']}</div>
    <div class="label">missing required</div>
  </div>
  <div class="stat">
    <div class="num">{summary['gotchas_triggered']}</div>
    <div class="label">gotchas triggered</div>
  </div>
</div>
""".strip()


def render_hero(summary: dict[str, int], adoption_pct: float, lang: str) -> str:
    """Top hero block: 3 stats + verdict line. Non-collapsible."""
    s = STRINGS[lang]
    miss_req = summary["missing_required"]
    gotchas = summary["gotchas_triggered"]
    miss_cls = " danger" if miss_req > 0 else ""
    got_cls = " warning" if gotchas > 0 else ""

    actions_count = miss_req + gotchas
    if actions_count == 0:
        verdict = s["hero_verdict_clean"]
        verdict_cls = "fact"
    else:
        verdict = s["hero_verdict_action_needed"].format(n=actions_count)
        verdict_cls = "warn"

    return f"""
<div class="stats hero">
  <div class="stat">
    <div class="num">{adoption_pct:.0f}<span class="unit">%</span></div>
    <div class="label">{esc(s['stat_adoption'])}</div>
  </div>
  <div class="stat{miss_cls}">
    <div class="num">{miss_req}</div>
    <div class="label">{esc(s['stat_missing_req'])}</div>
  </div>
  <div class="stat{got_cls}">
    <div class="num">{gotchas}</div>
    <div class="label">{esc(s['stat_gotchas'])}</div>
  </div>
</div>
<p class="hero-verdict {verdict_cls}">{esc(verdict)}</p>
""".strip()


def _action_importance_rank(imp: str) -> int:
    imp = (imp or "").lower()
    return {"required": 0, "recommended": 1, "optional": 2}.get(imp, 3)


def render_top_actions(
    missing_req: list[dict[str, Any]],
    missing_rec: list[dict[str, Any]],
    gotchas: list[dict[str, Any]],
    lang: str,
    k: int = 3,
) -> str:
    """Pick top-k actions across missing-required, missing-recommended, gotchas.

    Priority: missing-required → triggered gotchas → missing-recommended.
    Within each pool, sort by category alphabetical for stability.
    Emit one .callout per action.
    """
    s = STRINGS[lang]

    pool: list[dict[str, Any]] = []
    for d in sorted(missing_req, key=lambda x: (x.get("category") or "")):
        pool.append({"kind": "missing", "imp": "required", "dim": d})
    for g in gotchas:
        pool.append({"kind": "gotcha", "imp": "required", "g": g})
    for d in sorted(missing_rec, key=lambda x: (x.get("category") or "")):
        pool.append({"kind": "missing", "imp": "recommended", "dim": d})

    top = pool[:k]
    if not top:
        return f'<p class="callout fact"><span class="tag">OK</span> {esc(s["empty_top_actions"])}</p>'

    out: list[str] = []
    for item in top:
        if item["kind"] == "missing":
            d = item["dim"]
            imp = (d.get("importance") or "").lower()
            cls = "warn" if imp == "required" else "hypo"
            tag = (d.get("importance") or "").upper()
            cat = d.get("category") or ""
            title = d.get("title") or ""
            why = d.get("why_matters") or ""
            src = d.get("source_url") or ""
            fix_lines: list[str] = []
            if src:
                fix_lines.append(
                    f'<p><strong>{esc(s["fix_hint_label"])}:</strong> '
                    f'<a href="{esc(src)}" target="_blank" rel="noopener">'
                    f'{esc(s["source_link_label"])}: {esc(title)}</a></p>'
                )
            else:
                definition = d.get("definition") or ""
                if definition:
                    fix_lines.append(
                        f'<p><strong>{esc(s["fix_hint_label"])}:</strong> '
                        f'<code>{esc(definition)}</code></p>'
                    )
            out.append(
                f'<div class="callout {cls} action-row">'
                f'<span class="tag">{esc(tag)} · {esc(cat)} · {esc(d.get("id"))}</span>'
                f'<p><strong>{esc(title)}</strong></p>'
                f'<p class="mute">{esc(why)}</p>'
                + "".join(fix_lines)
                + "</div>"
            )
        else:  # gotcha
            g = item["g"]
            sev = (g.get("severity") or "warn").upper()
            cat = g.get("category") or "gotcha"
            title = g.get("title") or ""
            fix = g.get("fix_hint") or ""
            src = g.get("source_url") or ""
            src_html = (
                f' <a href="{esc(src)}" target="_blank" rel="noopener">'
                f'{esc(s["source_link_label"])}</a>'
                if src
                else ""
            )
            fix_html = (
                f'<p><strong>{esc(s["fix_hint_label"])}:</strong> {esc(fix)}</p>'
                if fix
                else ""
            )
            out.append(
                f'<div class="callout warn action-row">'
                f'<span class="tag">GOTCHA · {esc(cat)} · {esc(g.get("id"))}</span>'
                f'<p><strong>{esc(title)}</strong>{src_html}</p>'
                + fix_html
                + "</div>"
            )
    return "\n".join(out)


def render_adopted_table(rows: list[dict[str, Any]], lang: str) -> str:
    s = STRINGS[lang]
    if not rows:
        return f'<p class="mute">{esc(s["empty_adopted"])}</p>'
    body = []
    for d in rows:
        det = d.get("detect") or {}
        body.append(
            f"<tr><td><code>{esc(d.get('id'))}</code></td>"
            f"<td>{esc(d.get('category'))}</td>"
            f"<td>{esc(d.get('title'))}</td>"
            f"<td><code>{esc(det.get('type'))}</code></td></tr>"
        )
    return (
        '<div class="table-scroll"><table>'
        f"<thead><tr><th>{esc(s['table_id'])}</th><th>{esc(s['table_category'])}</th>"
        f"<th>{esc(s['table_title'])}</th><th>{esc(s['table_detect'])}</th></tr></thead>"
        f"<tbody>{''.join(body)}</tbody></table></div>"
    )


def render_missing(rows: list[dict[str, Any]], lang: str) -> str:
    s = STRINGS[lang]
    if not rows:
        return f'<p class="mute">{esc(s["empty_missing"])}</p>'

    # Sort: required first, then recommended; within tier alphabetical by category, then id
    def _key(d: dict[str, Any]) -> tuple[int, str, str]:
        return (
            _action_importance_rank(d.get("importance") or ""),
            (d.get("category") or "").lower(),
            (d.get("id") or "").lower(),
        )

    rows_sorted = sorted(rows, key=_key)

    # Group by category preserving sorted order (required first means each category
    # may appear twice if it has both req and rec — we still group by category alone
    # to keep the visual compact, but rows within a category are still ordered req→rec).
    by_cat: dict[str, list[dict[str, Any]]] = {}
    for d in rows_sorted:
        by_cat.setdefault(d.get("category") or "other", []).append(d)
    # Re-order categories: those with any required item first, then alphabetical
    cats_with_req: list[str] = []
    cats_rec_only: list[str] = []
    for cat, items in by_cat.items():
        if any((it.get("importance") or "").lower() == "required" for it in items):
            cats_with_req.append(cat)
        else:
            cats_rec_only.append(cat)
    cats_ordered = sorted(cats_with_req) + sorted(cats_rec_only)

    out: list[str] = []
    for cat in cats_ordered:
        items = by_cat[cat]
        out.append(f"<h3>{esc(cat)}</h3>")
        body: list[str] = []
        for d in items:
            imp = (d.get("importance") or "").lower()
            imp_label = imp.upper() or "—"
            src = d.get("source_url") or ""
            src_html = (
                f'<a href="{esc(src)}" target="_blank" rel="noopener">'
                f'{esc(s["source_link_label"])}</a>'
                if src
                else '<span class="mute">—</span>'
            )
            body.append(
                "<tr>"
                f"<td><code>{esc(d.get('id'))}</code></td>"
                f"<td>{esc(d.get('title'))}</td>"
                f"<td>{esc(imp_label)}</td>"
                f"<td>{esc(d.get('why_matters') or '')}</td>"
                f"<td>{src_html}</td>"
                "</tr>"
            )
        out.append(
            '<div class="table-scroll"><table>'
            f"<thead><tr><th>{esc(s['table_id'])}</th>"
            f"<th>{esc(s['table_title'])}</th>"
            f"<th>{esc(s['table_importance'])}</th>"
            f"<th>{esc(s['table_why'])}</th>"
            f"<th>{esc(s['table_source'])}</th></tr></thead>"
            f"<tbody>{''.join(body)}</tbody></table></div>"
        )
    return "\n".join(out)


def render_collapsed_table(rows: list[dict[str, Any]], summary_label: str, lang: str) -> str:
    s = STRINGS[lang]
    if not rows:
        return (
            f'<details class="section"><summary>{esc(summary_label)} (0)</summary>'
            f'<div class="body"><p class="mute">{esc(s["empty_collapsed"])}</p></div></details>'
        )
    body = []
    for d in rows:
        det = d.get("detect") or {}
        body.append(
            f"<tr><td><code>{esc(d.get('id'))}</code></td>"
            f"<td>{esc(d.get('category'))}</td>"
            f"<td>{esc(d.get('title'))}</td>"
            f"<td><code>{esc(det.get('type'))}</code></td>"
            f"<td>{esc(d.get('importance'))}</td></tr>"
        )
    table = (
        '<div class="table-scroll"><table>'
        f"<thead><tr><th>{esc(s['table_id'])}</th><th>{esc(s['table_category'])}</th>"
        f"<th>{esc(s['table_title'])}</th><th>{esc(s['table_detect'])}</th>"
        f"<th>{esc(s['table_importance'])}</th></tr></thead>"
        f"<tbody>{''.join(body)}</tbody></table></div>"
    )
    return (
        f'<details class="section"><summary>{esc(summary_label)} ({len(rows)})</summary>'
        f'<div class="body">{table}</div></details>'
    )


def render_gotchas(triggered: list[dict[str, Any]], lang: str) -> str:
    s = STRINGS[lang]
    if not triggered:
        return f'<p class="mute">{esc(s["empty_gotchas"])}</p>'
    out = []
    for g in triggered:
        sev = (g.get("severity") or "warn").lower()
        cls = "warn" if sev in ("warn", "error") else "note"
        out.append(
            f'<div class="callout {cls}">'
            f'<span class="tag">{esc(sev.upper())} · {esc(g.get("id"))}</span>'
            f'<p><strong>{esc(g.get("title"))}</strong></p>'
            f'<p>{esc(g.get("fix_hint") or "")}</p>'
            "</div>"
        )
    return "\n".join(out)


def render_manifest(manifest: dict[str, Any], lang: str) -> str:
    strs = STRINGS[lang]
    if not manifest:
        return f'<p class="mute">{esc(strs["empty_manifest"])}</p>'
    sources = manifest.get("sources") or manifest.get("entries") or []
    if not isinstance(sources, list) or not sources:
        return f'<p class="mute">{esc(strs["empty_sources"])}</p>'

    # Filter valid dicts; sort by fetched_at desc (lexicographic on ISO works).
    valid = [s for s in sources if isinstance(s, dict)]

    def _ts(s: dict[str, Any]) -> str:
        return str(s.get("fetched_at") or s.get("last_fetched") or "")

    valid_sorted = sorted(valid, key=_ts, reverse=True)
    total = len(valid_sorted)
    changed_total = sum(1 for s in valid_sorted if s.get("changed"))
    top = valid_sorted[:8]

    rows: list[str] = []
    for src in top:
        name = src.get("name") or src.get("id") or src.get("url") or "?"
        last = src.get("fetched_at") or src.get("last_fetched") or "-"
        url = src.get("url") or ""
        name_html = (
            f'<a href="{esc(url)}" target="_blank" rel="noopener">{esc(name)}</a>'
            if url
            else esc(name)
        )
        if src.get("changed"):
            status_html = (
                f'<span class="badge hypo">{esc(strs["changed_tag"])}</span>'
            )
        else:
            status_html = f'<span class="mute">{esc(src.get("status") or "-")}</span>'
        rows.append(
            f"<tr><td>{name_html}</td><td>{esc(last)}</td><td>{status_html}</td></tr>"
        )
    if not rows:
        return f'<p class="mute">{esc(strs["empty_sources"])}</p>'

    tracking = strs["sources_tracking_line"].format(n=total, m=changed_total)
    return (
        f'<p class="mute">{esc(tracking)}</p>'
        '<div class="table-scroll"><table>'
        f"<thead><tr><th>{esc(strs['table_source'])}</th>"
        f"<th>{esc(strs['table_last_fetched'])}</th>"
        f"<th>{esc(strs['table_status'])}</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table></div>"
    )


def compose_body(
    title: str,
    sections: dict[str, str],
    lang: str,
) -> str:
    s = STRINGS[lang]
    return f"""
<p class="lead">{s['lead']}</p>

<h2 id="hero" class="numbered">{esc(s['section_hero'])}</h2>
{sections['hero']}

<h2 id="top-actions" class="numbered">{esc(s['section_top_actions'])}</h2>
{sections['top_actions']}

<h2 id="missing" class="numbered">{esc(s['section_missing'])}</h2>
{sections['missing']}

<h2 id="gotchas" class="numbered">{esc(s['section_gotchas'])}</h2>
{sections['gotchas']}

<h2 id="sources" class="numbered">{esc(s['section_sources'])}</h2>
{sections['manifest']}

<h2 id="adopted" class="numbered">{esc(s['section_adopted'])}</h2>
<details class="section"><summary>{esc(s['section_adopted'])} ({sections['adopted_count']})</summary>
<div class="body">{sections['adopted']}</div></details>

<h2 id="not-needed" class="numbered">{esc(s['section_not_needed'])}</h2>
{sections['not_needed']}

<h2 id="unknown" class="numbered">{esc(s['section_unknown'])}</h2>
{sections['unknown']}
""".strip()


# ----------------------------- template injection -----------------------------


_MAIN_BLOCK_RE = re.compile(
    r'(<main[^>]*>\s*<div class="container">)(.*?)(</div>\s*</main>)',
    re.DOTALL,
)


def ensure_sentinel(template_path: Path) -> str:
    """Read template; if no sentinel, inject one inside main.container and write back."""
    text = template_path.read_text(encoding="utf-8")
    if SENTINEL in text:
        return text
    m = _MAIN_BLOCK_RE.search(text)
    if not m:
        sys.stderr.write(
            f"ERROR: template {template_path} has no <main><div class='container'>...</div></main> block.\n"
        )
        sys.exit(2)
    new_text = text[: m.start(2)] + f"\n{SENTINEL}\n" + text[m.end(2) :]
    template_path.write_text(new_text, encoding="utf-8")
    return new_text


def inject(text: str, title: str, body_html: str, scope: str) -> str:
    """Replace title, h1, syslabel, meta date/scope, then sentinel with body_html."""
    date = datetime.now().strftime("%Y-%m-%d")
    # <title>
    text = re.sub(
        r"<title>[^<]*</title>",
        f"<title>{esc(title)} — {date}</title>",
        text,
        count=1,
    )
    # syslabel
    text = re.sub(
        r'(<p class="syslabel">)[^<]*(</p>)',
        rf"\1// HARNESS GAP · v1\2",
        text,
        count=1,
    )
    # h1 in header.doc
    text = re.sub(
        r'(<header class="doc">.*?<h1[^>]*>)[^<]*(</h1>)',
        rf"\1{esc(title)}\2",
        text,
        count=1,
        flags=re.DOTALL,
    )
    # meta block (rewrite the three spans)
    meta_html = (
        f'<span><span class="k">date</span> {esc(date)}</span>'
        f'<span><span class="k">author</span> harness-gap</span>'
        f'<span><span class="k">scope</span> {esc(scope)}</span>'
    )
    text = re.sub(
        r'(<div class="meta">)(.*?)(</div>)',
        rf"\1{meta_html}\3",
        text,
        count=1,
        flags=re.DOTALL,
    )
    # Inject body
    text = text.replace(SENTINEL, body_html, 1)
    return text


# ----------------------------- main -----------------------------


def main() -> int:
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "").rstrip("/")
    default_template = (
        f"{plugin_root}/skills/harness-gap/templates/report.html"
        if plugin_root
        else str(
            Path(__file__).resolve().parent.parent / "templates" / "report.html"
        )
    )

    ap = argparse.ArgumentParser(description="Render Claude Code harness gap HTML report.")
    ap.add_argument("--inventory", required=True)
    ap.add_argument("--rubric", required=True)
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--template", default=default_template)
    ap.add_argument("--output", required=True)
    ap.add_argument("--title", default="Claude Code Harness Gap Report")
    ap.add_argument("--scope", default="repo")
    ap.add_argument("--lang", choices=["en", "ja"], default="en", help="report language")
    args = ap.parse_args()
    lang = args.lang

    inventory = load_json(args.inventory)
    inventory = normalize_inventory(inventory)
    rubric = load_yaml(args.rubric)
    manifest = load_json(args.manifest) if args.manifest else {}

    dimensions = rubric.get("dimensions") or []
    gotchas = rubric.get("gotchas") or []

    # 1. Run detectors and bucket
    adopted: list[dict[str, Any]] = []
    missing: list[dict[str, Any]] = []  # required+recommended
    missing_required: list[dict[str, Any]] = []
    missing_recommended: list[dict[str, Any]] = []
    not_needed: list[dict[str, Any]] = []
    unknown: list[dict[str, Any]] = []

    for dim in dimensions:
        status = detect(dim, inventory)
        b = bucket(dim, status)
        dim_view = {
            "id": dim.get("id"),
            "category": dim.get("category"),
            "title": dim.get("title"),
            "importance": dim.get("importance"),
            "why_matters": dim.get("why_matters"),
            "definition": dim.get("definition"),
            "source_url": dim.get("source_url"),
            "detect": dim.get("detect"),
        }
        if b == "adopted":
            adopted.append(dim_view)
        elif b == "missing":
            missing.append(dim_view)
            if (dim_view["importance"] or "").lower() == "required":
                missing_required.append(dim_view)
            else:
                missing_recommended.append(dim_view)
        elif b == "not-needed":
            not_needed.append(dim_view)
        else:
            unknown.append(dim_view)

    # 2. Check gotchas
    triggered_gotchas: list[dict[str, Any]] = []
    for g in gotchas:
        status = detect(g, inventory)
        if status == "pass":  # gotcha detect=pass means triggered
            triggered_gotchas.append(g)

    # 3. Summary
    total = len(dimensions)
    req_rec_total = sum(
        1 for d in dimensions if (d.get("importance") or "").lower() in ("required", "recommended")
    )
    adopted_req_rec = sum(
        1 for d in adopted if (d.get("importance") or "").lower() in ("required", "recommended")
    )
    adoption_pct = (adopted_req_rec / req_rec_total * 100) if req_rec_total else 0.0
    summary = {
        "total": total,
        "adopted": len(adopted),
        "missing_required": len(missing_required),
        "missing_recommended": len(missing_recommended),
        "not_needed": len(not_needed),
        "unknown": len(unknown),
        "gotchas_triggered": len(triggered_gotchas),
    }

    # 4. Compose body
    strs = STRINGS[lang]
    sections = {
        "hero": render_hero(summary, adoption_pct, lang),
        "top_actions": render_top_actions(
            missing_required, missing_recommended, triggered_gotchas, lang, k=3
        ),
        "adopted": render_adopted_table(adopted, lang),
        "adopted_count": len(adopted),
        "missing": render_missing(missing, lang),
        "not_needed": render_collapsed_table(not_needed, strs["collapsed_not_needed"], lang),
        "unknown": render_collapsed_table(unknown, strs["collapsed_unknown"], lang),
        "gotchas": render_gotchas(triggered_gotchas, lang),
        "manifest": render_manifest(manifest, lang),
    }
    body_html = compose_body(args.title, sections, lang)

    # 5. Inject into template
    tpl_path = Path(args.template)
    template_text = ensure_sentinel(tpl_path)
    final_html = inject(template_text, args.title, body_html, args.scope)

    # 6. Write
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(final_html, encoding="utf-8")

    # 7. Stdout summary
    print(
        "[render-report] "
        f"total={summary['total']} "
        f"adopted={summary['adopted']} "
        f"missing_req={summary['missing_required']} "
        f"missing_rec={summary['missing_recommended']} "
        f"not_needed={summary['not_needed']} "
        f"unknown={summary['unknown']} "
        f"gotchas={summary['gotchas_triggered']} "
        f"adoption={adoption_pct:.1f}%"
    )
    print(f"[render-report] output: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
