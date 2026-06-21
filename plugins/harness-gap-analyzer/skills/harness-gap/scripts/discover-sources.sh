#!/usr/bin/env bash
# discover-sources.sh
# -----------------------------------------------------------------------------
# Probe the public web for *new* Claude Code / Anthropic / agent-harness best-
# practice sources (GitHub topics, repo releases, Anthropic engineering blog,
# Claude Code llms.txt, Hacker News, GitHub code search).
#
# Output is a single candidates YAML for human review. The script *never*
# auto-appends to sources/anthropic.yaml or sources/community.yaml — the user
# promotes individual candidates manually.
#
# Failures are non-blocking: per-probe errors go to stderr and the run keeps
# going. Exit code is 0 unless CLI args are unparseable.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults / CLI
# -----------------------------------------------------------------------------

CONFIG="${CLAUDE_PLUGIN_ROOT:-}/skills/harness-gap/sources/discovery.yaml"
DEFAULT_OUT="${HOME}/.claude/harness-gap/discovered-$(date +%Y%m%d).yaml"
OUT="${DEFAULT_OUT}"
SINCE_DAYS=30
MAX_PER_QUERY=20
VERBOSITY=1   # 0=quiet, 1=normal, 2=verbose

usage() {
  cat >&2 <<EOF
Usage: $0 [options]

Options:
  --config <path>         discovery.yaml config
                          (default: \${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/sources/discovery.yaml)
  --out <path>            candidates YAML output
                          (default: ~/.claude/harness-gap/discovered-YYYYMMDD.yaml)
  --since-days <int>      look back window in days  (default: 30)
  --max-per-query <int>   cap hits per probe        (default: 20)
  --quiet                 errors only
  --verbose               per-probe progress
  -h | --help             this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)         CONFIG="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --since-days)     SINCE_DAYS="$2"; shift 2 ;;
    --max-per-query)  MAX_PER_QUERY="$2"; shift 2 ;;
    --quiet)          VERBOSITY=0; shift ;;
    --verbose)        VERBOSITY=2; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "${CONFIG}" ] || [ ! -f "${CONFIG}" ]; then
  echo "discover-sources: --config not found: ${CONFIG}" >&2
  exit 2
fi

mkdir -p "$(dirname "${OUT}")"

log()  { [ "${VERBOSITY}" -ge 1 ] && printf '[discover] %s\n' "$*" >&2 || true; }
vlog() { [ "${VERBOSITY}" -ge 2 ] && printf '[discover] %s\n' "$*" >&2 || true; }
err()  { printf '[discover:ERROR] %s\n' "$*" >&2; }

START_TIME="$(date +%s)"
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hg-discover.XXXXXX")"
trap 'rm -rf "${RUN_TMP}"' EXIT

# -----------------------------------------------------------------------------
# Read config + fetch policy via python3 -> JSON lines
# -----------------------------------------------------------------------------

# Build "since" date for GitHub queries (YYYY-MM-DD)
case "$(uname -s)" in
  Darwin) SINCE_DATE="$(date -v-${SINCE_DAYS}d +%Y-%m-%d)" ;;
  *)      SINCE_DATE="$(date -d "${SINCE_DAYS} days ago" +%Y-%m-%d)" ;;
esac

# Unix epoch SINCE for HN
case "$(uname -s)" in
  Darwin) SINCE_EPOCH="$(date -v-${SINCE_DAYS}d +%s)" ;;
  *)      SINCE_EPOCH="$(date -d "${SINCE_DAYS} days ago" +%s)" ;;
esac

# Parse discovery.yaml -> JSON Lines (one query per line) + fetch policy JSON.
POLICY_JSON="$(python3 - "$CONFIG" <<'PY'
import json, sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    text = f.read()

# Minimal YAML parser: rely on PyYAML if available, else fall back.
try:
    import yaml
    data = yaml.safe_load(text)
except ImportError:
    # Tiny hand-rolled subset parser - good enough for our config shape
    data = {}
    cur = data
    stack = [(0, data)]
    last_list = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith('#'):
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        # ignore — too brittle. Just emit empty and let outer fail loudly.
    raise SystemExit("PyYAML not available; please `pip install pyyaml`.")

