#!/usr/bin/env bash

# discover.sh — deterministic codebase navigation using ast-grep.
#
# Subcommands:
#   resolve <uri> [--from <file>]
#   inspect <file> [--imports] [--exports] [--parts] [--entities] [--depth names|signatures|full]
#   definition <file> <symbol>
#   live-files [--rebuild]
#   dead-files [--rebuild]
#   is-live <file> [--rebuild]
#   importers <file> [--rebuild]
#   trace <file> [--rebuild]
#   prune <file>
#   usages <pattern> [--live-only]
#   usages --assets <asset-path>


# TODO: add something like knowledge's index updating directives
#       so we can selectively prune the cache and update the fingerprint instead of rebuilding after every change.

SELF="$(realpath "${BASH_SOURCE[0]}")"
[[ -n $REPO_ROOT ]] || REPO_ROOT="$(dirname "${SELF%\/*}")"

PACKAGE_NAME="malsi_app"

LIB_DIR="$REPO_ROOT/lib"
CACHE_DIR="$REPO_ROOT/tmp"

CACHE_FILE="$CACHE_DIR/discover_live_cache.txt"
DEAD_LIST="$CACHE_DIR/discover_dead.txt"
IMPORTERS_CACHE_FILE="$CACHE_DIR/discover_importers_cache.json"


die() { echo "error: $*" >&2; exit 1; }

# Every query shells out to ast-grep with stderr silenced, so a missing binary
# would otherwise produce empty results and poison the caches with them.
command -v ast-grep >/dev/null 2>&1 || die "ast-grep not found on PATH (needs the Dart-enabled fork: https://github.com/asmrtfm/ast-grep)"

# The cache dir must exist before anything redirects into it: `fn > "$CACHE_FILE"`
# opens the target before fn's own mkdir runs, and stamp_cache writes here
# after every build.
mkdir -p "$CACHE_DIR" || die "cannot create cache dir: $CACHE_DIR"


relavent_files() { find "$LIB_DIR" -name "*.dart" -not -name "*.g.dart" -not -name "*.freezed.dart" -print0 | sort -z; }

blank_() { [[ -z "$1" || "$1" == "[]" ]]; }
present_() { [[ -n "$1" && "$1" != "[]" ]]; }


# ─────────────────────────────────────────────────────────
# Cache validity: the fingerprint is a hash of the sorted
# dart file listing under lib/ (excludes generated files).
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
compute_fingerprint() { relavent_files | md5sum | cut -d' ' -f1; }

# Computed once per run; nothing in a run adds or removes dart files
# (except prune, which recomputes it).
SOURCE_FP="$(compute_fingerprint)"

cache_is_valid() { [[ -f "$1" && -f "$1.fp" && "$(< "$1.fp")" == "$SOURCE_FP" ]]; }

stamp_cache() { echo "$SOURCE_FP" > "$1.fp"; }


# ─────────────────────────────────────────────────────────
# build_live_files — reachability from main.dart
# ─────────────────────────────────────────────────────────
build_live_cache() {
  echo "Building live-files cache" >&2
  mkdir -p "$CACHE_DIR"

  local main_dart="$LIB_DIR/main.dart"
  [[ -f "$main_dart" ]] || die "lib/main.dart not found"
  main_dart="$(realpath "$main_dart")"

  local -A live=()
  live["$main_dart"]=1

  local -a queue=()
  queue[${#queue[@]}]="$main_dart"

  local -i idx=0
  local current current_rel resolved abs_resolved

  while (( idx < ${#queue[@]} )); do
    current="${queue[$idx]}"
    ((idx++))
    [[ -f "$current" ]] || continue
    current_rel="$(realpath --relative-to="$REPO_ROOT" "$current")"

    for directive in 'import' 'export' 'part'; do
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


# Scan every dart file under lib/, extract import/export URIs,
# resolve them, and emit a JSON object keyed by repo-relative
# target path → array of {file, directive, uri, entities_used} entries.
# For each edge, determines which of the target's entities are actually
# referenced in the importing file (using ast-grep, same as cmd_usages).
build_importers_cache() {
  echo "importers: rebuilding" >&2
  mkdir -p "$CACHE_DIR"

  local tmp_file="$(mktemp)"

  # Cache entity names per target file so we only call ast_grep_entities once per target.
  local -A entity_cache=()
  local dart_rel resolved resolved_abs canon entities_json used ename hits used_compact

  # Collect all edges as newline-delimited JSON objects.
  while IFS= read -r -d '' dart_file; do
    dart_rel="$(realpath --relative-to="$REPO_ROOT" "$dart_file")"

    for directive in 'import' 'export'; do
      while IFS= read -r uri; do
        [[ -n "$uri" ]] || continue

        resolved="$(resolve_uri "$uri" "$dart_rel")"
        [[ -n "$resolved" ]] || continue

        # Canonicalize so relative and package: forms merge to the same key.

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
        used="[]"
        while IFS= read -r ename; do
          [[ -n "$ename" ]] || continue
          hits="$(ast-grep run -l dart -p "$ename" "$dart_file" --json 2>/dev/null)"
          blank_ "$hits" || used="$(echo "$used" | jq --arg n "$ename" '. + [$n]')"
        done < <(echo "$entities_json" | jq -r '.[]')

        used_compact="$(echo "$used" | jq -c '.')"
        printf '{"target":"%s","file":"%s","directive":"%s","uri":"%s","entities_used":%s}\n' \
          "$canon" "$dart_rel" "$directive" "$uri" "$used_compact" >> "$tmp_file"
      done < <(ast_grep_uris "$dart_file" "$directive")
    done
  done < <(relavent_files)

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
# list of files that import/export it. Same fingerprint
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
  while IFS= read -r -d '' dart_file; do
    repo_rel="$(realpath --relative-to="$REPO_ROOT" "$(realpath "$dart_file")")"

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
# ─────────────────────────────────────────────────────────
build_all_caches() {
  _build_live_cache
  _build_importers_cache
  _build_dead_cache
  (($? != 0)) || echo "Done." >&2
}



# ─────────────────────────────────────────────────────────
# resolve_uri <uri> [<from-file-repo-relative>]
# Prints repo-relative path. Prints nothing for dart:/external packages.
# ─────────────────────────────────────────────────────────
resolve_uri() {
  local uri="$1" from_file="$2"
  case "$uri" in
  dart:*) return ;;
  package:${PACKAGE_NAME}/*)
    local rel="${uri#package:${PACKAGE_NAME}/}"
    local full="$LIB_DIR/$rel"
    [[ ! -f "$full" ]] || realpath --relative-to="$REPO_ROOT" "$full" 2>/dev/null
    ;;
  package:*) return ;;
  *)
    if [[ -n "$from_file" ]]; then
      local abs_from="$REPO_ROOT/$from_file"
      [[ -f "$abs_from" ]] || abs_from="$from_file"
      local _dir="$(dirname "$(realpath "$abs_from" 2>/dev/null || echo "$abs_from")")"
      local resolved="$(realpath -m "$_dir/$uri" 2>/dev/null)"
      [[ -f "$resolved" ]] && realpath --relative-to="$REPO_ROOT" "$resolved" 2>/dev/null
    fi
  esac
}

# ─────────────────────────────────────────────────────────
# ast_grep_uris <absolute-file-path> <directive>
# Extracts URIs for import/export/part using ast-grep. One per line.
# ─────────────────────────────────────────────────────────
ast_grep_uris() {
  # file="$1" directive="$2"
  ast-grep run -l dart -p "$2 '\$URI';" "$1" --json 2>/dev/null \
    | jq -r '.[].metaVariables.single.URI.text' 2>/dev/null
}

# ─────────────────────────────────────────────────────────
# ast_grep_entities <absolute-file-path> <depth>
# Outputs JSON array of entities. depth: names | signatures | full
# ─────────────────────────────────────────────────────────
ast_grep_entities() {
    local file="$1" depth="${2:-names}"
    local kinds="class_declaration enum_declaration mixin_declaration extension_declaration type_alias"
    local keyword_map="class_declaration:class enum_declaration:enum mixin_declaration:mixin extension_declaration:extension type_alias:typedef"

    # Collect results into a temp array via jq
    local all_json="[]"

    for kind in $kinds; do
      local keyword=""
      for pair in $keyword_map; do
        if [[ "${pair%%:*}" == "$kind" ]]; then
          keyword="${pair#*:}"
          break
        fi
      done

      local raw="$(ast-grep run -l dart --kind "$kind" "$file" --json 2>/dev/null)"
      present_ "$raw" || continue

      # ast-grep's declaration nodes include leading annotations
      # (e.g. `@JsonSerializable()`, `@riverpod`), so the node's first line
      # is not necessarily the `<keyword> <Name>` header. Use the first line
      # that contains the header instead (falls back to the first line).
      # The name capture is wrapped in [...] | first so a failed match
      # yields "?" rather than an empty stream, which would silently drop
      # the whole entity.
      local extracted="$(echo "$raw" | jq --arg kw "$keyword" --arg depth "$depth" '
          ("(?:^|\\s)" + $kw + "\\s+(?<n>\\w+)") as $re
          | [.[] | ((.text | split("\n")) as $lines
              | (([$lines[] | select(test($re))] | first) // $lines[0]) as $header
              | {
                  kind: $kw,
                  name: (([$header | capture($re)] | first | .n) // "?"),
                  line: (.range.start.line + 1),
                  text: (
                      if $depth == "full" then .text
                      elif $depth == "signatures" then $header
                      else null
                      end
                  )
              })]
      ' 2>/dev/null)"

      present_ "$extracted" || continue
      all_json="$(echo "$all_json" "$extracted" | jq -s '.[0] + .[1]')"
    done

    # Top-level functions (column 0 only)
    local fn_raw="$(ast-grep run -l dart --kind function_signature "$file" --json 2>/dev/null)"
    if present_ "$fn_raw"; then
      local fn_extracted="$(echo "$fn_raw" | jq --arg depth "$depth" '
          [.[] | select(.range.start.column == 0) | {
              kind: "function",
              name: (.text | capture("(?<n>\\w+)\\s*\\(") | .n // "?"),
              line: (.range.start.line + 1),
              text: (
                  if $depth == "full" then .text
                  elif $depth == "signatures" then (.text | split("\n")[0])
                  else null
                  end
              )
          }]
      ' 2>/dev/null)"

      # fucking slop [[ -n "$fn_extracted" && "$fn_extracted" != "[]" ]] || true
      if present_ "$fn_extracted"; then
        all_json="$(echo "$all_json" "$fn_extracted" | jq -s '.[0] + .[1]')"
      fi
    fi

    # Top-level variables/constants (e.g. `final fooProvider = ...`,
    # `const x = ...`, `var y = ...`, `String? z;`). These are importable
    # library members, so they count as entities. One entity per declared
    # name (`final a = 1, b = 2;` yields a and b). The tree-sitter Dart
    # grammar puts each name in one of two shapes depending on modifiers:
    #   const/final:  top_level_variable_declaration > static_final_declaration_list > static_final_declaration
    #   var/typed/late: top_level_variable_declaration > initialized_identifier_list > initialized_identifier
    # Direct-parent chains only, so locals inside a top-level initializer
    # (e.g. a closure's `var`) are not picked up.
    local var_rule='id: top-level-variable
language: dart
rule:
  any:
    - kind: initialized_identifier
      inside:
        kind: initialized_identifier_list
        inside:
          kind: top_level_variable_declaration
    - kind: static_final_declaration
      inside:
        kind: static_final_declaration_list
        inside:
          kind: top_level_variable_declaration'

    local var_raw="$(ast-grep scan --inline-rules "$var_rule" "$file" --json 2>/dev/null)"
    if present_ "$var_raw"; then
      # Each matched node's text starts with the declared name.
      local var_extracted="$(echo "$var_raw" | jq --arg depth "$depth" '
          [.[] | {
              kind: "variable",
              name: (([.text | capture("^(?<n>\\w+)")] | first | .n) // "?"),
              line: (.range.start.line + 1),
              text: (
                  if $depth == "full" then .text
                  elif $depth == "signatures" then (.text | split("\n")[0])
                  else null
                  end
              )
          }]
      ' 2>/dev/null)"

      blank_ "$var_extracted" || all_json="$(echo "$all_json" "$var_extracted" | jq -s '.[0] + .[1]')"
    fi

    # Sort by line
    echo "$all_json" | jq 'sort_by(.line) | if .[0].text == null then [.[] | del(.text)] else . end'
}

# ─────────────────────────────────────────────────────────
# to_abs <file>
# ─────────────────────────────────────────────────────────
to_abs() { [[ "$1" == /* ]] && echo "$1" || echo "$REPO_ROOT/$1"; }

to_rel() { realpath --relative-to="$REPO_ROOT" "$(to_abs "$1")" 2>/dev/null; }

# ─────────────────────────────────────────────────────────
# parse_pubspec_assets
# Extracts declared asset paths from pubspec.yaml, one per line.
# Directory entries keep their trailing /.
# ─────────────────────────────────────────────────────────
parse_pubspec_assets() {
  local pubspec="$REPO_ROOT/pubspec.yaml"
  [[ -f "$pubspec" ]] || return
  grep -E '^\s+- assets/' "$pubspec" | sed -E 's/^\s+- //'
  grep -E '^\s+- asset: assets/' "$pubspec" | sed -E 's/^\s+- asset: //'
}

# ─────────────────────────────────────────────────────────
# is_asset_declared <path> <declared-entries>
# Returns 0 if the asset path is under a declared directory or
# matches a declared file exactly.
# ─────────────────────────────────────────────────────────
is_asset_declared() {
  # local path="$1" declared="$2"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" == */ && "$1" == "$entry"* ]] && return 0
    [[ "$entry" != "$1" ]] || return 0
  done <<< "$2"
  return 1
}

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
  [[ -n "$uri" ]] || die "usage: discover.sh resolve <uri> [--from <file>]"
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
    local file="" show_imports=false show_exports=false show_parts=false show_entities=false depth="names"
    while [ $# -gt 0 ]; do
        case "$1" in
            --imports)  show_imports=true ;;
            --exports)  show_exports=true ;;
            --parts)    show_parts=true ;;
            --entities)
                show_entities=true
                case "${2:-}" in name|names|signatures|full) depth="$2"; shift ;; esac
                ;;
            --depth)    shift; depth="$1" ;;
            *) file="$1" ;;
        esac
        shift
    done
    [ -n "$file" ] || die "usage: discover.sh inspect <file> [--imports] [--exports] [--parts] [--entities] [--depth names|signatures|full]"

    if ! $show_imports && ! $show_exports && ! $show_parts && ! $show_entities; then
        show_imports=true; show_exports=true; show_parts=true; show_entities=true
    fi

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    # Start building JSON
    local result="{\"file\":\"$repo_rel\""

    # Directive helper: outputs JSON array of {uri, resolved} objects
    emit_directive() {
        local directive="$1"
        local arr="["
        local first=true
        while IFS= read -r uri; do
            [ -n "$uri" ] || continue
            local resolved
            resolved="$(resolve_uri "$uri" "$repo_rel")"
            $first || arr+=","
            first=false
            arr+="{\"uri\":\"$uri\""
            [ -n "$resolved" ] && arr+=",\"resolved\":\"$resolved\""
            arr+="}"
        done < <(ast_grep_uris "$abs_file" "$directive")
        arr+="]"
        echo "$arr"
    }

    if $show_imports; then
        result+=",\"imports\":$(emit_directive import)"
    fi
    if $show_exports; then
        result+=",\"exports\":$(emit_directive export)"
    fi
    if $show_parts; then
        result+=",\"parts\":$(emit_directive part)"
    fi
    if $show_entities; then
        # --entities name: plain text, one name per line, no JSON wrapper
        if [[ "$depth" == "name" ]]; then
            ast_grep_entities "$abs_file" names | jq -r '.[].name'
            return
        fi
        result+=",\"entities\":$(ast_grep_entities "$abs_file" "$depth")"
    fi

    result+="}"
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

    # Search imports, following re-exports
    declare -A visited

    # search_file <abs-path> <via-chain-json-array>
    search_file() {
        local target_abs="$1" via_json="$2"
        [ -f "$target_abs" ] || return 1

        local target_real
        target_real="$(realpath "$target_abs")"
        [[ -v visited["$target_real"] ]] && return 1
        visited["$target_real"]=1

        local target_rel
        target_rel="$(realpath --relative-to="$REPO_ROOT" "$target_real")"

        # Check entities in this file
        local match
        match="$(ast_grep_entities "$target_real" names | jq -r --arg sym "$symbol" '.[] | select(.name == $sym) | "\(.kind)\t\(.line)"' | head -1)"
        if [ -n "$match" ]; then
            local kind="${match%%	*}"
            local line="${match#*	}"
            jq -n --arg sym "$symbol" --arg kind "$kind" --arg file "$target_rel" --argjson line "$line" --argjson via "$via_json" \
                '{symbol: $sym, kind: $kind, file: $file, line: $line, via: $via}'
            return 0
        fi

        # Follow re-exports
        while IFS= read -r uri; do
            [ -n "$uri" ] || continue
            local resolved
            resolved="$(resolve_uri "$uri" "$target_rel")"
            [ -n "$resolved" ] || continue
            local resolved_abs
            resolved_abs="$(realpath "$REPO_ROOT/$resolved" 2>/dev/null)"
            [ -f "$resolved_abs" ] || continue

            local new_via
            new_via="$(echo "$via_json" | jq --arg f "$target_rel" '. + [$f]')"
            if search_file "$resolved_abs" "$new_via"; then
                return 0
            fi
        done < <(ast_grep_uris "$target_real" "export")

        return 1
    }

    # Search each import
    while IFS= read -r uri; do
        [ -n "$uri" ] || continue
        local resolved
        resolved="$(resolve_uri "$uri" "$repo_rel")"
        [ -n "$resolved" ] || continue
        local resolved_abs="$REPO_ROOT/$resolved"
        if search_file "$resolved_abs" "[]"; then
            return 0
        fi
    done < <(ast_grep_uris "$abs_file" "import")

    # Search part files
    while IFS= read -r uri; do
        [ -n "$uri" ] || continue
        local resolved
        resolved="$(resolve_uri "$uri" "$repo_rel")"
        [ -n "$resolved" ] || continue
        local resolved_abs="$REPO_ROOT/$resolved"
        if search_file "$resolved_abs" "[\"(part)\"]"; then
            return 0
        fi
    done < <(ast_grep_uris "$abs_file" "part")

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
# its import chain upward toward main.dart. Each importer
# is tagged:
#   active — live importer that uses the target's entities
#   stale  — live importer that doesn't use any entities
#   zombie — dead importer (uses entities, but from a dead chain)
# The file-level "dead" is true when no importer is active.
#
# After resolving, cross-checks against is-live (BFS cache)
# and warns on disagreement.
# ─────────────────────────────────────────────────────────

