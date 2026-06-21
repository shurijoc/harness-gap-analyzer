#!/usr/bin/env bash
# fetch-sources.sh
# -----------------------------------------------------------------------------
# Fetch the configured Anthropic + community knowledge sources, cache responses,
# and emit a manifest of what changed since the last fetch.
#
# The script reads `*.yaml` files in --sources-dir, treats every entry under
# `sources:` as a source record, and supports two transports:
#   - method: HTML     -> curl with conditional-get + redirect follow
#   - method: git_api  -> `gh api` if logged in, else api.github.com anon
#
# Each source body is cached at:    <cache-dir>/<cache_key>.body
# Each source's metadata at:        <cache-dir>/<cache_key>.meta.json
# Run-level manifest at:            <cache-dir>/manifest.json
#
# Failures are non-blocking: they are logged to stderr, marked failed in the
# manifest, and the run continues. The script's exit code is 0 unless something
# catastrophic happens (bad CLI args, no sources at all, etc.).
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults / CLI
# -----------------------------------------------------------------------------

SOURCES_DIR="${CLAUDE_PLUGIN_ROOT:-}/skills/harness-gap/sources"
CACHE_DIR="${HOME}/.claude/harness-gap/cache"
MAX_AGE_HOURS=24
ONLY_CATEGORY=""
VERBOSITY=1   # 0=quiet, 1=normal, 2=verbose
MAX_PARALLEL=4
LAUNCH_SLEEP="0.5"

usage() {
  cat >&2 <<EOF
Usage: $0 [options]

Options:
  --sources-dir <path>    Directory of *.yaml source catalogs
                          (default: \${CLAUDE_PLUGIN_ROOT}/skills/harness-gap/sources)
  --cache-dir <path>      Cache directory  (default: ~/.claude/harness-gap/cache)
  --max-age-hours <int>   Skip fetch if cached body is fresher  (default: 24)
  --only <category>       Filter by category (product-docs, blog, repo, ...)
  --quiet                 Errors only
  --verbose               Per-source progress
  -h | --help             This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sources-dir)    SOURCES_DIR="$2"; shift 2 ;;
    --cache-dir)      CACHE_DIR="$2"; shift 2 ;;
    --max-age-hours)  MAX_AGE_HOURS="$2"; shift 2 ;;
    --only)           ONLY_CATEGORY="$2"; shift 2 ;;
    --quiet)          VERBOSITY=0; shift ;;
    --verbose)        VERBOSITY=2; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "${SOURCES_DIR}" ] || [ ! -d "${SOURCES_DIR}" ]; then
  echo "fetch-sources: --sources-dir not found: ${SOURCES_DIR}" >&2
  exit 2
fi

mkdir -p "${CACHE_DIR}"

# Per-run scratch directory for parallel worker results.
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hg-fetch.XXXXXX")"
trap 'rm -rf "${RUN_TMP}"' EXIT