policy = data.get('fetch_policy', {}) or {}
print(json.dumps(policy))
PY
)"

RATE_LIMIT_MS="$(printf '%s' "$POLICY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("rate_limit_ms", 500))')"
USER_AGENT="$(printf '%s' "$POLICY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("user_agent", "harness-gap-analyzer/0.2"))')"
SLEEP_SEC="$(python3 -c "print(${RATE_LIMIT_MS}/1000)")"

# Queries as JSONL
QUERIES_JSONL="${RUN_TMP}/queries.jsonl"
python3 - "$CONFIG" >"${QUERIES_JSONL}" <<'PY'
import json, sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for q in (data.get('queries') or []):
    print(json.dumps(q))
PY

if [ ! -s "${QUERIES_JSONL}" ]; then
  err "no queries in ${CONFIG}"
  exit 2
fi

log "config:        ${CONFIG}"
log "since:         ${SINCE_DATE} (epoch ${SINCE_EPOCH})"
log "out:           ${OUT}"
log "max-per-query: ${MAX_PER_QUERY}"
log "rate limit:    ${RATE_LIMIT_MS}ms"

# -----------------------------------------------------------------------------
# Existing-catalog URL set, used for `existing_in_catalog` flag.
# -----------------------------------------------------------------------------

SOURCES_DIR="$(dirname "${CONFIG}")"
EXISTING_URLS="${RUN_TMP}/existing_urls.txt"
{
  grep -hE "^\s*url:\s*" "${SOURCES_DIR}/anthropic.yaml" 2>/dev/null || true
  grep -hE "^\s*url:\s*" "${SOURCES_DIR}/community.yaml" 2>/dev/null || true
} | sed -E 's/^\s*url:\s*//; s/^"//; s/"$//; s/[[:space:]]*$//' \
  | sort -u >"${EXISTING_URLS}"
vlog "existing URLs known: $(wc -l <"${EXISTING_URLS}" | tr -d ' ')"

is_existing() {
  # arg1: url
  grep -Fxq "$1" "${EXISTING_URLS}" 2>/dev/null
}

# -----------------------------------------------------------------------------
# gh CLI detection
# -----------------------------------------------------------------------------

HAS_GH=0
GH_AUTHED=0
if command -v gh >/dev/null 2>&1; then
  HAS_GH=1
  if gh auth status >/dev/null 2>&1; then
    GH_AUTHED=1
  fi
fi
if [ "${HAS_GH}" -eq 0 ]; then
  log "gh CLI not found — falling back to anonymous api.github.com (rate-limited)"
elif [ "${GH_AUTHED}" -eq 0 ]; then
  log "gh CLI present but not authenticated — using anonymous api.github.com"
fi

gh_get() {
  # arg1: path (e.g. search/repositories), arg2..: -f flags or raw query
  local path="$1"; shift
  if [ "${HAS_GH}" -eq 1 ] && [ "${GH_AUTHED}" -eq 1 ]; then
    gh api -X GET "${path}" "$@" 2>>"${RUN_TMP}/gh.err" || return 1
  else
    # Build query string from -f key=value pairs
    local qs=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f)
          local kv="$2"
          qs="${qs}&${kv}"
          shift 2 ;;
        *) shift ;;
      esac
    done
    qs="${qs#&}"
    local url="https://api.github.com/${path}"
    [ -n "${qs}" ] && url="${url}?${qs}"
    curl -sSL -A "${USER_AGENT}" -H "Accept: application/vnd.github+json" "${url}" 2>>"${RUN_TMP}/curl.err" || return 1
  fi
}

# -----------------------------------------------------------------------------
# Per-probe emitters — each writes JSONL records:
#   {kind, url, title, signal, raw, query_id}
# -----------------------------------------------------------------------------

CANDIDATES_JSONL="${RUN_TMP}/candidates.jsonl"
: >"${CANDIDATES_JSONL}"

emit_record() {
  # stdin: JSON record on a single line
  cat >>"${CANDIDATES_JSONL}"
}