# Recursive helper: determines if a file is reachable from main.dart
# by walking importers upward. Uses the importers cache for edges,
# but does NOT use the live cache — it traces independently.
# Results are memoized in _trace_live to avoid redundant walks.
# _trace_visited tracks the current recursion stack for cycle detection.
declare -A _trace_live
declare -A _trace_visited

_is_reachable() {
    local file="$1"

    # Base case: main.dart is the root of all liveness.
    [[ "$file" != "lib/main.dart" ]] || return 0

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
  local raw="$(ast-grep run -l dart -p "$pattern" "$LIB_DIR" --json 2>/dev/null)"
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
# Reports two separate sections:
#   "constant_refs"  — usages via a constant field (e.g. AppIcons.bubbles)
#   "direct_refs"    — hardcoded string literals matching the path
_usages_asset() {
  local asset_path="$1"
  local live_cache="$(get_live_cache 2>/dev/null)"

  # Step 1: find the constant field(s) whose value matches this asset path.
  # ast-grep pattern matches `static String <name> = "<path>";` declarations.
  local decl_raw="$(ast-grep run -l dart -p 'static String $FIELD = "'"$asset_path"'"' "$LIB_DIR" --json 2>/dev/null)"
  present_ "$decl_raw" || decl_raw="[]"

  local constant_results="[]"
  local constant_count=0

  if [[ "$decl_raw" != "[]" ]]; then
    local num_decls="$(echo "$decl_raw" | jq 'length')"

    local i=0
    local file_abs rel_file field_name class_name qualified raw filtered
    while ((i < num_decls)); do
      file_abs="$(echo "$decl_raw" | jq -r ".[$i].file")"
      rel_file="$(realpath --relative-to="$REPO_ROOT" "$file_abs")"
      field_name="$(echo "$decl_raw" | jq -r ".[$i].metaVariables.single.FIELD.text")"

      # Find the enclosing class name
      class_name="$(ast-grep run -l dart -p 'class $NAME { $$$BODY }' "$file_abs" --json 2>/dev/null \
          | jq -r '.[0].metaVariables.single.NAME.text // empty' 2>/dev/null)"
      [[ -n "$class_name" ]] || { ((++i)); continue; }

      qualified="${class_name}.${field_name}"
      echo "constant: ${qualified} (${rel_file})" >&2

      # Search for usages of this qualified field in live code
      raw="$(ast-grep run -l dart -p "$qualified" "$LIB_DIR" --json 2>/dev/null)"
      present_ "$raw" || { ((++i)); continue; }

      # Filter to live files, exclude the declaration file itself
      filtered="$(echo "$raw" | jq --slurpfile lf <(echo "$live_cache" | jq -R -s 'split("\n") | map(select(. != ""))') \
          --arg decl_file "$rel_file" \
          '[.[] | . as $m |
              ($m.file | ltrimstr("'"$REPO_ROOT/"'")) as $rel |
              select($rel != $decl_file) |
              select($lf[0] | index($rel)) |
              {file: $rel, line: (.range.start.line + 1), text: (.lines | split("\n")[0] | ltrimstr(" "))}
          ] | unique_by("\(.file):\(.line)") | sort_by(.file, .line)')"

      [[ "$filtered" != "[]" ]] || { ((++i)); continue; }
      constant_results="$(echo "$constant_results" "$filtered" | jq -s '.[0] + .[1]')"
      ((++i))
    done
    constant_count="$(echo "$constant_results" | jq 'length')"
  fi

  # Step 2: find direct string literal references to the asset path in live code.
  # ast-grep finds the exact string literal; jq filters out the declaration.
  local direct_results="[]"
  local direct_count=0

  local lit_raw="$(ast-grep run -l dart -p "\"$asset_path\"" "$LIB_DIR" --json 2>/dev/null)"
  present_ "$lit_raw" || lit_raw="[]"

  if [[ "$lit_raw" != "[]" ]]; then
    direct_results="$(echo "$lit_raw" | jq --slurpfile lf <(echo "$live_cache" | jq -R -s 'split("\n") | map(select(. != ""))') \
        '[.[] | . as $m |
            ($m.file | ltrimstr("'"$REPO_ROOT/"'")) as $rel |
            select($lf[0] | index($rel)) |
            select((.lines | test("static String")) | not) |
            {file: $rel, line: (.range.start.line + 1), text: (.lines | split("\n")[0] | ltrimstr(" "))}
        ] | unique_by("\(.file):\(.line)") | sort_by(.file, .line)')"
    direct_count="$(echo "$direct_results" | jq 'length')"
  fi

  # Output as two distinct sections
  jq -n --argjson constant "$constant_results" --argjson direct "$direct_results" \
      '{constant_refs: $constant, direct_refs: $direct}'

  echo "${constant_count} constant ref(s), ${direct_count} direct ref(s)" >&2
}


