#!/usr/bin/env bash

# discover.sh — deterministic TypeScript codebase navigation using ast-grep.
#
# Subcommands:
#   resolve <specifier> [--from <file>]
#   inspect <file> [--imports] [--exports] [--dynamic] [--entities] [--depth names|signatures|full]
#   definition <file> <symbol>
#   live-files [--rebuild]
#   dead-files [--rebuild]
#   is-live <file> [--rebuild]
#   importers <file> [--rebuild]
#   trace <file> [--rebuild]
#   prune <file>
#   usages <pattern> [--live-only]
#   usages --assets <asset-path>
#
# Nothing project-specific is hardcoded; it is all read from the project:
#   source files — *.ts *.tsx *.mts *.cts the project hasn't gitignored
#                  (declaration files and tests excluded)
#   path aliases — tsconfig.json compilerOptions.paths / baseUrl, following `extends`
#   entry points — $DISCOVER_ENTRY, else package.json source/module/main,
#                  else the conventional index/main module at the root or in src/


# TODO: add something like knowledge's index updating directives
#       so we can selectively prune the cache and update the fingerprint instead of rebuilding after every change.

# The script lives one level below the project root (bin/ or scripts/), so the
# root is the parent of its own directory unless REPO_ROOT is already set.
SELF="$(realpath "${BASH_SOURCE[0]}")"
[[ -n $REPO_ROOT ]] || REPO_ROOT="$(dirname "${SELF%\/*}")"

TSCONFIG="$REPO_ROOT/tsconfig.json"
# Overridable like REPO_ROOT, e.g. to keep caches out of a project's tmp/.
[[ -n $CACHE_DIR ]] || CACHE_DIR="$REPO_ROOT/tmp"

CACHE_FILE="$CACHE_DIR/discover_live_cache.txt"
DEAD_LIST="$CACHE_DIR/discover_dead.txt"
IMPORTERS_CACHE_FILE="$CACHE_DIR/discover_importers_cache.json"
TSCONFIG_PATHS_CACHE="$CACHE_DIR/discover_tsconfig_paths.tsv"


die() { echo "error: $*" >&2; exit 1; }

# Every query shells out to ast-grep with stderr silenced, so a missing binary
# would otherwise produce empty results and poison the caches with them.
command -v ast-grep >/dev/null 2>&1 || die "ast-grep not found on PATH"

# The cache dir must exist before anything redirects into it: `fn > "$CACHE_FILE"`
# opens the target before fn's own mkdir runs, and stamp_cache writes here
# after every build.
mkdir -p "$CACHE_DIR" || die "cannot create cache dir: $CACHE_DIR"


# ─────────────────────────────────────────────────────────
# Source files under analysis. git's view is used when available
# so node_modules, build output and anything else the project
# ignores never enters the graph. Declaration files carry no
# runtime code and tests are never reachable from an entry
# point, so both are excluded (the TS analog of skipping
# *.g.dart / *.freezed.dart and of Dart keeping tests out of lib/).
# ─────────────────────────────────────────────────────────
_source_listing() {
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$REPO_ROOT" ls-files -z -co --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts' 2>/dev/null
  else
    # Without git there is no ignore list, so at least skip installed packages.
    find "$REPO_ROOT" \( -name node_modules -o -name .git \) -prune -o -type f \
      \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' \) -printf '%P\0'
  fi
}

relavent_files() {
  local f
  while IFS= read -r -d '' f; do
    case "$f" in
    *.d.ts|*.d.mts|*.d.cts|*.test.*|*.spec.*|__tests__/*|*/__tests__/*|__mocks__/*|*/__mocks__/*) continue ;;
    esac
    # git also lists index entries that were deleted from the working tree.
    [[ ! -f "$REPO_ROOT/$f" ]] || printf '%s\0' "$REPO_ROOT/$f"
  done < <(_source_listing) | sort -z
}

# Files whose imports form the graph: the sources plus the entry points,
# which may be plain JavaScript (e.g. a React Native index.js) and so fall
# outside relavent_files. Without them their edges would be missing from
# the importers index and everything below them would trace as dead.
graph_files() {
  local -i i
  {
    relavent_files
    for ((i=0;i<${#ENTRY_FILES[@]};i++)); do printf '%s\0' "${ENTRY_FILES[$i]}"; done
  } | sort -zu
}

# Scripts are the only files with imports to follow; anything else an
# import resolves to (JSON, images, styles) is a leaf in the graph.
is_script() { case "$1" in *.ts|*.tsx|*.mts|*.cts|*.js|*.jsx|*.mjs|*.cjs) return 0 ;; esac; return 1; }

blank_() { [[ -z "$1" || "$1" == "[]" ]]; }
present_() { [[ -n "$1" && "$1" != "[]" ]]; }


# ─────────────────────────────────────────────────────────
# Cache validity: the fingerprint is a hash of the sorted
# source listing (see relavent_files), the entry points and
# tsconfig.json (aliases change what imports resolve to).
# Detects file additions and removals automatically.
# Import-content changes require --rebuild-cache.
#
# Each cache is stamped with the fingerprint it was built
# from (<cache>.fp). A single shared fingerprint file breaks
# when one cache's check refreshes it: the other caches then
# look current while still stale, and --rebuild-cache, whose
# builds never refreshed it, rebuilt the importers cache a
# second time from build_dead_cache.
# ─────────────────────────────────────────────────────────
compute_fingerprint() {
  {
    relavent_files
    printf '%s\n' "${ENTRY_FILES[@]}"
    cat "$TSCONFIG" 2>/dev/null
  } | md5sum | cut -d' ' -f1
}

cache_is_valid() { [[ -f "$1" && -f "$1.fp" && "$(< "$1.fp")" == "$SOURCE_FP" ]]; }

stamp_cache() { echo "$SOURCE_FP" > "$1.fp"; }


# ─────────────────────────────────────────────────────────
# tsconfig path aliases — the TS analog of Dart's
# `package:<self>/` imports: non-relative specifiers that
# still point into the project.
#
# Cache format: line 1 is the absolute baseUrl (empty when
# unset); every following line is
#   <pattern>\t<absolute substitution>
# one per substitution, in tsconfig order.
# Rebuilt when tsconfig.json changes or with --rebuild-cache
# (edits to an `extends`-ed config need --rebuild-cache).
# ─────────────────────────────────────────────────────────

# read_jsonc <file> — tsconfig files are JSONC (comments, trailing commas),
# which jq rejects. Node is always present in a TypeScript project, so strip
# both there with a string-aware regex; fall back to plain jq without node.
read_jsonc() {
  if command -v node >/dev/null 2>&1; then
    node -e '
      const src = require("fs").readFileSync(process.argv[1], "utf8");
      // Keep string literals intact; drop // and /* */ comments.
      const noComments = src.replace(/("(?:\\.|[^"\\])*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (m, s) => s ?? "");
      // Drop commas that directly precede a closing bracket.
      const noTrailing = noComments.replace(/("(?:\\.|[^"\\])*")|,(\s*[}\]])/g, (m, s, close) => s ?? close);
      process.stdout.write(JSON.stringify(JSON.parse(noTrailing)));
    ' "$1" 2>/dev/null
  else
    jq -c . "$1" 2>/dev/null
  fi
}

