#!/usr/bin/env bash
# discover core — language-agnostic structural codebase navigation.
#
# This file is sourced AFTER a language config (langs/*.sh) that defines
# LANG_ID, FILE_EXT, resolve_import, ast_grep_imports, ast_grep_entities,
# and the other required variables/functions.
#
# Usage: source the lang config first, then source this file, then call
# discover_main "$@".

# ─────────────────────────────────────────────────────────
# Bootstrap: verify lang config provided the required pieces
# ─────────────────────────────────────────────────────────
_require_var()  { [ -n "${!1}" ] || { echo "error: lang config must set $1" >&2; exit 1; }; }
_require_func() { declare -f "$1" >/dev/null || { echo "error: lang config must define $1()" >&2; exit 1; }; }

_require_var LANG_ID
_require_var FILE_EXT
_require_var SRC_DIR_REL
_require_func resolve_import
_require_func ast_grep_imports
_require_func ast_grep_entities

# ─────────────────────────────────────────────────────────
# Derived globals
# ─────────────────────────────────────────────────────────
SELF="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_DIR:-${SELF%\/*}}"
# Scripts live in <project>/bin/discover/ or <project>/scripts/discover/
REPO_ROOT="${REPO_ROOT:-$(realpath "$SCRIPT_DIR/../..")}"
SRC_DIR="$REPO_ROOT/$SRC_DIR_REL"
ENTRY_POINT="${ENTRY_POINT_REL:+$REPO_ROOT/$ENTRY_POINT_REL}"

CACHE_DIR="$REPO_ROOT/tmp"
CACHE_FILE="$CACHE_DIR/discover_live_cache.txt"
CACHE_FINGERPRINT="$CACHE_DIR/discover_live_cache.fingerprint"

die() { echo "error: $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────
# Optional function defaults
# ─────────────────────────────────────────────────────────
if ! declare -f import_directives >/dev/null 2>&1; then
    import_directives() { echo "import"; }
fi

if ! declare -f ast_grep_directive_imports >/dev/null 2>&1; then
    ast_grep_directive_imports() {
        local file="$1" directive="$2"
        if [ "$directive" = "import" ]; then
            ast_grep_imports "$file"
        fi
    }
fi

if ! declare -f inspect_sections >/dev/null 2>&1; then
    inspect_sections() { echo "imports entities"; }
fi

# ast-grep language IDs for directory scans (may differ from LANG_ID)
if ! declare -f ast_grep_languages >/dev/null 2>&1; then
    ast_grep_languages() { echo "$LANG_ID"; }
fi

if ! declare -f find_source_files >/dev/null 2>&1; then
    find_source_files() {
        local cmd="find \"$SRC_DIR\""
        # FILE_EXT may be space-separated (e.g. ".ts .tsx")
        local ext_count=0
        for ext in $FILE_EXT; do
            ((ext_count++))
        done
        if [ "$ext_count" -gt 1 ]; then
            cmd+=" \\("
            local first=true
            for ext in $FILE_EXT; do
                $first || cmd+=" -o"
                first=false
                cmd+=" -name \"*${ext}\""
            done
            cmd+=" \\)"
        else
            cmd+=" -name \"*${FILE_EXT}\""
        fi
        for glob in $FILE_EXCLUDE_GLOBS; do
            cmd+=" -not -name \"$glob\""
        done
        cmd+=" -print0"
        eval "$cmd" | sort -z
    }
fi

# ─────────────────────────────────────────────────────────
# Path helpers
# ─────────────────────────────────────────────────────────
to_abs() { [[ "$1" == "/"* ]] && echo "$1" || echo "$REPO_ROOT/$1"; }

to_rel() { realpath --relative-to="$REPO_ROOT" "$(to_abs "$1")" 2>/dev/null; }


# ─────────────────────────────────────────────────────────
# Live-files cache
# ─────────────────────────────────────────────────────────
compute_fingerprint() {
    find_source_files | md5sum | cut -d' ' -f1
}

cache_is_valid() {
    [ -f "$CACHE_FILE" ] && [ -f "$CACHE_FINGERPRINT" ] || return 1
    local stored current
    stored="$(cat "$CACHE_FINGERPRINT")"
    current="$(compute_fingerprint)"
    [ "$stored" = "$current" ]
}

write_cache() {
    mkdir -p "$CACHE_DIR"
    echo "$1" > "$CACHE_FILE"
    compute_fingerprint > "$CACHE_FINGERPRINT"
}

get_live_set() {
    local force="${1:-false}"
    if [ "$force" = "false" ] && cache_is_valid; then
        echo "cache: hit" >&2
        cat "$CACHE_FILE"
        return
    fi
    echo "cache: rebuilding" >&2
    local result
    result="$(build_live_files)"
    write_cache "$result"
    echo "$result"
}

# ─────────────────────────────────────────────────────────
# build_live_files — BFS from entry point
# ─────────────────────────────────────────────────────────
if ! declare -f build_live_files >/dev/null 2>&1; then
build_live_files() {
    [ -n "$ENTRY_POINT" ] && [ -f "$ENTRY_POINT" ] || die "entry point not found: ${ENTRY_POINT_REL:-<not configured>}"
    local entry_real
    entry_real="$(realpath "$ENTRY_POINT")"

    declare -A live
    local queue=()
    local idx=0

    live["$entry_real"]=1
    queue+=("$entry_real")

    while [ "$idx" -lt "${#queue[@]}" ]; do
        local current="${queue[$idx]}"
        ((idx++))
        [ -f "$current" ] || continue

        local current_rel
        current_rel="$(realpath --relative-to="$REPO_ROOT" "$current")"

        for directive in $(import_directives); do
            while IFS= read -r specifier; do
                [ -n "$specifier" ] || continue
                local resolved
                resolved="$(resolve_import "$specifier" "$current_rel")"
                [ -n "$resolved" ] || continue

                # resolved may be multiple lines (glob imports)
                while IFS= read -r resolved_file; do
                    [ -n "$resolved_file" ] || continue
                    local abs_resolved
                    abs_resolved="$(realpath "$REPO_ROOT/$resolved_file" 2>/dev/null)"
                    [ -f "$abs_resolved" ] || continue
                    if [ -z "${live[$abs_resolved]+_}" ]; then
                        live["$abs_resolved"]=1
                        queue+=("$abs_resolved")
                    fi
                done <<< "$resolved"
            done < <(ast_grep_directive_imports "$current" "$directive")
        done
    done

    for f in "${!live[@]}"; do
        realpath --relative-to="$REPO_ROOT" "$f"
    done | sort

    echo "${#live[@]} live files" >&2
}
fi

# ─────────────────────────────────────────────────────────
# Subcommand: resolve
# ─────────────────────────────────────────────────────────
cmd_resolve() {
    local specifier="" from_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) shift; from_file="$1" ;;
            *) specifier="$1" ;;
        esac
        shift
    done
    [ -n "$specifier" ] || die "usage: discover.sh resolve <import> [--from <file>]"
    local result
    result="$(resolve_import "$specifier" "$from_file")"
    [ -n "$result" ] && echo "$result"
}