log()  { [ "${VERBOSITY}" -ge 1 ] && printf '[fetch] %s\n' "$*" >&2 || true; }
vlog() { [ "${VERBOSITY}" -ge 2 ] && printf '[fetch] %s\n' "$*" >&2 || true; }
err()  { printf '[fetch:ERROR] %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# Detect gh CLI auth (used for github.com sources)
# -----------------------------------------------------------------------------

HAS_GH=0
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    HAS_GH=1
  fi
fi
vlog "gh CLI logged in: ${HAS_GH}"

# -----------------------------------------------------------------------------
# Parse all *.yaml in SOURCES_DIR into JSON-lines (one source per line)
# -----------------------------------------------------------------------------

SOURCES_JSONL="${RUN_TMP}/sources.jsonl"

python3 - "${SOURCES_DIR}" "${SOURCES_JSONL}" "${ONLY_CATEGORY}" <<'PY'
import glob, json, os, sys
try:
    import yaml
except Exception as e:
    sys.stderr.write(f"fetch-sources: PyYAML required: {e}\n")
    sys.exit(3)

src_dir, out_path, only_cat = sys.argv[1], sys.argv[2], sys.argv[3]

records = []
yaml_files = sorted(glob.glob(os.path.join(src_dir, "*.yaml")) +
                    glob.glob(os.path.join(src_dir, "*.yml")))
for yf in yaml_files:
    try:
        with open(yf, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except Exception as e:
        sys.stderr.write(f"fetch-sources: failed to parse {yf}: {e}\n")
        continue
    catalog = os.path.basename(yf)
    sources = data.get("sources") or []
    if not isinstance(sources, list):
        continue
    for s in sources:
        if not isinstance(s, dict):
            continue
        if only_cat and (s.get("category") or "") != only_cat:
            continue
        # Required fields for fetch.
        sid = s.get("id")
        url = s.get("url")
        if not sid or not url:
            continue
        records.append({
            "id": sid,
            "url": url,
            "api_url": s.get("api_url") or "",
            "method": (s.get("method") or "HTML"),
            "cache_key": s.get("cache_key") or sid,
            "category": s.get("category") or "",
            "catalog": catalog,
        })

with open(out_path, "w", encoding="utf-8") as f:
    for r in records:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

TOTAL_SOURCES=$(wc -l < "${SOURCES_JSONL}" | tr -d ' ')

if [ "${TOTAL_SOURCES}" -eq 0 ]; then
  err "no sources matched (sources-dir=${SOURCES_DIR}, only=${ONLY_CATEGORY:-<none>})"
  exit 2
fi

log "parsed ${TOTAL_SOURCES} source(s) from ${SOURCES_DIR}"

# -----------------------------------------------------------------------------
# Per-source fetch worker
#
# Inputs (env):
#   SRC_JSON           - the source record as one JSON line
#   CACHE_DIR          - cache root
#   MAX_AGE_HOURS      - freshness threshold
#   HAS_GH             - 0/1
#   RUN_TMP            - tmp dir for result-shards
#   RESULT_SHARD       - path to write JSON result line into
# -----------------------------------------------------------------------------

fetch_one() {
  local src_json="$1"
  local result_shard="$2"

  # Extract fields with python3 (jq not assumed everywhere).
  local fields
  fields="$(python3 -c '
import json, sys
r = json.loads(sys.argv[1])
print(r["id"])
print(r["url"])
print(r["api_url"])
print(r["method"])
print(r["cache_key"])
print(r.get("category",""))
' "${src_json}")"

  local sid url api_url method cache_key category
  sid="$(echo  "${fields}" | sed -n '1p')"
  url="$(echo  "${fields}" | sed -n '2p')"
  api_url="$(echo "${fields}" | sed -n '3p')"
  method="$(echo "${fields}" | sed -n '4p')"
  cache_key="$(echo "${fields}" | sed -n '5p')"
  category="$(echo "${fields}" | sed -n '6p')"

  local body_path meta_path body_dir
  body_path="${CACHE_DIR}/${cache_key}.body"
  meta_path="${CACHE_DIR}/${cache_key}.meta.json"
  body_dir="$(dirname "${body_path}")"
  mkdir -p "${body_dir}"

  # Read previous metadata (if any).
  local prev_sha=""
  local first_time=1
  if [ -f "${meta_path}" ]; then
    first_time=0
    prev_sha="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("sha256",""))
except Exception:
    print("")
' "${meta_path}")"
  fi

  # Freshness check (cache hit).
  local cache_hit=0
  if [ -f "${body_path}" ] && [ -f "${meta_path}" ]; then
    # mtime in seconds-since-epoch (BSD stat -> -f, GNU stat -> -c)
    local mtime now age_h
    mtime="$(stat -f %m "${body_path}" 2>/dev/null || stat -c %Y "${body_path}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age_h=$(( (now - mtime) / 3600 ))
    if [ "${age_h}" -lt "${MAX_AGE_HOURS}" ]; then
      cache_hit=1
    fi
  fi

  # Pick the URL we actually hit. For github sources prefer api_url; otherwise url.
  local fetch_url="${url}"
  local fetch_kind="${method}"
  if [ "${method}" = "git_api" ] && [ -n "${api_url}" ]; then
    fetch_url="${api_url}"
  fi

  local status="" sha="" size=0 error=""
  local fetched=0

  if [ "${cache_hit}" -eq 1 ]; then
    # Don't refetch. Re-use prior meta values.
    status="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("status",""))
except Exception:
    print("")
' "${meta_path}")"
    sha="${prev_sha}"
    size="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("size_bytes",0))
except Exception:
    print(0)
' "${meta_path}")"
  else
    fetched=1
    local tmp_body
    tmp_body="$(mktemp "${RUN_TMP}/body.XXXXXX")"

    # Build If-Modified-Since header from prior cache mtime if present.
    local ims_header=""
    if [ -f "${body_path}" ]; then
      local mtime ims
      mtime="$(stat -f %m "${body_path}" 2>/dev/null || stat -c %Y "${body_path}" 2>/dev/null || echo 0)"
      if [ "${mtime}" -gt 0 ]; then
        # RFC 7231 / IMF-fixdate
        ims="$(date -u -r "${mtime}" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null || \
               date -u -d "@${mtime}" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null || echo "")"
        if [ -n "${ims}" ]; then
          ims_header="If-Modified-Since: ${ims}"
        fi
      fi
    fi

    if [ "${fetch_kind}" = "git_api" ] && [ "${HAS_GH}" -eq 1 ] && [[ "${fetch_url}" =~ ^https://api.github.com/ ]]; then
      # Use `gh api` (handles auth + base URL).
      local gh_path="${fetch_url#https://api.github.com/}"
      if gh api "${gh_path}" --header "User-Agent: harness-gap-analyzer/1.0" >"${tmp_body}" 2>"${RUN_TMP}/err.${sid}"; then
        status="200"
      else
        status="ERR"
        error="$(head -c 400 "${RUN_TMP}/err.${sid}" 2>/dev/null | tr '\n' ' ' || true)"
      fi
    else
      # curl branch (HTML or anonymous GitHub REST).
      local http_code curl_rc
      local hdr_file="${RUN_TMP}/hdr.${sid}"
      : >"${hdr_file}"

      # shellcheck disable=SC2086
      if [ -n "${ims_header}" ]; then
        http_code="$(curl --location --silent --show-error \
                          --fail-with-body \
                          --user-agent "harness-gap-analyzer/1.0" \
                          --header "Accept: */*" \
                          --header "${ims_header}" \
                          --max-time 30 \
                          --write-out '%{http_code}' \
                          --output "${tmp_body}" \
                          "${fetch_url}" 2>"${RUN_TMP}/err.${sid}" || true)"
        curl_rc=$?
      else
        http_code="$(curl --location --silent --show-error \
                          --fail-with-body \
                          --user-agent "harness-gap-analyzer/1.0" \
                          --header "Accept: */*" \
                          --max-time 30 \
                          --write-out '%{http_code}' \
                          --output "${tmp_body}" \
                          "${fetch_url}" 2>"${RUN_TMP}/err.${sid}" || true)"
        curl_rc=$?
      fi

      if [ -z "${http_code}" ]; then http_code="ERR"; fi
      status="${http_code}"

      case "${http_code}" in
        2*)
          : # ok
          ;;
        304)
          # Not modified - keep existing body if any, just refresh mtime.
          if [ -f "${body_path}" ]; then
            touch "${body_path}"
            # Reuse existing body content for the hash check.
            cp "${body_path}" "${tmp_body}"
          fi
          ;;
        *)
          error="HTTP ${http_code} ($(head -c 200 "${RUN_TMP}/err.${sid}" 2>/dev/null | tr '\n' ' ' || true))"
          ;;
      esac
    fi

    if [ -s "${tmp_body}" ] && [[ "${status}" =~ ^(2..|304)$ ]]; then
      sha="$(shasum -a 256 "${tmp_body}" 2>/dev/null | awk '{print $1}')"
      if [ -z "${sha}" ]; then
        sha="$(sha256sum "${tmp_body}" 2>/dev/null | awk '{print $1}')"
      fi
      size="$(wc -c < "${tmp_body}" | tr -d ' ')"
      # If hash matches previous, body unchanged - but we still updated mtime.
      mv "${tmp_body}" "${body_path}"
    else
      sha=""
      size=0
      rm -f "${tmp_body}" || true
    fi
  fi

  # Decide changed/new bookkeeping.
  local changed=false
  local is_new=false
  if [ "${first_time}" -eq 1 ] && [ -n "${sha}" ]; then
    is_new=true
    changed=true
  elif [ -n "${sha}" ] && [ -n "${prev_sha}" ] && [ "${sha}" != "${prev_sha}" ]; then
    changed=true
  fi

  # Write metadata file (only if we have a successful response or cache_hit).
  local fetched_at
  fetched_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if [ -n "${sha}" ]; then
    python3 -c '
import json, sys
d = {
    "fetched_at": sys.argv[1],
    "status":     sys.argv[2],
    "sha256":     sys.argv[3],
    "size_bytes": int(sys.argv[4] or 0),
    "source_id":  sys.argv[5],
    "url":        sys.argv[6],
}
with open(sys.argv[7], "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
' "${fetched_at}" "${status}" "${sha}" "${size}" "${sid}" "${fetch_url}" "${meta_path}"
  fi

  # Emit one-line JSON result for the manifest aggregator.
  python3 -c '
import json, sys
out = {
    "id":         sys.argv[1],
    "url":        sys.argv[2],
    "status":     sys.argv[3],
    "sha256":     sys.argv[4],
    "fetched_at": sys.argv[5],
    "size_bytes": int(sys.argv[6] or 0),
    "cache_hit":  sys.argv[7] == "1",
    "fetched":    sys.argv[8] == "1",
    "changed":    sys.argv[9] == "true",
    "new":        sys.argv[10] == "true",
    "category":   sys.argv[11],
    "error":      sys.argv[12],
}
print(json.dumps(out, ensure_ascii=False))
' "${sid}" "${fetch_url}" "${status}" "${sha}" "${fetched_at}" "${size}" \
   "${cache_hit}" "${fetched}" "${changed}" "${is_new}" "${category}" "${error}" \
   >>"${result_shard}"
}

# -----------------------------------------------------------------------------
# Fan out (max 4 parallel, 0.5s spacing)
# -----------------------------------------------------------------------------

i=0
running=0
RESULTS_FILE="${RUN_TMP}/results.jsonl"
: >"${RESULTS_FILE}"

# Read source lines into an array so we can index them in fish-safe bash.
SRC_LINES=()
while IFS= read -r line; do
  SRC_LINES+=("$line")
done < "${SOURCES_JSONL}"

for src in "${SRC_LINES[@]}"; do
  i=$((i + 1))
  shard="${RUN_TMP}/result.${i}.jsonl"
  : >"${shard}"

  (
    fetch_one "${src}" "${shard}" || true
    cat "${shard}" >>"${RESULTS_FILE}"
  ) &

  running=$((running + 1))

  if [ "${running}" -ge "${MAX_PARALLEL}" ]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi

  # Polite spacing between launches.
  sleep "${LAUNCH_SLEEP}"
done

wait

# -----------------------------------------------------------------------------
# Build manifest.json
# -----------------------------------------------------------------------------

MANIFEST_PATH="${CACHE_DIR}/manifest.json"

python3 - "${RESULTS_FILE}" "${MANIFEST_PATH}" "${TOTAL_SOURCES}" <<'PY'
import json, sys, datetime

results_path, manifest_path, total = sys.argv[1], sys.argv[2], int(sys.argv[3])

records = []
with open(results_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except Exception:
            continue

fetched = sum(1 for r in records if r.get("fetched"))
cache_hit = sum(1 for r in records if r.get("cache_hit"))
failed_records = [r for r in records if not (str(r.get("status","")).startswith("2") or r.get("status") == "304")]
failed = len(failed_records)

changed = [r["id"] for r in records if r.get("changed")]
new = [r["id"] for r in records if r.get("new")]
failed_detail = [
    {"id": r["id"], "url": r["url"], "status": r.get("status",""), "error": r.get("error","")}
    for r in failed_records
]

sources_summary = []
for r in records:
    sources_summary.append({
        "id": r["id"],
        "url": r["url"],
        "status": r.get("status",""),
        "sha256": r.get("sha256",""),
        "fetched_at": r.get("fetched_at",""),
        "size_bytes": r.get("size_bytes", 0),
        "category": r.get("category",""),
        "changed": bool(r.get("changed")),
        "cache_hit": bool(r.get("cache_hit")),
    })

manifest = {
    "schema_version": 1,
    "run_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "total_sources": total,
    "fetched": fetched,
    "cached_hit": cache_hit,
    "failed": failed,
    "changed": changed,
    "new": new,
    "failed_detail": failed_detail,
    "sources": sources_summary,
}

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)

print(f"total={total} fetched={fetched} cache_hit={cache_hit} failed={failed} changed={len(changed)} new={len(new)}")
PY

log "manifest -> ${MANIFEST_PATH}"
