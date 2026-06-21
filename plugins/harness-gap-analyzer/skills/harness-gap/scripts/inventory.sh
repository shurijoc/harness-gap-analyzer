#!/usr/bin/env bash
# inventory.sh — scan a Claude Code harness and emit JSON state.
#
# Used by the harness-gap analyzer skill. Reads only; never writes to the
# scanned harness. Output is consumed by rubric/*.md comparisons.

set -euo pipefail

# ---------- defaults / args ----------
GLOBAL_DIR="${HOME}/.claude"
REPO_DIR="$(pwd)/.claude"
OUTPUT=""
INCLUDE_CONTENT=0

usage() {
  cat <<'USAGE'
Usage: inventory.sh [options]

Options:
  --global-dir <path>   Global Claude harness dir (default: ~/.claude)
  --repo-dir <path>     Repo-local .claude dir   (default: $(pwd)/.claude)
  --output <path>       Output JSON file         (default: stdout)
  --include-content     Include sha256 of files where applicable
  -h, --help            Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --global-dir) GLOBAL_DIR="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --include-content) INCLUDE_CONTENT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# expand ~ if a literal "~" was passed
case "$GLOBAL_DIR" in "~"|"~/"*) GLOBAL_DIR="${HOME}${GLOBAL_DIR#\~}" ;; esac
case "$REPO_DIR"   in "~"|"~/"*) REPO_DIR="${HOME}${REPO_DIR#\~}"   ;; esac

# ---------- tool detection ----------
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
SHA_CMD=""
if command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA_CMD="shasum -a 256"
fi
HAS_PY=0; command -v python3 >/dev/null 2>&1 && HAS_PY=1

# ---------- helpers ----------
iso_now() {
  if [ "$HAS_PY" -eq 1 ]; then
    python3 -c 'import datetime; print(datetime.datetime.now().astimezone().isoformat())'
  else
    date +"%Y-%m-%dT%H:%M:%S%z"
  fi
}

# json_str <raw> -> JSON-escaped string (without surrounding quotes)
json_str() {
  if [ "$HAS_PY" -eq 1 ]; then
    # use argv (not stdin) so we don't pick up the herestring newline
    python3 -c 'import json,sys;sys.stdout.write(json.dumps(sys.argv[1])[1:-1])' "${1-}"
  else
    # crude fallback
    printf '%s' "${1-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
      -e 's/\t/\\t/g' -e ':a;N;$!ba;s/\n/\\n/g'
  fi
}

# size of file in bytes (portable: stat differs between mac and linux)
file_size() {
  local f="$1"
  if [ -f "$f" ]; then
    if stat -f%z "$f" >/dev/null 2>&1; then
      stat -f%z "$f"
    else
      stat -c%s "$f" 2>/dev/null || wc -c <"$f" | tr -d ' '
    fi
  else
    echo 0
  fi
}

file_lines() {
  local f="$1"
  if [ -f "$f" ]; then
    wc -l <"$f" | tr -d ' '
  else
    echo 0
  fi
}

file_sha() {
  local f="$1"
  if [ -f "$f" ] && [ -n "$SHA_CMD" ]; then
    $SHA_CMD "$f" 2>/dev/null | awk '{print $1}'
  else
    echo ""
  fi
}

# emit JSON object describing a single file under a dir: {name,size,lines[,sha256]}
file_record() {
  local path="$1"
  local rel="$2"
  local size lines sha
  size="$(file_size "$path")"
  lines="$(file_lines "$path")"
  if [ "$INCLUDE_CONTENT" -eq 1 ]; then
    sha="$(file_sha "$path")"
    printf '{"name":"%s","size":%s,"lines":%s,"sha256":"%s"}' \
      "$(json_str "$rel")" "$size" "$lines" "$(json_str "$sha")"
  else
    printf '{"name":"%s","size":%s,"lines":%s}' \
      "$(json_str "$rel")" "$size" "$lines"
  fi
}