# ─────────────────────────────────────────────────────────
# Subcommand: inspect
# ─────────────────────────────────────────────────────────
cmd_inspect() {
    local file="" depth="names"
    declare -A show_section
    local any_explicit=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --depth) shift; depth="$1" ;;
            --*)
                local section="${1#--}"
                show_section["$section"]=true
                any_explicit=true
                ;;
            *) file="$1" ;;
        esac
        shift
    done
    [ -n "$file" ] || die "usage: discover.sh inspect <file> [--<section>...] [--depth names|signatures|full]"

    if ! $any_explicit; then
        for s in $(inspect_sections); do
            show_section["$s"]=true
        done
    fi

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    local result="{\"file\":\"$repo_rel\""

    for section in $(inspect_sections); do
        [ "${show_section[$section]}" = "true" ] || continue

        if [ "$section" = "entities" ]; then
            result+=",\"entities\":$(ast_grep_entities "$abs_file" "$depth")"
        elif declare -f emit_inspect_section >/dev/null 2>&1 && \
             section_json="$(emit_inspect_section "$section" "$abs_file" "$repo_rel")"; then
            result+=",\"$section\":$section_json"
        else
            # Default: treat as a directive type and emit import-style JSON
            local arr="["
            local first=true
            while IFS= read -r specifier; do
                [ -n "$specifier" ] || continue
                local resolved
                resolved="$(resolve_import "$specifier" "$repo_rel")"
                $first || arr+=","
                first=false
                arr+="{\"specifier\":\"$specifier\""
                if [ -n "$resolved" ]; then
                    local line_count
                    line_count="$(echo "$resolved" | wc -l)"
                    if [ "$line_count" -gt 1 ]; then
                        local resolved_json
                        resolved_json="$(echo "$resolved" | jq -R -s 'split("\n") | map(select(. != ""))')"
                        arr+=",\"resolved\":$resolved_json"
                    else
                        arr+=",\"resolved\":\"$resolved\""
                    fi
                fi
                arr+="}"
            done < <(ast_grep_directive_imports "$abs_file" "${section%s}")
            arr+="]"
            result+=",\"$section\":$arr"
        fi
    done

    result+="}"
    echo "$result" | jq .
}