probe_github_topic() {
  local qid="$1" topic="$2" min_stars="$3"
  vlog "[${qid}] github_topic topic=${topic} since=${SINCE_DATE} min_stars=${min_stars}"
  local q="topic:${topic} created:>=${SINCE_DATE}"
  local body_file="${RUN_TMP}/body.${qid}.json"
  if ! gh_get search/repositories -f "q=${q}" -f "per_page=${MAX_PER_QUERY}" -f "sort=stars" -f "order=desc" >"${body_file}" 2>>"${RUN_TMP}/gh.err"; then
    err "[${qid}] github_topic fetch failed"
    return 0
  fi
  if [ ! -s "${body_file}" ]; then err "[${qid}] empty github_topic response"; return 0; fi
  python3 - "$qid" "$min_stars" "$body_file" <<'PY'
import json, sys
qid = sys.argv[1]
min_stars = int(sys.argv[2])
body_path = sys.argv[3]
try:
    with open(body_path) as f:
        data = json.load(f)
except Exception as e:
    print(f"[{qid}] json parse fail: {e}", file=sys.stderr)
    sys.exit(0)
items = data.get('items', []) or []
for it in items:
    stars = it.get('stargazers_count') or 0
    if stars < min_stars:
        continue
    rec = {
        "kind": "github_topic_hit",
        "url": it.get('html_url'),
        "title": it.get('full_name'),
        "signal": stars,
        "query_id": qid,
        "raw": {
            "description": it.get('description'),
            "pushed_at":   it.get('pushed_at'),
            "topics":      it.get('topics', []),
            "stargazers":  stars,
        },
    }
    print(json.dumps(rec))
PY
}