# ─────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────

# Check for --rebuild-cache before the subcommand.
if [[ "$1" == "--rebuild-cache" ]]; then
  build_all_caches

  # If no subcommand follows, the rebuild was the whole request.
  (($# > 1)) || exit 0
  # Drop the flag so the subcommand lands in $1.
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
        echo "commands:" >&2
        echo "  resolve <uri> [--from <file>]          Resolve import URI to repo-relative path" >&2
        echo "  inspect <file> [--imports] [--exports] [--parts] [--entities]" >&2
        echo "           [--depth names|signatures|full]" >&2
        echo "  definition <file> <symbol>             Find where a symbol used in <file> is defined" >&2
        echo "  live-files                             List all files reachable from main.dart" >&2
        echo "  dead-files [--rebuild]                 List all dead files (verified by recursive trace)" >&2
        echo "  is-live <file>                         Check if a file is reachable from main.dart" >&2
        echo "  importers <file>                       Find all files that import/export <file>" >&2
        echo "  trace <file>                           Trace usage and liveness of a file's import chain" >&2
        echo "  prune <file>                           Remove a file entry from caches without rebuilding" >&2
        echo "  usages <pattern> [--live-only]         Find all references to an ast-grep pattern" >&2
        echo "  usages --assets <asset-path>           Check if an asset is referenced in live code" >&2
        exit 1
esac