# list files (non-recursive top level) and emit JSON array
list_files_array() {
  local dir="$1"
  local first=1
  printf '['
  if [ -d "$dir" ]; then
    # shellcheck disable=SC2044
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local rel="${f#"$dir"/}"
      if [ $first -eq 0 ]; then printf ','; fi
      file_record "$f" "$rel"
      first=0
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null | sort)
  fi
  printf ']'
}

# ---------- frontmatter parsing for SKILL.md ----------
# emit JSON object: {name, description, model, when_to_use_present}
skill_frontmatter() {
  local skill_md="$1"
  local name="" desc="" model="" when_present=false
  if [ -f "$skill_md" ]; then
    # extract between first --- and second --- on their own lines
    local fm
    fm="$(awk 'BEGIN{f=0;c=0} /^---[[:space:]]*$/{c++; if(c==1){f=1;next} else if(c==2){f=0}} f{print}' "$skill_md" 2>/dev/null || true)"
    if [ -n "$fm" ]; then
      name="$(printf '%s\n' "$fm" | awk -F': *' '/^name:/{ $1=""; sub(/^ /,""); print; exit }')"
      desc="$(printf '%s\n' "$fm" | awk -F': *' '/^description:/{ $1=""; sub(/^ /,""); print; exit }')"
      model="$(printf '%s\n' "$fm" | awk -F': *' '/^model:/{ $1=""; sub(/^ /,""); print; exit }')"
    fi
    # body = below the closing ---
    if grep -qiE '^(##? *)?when to use' "$skill_md" 2>/dev/null; then
      when_present=true
    fi
  fi
  printf '{"name":"%s","description":"%s","model":"%s","when_to_use_present":%s}' \
    "$(json_str "$name")" "$(json_str "$desc")" "$(json_str "$model")" "$when_present"
}