probe_github_repo_releases() {
  local qid="$1" repo="$2"
  vlog "[${qid}] github_repo_releases repo=${repo}"
  local body_file="${RUN_TMP}/body.${qid}.json"
  if ! gh_get "repos/${repo}/releases" -f "per_page=10" >"${body_file}" 2>>"${RUN_TMP}/gh.err"; then
    err "[${qid}] repo_releases fetch failed"
    return 0
  fi
  if [ ! -s "${body_file}" ]; then err "[${qid}] empty repo_releases response"; return 0; fi
  python3 - "$qid" "$SINCE_DATE" "$MAX_PER_QUERY" "$body_file" <<'PY'
import json, sys
from datetime import datetime, timezone
qid, since_date, cap, body_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
since = datetime.strptime(since_date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
try:
    with open(body_path) as f:
        data = json.load(f)
except Exception as e:
    print(f"[{qid}] json parse fail: {e}", file=sys.stderr)
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
count = 0
for rel in data:
    pub = rel.get('published_at') or rel.get('created_at')
    if not pub:
        continue
    try:
        dt = datetime.strptime(pub, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        continue
    if dt < since:
        continue
    rec = {
        "kind": "gh_release",
        "url": rel.get('html_url'),
        "title": rel.get('name') or rel.get('tag_name'),
        "signal": rel.get('reactions', {}).get('total_count', 0) if isinstance(rel.get('reactions'), dict) else 0,
        "query_id": qid,
        "raw": {
            "tag_name":     rel.get('tag_name'),
            "published_at": pub,
            "prerelease":   rel.get('prerelease', False),
            "draft":        rel.get('draft', False),
        },
    }
    print(json.dumps(rec))
    count += 1
    if count >= cap:
        break
PY
}

probe_anthropic_blog_index() {
  local qid="$1" url="$2"
  vlog "[${qid}] anthropic_blog_index url=${url}"
  local body_file="${RUN_TMP}/body.${qid}.html"
  if ! curl -sSL -A "${USER_AGENT}" "${url}" >"${body_file}" 2>>"${RUN_TMP}/curl.err"; then
    err "[${qid}] blog index fetch failed"
    return 0
  fi
  if [ ! -s "${body_file}" ]; then err "[${qid}] empty blog index"; return 0; fi
  python3 - "$qid" "$MAX_PER_QUERY" "$EXISTING_URLS" "$body_file" <<'PY'
import json, sys, re
qid, cap, existing_path, body_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
try:
    with open(existing_path) as f:
        existing = set(l.strip() for l in f if l.strip())
except FileNotFoundError:
    existing = set()
with open(body_path) as f:
    html = f.read()
# Match /engineering/<slug> hrefs
slugs = set(re.findall(r'href="(/engineering/[a-z0-9][a-z0-9-]+)"', html))
# Filter the index page itself
slugs.discard('/engineering')
emitted = 0
for slug in sorted(slugs):
    full = f"https://www.anthropic.com{slug}"
    title = slug.rsplit('/', 1)[-1].replace('-', ' ').title()
    if full in existing:
        continue
    rec = {
        "kind": "blog_post",
        "url": full,
        "title": title,
        "signal": 0,
        "query_id": qid,
        "raw": {"slug": slug},
    }
    print(json.dumps(rec))
    emitted += 1
    if emitted >= cap:
        break
PY
}

probe_claude_docs_llms_txt() {
  local qid="$1" url="$2"
  vlog "[${qid}] claude_docs_llms_txt url=${url}"
  local cache_path body_file
  cache_path="${HOME}/.claude/harness-gap/cache/llms-txt-prev.txt"
  body_file="${RUN_TMP}/body.${qid}.txt"
  mkdir -p "$(dirname "${cache_path}")"
  if ! curl -sSL -A "${USER_AGENT}" "${url}" >"${body_file}" 2>>"${RUN_TMP}/curl.err"; then
    err "[${qid}] llms.txt fetch failed"
    return 0
  fi
  if [ ! -s "${body_file}" ]; then err "[${qid}] empty llms.txt"; return 0; fi
  cp "${body_file}" "${cache_path}.next"
  python3 - "$qid" "$MAX_PER_QUERY" "$EXISTING_URLS" "${cache_path}" "${body_file}" <<'PY'
import json, sys, re, os
qid, cap, existing_path, cache_path, body_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
try:
    with open(existing_path) as f:
        existing = set(l.strip() for l in f if l.strip())
except FileNotFoundError:
    existing = set()
prev = ""
if os.path.exists(cache_path):
    with open(cache_path) as f:
        prev = f.read()
prev_urls = set(re.findall(r'https?://[^\s)\]]+', prev))
with open(body_path) as f:
    text = f.read()
first_run = not os.path.exists(cache_path)
urls = re.findall(r'https?://[^\s)\]]+', text)
seen = set()
emitted = 0
for u in urls:
    u = u.rstrip('.,);')
    if u in seen:
        continue
    seen.add(u)
    if u in existing:
        continue
    # Only emit URLs new vs previous cache to keep noise down
    is_new = (u not in prev_urls)
    if not is_new:
        continue
    rec = {
        "kind": "doc_page",
        "url": u,
        "title": u.rsplit('/', 1)[-1] or u,
        "signal": 0,
        "query_id": qid,
        "raw": {"source_index": "llms.txt"},
    }
    print(json.dumps(rec))
    emitted += 1
    if emitted >= cap:
        break
PY
  # Commit the next cache for the diff next run
  if [ -f "${cache_path}.next" ]; then
    mv "${cache_path}.next" "${cache_path}"
  fi
}

probe_hn_query() {
  local qid="$1" query="$2" min_points="$3"
  vlog "[${qid}] hn_query query='${query}' min_points=${min_points}"
  local q_enc
  q_enc="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${query}")"
  # Note: `>` must be URL-encoded to %3E for the Algolia numericFilters param.
  local url="https://hn.algolia.com/api/v1/search_by_date?query=${q_enc}&tags=story&numericFilters=created_at_i%3E${SINCE_EPOCH}&hitsPerPage=${MAX_PER_QUERY}"
  local body_file="${RUN_TMP}/body.${qid}.json"
  if ! curl -sSL -A "${USER_AGENT}" "${url}" >"${body_file}" 2>>"${RUN_TMP}/curl.err"; then
    err "[${qid}] hn fetch failed"
    return 0
  fi
  if [ ! -s "${body_file}" ]; then err "[${qid}] empty hn response"; return 0; fi
  python3 - "$qid" "$min_points" "$body_file" <<'PY'
import json, sys
qid, min_points, body_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(body_path) as f:
        data = json.load(f)
except Exception as e:
    print(f"[{qid}] json parse fail: {e}", file=sys.stderr)
    sys.exit(0)
hits = data.get('hits', []) or []
for h in hits:
    points = h.get('points') or 0
    if points < min_points:
        continue
    obj_id = h.get('objectID')
    rec = {
        "kind": "hn_post",
        "url": h.get('url') or f"https://news.ycombinator.com/item?id={obj_id}",
        "title": h.get('title') or h.get('story_title') or "(untitled)",
        "signal": points,
        "query_id": qid,
        "raw": {
            "points":      points,
            "num_comments": h.get('num_comments'),
            "created_at":  h.get('created_at'),
            "author":      h.get('author'),
        },
    }
    print(json.dumps(rec))
PY
}

probe_github_search_code() {
  local qid="$1" query="$2"
  vlog "[${qid}] github_search_code query='${query}'"
  local body_file="${RUN_TMP}/body.${qid}.json"
  if ! gh_get search/code -f "q=${query}" -f "per_page=${MAX_PER_QUERY}" >"${body_file}" 2>>"${RUN_TMP}/gh.err"; then
    err "[${qid}] code search fetch failed (auth required?)"
    return 0
  fi
  if [ ! -s "${body_file}" ]; then err "[${qid}] empty code search (auth required?)"; return 0; fi
  python3 - "$qid" "$body_file" <<'PY'
import json, sys
qid, body_path = sys.argv[1], sys.argv[2]
try:
    with open(body_path) as f:
        data = json.load(f)
except Exception as e:
    print(f"[{qid}] json parse fail: {e}", file=sys.stderr)
    sys.exit(0)
items = data.get('items', []) or []
for it in items:
    repo = (it.get('repository') or {})
    rec = {
        "kind": "gh_code_hit",
        "url": it.get('html_url'),
        "title": f"{repo.get('full_name','?')}/{it.get('path','?')}",
        "signal": repo.get('stargazers_count') or 0,
        "query_id": qid,
        "raw": {
            "repo":   repo.get('full_name'),
            "path":   it.get('path'),
            "score":  it.get('score'),
        },
    }
    print(json.dumps(rec))
PY
}

# -----------------------------------------------------------------------------
# Dispatch loop (sequential w/ rate-limit sleep; max_parallel kept simple).
# -----------------------------------------------------------------------------

PROBE_COUNT=0
while IFS= read -r line; do
  [ -z "${line}" ] && continue
  PROBE_COUNT=$((PROBE_COUNT+1))
  before_lines="$(wc -l <"${CANDIDATES_JSONL}" | tr -d ' ')"
  qid="$(printf '%s' "${line}" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')"
  kind="$(printf '%s' "${line}" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["kind"])')"

  set +e
  case "${kind}" in
    github_topic)
      topic="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["topic"])')"
      min_stars="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("min_stars",0))')"
      probe_github_topic "${qid}" "${topic}" "${min_stars}" | tee -a "${CANDIDATES_JSONL}" >/dev/null
      ;;
    github_repo_releases)
      repo="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["repo"])')"
      probe_github_repo_releases "${qid}" "${repo}" | tee -a "${CANDIDATES_JSONL}" >/dev/null
      ;;
    anthropic_blog_index)
      url="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["url"])')"
      probe_anthropic_blog_index "${qid}" "${url}" | tee -a "${CANDIDATES_JSONL}" >/dev/null
      ;;
    claude_docs_llms_txt)
      url="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["url"])')"
      probe_claude_docs_llms_txt "${qid}" "${url}" | tee -a "${CANDIDATES_JSONL}" >/dev/null
      ;;
    hn_query)
      query="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["query"])')"
      min_points="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("min_points",0))')"
      probe_hn_query "${qid}" "${query}" "${min_points}" | tee -a "${CANDIDATES_JSONL}" >/dev/null
      ;;
    github_search_code)
      query="$(printf '%s' "${line}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["query"])')"
      probe_github_search_code "${qid}" "${query}" | tee -a "${CANDIDATES_JSONL}" >/dev/null
      ;;
    *)
      err "[${qid}] unknown kind: ${kind}"
      ;;
  esac
  rc=$?
  set -e

  after_lines="$(wc -l <"${CANDIDATES_JSONL}" | tr -d ' ')"
  added=$((after_lines - before_lines))
  if [ "${added}" -eq 0 ]; then
    log "[${qid}] 0 hits (probe may need tuning or upstream returned empty)"
  else
    vlog "[${qid}] +${added} candidates"
  fi

  # Polite delay between probes
  sleep "${SLEEP_SEC}" 2>/dev/null || true