# resolve_extends <extends-value> <dir-of-extending-config>
# Prints the absolute path of the inherited config. Relative values are file
# paths (".json" optional); anything else names a package, looked up in the
# nearest node_modules walking up from the extending config.
resolve_extends() {
  local spec="$1" dir="$2" nm
  local -a candidates=()
  local -i i
  case "$spec" in
  ./*|../*|/*)
    [[ "$spec" == /* ]] || spec="$dir/$spec"
    candidates[${#candidates[@]}]="$spec"
    candidates[${#candidates[@]}]="$spec.json"
    ;;
  *)
    nm="$dir"
    while :; do
      candidates[${#candidates[@]}]="$nm/node_modules/$spec"
      candidates[${#candidates[@]}]="$nm/node_modules/$spec.json"
      candidates[${#candidates[@]}]="$nm/node_modules/$spec/tsconfig.json"
      [[ "$nm" != / ]] || break
      nm="$(dirname "$nm")"
    done
  esac
  for ((i=0;i<${#candidates[@]};i++)); do
    [[ -f "${candidates[$i]}" ]] && { realpath "${candidates[$i]}"; return; }
  done
}

# _collect_tsconfig <absolute-config-path>
# Walks the `extends` chain filling _ts_base_url, _ts_paths_json and
# _ts_paths_dir. The nearest config to set an option wins, so only options
# still unset are taken from each config.
_collect_tsconfig() {
  local cfg="$1" json dir value
  local -a parents=()
  local -i i

  # Guard against `extends` cycles.
  [[ ! -v _ts_seen["$cfg"] ]] || return
  _ts_seen["$cfg"]=1

  json="$(read_jsonc "$cfg")"
  [[ -n "$json" ]] || return
  dir="$(dirname "$cfg")"

  if [[ -z "$_ts_base_url" ]]; then
    value="$(jq -r '.compilerOptions.baseUrl // empty' <<< "$json")"
    if [[ -n "$value" ]]; then
      [[ "$value" == /* ]] || value="$dir/$value"
      _ts_base_url="$(realpath -m "$value")"
    fi
  fi
  if [[ -z "$_ts_paths_json" ]]; then
    value="$(jq -c '.compilerOptions.paths // empty' <<< "$json")"
    [[ -z "$value" ]] || { _ts_paths_json="$value"; _ts_paths_dir="$dir"; }
  fi
  [[ -z "$_ts_base_url" || -z "$_ts_paths_json" ]] || return

  # `extends` is a string or (TS 5+) an array whose later entries override
  # earlier ones, so walk it last-to-first.
  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    value="$(resolve_extends "$value" "$dir")"
    [[ -z "$value" ]] || parents[${#parents[@]}]="$value"
  done < <(jq -r '.extends // empty | if type == "array" then reverse[] else . end' <<< "$json")

  for ((i=0;i<${#parents[@]};i++)); do _collect_tsconfig "${parents[$i]}"; done
}

build_tsconfig_paths() {
  _ts_base_url="" _ts_paths_json="" _ts_paths_dir=""
  declare -gA _ts_seen=()
  [[ ! -f "$TSCONFIG" ]] || _collect_tsconfig "$(realpath "$TSCONFIG")"

  echo "$_ts_base_url"
  [[ -n "$_ts_paths_json" ]] || return 0
  # Substitutions are relative to baseUrl when one is in effect, otherwise
  # to the config that declared `paths`.
  jq -r --arg base "${_ts_base_url:-$_ts_paths_dir}" \
    'to_entries[] | .key as $p | .value[] | "\($p)\t\($base)/\(.)"' <<< "$_ts_paths_json"
}

# Load the alias table into globals once per run. resolve_uri mostly runs in
# command substitutions, so lazy loading there would never stick.
declare -a ALIAS_PATTERN=() ALIAS_TARGET=()
TS_BASE_URL=""

load_aliases() {
  if [[ ! -f "$TSCONFIG_PATHS_CACHE" || "$TSCONFIG" -nt "$TSCONFIG_PATHS_CACHE" ]]; then
    build_tsconfig_paths > "$TSCONFIG_PATHS_CACHE"
  fi
  local pattern target
  {
    IFS= read -r TS_BASE_URL
    while IFS=$'\t' read -r pattern target; do
      [[ -n "$pattern" ]] || continue
      ALIAS_PATTERN[${#ALIAS_PATTERN[@]}]="$pattern"
      ALIAS_TARGET[${#ALIAS_TARGET[@]}]="$target"
    done
  } < "$TSCONFIG_PATHS_CACHE"
}


# ─────────────────────────────────────────────────────────
# Entry points — the TS analog of lib/main.dart, the roots of
# liveness. In order of precedence:
#   DISCOVER_ENTRY="src/server.ts src/worker.ts" (repo-relative)
#   package.json source/module/main, only when it names a source
#     file the project hasn't ignored (`main` often points at
#     build output)
#   the first of index / src/index / src/main / main that exists
# ─────────────────────────────────────────────────────────
declare -a ENTRY_FILES=()
declare -A ENTRY_SET=()

add_entry() {
  [[ -n "$1" && ! -v ENTRY_SET["$1"] ]] || return 0
  ENTRY_SET["$1"]=1
  ENTRY_FILES[${#ENTRY_FILES[@]}]="$REPO_ROOT/$1"
}

detect_entries() {
  local field rel
  local -a words=() bases=(index src/index src/main main)
  local -i i

  if [[ -n "$DISCOVER_ENTRY" ]]; then
    read -ra words <<< "$DISCOVER_ENTRY"
    for ((i=0;i<${#words[@]};i++)); do
      [[ -f "$(to_abs "${words[$i]}")" ]] || die "DISCOVER_ENTRY file not found: ${words[$i]}"
      add_entry "$(to_rel "${words[$i]}")"
    done
    return
  fi

  if [[ -f "$REPO_ROOT/package.json" ]]; then
    while IFS= read -r field; do
      rel="$(resolve_module_path "$(realpath -m "$REPO_ROOT/$field")")"
      [[ -n "$rel" ]] && is_script "$rel" || continue
      ! git -C "$REPO_ROOT" check-ignore -q "$rel" 2>/dev/null || continue
      add_entry "$rel"
    done < <(jq -r '.source, .module, .main | strings' "$REPO_ROOT/package.json" 2>/dev/null)
    ((${#ENTRY_FILES[@]} == 0)) || return
  fi

  for ((i=0;i<${#bases[@]};i++)); do
    rel="$(resolve_module_path "$REPO_ROOT/${bases[$i]}")"
    [[ -n "$rel" ]] && is_script "$rel" || continue
    add_entry "$rel"
    return
  done
}

require_entries() {
  ((${#ENTRY_FILES[@]} > 0)) || die "no entry point found (set DISCOVER_ENTRY to the repo-relative entry file(s))"
}


# ─────────────────────────────────────────────────────────
# build_live_files — reachability from the entry points
# ─────────────────────────────────────────────────────────
build_live_cache() {
  echo "Building live-files cache" >&2
  mkdir -p "$CACHE_DIR"
  require_entries

  local -A live=()
  local -a queue=()
  local -i i
  for ((i=0;i<${#ENTRY_FILES[@]};i++)); do
    live["${ENTRY_FILES[$i]}"]=1
    queue[${#queue[@]}]="${ENTRY_FILES[$i]}"
  done

  local -i idx=0
  local current current_rel resolved abs_resolved

  while (( idx < ${#queue[@]} )); do
    current="${queue[$idx]}"
    ((idx++))
    [[ -f "$current" ]] || continue
    current_rel="$(realpath --relative-to="$REPO_ROOT" "$current")"

    for directive in 'import' 'export' 'dynamic'; do
      while IFS= read -r uri; do
        [[ -n "$uri" ]] || continue
        resolved="$(resolve_uri "$uri" "$current_rel")"
        [[ -n "$resolved" ]] || continue
        abs_resolved="$(realpath "$REPO_ROOT/$resolved" 2>/dev/null)"
        [[ -f "$abs_resolved" ]] || continue
        if [[ ! -v live["$abs_resolved"] ]]; then
          live["$abs_resolved"]=1
          queue[${#queue[@]}]="$abs_resolved"
        fi
      done < <(ast_grep_uris "$current" "$directive")
    done
  done

  for f in "${!live[@]}"; do
    realpath --relative-to="$REPO_ROOT" "$f"
  done | sort

  echo "${#live[@]} live files" >&2
}


# Scan every graph file, extract import/export/dynamic specifiers,
# resolve them, and emit a JSON object keyed by repo-relative
# target path → array of {file, directive, uri, entities_used} entries.
# For each edge, determines which of the target's entities are actually
# referenced in the importing file. Markers stand in for references that
# have no name to match:
#   "default"       — a default-import binding that the importer uses
#   "*"             — `export * from` re-exports everything
#   "(side-effect)" — `import "./x"` runs the module for its effects
#   "(dynamic)"     — import()/require(), consumed at runtime
build_importers_cache() {
  echo "importers: rebuilding" >&2
  mkdir -p "$CACHE_DIR"

  local tmp_file="$(mktemp)"

  # Cache entity names per target file so we only call ast_grep_entities once per target.
  local -A entity_cache=()
  local src_rel resolved resolved_abs canon entities_json idents_json binds_json used

  # Collect all edges as newline-delimited JSON objects.
  while IFS= read -r -d '' src_file; do
    src_rel="$(realpath --relative-to="$REPO_ROOT" "$src_file")"

    # Names this file references (outside its import statements) and its
    # import/export bindings, gathered once per importer.
    idents_json="$(ast_grep_identifiers "$src_file")"
    binds_json="$(ast_grep_bindings "$src_file")"

    for directive in 'import' 'export' 'dynamic'; do
      while IFS= read -r uri; do
        [[ -n "$uri" ]] || continue

        resolved="$(resolve_uri "$uri" "$src_rel")"
        [[ -n "$resolved" ]] || continue

        # Canonicalize so relative and aliased forms merge to the same key.
        resolved_abs="$(realpath "$REPO_ROOT/$resolved" 2>/dev/null)"
        [[ -f "$resolved_abs" ]] || continue
        canon="$(realpath --relative-to="$REPO_ROOT" "$resolved_abs")"

        # Get entities defined in the target file (cached per target).
        if [[ -v entity_cache["$canon"] ]]; then
          entities_json="${entity_cache[$canon]}"
        else
          entities_json="$(ast_grep_entities "$resolved_abs" names | jq -c '[.[].name]')"
          entity_cache["$canon"]="$entities_json"
        fi

        # Determine which of the target's entities are used in this importer.
        if [[ "$directive" == dynamic ]]; then
          used='["(dynamic)"]'
        else
          used="$(jq -nc --argjson ents "$entities_json" --argjson ids "$idents_json" \
              --argjson binds "$binds_json" --arg uri "$uri" --arg d "$directive" '
            ($binds | map(select(.src == $uri))) as $mine
            | [$ents[] | select(IN($ids[]))]
              + (if $d == "export" and ($mine | any(.id == "export-star")) then ["*"] else [] end)
              + (if $d == "import" and ($mine | any(.id == "import-bare")) then ["(side-effect)"] else [] end)
              + (if $d == "import" and ($mine | any(.id == "import-default" and (.local | IN($ids[])))) then ["default"] else [] end)
            | unique')"
        fi

        jq -nc --arg target "$canon" --arg file "$src_rel" --arg directive "$directive" \
            --arg uri "$uri" --argjson used "$used" \
          '{target: $target, file: $file, directive: $directive, uri: $uri, entities_used: $used}' >> "$tmp_file"
      done < <(ast_grep_uris "$src_file" "$directive")
    done
  done < <(graph_files)

  # Group edges by target into a JSON object.
  if [[ -s "$tmp_file" ]]; then
    jq -s 'group_by(.target)
      | map({key: .[0].target, value: [.[] | {file, directive, uri, entities_used}]})
      | from_entries' "$tmp_file"
  else
    echo "{}"
  fi

  rm -f "$tmp_file"
}



# Build and write live-files cache to disk.
_build_live_cache() {
  rm -f "$CACHE_FILE" 2>/dev/null
  build_live_cache > "$CACHE_FILE" && stamp_cache "$CACHE_FILE"
}

# Return cached live-files, rebuilding if stale.
get_live_cache() {
  [[ "${1,,}" != +(\-)'rebuild' && "$FORCE_REBUILD" != "true" && "$BUST_CACHE" != "true" ]] || rm -f "$CACHE_FILE" 2>/dev/null
  cache_is_valid "$CACHE_FILE" || _build_live_cache
  cat "$CACHE_FILE"
}


# ─────────────────────────────────────────────────────────
# importers cache: reverse-index mapping each file to the
# list of files that import/export/load it. Same fingerprint
# strategy as live-files (invalidates on file add/remove;
# import-content changes require --rebuild-cache).
# ─────────────────────────────────────────────────────────

# Build and write importers cache to disk.
_build_importers_cache() {
  rm -f "$IMPORTERS_CACHE_FILE" 2>/dev/null
  build_importers_cache > "$IMPORTERS_CACHE_FILE" && stamp_cache "$IMPORTERS_CACHE_FILE"
}

# Return cached importers index, rebuilding if stale.
get_importers_cache() {
  [[ "${1,,}" != +(\-)'rebuild' && "$FORCE_REBUILD" != "true" && "$BUST_CACHE" != "true" ]] || rm -f "$IMPORTERS_CACHE_FILE" 2>/dev/null
  cache_is_valid "$IMPORTERS_CACHE_FILE" || _build_importers_cache
  cat "$IMPORTERS_CACHE_FILE"
}


# ─────────────────────────────────────────────────────────
# dead cache: uses _is_reachable (recursive trace via the
# importers cache) to independently determine which files
# are dead, then cross-checks against the live cache.
# Must run after both live and importers caches are built.
# ─────────────────────────────────────────────────────────
build_dead_cache() {
  echo "Building dead-files cache" >&2

  # Load importers index for _is_reachable.
  _importers_json="$(get_importers_cache)"
  _trace_live=()
  _trace_visited=()

  # Load the live cache for cross-checking.
  local live_cache
  live_cache="$(get_live_cache 2>/dev/null)"

  local disagreements=0

  local repo_rel
  while IFS= read -r -d '' src_file; do
    repo_rel="$(realpath --relative-to="$REPO_ROOT" "$(realpath "$src_file")")"

    local trace_dead=true
    _is_reachable "$repo_rel" && trace_dead=false

    local bfs_dead=true
    echo "$live_cache" | grep -qxF "$repo_rel" && bfs_dead=false

    if [[ "$trace_dead" != "$bfs_dead" ]]; then
      echo "DISAGREEMENT: $repo_rel — trace says dead=$trace_dead, is-live says dead=$bfs_dead" >&2
      ((disagreements++))
    fi

    [[ "$trace_dead" == false ]] || echo "$repo_rel"
  done < <(relavent_files)

  echo "${disagreements} disagreement(s)" >&2
}

_build_dead_cache() {
  rm -f "$DEAD_LIST" 2>/dev/null
  build_dead_cache > "$DEAD_LIST" && stamp_cache "$DEAD_LIST"
}

# Return cached dead-files, rebuilding if stale.
get_dead_cache() {
  [[ "$FORCE_REBUILD" != "true" && "$BUST_CACHE" != "true" ]] || rm -f "$DEAD_LIST" 2>/dev/null
  cache_is_valid "$DEAD_LIST" || _build_dead_cache
  cat "$DEAD_LIST"
}


# ─────────────────────────────────────────────────────────
# Global --rebuild-cache: wipe and rebuild all caches.
# Handled before dispatch so it works with any subcommand.
# Dead cache runs last since it depends on both others.
# (The tsconfig alias table is rebuilt before this runs,
# since every resolution depends on it.)
# ─────────────────────────────────────────────────────────
build_all_caches() {
  _build_live_cache
  _build_importers_cache
  _build_dead_cache
  (($? != 0)) || echo "Done." >&2
}



# ─────────────────────────────────────────────────────────
# resolve_uri <specifier> [<from-file-repo-relative>]
# Prints repo-relative path. Prints nothing for node: builtins
# and packages (bare specifiers that no tsconfig alias claims).
# ─────────────────────────────────────────────────────────
resolve_uri() {
  local uri="$1" from_file="$2"
  case "$uri" in
  node:*) return ;;
  .|..|./*|../*)
    if [[ -n "$from_file" ]]; then
      local abs_from="$REPO_ROOT/$from_file"
      [[ -f "$abs_from" ]] || abs_from="$from_file"
      local _dir="$(dirname "$(realpath "$abs_from" 2>/dev/null || echo "$abs_from")")"
      resolve_module_path "$(realpath -m "$_dir/$uri" 2>/dev/null)"
    fi
    ;;
  /*) resolve_module_path "$uri" ;;
  *) resolve_alias "$uri" ;;
  esac
}

# resolve_alias <specifier>
# TypeScript picks the `paths` pattern with the longest prefix before its `*`
# (an exact pattern beats any wildcard), then tries that pattern's
# substitutions in order. baseUrl is the last resort.
resolve_alias() {
  local uri="$1" pattern prefix suffix best="" star="" hit
  local -i i best_len=-1

  for ((i=0;i<${#ALIAS_PATTERN[@]};i++)); do
    pattern="${ALIAS_PATTERN[$i]}"
    if [[ "$pattern" != *'*'* ]]; then
      [[ "$pattern" == "$uri" ]] || continue
      best="$pattern" star=""
      break
    fi
    prefix="${pattern%%\**}" suffix="${pattern#*\*}"
    [[ "$uri" == "$prefix"* && "$uri" == *"$suffix" ]] || continue
    (( ${#uri} >= ${#prefix} + ${#suffix} && ${#prefix} > best_len )) || continue
    best="$pattern" best_len=${#prefix}
    star="${uri:${#prefix}:$(( ${#uri} - ${#prefix} - ${#suffix} ))}"
  done

  if [[ -n "$best" ]]; then
    for ((i=0;i<${#ALIAS_PATTERN[@]};i++)); do
      [[ "${ALIAS_PATTERN[$i]}" == "$best" ]] || continue
      # Quoted replacement so a `&` in the specifier isn't expanded (bash 5.2 patsub_replacement).
      hit="$(resolve_module_path "$(realpath -m "${ALIAS_TARGET[$i]/\*/"$star"}" 2>/dev/null)")"
      [[ -z "$hit" ]] || { echo "$hit"; return; }
    done
  fi

  [[ -z "$TS_BASE_URL" ]] || resolve_module_path "$(realpath -m "$TS_BASE_URL/$uri" 2>/dev/null)"
}