# body line count of SKILL.md (below closing ---)
skill_body_lines() {
  local skill_md="$1"
  if [ -f "$skill_md" ]; then
    awk 'BEGIN{f=0;c=0} /^---[[:space:]]*$/{c++; if(c==2){f=1;next} else next} f{print}' "$skill_md" 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

# ---------- section builders ----------
section_claude_md() {
  local root="$1"
  local f="$root/CLAUDE.md"
  if [ ! -f "$f" ]; then
    printf '{"exists":false}'
    return
  fi
  local sha=""
  [ "$INCLUDE_CONTENT" -eq 1 ] && sha="$(file_sha "$f")"
  printf '{"exists":true,"size_bytes":%s,"line_count":%s,"sha256":"%s"}' \
    "$(file_size "$f")" "$(file_lines "$f")" "$(json_str "$sha")"
}

section_rules() {
  local root="$1"
  local d="$root/rules"
  if [ ! -d "$d" ]; then
    printf '{"exists":false}'
    return
  fi
  printf '{"exists":true,"files":'
  list_files_array "$d"
  printf '}'
}

section_skills() {
  local root="$1"
  local d="$root/skills"
  if [ ! -d "$d" ]; then
    printf '{"exists":false}'
    return
  fi
  printf '{"exists":true,"skills":['
  local first=1
  while IFS= read -r sd; do
    [ -z "$sd" ] && continue
    local name; name="$(basename "$sd")"
    local skill_md="$sd/SKILL.md"
    local has_md=false; [ -f "$skill_md" ] && has_md=true
    local body_lines=0
    [ "$has_md" = "true" ] && body_lines="$(skill_body_lines "$skill_md")"
    local has_refs=false; [ -d "$sd/references" ] && has_refs=true
    local has_tpl=false;  [ -d "$sd/templates"  ] && has_tpl=true
    if [ $first -eq 0 ]; then printf ','; fi
    printf '{"name":"%s","has_skill_md":%s,"frontmatter":' "$(json_str "$name")" "$has_md"
    if [ "$has_md" = "true" ]; then
      skill_frontmatter "$skill_md"
    else
      printf 'null'
    fi
    printf ',"body_lines":%s,"has_references_dir":%s,"has_templates_dir":%s}' \
      "$body_lines" "$has_refs" "$has_tpl"
    first=0
  done < <(find "$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
  printf ']}'
}

section_dir_files() {
  local root="$1"; local name="$2"
  local d="$root/$name"
  if [ ! -d "$d" ]; then
    printf '{"exists":false}'
    return
  fi
  printf '{"exists":true,"files":'
  list_files_array "$d"
  printf '}'
}

# Hook scripts dir + events parsed out of settings.json
section_hooks() {
  local root="$1"
  local scripts_dir="$root/hooks"
  local scripts_exists=false
  [ -d "$scripts_dir" ] && scripts_exists=true
  local settings="$root/settings.json"
  local events_json="[]"
  if [ -f "$settings" ] && [ "$HAS_JQ" -eq 1 ]; then
    events_json="$(jq -c '
      (.hooks // {}) | to_entries | map(.key) | unique
    ' "$settings" 2>/dev/null || echo '[]')"
  elif [ -f "$settings" ]; then
    # grep top-level keys under "hooks": { ... } — crude
    events_json="[$(grep -oE '"(PreToolUse|PostToolUse|UserPromptSubmit|Notification|Stop|SubagentStop|PreCompact|SessionStart|SessionEnd)"' "$settings" 2>/dev/null | sort -u | awk 'BEGIN{first=1}{if(!first)printf",";printf"%s",$0;first=0}')]"
  fi
  printf '{"scripts_dir_exists":%s,"files":' "$scripts_exists"
  if [ "$scripts_exists" = "true" ]; then
    list_files_array "$scripts_dir"
  else
    printf '[]'
  fi
  printf ',"events_in_settings":%s}' "$events_json"
}

# Settings file analysis
section_settings() {
  local f="$1"
  if [ ! -f "$f" ]; then
    printf '{"exists":false}'
    return
  fi
  local top_keys="[]"
  local allow_n=0 deny_n=0 ask_n=0 default_mode="" has_addl=false
  local has_model=false has_effort=false
  if [ "$HAS_JQ" -eq 1 ]; then
    top_keys="$(jq -c 'keys' "$f" 2>/dev/null || echo '[]')"
    allow_n="$(jq -r '(.permissions.allow // []) | length' "$f" 2>/dev/null || echo 0)"
    deny_n="$(jq  -r '(.permissions.deny  // []) | length' "$f" 2>/dev/null || echo 0)"
    ask_n="$(jq   -r '(.permissions.ask   // []) | length' "$f" 2>/dev/null || echo 0)"
    default_mode="$(jq -r '(.permissions.defaultMode // "") | tostring' "$f" 2>/dev/null || echo "")"
    if jq -e '(.permissions.additionalDirectories // []) | length > 0' "$f" >/dev/null 2>&1; then
      has_addl=true
    fi
    jq -e '.model? != null' "$f"        >/dev/null 2>&1 && has_model=true
    jq -e '.effortLevel? != null' "$f"  >/dev/null 2>&1 && has_effort=true
  else
    # crude grep-based fallback
    top_keys="[$(grep -oE '^[[:space:]]*"[a-zA-Z_][a-zA-Z0-9_]*"[[:space:]]*:' "$f" 2>/dev/null | sed -E 's/^[[:space:]]*("[^"]+")[[:space:]]*:.*/\1/' | sort -u | awk 'BEGIN{first=1}{if(!first)printf",";printf"%s",$0;first=0}')]"
    grep -qE '"model"[[:space:]]*:'       "$f" 2>/dev/null && has_model=true
    grep -qE '"effortLevel"[[:space:]]*:' "$f" 2>/dev/null && has_effort=true
    grep -qE '"additionalDirectories"' "$f" 2>/dev/null && has_addl=true
  fi
  printf '{"exists":true,"top_keys":%s,"permissions":{"allow_count":%s,"deny_count":%s,"ask_count":%s,"default_mode":"%s","has_additional_dirs":%s},"has_model_setting":%s,"has_effort_setting":%s}' \
    "$top_keys" "$allow_n" "$deny_n" "$ask_n" "$(json_str "$default_mode")" "$has_addl" "$has_model" "$has_effort"
}

section_keybindings() {
  local f="$1"
  if [ ! -f "$f" ]; then
    printf '{"exists":false}'
    return
  fi
  local count=0
  if [ "$HAS_JQ" -eq 1 ]; then
    count="$(jq -r '
      if type=="array" then length
      elif type=="object" then
        (if has("bindings") then (.bindings|length) else (keys|length) end)
      else 0 end' "$f" 2>/dev/null || echo 0)"
  else
    count="$(grep -cE '"key"[[:space:]]*:' "$f" 2>/dev/null || echo 0)"
  fi
  printf '{"exists":true,"binding_count":%s}' "$count"
}

section_memory() {
  local root="$1"
  local d="$root/projects"
  if [ ! -d "$d" ]; then
    printf '{"exists":false}'
    return
  fi
  local cnt=0
  cnt="$(find "$d" -type f -name 'MEMORY.md' 2>/dev/null | wc -l | tr -d ' ')"
  printf '{"exists":true,"file_count":%s}' "$cnt"
}

section_plugins() {
  local root="$1"
  # Check both possible locations: settings.json (current) and plugins/config.json (legacy)
  local candidates=("$root/settings.json" "$root/plugins/config.json")
  local enabled_json="[]" cnt=0
  for f in "${candidates[@]}"; do
    [ -f "$f" ] || continue
    if [ "$HAS_JQ" -eq 1 ]; then
      local got
      got="$(jq -c '
        [
          (.enabledPlugins // {}) | to_entries[]
          | select(.value == true or (.value|type=="object"))
          | .key
        ]
      ' "$f" 2>/dev/null || echo '[]')"
      if [ "$got" != "[]" ] && [ -n "$got" ]; then
        enabled_json="$got"
        cnt="$(printf '%s' "$enabled_json" | jq -r 'length' 2>/dev/null || echo 0)"
        break
      fi
    else
      local got
      got="[$(grep -oE '"[^"]+@[^"]+"[[:space:]]*:[[:space:]]*true' "$f" 2>/dev/null | grep -oE '"[^"]+@[^"]+"' | sort -u | awk 'BEGIN{first=1}{if(!first)printf",";printf"%s",$0;first=0}')]"
      if [ "$got" != "[]" ]; then
        enabled_json="$got"
        cnt="$(grep -oE '"[^"]+@[^"]+"[[:space:]]*:[[:space:]]*true' "$f" 2>/dev/null | wc -l | tr -d ' ')"
        break
      fi
    fi
  done
  printf '{"enabled_count":%s,"enabled":%s}' "$cnt" "$enabled_json"
}

# ---------- one root => full block ----------
build_root_block() {
  local root="$1"
  printf '{'
  printf '"root":"%s",' "$(json_str "$root")"
  printf '"claude_md":';      section_claude_md      "$root"; printf ','
  printf '"rules":';          section_rules          "$root"; printf ','
  printf '"skills":';         section_skills         "$root"; printf ','
  printf '"agents":';         section_dir_files      "$root" "agents"; printf ','
  printf '"commands":';       section_dir_files      "$root" "commands"; printf ','
  printf '"hooks":';          section_hooks          "$root"; printf ','
  printf '"settings":';       section_settings       "$root/settings.json"; printf ','
  printf '"settings_local":'; section_settings       "$root/settings.local.json"; printf ','
  printf '"keybindings":';    section_keybindings    "$root/keybindings.json"; printf ','
  printf '"memory":';         section_memory         "$root"; printf ','
  printf '"plugins":';        section_plugins        "$root"
  printf '}'
}

# ---------- metrics (global only) ----------
build_metrics() {
  local root="$1"
  local cmd_lines=0
  if [ -f "$root/CLAUDE.md" ]; then
    cmd_lines="$(file_lines "$root/CLAUDE.md")"
  fi
  local cmd_over=false
  if [ "$cmd_lines" -gt 200 ] 2>/dev/null; then cmd_over=true; fi

  # skills > 500 lines (SKILL.md only)
  local skills_over='[]'
  if [ -d "$root/skills" ]; then
    skills_over="[$(
      first=1
      while IFS= read -r sm; do
        [ -z "$sm" ] && continue
        ln="$(file_lines "$sm")"
        if [ "$ln" -gt 500 ] 2>/dev/null; then
          nm="$(basename "$(dirname "$sm")")"
          if [ $first -eq 0 ]; then printf ','; fi
          printf '{"name":"%s","lines":%s}' "$(json_str "$nm")" "$ln"
          first=0
        fi
      done < <(find "$root/skills" -maxdepth 2 -mindepth 2 -name 'SKILL.md' 2>/dev/null | sort)
    )]"
  fi

  # memory files > 25KB
  local mem_over='[]'
  if [ -d "$root/projects" ]; then
    mem_over="[$(
      first=1
      while IFS= read -r mf; do
        [ -z "$mf" ] && continue
        sz="$(file_size "$mf")"
        if [ "$sz" -gt 25600 ] 2>/dev/null; then
          if [ $first -eq 0 ]; then printf ','; fi
          printf '{"path":"%s","size_bytes":%s}' "$(json_str "${mf#"$root"/}")" "$sz"
          first=0
        fi
      done < <(find "$root/projects" -type f -name 'MEMORY.md' 2>/dev/null | sort)
    )]"
  fi

  printf '{"global_claude_md_lines":%s,"skills_over_500_lines":%s,"claude_md_over_200_lines":%s,"memory_file_over_25kb":%s}' \
    "$cmd_lines" "$skills_over" "$cmd_over" "$mem_over"
}

# ---------- main assembly ----------
GENERATED_AT="$(iso_now)"

GLOBAL_BLOCK=""
if [ -d "$GLOBAL_DIR" ]; then
  GLOBAL_BLOCK="$(build_root_block "$GLOBAL_DIR")"
else
  GLOBAL_BLOCK='{"exists":false,"root":"'"$(json_str "$GLOBAL_DIR")"'"}'
fi

REPO_BLOCK=""
if [ -d "$REPO_DIR" ]; then
  REPO_BLOCK="$(build_root_block "$REPO_DIR")"
else
  REPO_BLOCK='{"exists":false}'
fi

METRICS_BLOCK=""
if [ -d "$GLOBAL_DIR" ]; then
  METRICS_BLOCK="$(build_metrics "$GLOBAL_DIR")"
else
  METRICS_BLOCK='{"global_claude_md_lines":0,"skills_over_500_lines":[],"claude_md_over_200_lines":false,"memory_file_over_25kb":[]}'
fi

RAW="$(printf '{"schema_version":1,"generated_at":"%s","global":%s,"repo":%s,"metrics":%s}' \
  "$(json_str "$GENERATED_AT")" "$GLOBAL_BLOCK" "$REPO_BLOCK" "$METRICS_BLOCK")"

# pretty-print if jq is around; otherwise emit raw
if [ "$HAS_JQ" -eq 1 ]; then
  FINAL="$(printf '%s' "$RAW" | jq '.' 2>/dev/null || printf '%s' "$RAW")"
else
  FINAL="$RAW"
fi

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$FINAL" > "$OUTPUT"
else
  printf '%s\n' "$FINAL"
fi