done <"${QUERIES_JSONL}"

# -----------------------------------------------------------------------------
# Aggregate -> output YAML
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "${OUT}")"

python3 - "${CANDIDATES_JSONL}" "${EXISTING_URLS}" "${OUT}" <<'PY'
import json, sys, os, re, datetime

jsonl_path, existing_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(existing_path) as f:
        existing = set(l.strip() for l in f if l.strip())
except FileNotFoundError:
    existing = set()

KIND_TO_CATEGORY = {
    "github_topic_hit": "repo",
    "gh_release":       "repo",
    "gh_code_hit":      "repo",
    "blog_post":        "blog",
    "doc_page":         "product-docs",
    "hn_post":          "blog",
}

def slugify(s, fallback="cand"):
    s = (s or fallback).strip().lower()
    s = re.sub(r'[^a-z0-9]+', '-', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s[:80] or fallback

records = []
seen_urls = set()
if os.path.exists(jsonl_path):
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            url = (rec.get('url') or '').strip()
            if not url:
                continue
            if url in seen_urls:
                continue
            seen_urls.add(url)
            records.append(rec)

# Sort by signal desc, then by kind for stability
records.sort(key=lambda r: (-(r.get('signal') or 0), r.get('kind', ''), r.get('url', '')))

now_iso = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0, tzinfo=None).isoformat() + "Z"