# ─────────────────────────────────────────────────────────
# Subcommand: live-files
# ─────────────────────────────────────────────────────────
cmd_live_files() {
    local force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --rebuild-cache) force=true ;;
            *) die "unknown flag: $1" ;;
        esac
        shift
    done
    get_live_set "$force"
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

    if get_live_set 2>/dev/null | grep -qxF "$repo_rel"; then
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
if ! declare -f cmd_definition >/dev/null 2>&1; then
cmd_definition() {
    local file="$1" symbol="$2"
    [ -n "$file" ] && [ -n "$symbol" ] || die "usage: discover.sh definition <file> <symbol>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    # Check local definitions first
    local local_match
    local_match="$(ast_grep_entities "$abs_file" names | jq -r --arg sym "$symbol" '.[] | select(.name == $sym) | "\(.kind)\t\(.line)"' | head -1)"
    if [ -n "$local_match" ]; then
        local kind="${local_match%%	*}"
        local line="${local_match#*	}"
        jq -n --arg sym "$symbol" --arg kind "$kind" --arg file "$repo_rel" --argjson line "$line" \
            '{symbol: $sym, kind: $kind, file: $file, line: $line, source: "local"}'
        return 0
    fi

    # BFS through import graph
    declare -A visited

    _search_file() {
        local target_abs="$1" via_json="$2"
        [ -f "$target_abs" ] || return 1

        local target_real
        target_real="$(realpath "$target_abs")"
        [ -z "${visited[$target_real]+_}" ] || return 1
        visited["$target_real"]=1

        local target_rel
        target_rel="$(realpath --relative-to="$REPO_ROOT" "$target_real")"

        local match
        match="$(ast_grep_entities "$target_real" names | jq -r --arg sym "$symbol" '.[] | select(.name == $sym) | "\(.kind)\t\(.line)"' | head -1)"
        if [ -n "$match" ]; then
            local kind="${match%%	*}"
            local line="${match#*	}"
            jq -n --arg sym "$symbol" --arg kind "$kind" --arg file "$target_rel" --argjson line "$line" --argjson via "$via_json" \
                '{symbol: $sym, kind: $kind, file: $file, line: $line, via: $via}'
            return 0
        fi

        # Follow re-exports / transitive imports
        for directive in $(import_directives); do
            [ "$directive" = "import" ] && continue
            while IFS= read -r specifier; do
                [ -n "$specifier" ] || continue
                local resolved
                resolved="$(resolve_import "$specifier" "$target_rel")"
                [ -n "$resolved" ] || continue

                while IFS= read -r resolved_file; do
                    [ -n "$resolved_file" ] || continue
                    local resolved_abs
                    resolved_abs="$(realpath "$REPO_ROOT/$resolved_file" 2>/dev/null)"
                    [ -f "$resolved_abs" ] || continue
                    local new_via
                    new_via="$(echo "$via_json" | jq --arg f "$target_rel" '. + [$f]')"
                    if _search_file "$resolved_abs" "$new_via"; then
                        return 0
                    fi
                done <<< "$resolved"
            done < <(ast_grep_directive_imports "$target_real" "$directive")
        done

        return 1
    }

    # Search each import from the source file
    for directive in $(import_directives); do
        while IFS= read -r specifier; do
            [ -n "$specifier" ] || continue
            local resolved
            resolved="$(resolve_import "$specifier" "$repo_rel")"
            [ -n "$resolved" ] || continue

            while IFS= read -r resolved_file; do
                [ -n "$resolved_file" ] || continue
                if _search_file "$REPO_ROOT/$resolved_file" "[]"; then
                    return 0
                fi
            done <<< "$resolved"
        done < <(ast_grep_directive_imports "$abs_file" "$directive")
    done

    jq -n --arg sym "$symbol" '{symbol: $sym, error: "not found in import graph"}'
    return 1
}
fi

# ─────────────────────────────────────────────────────────
# Subcommand: importers
# ─────────────────────────────────────────────────────────
if ! declare -f cmd_importers >/dev/null 2>&1; then
cmd_importers() {
    local file="$1"
    [ -n "$file" ] || die "usage: discover.sh importers <file>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local target_real
    target_real="$(realpath "$abs_file")"
    local repo_rel
    repo_rel="$(to_rel "$file")"

    local results="[]"

    while IFS= read -r -d '' src_file; do
        local src_real
        src_real="$(realpath "$src_file")"
        [ "$src_real" != "$target_real" ] || continue

        local src_rel
        src_rel="$(realpath --relative-to="$REPO_ROOT" "$src_real")"

        for directive in $(import_directives); do
            while IFS= read -r specifier; do
                [ -n "$specifier" ] || continue
                local resolved
                resolved="$(resolve_import "$specifier" "$src_rel")"
                [ -n "$resolved" ] || continue

                local match=false
                while IFS= read -r resolved_file; do
                    [ -n "$resolved_file" ] || continue
                    local resolved_real
                    resolved_real="$(realpath "$REPO_ROOT/$resolved_file" 2>/dev/null)"
                    if [ "$resolved_real" = "$target_real" ]; then
                        match=true
                        break
                    fi
                done <<< "$resolved"

                if $match; then
                    results="$(echo "$results" | jq --arg f "$src_rel" --arg d "$directive" --arg s "$specifier" \
                        '. + [{file: $f, directive: $d, specifier: $s}]')"
                fi
            done < <(ast_grep_directive_imports "$src_file" "$directive")
        done
    done < <(find_source_files)

    local count
    count="$(echo "$results" | jq 'length')"
    echo "$results" | jq 'sort_by(.file)'
    echo "$count importers found" >&2
}
fi