# ─────────────────────────────────────────────────────────
# resolve_module_path <absolute-path>
# Applies TypeScript's extension rules to a candidate path and prints
# the repo-relative file it lands on:
#   - a .js/.jsx/.mjs/.cjs specifier maps to its TS source first
#   - an extensionless one tries each script extension, then a
#     directory index
#   - any other existing file (JSON, images, styles) resolves as
#     itself, so imported assets show up in the graph
# ─────────────────────────────────────────────────────────
resolve_module_path() {
  local base="$1"
  [[ -n "$base" ]] || return
  local -a candidates=() exts=(.ts .tsx .js .jsx)
  local -i i

  case "$base" in
  *.js)  candidates[${#candidates[@]}]="${base%.js}.ts"; candidates[${#candidates[@]}]="${base%.js}.tsx" ;;
  *.jsx) candidates[${#candidates[@]}]="${base%.jsx}.tsx" ;;
  *.mjs) candidates[${#candidates[@]}]="${base%.mjs}.mts" ;;
  *.cjs) candidates[${#candidates[@]}]="${base%.cjs}.cts" ;;
  esac
  candidates[${#candidates[@]}]="$base"
  for ((i=0;i<${#exts[@]};i++)); do candidates[${#candidates[@]}]="$base${exts[$i]}"; done
  for ((i=0;i<${#exts[@]};i++)); do candidates[${#candidates[@]}]="$base/index${exts[$i]}"; done

  for ((i=0;i<${#candidates[@]};i++)); do
    [[ -f "${candidates[$i]}" ]] || continue
    realpath --relative-to="$REPO_ROOT" "${candidates[$i]}" 2>/dev/null
    return
  done
}


# ─────────────────────────────────────────────────────────
# ast-grep plumbing
# ─────────────────────────────────────────────────────────

# sg_lang <file> — grammar for a file. Plain .ts must use the typescript
# grammar (its `<T>expr` casts clash with JSX); everything else, including
# JavaScript entry points, parses with tsx, which is a superset of JS + JSX.
sg_lang() { case "$1" in *.ts|*.mts|*.cts) echo typescript ;; *) echo tsx ;; esac; }

# sg_scan <file> <rules> — runs inline rules (written with __LANG__ in place
# of the language) against one file. The file goes through stdin because
# ast-grep silently skips explicit paths whose extension doesn't belong to
# the rule's language (e.g. a tsx-parsed index.js).
sg_scan() {
  local lang="$(sg_lang "$1")"
  ast-grep scan --inline-rules "${2//__LANG__/$lang}" --stdin --json < "$1" 2>/dev/null
}

# Module specifiers, one rule per directive (the rule id is the directive):
#   import  — `import … from "x"`, `import "x"`, `import type …`, `import x = require("x")`
#   export  — `export … from "x"`, `export * from "x"`
#   dynamic — `import("x")` and `require("x")` (lazy routes, React Native assets)
URI_RULES='id: import
language: __LANG__
rule:
  kind: string_fragment
  inside:
    kind: string
    inside:
      field: source
      any:
        - kind: import_statement
        - kind: import_require_clause
---
id: export
language: __LANG__
rule:
  kind: string_fragment
  inside:
    kind: string
    inside:
      field: source
      kind: export_statement
---
id: dynamic
language: __LANG__
rule:
  kind: string_fragment
  inside:
    kind: string
    nthChild: 1
    inside:
      kind: arguments
      inside:
        kind: call_expression
        has:
          field: function
          any:
            - kind: import
            - { kind: identifier, regex: ^require$ }'

# Top-level declarations (directly in the module or under an `export`),
# one rule per entity kind (the rule id is the kind). Destructured
# variables are skipped: their "name" is a pattern, not an identifier.
# Namespaces sit in an expression_statement unless exported.
# YAML anchors don't carry across `---` documents, so each rule gets its
# own copy of the `top` util.
ENTITY_UTILS='utils:
  top:
    any:
      - kind: program
      - kind: export_statement
        inside: { kind: program }'
ENTITY_RULES='id: class
language: __LANG__
utils: *utils
rule:
  any: [kind: class_declaration, kind: abstract_class_declaration]
  inside: { matches: top }
  has: { field: name, pattern: $NAME }
---
id: interface
language: __LANG__
utils: *utils
rule:
  kind: interface_declaration
  inside: { matches: top }
  has: { field: name, pattern: $NAME }
---
id: type
language: __LANG__
utils: *utils
rule:
  kind: type_alias_declaration
  inside: { matches: top }
  has: { field: name, pattern: $NAME }
---
id: enum
language: __LANG__
utils: *utils
rule:
  kind: enum_declaration
  inside: { matches: top }
  has: { field: name, pattern: $NAME }
---
id: function
language: __LANG__
utils: *utils
rule:
  any: [kind: function_declaration, kind: generator_function_declaration]
  inside: { matches: top }
  has: { field: name, pattern: $NAME }
---
id: namespace
language: __LANG__
utils: *utils
rule:
  kind: internal_module
  any:
    - inside: { matches: top }
    - inside: { kind: expression_statement, inside: { matches: top } }
  has: { field: name, pattern: $NAME }
---
id: variable
language: __LANG__
utils: *utils
rule:
  kind: variable_declarator
  inside:
    any: [kind: lexical_declaration, kind: variable_declaration]
    inside: { matches: top }
  has: { field: name, kind: identifier, pattern: $NAME }'
ENTITY_RULES="${ENTITY_RULES//'utils: *utils'/$ENTITY_UTILS}"

# Every name a file references outside its import statements. Covers
# values, types, member access (`ns.Foo`, `Class.field`) and JSX tags.
IDENT_RULES='id: ident
language: __LANG__
rule:
  any:
    - kind: identifier
    - kind: type_identifier
    - kind: property_identifier
    - kind: shorthand_property_identifier
  not:
    inside: { kind: import_statement, stopBy: end }'

# Import/export bindings, i.e. which name comes from which specifier:
#   import-spec    — `import { A as B } from "x"`  (NAME = A)
#   import-default — `import B from "x"`           (NAME = B, the local)
#   import-bare    — `import "x"`
#   export-spec    — `export { A as B } from "x"`  (NAME = A)
#   export-star    — `export * from "x"`, `export * as ns from "x"`
#   default-export — `export default <decl or identifier>` (NAME = its name)
#   require-binding — `const B = require("x")` / `= import("x")` (NAME = B)
BINDING_RULES='id: import-spec
language: __LANG__
rule:
  kind: import_specifier
  has: { field: name, pattern: $NAME }
  inside:
    kind: named_imports
    inside:
      kind: import_clause
      inside:
        kind: import_statement
        has: { field: source, has: { kind: string_fragment, pattern: $SRC } }
---
id: import-default
language: __LANG__
rule:
  kind: identifier
  pattern: $NAME
  inside:
    kind: import_clause
    inside:
      kind: import_statement
      has: { field: source, has: { kind: string_fragment, pattern: $SRC } }
---
id: import-bare
language: __LANG__
rule:
  kind: import_statement
  has: { field: source, has: { kind: string_fragment, pattern: $SRC } }
  not: { has: { any: [kind: import_clause, kind: import_require_clause] } }
---
id: export-spec
language: __LANG__
rule:
  kind: export_specifier
  has: { field: name, pattern: $NAME }
  inside:
    kind: export_clause
    inside:
      kind: export_statement
      has: { field: source, has: { kind: string_fragment, pattern: $SRC } }
---
id: export-star
language: __LANG__
rule:
  kind: export_statement
  has: { field: source, has: { kind: string_fragment, pattern: $SRC } }
  not: { has: { kind: export_clause } }
---
id: default-export
language: __LANG__
rule:
  kind: export_statement
  regex: ^export\s+default\b
  inside: { kind: program }
  any:
    - has: { field: declaration, has: { field: name, pattern: $NAME } }
    - has: { field: value, kind: identifier, pattern: $NAME }
---
id: require-binding
language: __LANG__
rule:
  kind: variable_declarator
  all:
    - has: { field: name, kind: identifier, pattern: $NAME }
    - has:
        field: value
        kind: call_expression
        all:
          - has:
              field: function
              any:
                - kind: import
                - { kind: identifier, regex: ^require$ }
          - has:
              field: arguments
              has:
                kind: string
                nthChild: 1
                has: { kind: string_fragment, pattern: $SRC }'

# ─────────────────────────────────────────────────────────
# ast_grep_uris <absolute-file-path> <directive>
# Extracts specifiers for import/export/dynamic. One per line.
# ─────────────────────────────────────────────────────────
ast_grep_uris() {
  # file="$1" directive="$2"
  is_script "$1" || return 0
  sg_scan "$1" "$URI_RULES" | jq -r --arg d "$2" '.[] | select(.ruleId == $d) | .text' 2>/dev/null
}

# ─────────────────────────────────────────────────────────
# ast_grep_identifiers <absolute-file-path>
# Outputs a JSON array of the distinct names the file references.
# ─────────────────────────────────────────────────────────
ast_grep_identifiers() {
  is_script "$1" || { echo "[]"; return; }
  local raw="$(sg_scan "$1" "$IDENT_RULES")"
  present_ "$raw" || { echo "[]"; return; }
  echo "$raw" | jq -c '[.[].text] | unique'
}

# ─────────────────────────────────────────────────────────
# ast_grep_bindings <absolute-file-path>
# Outputs a JSON array of {id, name, local, src, line} (see BINDING_RULES).
# `name` is what the other module calls it ("default" for default
# imports), `local` is what this file calls it.
# ─────────────────────────────────────────────────────────
ast_grep_bindings() {
  is_script "$1" || { echo "[]"; return; }
  local raw="$(sg_scan "$1" "$BINDING_RULES")"
  present_ "$raw" || { echo "[]"; return; }
  echo "$raw" | jq -c '[.[] | .metaVariables.single as $mv | {
      id: .ruleId,
      name: (if .ruleId == "import-default" then "default"
             elif .ruleId == "export-star" then "*"
             else $mv.NAME.text end),
      # `A as B` binds B; a `type` modifier on the specifier is not part of the name.
      local: (if .ruleId == "import-spec" or .ruleId == "export-spec"
              then (.text | sub("^type\\s+"; "") | [splits("\\s+as\\s+")] | last)
              else $mv.NAME.text end),
      src: $mv.SRC.text,
      line: (.range.start.line + 1)
  }]'
}

# ─────────────────────────────────────────────────────────
# ast_grep_entities <absolute-file-path> <depth>
# Outputs JSON array of entities. depth: names | signatures | full
# ─────────────────────────────────────────────────────────
ast_grep_entities() {
    local file="$1" depth="${2:-names}"
    is_script "$file" || { echo "[]"; return; }

    local raw="$(sg_scan "$file" "$ENTITY_RULES")"
    present_ "$raw" || { echo "[]"; return; }

    # A declaration's first line is not necessarily its header: decorators
    # (`@Injectable()`) are part of a class node. Use the first line that
    # contains the name instead (falls back to the first line). Variable
    # nodes start at the name (`foo = …`), like Dart's top-level variables.
    echo "$raw" | jq --arg depth "$depth" '
        [.[] | .metaVariables.single.NAME.text as $n
            | (.text | split("\n")) as $lines
            | (([$lines[] | select(contains($n))] | first) // $lines[0]) as $header
            | {
                kind: .ruleId,
                name: $n,
                line: (.range.start.line + 1),
                text: (
                    if $depth == "full" then .text
                    elif $depth == "signatures" then $header
                    else null
                    end
                )
            }]
        | sort_by(.line) | if .[0].text == null then [.[] | del(.text)] else . end'
}

# ─────────────────────────────────────────────────────────
# to_abs <file>
# ─────────────────────────────────────────────────────────
to_abs() { [[ "$1" == /* ]] && echo "$1" || echo "$REPO_ROOT/$1"; }

to_rel() { realpath --relative-to="$REPO_ROOT" "$(to_abs "$1")" 2>/dev/null; }

# Escape a string for use inside an ast-grep (Rust) regex.
regex_escape() { sed 's/[][\.*^$+?(){}|]/\\&/g' <<< "$1"; }

# ─────────────────────────────────────────────────────────
# Subcommand: resolve
# ─────────────────────────────────────────────────────────
cmd_resolve() {
  local uri="" from_file=""
  local -i a=1
  for ((;a<=$#;a++)); do
    case "${!a}" in
    --from) ((++a)); from_file="${!a}" ;;
    *) uri="${!a}"
    esac
  done
  [[ -n "$uri" ]] || die "usage: discover.sh resolve <specifier> [--from <file>]"
  ## fucking slop
  # local result
  # result="$(resolve_uri "$uri" "$from_file")"
  # [ -n "$result" ] && echo "$result"
  resolve_uri "$uri" "$from_file"
}

# ─────────────────────────────────────────────────────────
# Subcommand: inspect
# ─────────────────────────────────────────────────────────
cmd_inspect() {
    local file="" show_imports=false show_exports=false show_dynamic=false show_entities=false depth="names"
    while [ $# -gt 0 ]; do
        case "$1" in
            --imports)  show_imports=true ;;
            --exports)  show_exports=true ;;
            --dynamic)  show_dynamic=true ;;
            --entities)
                show_entities=true
                case "${2:-}" in name|names|signatures|full) depth="$2"; shift ;; esac
                ;;
            --depth)    shift; depth="$1" ;;
            *) file="$1" ;;
        esac
        shift
    done
    [ -n "$file" ] || die "usage: discover.sh inspect <file> [--imports] [--exports] [--dynamic] [--entities] [--depth names|signatures|full]"

    if ! $show_imports && ! $show_exports && ! $show_dynamic && ! $show_entities; then
        show_imports=true; show_exports=true; show_dynamic=true; show_entities=true
    fi

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"
    is_script "$abs_file" || die "not a TypeScript/JavaScript module: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    # Start building JSON
    local result="$(jq -nc --arg f "$repo_rel" '{file: $f}')"

    # Directive helper: outputs JSON array of {uri, resolved} objects
    # (built with jq so quotes in a specifier can't break the JSON).
    emit_directive() {
        local directive="$1" uri resolved
        while IFS= read -r uri; do
            [ -n "$uri" ] || continue
            resolved="$(resolve_uri "$uri" "$repo_rel")"
            jq -nc --arg uri "$uri" --arg r "$resolved" '{uri: $uri} + (if $r != "" then {resolved: $r} else {} end)'
        done < <(ast_grep_uris "$abs_file" "$directive") | jq -sc .
    }

    if $show_imports; then
        result="$(jq -c --argjson v "$(emit_directive import)" '. + {imports: $v}' <<< "$result")"
    fi
    if $show_exports; then
        result="$(jq -c --argjson v "$(emit_directive export)" '. + {exports: $v}' <<< "$result")"
    fi
    if $show_dynamic; then
        result="$(jq -c --argjson v "$(emit_directive dynamic)" '. + {dynamic: $v}' <<< "$result")"
    fi
    if $show_entities; then
        # --entities name: plain text, one name per line, no JSON wrapper
        if [[ "$depth" == "name" ]]; then
            ast_grep_entities "$abs_file" names | jq -r '.[].name'
            return
        fi
        result="$(jq -c --argjson v "$(ast_grep_entities "$abs_file" "$depth")" '. + {entities: $v}' <<< "$result")"
    fi

    echo "$result" | jq .
}


# ─────────────────────────────────────────────────────────
# Subcommand: live-files [--rebuild-cache]
# ─────────────────────────────────────────────────────────
cmd_live_files() { get_live_cache; }

# ─────────────────────────────────────────────────────────
# Subcommand: dead-files
# Lists all files determined dead by recursive trace (not
# simply the inverse of live-files). Requires the dead cache,
# which is built during --rebuild-cache or on first call.
#
# WARNING: Before deleting any file listed here, back it up under .ignore/
# replicating the original directory structure. There are known edge cases
# where live/dead cannot be determined programmatically. Backing up into
# .ignore/ allows easy restoration of anything falsely flagged.
# ─────────────────────────────────────────────────────────
cmd_dead_files() {
    if [[ "${1:-}" == "--rebuild" ]]; then
        _build_dead_cache
    fi
    get_dead_cache
}

# ─────────────────────────────────────────────────────────
# Subcommand: is-live
# ─────────────────────────────────────────────────────────
cmd_is_live() {
    local file="$1"
    [ -n "$file" ] || die "usage: discover.sh is-live <file>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    if get_live_cache 2>/dev/null | grep -qxF "$repo_rel"; then
        echo "LIVE: $repo_rel"
        return 0
    else
        echo "DEAD: $repo_rel"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────
# Subcommand: definition
# ─────────────────────────────────────────────────────────
cmd_definition() {
    local file="$1" symbol="$2"
    [ -n "$file" ] && [ -n "$symbol" ] || die "usage: discover.sh definition <file> <symbol>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    # Check if symbol is defined locally
    local local_match
    local_match="$(ast_grep_entities "$abs_file" names | jq -r --arg sym "$symbol" '.[] | select(.name == $sym) | "\(.kind)\t\(.line)"' | head -1)"
    if [ -n "$local_match" ]; then
        local kind="${local_match%%	*}"
        local line="${local_match#*	}"
        jq -n --arg sym "$symbol" --arg kind "$kind" --arg file "$repo_rel" --argjson line "$line" \
            '{symbol: $sym, kind: $kind, file: $file, line: $line, source: "local"}'
        return 0
    fi

    # Search imports, following re-exports. Keyed by file AND name: a barrel
    # can legitimately be searched once per name it re-exports under.
    declare -A visited

    # search_file <abs-path> <name> <via-chain-json-array>
    # <name> is what the module itself calls the symbol, which differs from
    # the importer's name for `import { A as B }` and default imports.
    search_file() {
        local target_abs="$1" name="$2" via_json="$3"
        [ -f "$target_abs" ] || return 1
        is_script "$target_abs" || return 1

        local target_real
        target_real="$(realpath "$target_abs")"
        [[ -v visited["$target_real#$name"] ]] && return 1
        visited["$target_real#$name"]=1

        local target_rel
        target_rel="$(realpath --relative-to="$REPO_ROOT" "$target_real")"

        local binds
        binds="$(ast_grep_bindings "$target_real")"

        # A default import names whatever this module's default export declares.
        if [[ "$name" == default ]]; then
            name="$(echo "$binds" | jq -r '[.[] | select(.id == "default-export")] | first | .name // empty')"
            [ -n "$name" ] || return 1
        fi

        # Check entities in this file
        local match
        match="$(ast_grep_entities "$target_real" names | jq -r --arg sym "$name" '.[] | select(.name == $sym) | "\(.kind)\t\(.line)"' | head -1)"
        if [ -n "$match" ]; then
            local kind="${match%%	*}"
            local line="${match#*	}"
            jq -n --arg sym "$symbol" --arg kind "$kind" --arg file "$target_rel" --argjson line "$line" --argjson via "$via_json" \
                '{symbol: $sym, kind: $kind, file: $file, line: $line, via: $via}'
            return 0
        fi

        # Follow re-exports: `export { X } from`, `export * from` (which never
        # carries a default export), and `import { X } …; export { X }`.
        local src orig resolved resolved_abs new_via
        while IFS=$'\t' read -r src orig; do
            [ -n "$src" ] || continue
            resolved="$(resolve_uri "$src" "$target_rel")"
            [ -n "$resolved" ] || continue
            resolved_abs="$(realpath "$REPO_ROOT/$resolved" 2>/dev/null)"
            [ -f "$resolved_abs" ] || continue

            new_via="$(echo "$via_json" | jq -c --arg f "$target_rel" '. + [$f]')"
            if search_file "$resolved_abs" "$orig" "$new_via"; then
                return 0
            fi
        done < <(echo "$binds" | jq -r --arg n "$name" '.[]
            | if .id == "export-star" then (if $n != "default" then "\(.src)\t\($n)" else empty end)
              elif (.id == "export-spec" or .id == "import-spec" or .id == "import-default") and .local == $n then "\(.src)\t\(.name)"
              else empty end')

        return 1
    }

    # The symbol is an import binding in this file: follow exactly that import.
    local src orig resolved
    while IFS=$'\t' read -r src orig; do
        [ -n "$src" ] || continue
        resolved="$(resolve_uri "$src" "$repo_rel")"
        [ -n "$resolved" ] || continue
        if search_file "$REPO_ROOT/$resolved" "$orig" "[]"; then
            return 0
        fi
    done < <(ast_grep_bindings "$abs_file" | jq -r --arg n "$symbol" '.[]
        | select((.id == "import-spec" or .id == "import-default") and .local == $n)
        | "\(.src)\t\(.name)"')

    # Otherwise search each import by name (covers namespace access, `ns.Foo`).
    local uri
    while IFS= read -r uri; do
        [ -n "$uri" ] || continue
        resolved="$(resolve_uri "$uri" "$repo_rel")"
        [ -n "$resolved" ] || continue
        if search_file "$REPO_ROOT/$resolved" "$symbol" "[]"; then
            return 0
        fi
    done < <(ast_grep_uris "$abs_file" "import")

    # Search dynamically loaded modules
    while IFS= read -r uri; do
        [ -n "$uri" ] || continue
        resolved="$(resolve_uri "$uri" "$repo_rel")"
        [ -n "$resolved" ] || continue
        if search_file "$REPO_ROOT/$resolved" "$symbol" "[\"(dynamic)\"]"; then
            return 0
        fi
    done < <(ast_grep_uris "$abs_file" "dynamic")

    jq -n --arg sym "$symbol" '{symbol: $sym, error: "not found in import graph"}'
    return 1
}

# ─────────────────────────────────────────────────────────
# Subcommand: importers
# ─────────────────────────────────────────────────────────
cmd_importers() {
  (($# > 0)) || die "usage: discover.sh importers <file>"

  local abs_file
  abs_file="$(to_abs "$1")"
  [[ -f "$abs_file" ]] || die "file not found: $1"

  # Canonicalize to repo-relative path (matches index keys).
  local repo_rel
  repo_rel="$(realpath --relative-to="$REPO_ROOT" "$(realpath "$abs_file")")"
  get_importers_cache | jq --arg key "$repo_rel" '.[$key] // []' | jq 'sort_by(.file)' | jq -r '.[].file'
}

# ─────────────────────────────────────────────────────────
# Subcommand: trace
# Determines whether a file is dead by recursively walking
# its import chain upward toward the entry points. Each
# importer is tagged:
#   active — live importer that uses the target's entities
#   stale  — live importer that doesn't use any entities
#   zombie — dead importer (uses entities, but from a dead chain)
# The file-level "dead" is true when no importer is active.
#
# After resolving, cross-checks against is-live (BFS cache)
# and warns on disagreement.
# ─────────────────────────────────────────────────────────

# Recursive helper: determines if a file is reachable from an entry point
# by walking importers upward. Uses the importers cache for edges,
# but does NOT use the live cache — it traces independently.
# Results are memoized in _trace_live to avoid redundant walks.
# _trace_visited tracks the current recursion stack for cycle detection.
declare -A _trace_live
declare -A _trace_visited

_is_reachable() {
    local file="$1"

    # Base case: the entry points are the root of all liveness.
    [[ ! -v ENTRY_SET["$file"] ]] || return 0

    # Cycle: we're already walking this file's chain.
    [[ ! -v _trace_visited["$file"] ]] || return 1

    # Memoized result from a prior call.
    if [[ -v _trace_live["$file"] ]]; then
        return "${_trace_live[$file]}"
    fi

    # Mark as in-progress for cycle detection.
    _trace_visited["$file"]=1

    # Walk importers. If any importer is reachable, this file is reachable.
    local importer
    while IFS= read -r importer; do
        [[ -n "$importer" ]] || continue
        if _is_reachable "$importer"; then
            unset _trace_visited["$file"]
            _trace_live["$file"]=0
            return 0
        fi
    done < <(echo "$_importers_json" | jq -r --arg key "$file" '.[$key] // [] | .[].file')

    unset _trace_visited["$file"]
    # Don't memoize dead results — a file marked dead here may only
    # be unreachable because a valid ancestor was on the cycle-detection
    # stack. A later call from a different entry point may find it live.
    return 1
}

cmd_trace() {
    local file="$1"
    [ -n "$file" ] || die "usage: discover.sh trace <file>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    # Canonicalize to repo-relative path (matches index keys).
    local repo_rel
    repo_rel="$(realpath --relative-to="$REPO_ROOT" "$(realpath "$abs_file")")"

    # Get the entities defined in this file.
    local entities
    entities="$(ast_grep_entities "$abs_file" names | jq -c '[.[].name]')"

    # Load the full importers index once for the recursive walk.
    _importers_json="$(get_importers_cache)"

    # Reset memoization for this trace invocation.
    _trace_live=()
    _trace_visited=()

    # Look up direct importers of this file.
    local importers
    importers="$(echo "$_importers_json" | jq --arg key "$repo_rel" '.[$key] // []')"

    # Tag each importer by recursively determining reachability.
    local tagged="[]"
    local importer_file entities_used status
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        importer_file="$(echo "$row" | jq -r '.file')"
        entities_used="$(echo "$row" | jq -c '.entities_used')"

        if _is_reachable "$importer_file"; then
            # Live importer: active if it uses entities, stale otherwise.
            if [[ "$(echo "$entities_used" | jq 'length')" -gt 0 ]]; then
                status="active"
            else
                status="stale"
            fi
        else
            # Dead importer: zombie (the import exists but the chain is dead).
            status="zombie"
        fi

        tagged="$(echo "$tagged" | jq --argjson row "$row" --arg status "$status" \
            '. + [$row + {status: $status}]')"
    done < <(echo "$importers" | jq -c '.[]')

    tagged="$(echo "$tagged" | jq 'sort_by(.file)')"

    # File is dead if no importer is active.
    local active_count
    active_count="$(echo "$tagged" | jq '[.[] | select(.status == "active")] | length')"
    local is_dead=true
    [[ "$active_count" -eq 0 ]] || is_dead=false
    # An entry point has no importers by definition, yet is live.
    [[ ! -v ENTRY_SET["$repo_rel"] ]] || is_dead=false

    # Cross-check: verify is-live (BFS cache) agrees with our conclusion.
    local is_live_result
    is_live_result="$(cmd_is_live "$file" 2>/dev/null)" || true
    local bfs_says_dead=true
    [[ "$is_live_result" != *"LIVE"* ]] || bfs_says_dead=false

    local warning=""
    if [[ "$is_dead" != "$bfs_says_dead" ]]; then
        warning="DISAGREEMENT: trace says dead=$is_dead but is-live says dead=$bfs_says_dead"
        echo "WARNING: $warning" >&2
    fi

    local result
    result="$(jq -n \
        --arg file "$repo_rel" \
        --argjson entities "$entities" \
        --argjson importers "$tagged" \
        --argjson dead "$is_dead" \
        --argjson active_count "$active_count" \
        '{file: $file, entities: $entities, importers: $importers, dead: $dead, active_count: $active_count}')"

    # Attach warning only if present.
    if [[ -n "$warning" ]]; then
        result="$(echo "$result" | jq --arg w "$warning" '. + {warning: $w}')"
    fi

    echo "$result"
}

# ─────────────────────────────────────────────────────────
# Subcommand: prune — remove one entry from both caches
# ─────────────────────────────────────────────────────────
cmd_prune() {
    local f="${1:?usage: discover.sh prune <file>}"
    # Drop the exact line from the live-files list.
    [[ -f "$CACHE_FILE" ]] && grep -vxF "$f" "$CACHE_FILE" > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
    # Remove as a target key and as an importer (.file) in other entries.
    [[ -f "$IMPORTERS_CACHE_FILE" ]] && jq --arg f "$f" 'del(.[$f]) | map_values([.[] | select(.file != $f)]) | with_entries(select(.value | length > 0))' "$IMPORTERS_CACHE_FILE" > "$IMPORTERS_CACHE_FILE.tmp" && mv "$IMPORTERS_CACHE_FILE.tmp" "$IMPORTERS_CACHE_FILE"
    # Stamp a fresh fingerprint so patched caches aren't treated as stale.
    SOURCE_FP="$(compute_fingerprint)"
    local c
    for c in "$CACHE_FILE" "$IMPORTERS_CACHE_FILE"; do
        [[ ! -f "$c" ]] || stamp_cache "$c"
    done
}

# ─────────────────────────────────────────────────────────
# Subcommand: usages
# ─────────────────────────────────────────────────────────

# sg_run_sources <pattern> — runs an ast-grep pattern over every source
# file, grouped by grammar (.tsx needs the tsx grammar, .ts must not use
# it), and prints one merged JSON array.
sg_run_sources() {
  local f
  local -a ts=() tsx=()
  while IFS= read -r -d '' f; do
    case "$f" in
    *.tsx) tsx[${#tsx[@]}]="$f" ;;
    *)     ts[${#ts[@]}]="$f" ;;
    esac
  done < <(relavent_files)
  {
    ((${#ts[@]} == 0)) || ast-grep run -l typescript -p "$1" "${ts[@]}" --json 2>/dev/null
    ((${#tsx[@]} == 0)) || ast-grep run -l tsx -p "$1" "${tsx[@]}" --json 2>/dev/null
  } | jq -s 'add // []'
}

cmd_usages() {
  local pattern="" asset_path="" live_only=false
  local -i a=1
  for ((;a<=$#;a++)); do
    case "${!a}" in
    --live-only) live_only=true ;;
    --assets) ((++a)); asset_path="${!a}" 2>/dev/null
      [[ -n "$asset_path" ]] || die "--assets requires an asset path argument" ;;
    *) pattern="${!a}"
    esac
  done

  # --assets mode: find what references a specific asset path
  if [[ -n "$asset_path" ]]; then
    _usages_asset "$asset_path"
    return
  fi

  [[ -n "$pattern" ]] || die "usage: discover.sh usages <pattern> [--live-only]\n       discover.sh usages --assets <asset-path>"

  local live_cache=""
  if $live_only; then
    live_cache="$(get_live_cache 2>/dev/null)"
  fi

  # Structural pass: ast-grep with the caller's pattern
  local raw="$(sg_run_sources "$pattern")"
  present_ "$raw" || { echo "[]"; echo "0 usages found" >&2; return; }

  local formatted
  if $live_only && [[ -n "$live_cache" ]]; then
    formatted="$(echo "$raw" | jq --slurpfile lf <(echo "$live_cache" | jq -R -s 'split("\n") | map(select(. != ""))') \
        '[.[] | . as $m |
            ($m.file | ltrimstr("'"$REPO_ROOT/"'")) as $rel |
            select($lf[0] | index($rel)) |
            {file: $rel, line: (.range.start.line + 1), text: (.lines | split("\n")[0] | ltrimstr(" "))}
        ] | unique_by("\(.file):\(.line)") | sort_by(.file, .line)')"
  else
    formatted="$(echo "$raw" | jq --arg root "$REPO_ROOT/" \
        '[.[] | {
            file: (.file | ltrimstr($root)),
            line: (.range.start.line + 1),
            text: (.lines | split("\n")[0] | ltrimstr(" "))
        }] | unique_by("\(.file):\(.line)") | sort_by(.file, .line)')"
  fi

  # Results on stdout so they can be piped; the count is commentary.
  echo "$formatted"
  echo "$(echo "$formatted" | jq 'length') usages found" >&2
}

# --assets helper: given an asset path, find all live references to it.
# Assets reach TS code as modules — `import logo from "./logo.svg"`,
# `require("../img/x.png")` (React Native) — or as URL strings for files
# under public/, which web toolchains serve from the site root. Reports two
# separate sections:
#   "binding_refs" — usages via a name bound to the asset
#                    (`import logo from …`, `const logo = require(…)`)
#   "direct_refs"  — the asset loaded or named inline: an unbound
#                    import()/require(), or a string literal of its path
_usages_asset() {
  local asset_rel
  asset_rel="$(to_rel "$1")"
  [[ -f "$REPO_ROOT/$asset_rel" ]] || die "asset not found: $1"
  local live_cache="$(get_live_cache 2>/dev/null)"

  # String literals that name the asset: its repo path and, for public/
  # files, the URL it is served at.
  local literal_re="$(regex_escape "$asset_rel")"
  [[ "$asset_rel" != public/* ]] || literal_re+="|$(regex_escape "/${asset_rel#public/}")"
  local literal_rule="---
id: literal
language: __LANG__
rule:
  kind: string_fragment
  regex: ^(${literal_re})\$"

  local binding_results="[]" direct_results="[]"
  local rel file raw refs binds bound uses entry name decl_line

  while IFS= read -r rel; do
    is_script "$rel" || continue
    file="$REPO_ROOT/$rel"

    raw="$(sg_scan "$file" "$URI_RULES
$literal_rule")"
    present_ "$raw" || continue

    # Module references whose specifier resolves to this asset.
    refs="[]"
    local -i n i
    n="$(echo "$raw" | jq '[.[] | select(.ruleId != "literal")] | length')"
    for ((i=0;i<n;i++)); do
      entry="$(echo "$raw" | jq -c "[.[] | select(.ruleId != \"literal\")][$i]")"
      [[ "$(resolve_uri "$(echo "$entry" | jq -r '.text')" "$rel")" == "$asset_rel" ]] || continue
      refs="$(echo "$refs" | jq -c --argjson e "$entry" '. + [$e]')"
    done

    # Literal path strings are always direct references.
    direct_results="$(echo "$direct_results" | jq -c --arg rel "$rel" --argjson raw "$raw" '. + [$raw[]
        | select(.ruleId == "literal")
        | {file: $rel, line: (.range.start.line + 1), text: (.lines | split("\n")[0] | ltrimstr(" "))}]')"
    [[ "$refs" != "[]" ]] || continue

    # Names this file binds to one of those references.
    binds="$(ast_grep_bindings "$file" | jq -c --argjson refs "$refs" \
        '[.[] | select(.id == "import-default" or .id == "require-binding")
              | select(.line as $l | .src as $s | $refs | any((.range.start.line + 1) == $l and .text == $s))]')"

    # Unbound references are direct.
    direct_results="$(echo "$direct_results" | jq -c --arg rel "$rel" --argjson refs "$refs" --argjson binds "$binds" '. + [$refs[]
        | select((.range.start.line + 1) as $l | $binds | any(.line == $l) | not)
        | {file: $rel, line: (.range.start.line + 1), text: (.lines | split("\n")[0] | ltrimstr(" "))}]')"

    # Bound references: report every use of the bound name in live code,
    # i.e. in this file and in live importers that use it by that name.
    while IFS=$'\t' read -r name decl_line; do
      [[ -n "$name" ]] || continue
      echo "binding: ${name} (${rel}:${decl_line})" >&2

      local -a scan_files=("$rel")
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        echo "$live_cache" | grep -qxF "$entry" && scan_files[${#scan_files[@]}]="$entry"
      done < <(get_importers_cache 2>/dev/null | jq -r --arg key "$rel" --arg n "$name" \
          '.[$key] // [] | .[] | select(.entities_used | index($n)) | .file')

      local -i j
      for ((j=0;j<${#scan_files[@]};j++)); do
        uses="$(sg_scan "$REPO_ROOT/${scan_files[$j]}" "id: use
language: __LANG__
rule:
  any: [kind: identifier, kind: property_identifier, kind: shorthand_property_identifier]
  regex: ^$(regex_escape "$name")\$
  not:
    inside: { kind: import_statement, stopBy: end }")"
        present_ "$uses" || continue
        # Skip the binding itself (its declaration line in its own file).
        binding_results="$(echo "$binding_results" | jq -c --arg f "${scan_files[$j]}" --arg decl_file "$rel" \
            --argjson decl_line "$decl_line" --arg via "$name" --argjson uses "$uses" '. + [$uses[]
            | {file: $f, line: (.range.start.line + 1), text: (.lines | split("\n")[0] | ltrimstr(" ")), binding: $via}
            | select((.file == $decl_file and .line == $decl_line) | not)]')"
      done
    done < <(echo "$binds" | jq -r '.[] | "\(.local)\t\(.line)"')
  done < <(echo "$live_cache")

  binding_results="$(echo "$binding_results" | jq -c 'unique_by("\(.file):\(.line)") | sort_by(.file, .line)')"
  direct_results="$(echo "$direct_results" | jq -c 'unique_by("\(.file):\(.line)") | sort_by(.file, .line)')"

  # Output as two distinct sections
  jq -n --argjson binding "$binding_results" --argjson direct "$direct_results" \
      '{binding_refs: $binding, direct_refs: $direct}'

  echo "$(echo "$binding_results" | jq 'length') binding ref(s), $(echo "$direct_results" | jq 'length') direct ref(s)" >&2
}


# ─────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────

# --rebuild-cache also covers the alias table, which every resolution
# (including entry detection) depends on, so drop it before loading.
[[ "$1" != "--rebuild-cache" ]] || rm -f "$TSCONFIG_PATHS_CACHE"
load_aliases
detect_entries
# Once per run; it covers the entry points, so it follows their detection.
SOURCE_FP="$(compute_fingerprint)"

# Check for --rebuild-cache before the subcommand.
if [[ "$1" == "--rebuild-cache" ]]; then
  build_all_caches

  # If no subcommand follows, the rebuild was the whole request.
  (($# > 1)) || exit 0
  shift
fi

subcmd="$1"
shift 2>/dev/null || true

case "$subcmd" in
    resolve)    cmd_resolve "$@" ;;
    inspect)    cmd_inspect "$@" ;;
    live-files) cmd_live_files "$@" ;;
    dead-files) cmd_dead_files "$@" ;;
    is-live)    cmd_is_live "$@" ;;
    definition) cmd_definition "$@" ;;
    importers)  cmd_importers "$@" ;;
    trace)      cmd_trace "$@" ;;
    prune)      cmd_prune "$@" ;;
    usages)     cmd_usages "$@" ;;
    *)
        echo "usage: discover.sh [--rebuild-cache] <command> [args]" >&2
        echo "" >&2
        echo "global flags:" >&2
        echo "  --rebuild-cache                        Wipe and rebuild all caches before running command" >&2
        echo "" >&2
        echo "environment:" >&2
        echo "  DISCOVER_ENTRY=\"<file> ...\"            Entry point(s), overriding package.json / index detection" >&2
        echo "" >&2
        echo "commands:" >&2
        echo "  resolve <specifier> [--from <file>]    Resolve import specifier to repo-relative path" >&2
        echo "  inspect <file> [--imports] [--exports] [--dynamic] [--entities]" >&2
        echo "           [--depth names|signatures|full]" >&2
        echo "  definition <file> <symbol>             Find where a symbol used in <file> is defined" >&2
        echo "  live-files                             List all files reachable from the entry points" >&2
        echo "  dead-files [--rebuild]                 List all dead files (verified by recursive trace)" >&2
        echo "  is-live <file>                         Check if a file is reachable from the entry points" >&2
        echo "  importers <file>                       Find all files that import/export/load <file>" >&2
        echo "  trace <file>                           Trace usage and liveness of a file's import chain" >&2
        echo "  prune <file>                           Remove a file entry from caches without rebuilding" >&2
        echo "  usages <pattern> [--live-only]         Find all references to an ast-grep pattern" >&2
        echo "  usages --assets <asset-path>           Check if an asset is referenced in live code" >&2
        exit 1
esac