candidates = []
used_ids = set()
for r in records:
    base_id = slugify(r.get('title') or r.get('url'))
    cand_id = base_id
    n = 2
    while cand_id in used_ids:
        cand_id = f"{base_id}-{n}"
        n += 1
    used_ids.add(cand_id)
    candidates.append({
        "id":                cand_id,
        "url":               r.get('url'),
        "title":             r.get('title') or '',
        "kind":              r.get('kind'),
        "signal":            r.get('signal') or 0,
        "category_guess":    KIND_TO_CATEGORY.get(r.get('kind', ''), 'repo'),
        "discovered_at":     now_iso,
        "first_seen_via":    r.get('query_id') or '',
        "existing_in_catalog": (r.get('url') in existing),
    })

# Manual YAML emit (avoid depending on PyYAML's output style).
def yaml_str(v):
    if v is None:
        return '""'
    s = str(v)
    if any(ch in s for ch in [':', '#', '"', "'", '\n', '@']) or s.strip() != s:
        # quote safely
        s2 = s.replace('\\', '\\\\').replace('"', '\\"')
        return f"\"{s2}\""
    if s == '' or s.lower() in ('yes', 'no', 'true', 'false', 'null'):
        return f"\"{s}\""
    return s

lines = []
lines.append(f"# Auto-generated by discover-sources.sh at {now_iso}")
lines.append(f"# Total candidates: {len(candidates)}")
lines.append("meta:")
lines.append(f"  generated_at: {now_iso}")
lines.append(f"  total: {len(candidates)}")
lines.append("candidates:")
for c in candidates:
    lines.append(f"  - id: {yaml_str(c['id'])}")
    lines.append(f"    url: {yaml_str(c['url'])}")
    lines.append(f"    title: {yaml_str(c['title'])}")
    lines.append(f"    kind: {yaml_str(c['kind'])}")
    lines.append(f"    signal: {int(c['signal'])}")
    lines.append(f"    category_guess: {yaml_str(c['category_guess'])}")
    lines.append(f"    discovered_at: {yaml_str(c['discovered_at'])}")
    lines.append(f"    first_seen_via: {yaml_str(c['first_seen_via'])}")
    lines.append(f"    existing_in_catalog: {'true' if c['existing_in_catalog'] else 'false'}")

with open(out_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')

# Stats to stderr
from collections import Counter
by_kind = Counter(c['kind'] for c in candidates)
print(f"[discover] wrote {len(candidates)} candidates to {out_path}", file=sys.stderr)
for k, n in sorted(by_kind.items()):
    print(f"[discover]   {k}: {n}", file=sys.stderr)
PY

END_TIME="$(date +%s)"
ELAPSED=$((END_TIME - START_TIME))
log "done in ${ELAPSED}s — output: ${OUT}"