# ─────────────────────────────────────────────────────────
# Subcommand: usages
# ─────────────────────────────────────────────────────────
# --json suppresses the human-readable count trailer on stderr, so that a
# consumer capturing stdout and stderr as one stream (agent harnesses, CI logs)
# still receives parseable JSON. Without it the trailer is emitted on stderr as
# before, which is what a human at a terminal wants.
cmd_usages() {
    local pattern="" live_only=false json_mode=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --live-only) live_only=true ;;
            --json)      json_mode=true ;;
            *) pattern="$1" ;;
        esac
        shift
    done

    [ -n "$pattern" ] || die "usage: discover.sh usages <pattern> [--live-only] [--json]"

    local live_set=""
    if $live_only; then
        live_set="$(get_live_set 2>/dev/null)"
    fi

    local raw="[]"
    # Scan with each ast-grep language ID (e.g. typescript + tsx)
    for _lang in $(ast_grep_languages); do
        local _hits
        _hits="$(ast-grep run -l "$_lang" -p "$pattern" "$REPO_ROOT" --json 2>/dev/null)"
        if [ -n "$_hits" ] && [ "$_hits" != "[]" ]; then
            raw="$(echo "$raw" "$_hits" | jq -s '.[0] + .[1]')"
        fi
    done

    [ "$raw" != "[]" ] || { echo "[]"; $json_mode || echo "0 usages found" >&2; return; }

    local formatted
    if $live_only && [ -n "$live_set" ]; then
        formatted="$(echo "$raw" | jq --slurpfile lf <(echo "$live_set" | jq -R -s 'split("\n") | map(select(. != ""))') \
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

    echo "$formatted"
    if ! $json_mode; then
        local count
        count="$(echo "$formatted" | jq 'length')"
        echo "$count usages found" >&2
    fi
}

# ─────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────
discover_main() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    # Build section flags for help text
    local sections
    sections="$(inspect_sections)"
    local section_flags=""
    for s in $sections; do
        section_flags+=" [--${s}]"
    done

    case "$subcmd" in
        resolve)    cmd_resolve "$@" ;;
        inspect)    cmd_inspect "$@" ;;
        live-files) cmd_live_files "$@" ;;
        is-live)    cmd_is_live "$@" ;;
        definition) cmd_definition "$@" ;;
        importers)  cmd_importers "$@" ;;
        usages)     cmd_usages "$@" ;;
        modules)
            if declare -f cmd_modules >/dev/null 2>&1; then
                cmd_modules "$@"
            else
                die "modules: not supported for $LANG_ID (no module graph)"
            fi
            ;;
        module-of)
            if declare -f cmd_module_of >/dev/null 2>&1; then
                cmd_module_of "$@"
            else
                die "module-of: not supported for $LANG_ID (no module graph)"
            fi
            ;;
        trace)
            if declare -f cmd_trace >/dev/null 2>&1; then
                cmd_trace "$@"
            else
                die "trace: not supported for $LANG_ID"
            fi
            ;;
        *)
            echo "usage: discover.sh <command> [args]" >&2
            echo "" >&2
            echo "commands:" >&2
            echo "  resolve <import> [--from <file>]        Resolve import to repo-relative path" >&2
            echo "  inspect <file>${section_flags}" >&2
            echo "           [--depth names|signatures|full]" >&2
            echo "  definition <file> <symbol>               Find where a symbol is defined" >&2
            echo "  live-files [--rebuild-cache]              List all files reachable from entry point" >&2
            echo "  is-live <file>                           Check if a file is reachable" >&2
            echo "  importers <file>                         Find all files that import <file>" >&2
            echo "  usages <pattern> [--live-only] [--json]  Structural search for a pattern" >&2
            echo "                                           (--json: omit the stderr count trailer)" >&2
            if declare -f cmd_trace >/dev/null 2>&1; then
                echo "  trace <symbol> [--max-depth N] [--json]  Trace call chain upward from callsites" >&2
            fi
            if declare -f cmd_modules >/dev/null 2>&1; then
                echo "  modules [--json]                         List modules and dependencies" >&2
                echo "  module-of <file>                         Show which module owns a file" >&2
            fi
            exit 1
            ;;
    esac
}
