#!/usr/bin/env bash
# discover.sh — deterministic Dart codebase navigation using ast-grep.
#
# Subcommands:
#   resolve <uri> [--from <file>]
#   inspect <file> [--imports] [--exports] [--parts] [--entities] [--depth names|signatures|full]
#   definition <file> <symbol>
#   live-files
#   is-live <file>
#   importers <file>
#   usages <pattern> [--live-only]
#   usages --assets <asset-path>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(realpath "$SCRIPT_DIR/..")"
LIB_DIR="$REPO_ROOT/lib"
PACKAGE_NAME="malsi_app"

CACHE_DIR="$REPO_ROOT/tmp"
CACHE_FILE="$CACHE_DIR/discover_live_cache.txt"
CACHE_FINGERPRINT="$CACHE_DIR/discover_live_cache.fingerprint"

die() { echo "error: $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────
# live-files cache: fingerprint is a hash of the sorted
# dart file listing under lib/ (excludes generated files).
# Detects file additions and removals automatically.
# Import-content changes require --rebuild-cache.
# ─────────────────────────────────────────────────────────
compute_fingerprint() {
    find "$LIB_DIR" -name "*.dart" -not -name "*.g.dart" -not -name "*.freezed.dart" -print0 \
        | sort -z | md5sum | cut -d' ' -f1
}

cache_is_valid() {
    [ -f "$CACHE_FILE" ] && [ -f "$CACHE_FINGERPRINT" ] || return 1
    local stored current
    stored="$(cat "$CACHE_FINGERPRINT")"
    current="$(compute_fingerprint)"
    [ "$stored" = "$current" ]
}

write_cache() {
    local content="$1"
    mkdir -p "$CACHE_DIR"
    echo "$content" > "$CACHE_FILE"
    compute_fingerprint > "$CACHE_FINGERPRINT"
}

# Return cached live-files if valid, otherwise rebuild.
# Pass "true" as $1 to force rebuild.
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
# resolve_uri <uri> [<from-file-repo-relative>]
# Prints repo-relative path. Prints nothing for dart:/external packages.
# ─────────────────────────────────────────────────────────
resolve_uri() {
    local uri="$1" from_file="$2"
    case "$uri" in
        dart:*)
            return ;;
        package:${PACKAGE_NAME}/*)
            local rel="${uri#package:${PACKAGE_NAME}/}"
            local full="$LIB_DIR/$rel"
            [ -f "$full" ] && realpath --relative-to="$REPO_ROOT" "$full" 2>/dev/null
            ;;
        package:*)
            return ;;
        *)
            if [ -n "$from_file" ]; then
                local abs_from="$REPO_ROOT/$from_file"
                [ -f "$abs_from" ] || abs_from="$from_file"
                local dir
                dir="$(dirname "$(realpath "$abs_from" 2>/dev/null || echo "$abs_from")")"
                local resolved
                resolved="$(realpath -m "$dir/$uri" 2>/dev/null)"
                [ -f "$resolved" ] && realpath --relative-to="$REPO_ROOT" "$resolved" 2>/dev/null
            fi
            ;;
    esac
}

# ─────────────────────────────────────────────────────────
# ast_grep_uris <absolute-file-path> <directive>
# Extracts URIs for import/export/part using ast-grep. One per line.
# ─────────────────────────────────────────────────────────
ast_grep_uris() {
    local file="$1" directive="$2"
    ast-grep run -l dart -p "${directive} '\$URI';" "$file" --json 2>/dev/null \
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
            if [ "${pair%%:*}" = "$kind" ]; then
                keyword="${pair#*:}"
                break
            fi
        done

        local raw
        raw="$(ast-grep run -l dart --kind "$kind" "$file" --json 2>/dev/null)"
        [ -n "$raw" ] && [ "$raw" != "[]" ] || continue

        local extracted
        extracted="$(echo "$raw" | jq --arg kw "$keyword" --arg depth "$depth" '
            [.[] | {
                kind: $kw,
                name: (.text | split("\n")[0] | capture("(?:^|\\s)" + $kw + "\\s+(?<n>\\w+)") | .n // "?"),
                line: (.range.start.line + 1),
                text: (
                    if $depth == "full" then .text
                    elif $depth == "signatures" then (.text | split("\n")[0])
                    else null
                    end
                )
            }]
        ' 2>/dev/null)"

        [ -n "$extracted" ] && [ "$extracted" != "[]" ] || continue
        all_json="$(echo "$all_json" "$extracted" | jq -s '.[0] + .[1]')"
    done

    # Top-level functions (column 0 only)
    local fn_raw
    fn_raw="$(ast-grep run -l dart --kind function_signature "$file" --json 2>/dev/null)"
    if [ -n "$fn_raw" ] && [ "$fn_raw" != "[]" ]; then
        local fn_extracted
        fn_extracted="$(echo "$fn_raw" | jq --arg depth "$depth" '
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

        [ -n "$fn_extracted" ] && [ "$fn_extracted" != "[]" ] || true
        if [ -n "$fn_extracted" ] && [ "$fn_extracted" != "[]" ]; then
            all_json="$(echo "$all_json" "$fn_extracted" | jq -s '.[0] + .[1]')"
        fi
    fi

    # Sort by line
    echo "$all_json" | jq 'sort_by(.line) | if .[0].text == null then [.[] | del(.text)] else . end'
}

# ─────────────────────────────────────────────────────────
# to_abs <file>
# ─────────────────────────────────────────────────────────
to_abs() {
    local file="$1"
    if [[ "$file" = /* ]]; then
        echo "$file"
    else
        echo "$REPO_ROOT/$file"
    fi
}

to_rel() {
    realpath --relative-to="$REPO_ROOT" "$(to_abs "$1")" 2>/dev/null
}

# ─────────────────────────────────────────────────────────
# parse_pubspec_assets
# Extracts declared asset paths from pubspec.yaml, one per line.
# Directory entries keep their trailing /.
# ─────────────────────────────────────────────────────────
parse_pubspec_assets() {
    local pubspec="$REPO_ROOT/pubspec.yaml"
    [ -f "$pubspec" ] || return
    grep -E '^\s+- assets/' "$pubspec" | sed -E 's/^\s+- //'
    grep -E '^\s+- asset: assets/' "$pubspec" | sed -E 's/^\s+- asset: //'
}

# ─────────────────────────────────────────────────────────
# is_asset_declared <path> <declared-entries>
# Returns 0 if the asset path is under a declared directory or
# matches a declared file exactly.
# ─────────────────────────────────────────────────────────
is_asset_declared() {
    local path="$1" declared="$2"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if [[ "$entry" == */ ]] && [[ "$path" == "$entry"* ]]; then
            return 0
        fi
        if [ "$entry" = "$path" ]; then
            return 0
        fi
    done <<< "$declared"
    return 1
}

# ─────────────────────────────────────────────────────────
# Subcommand: resolve
# ─────────────────────────────────────────────────────────
cmd_resolve() {
    local uri="" from_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) shift; from_file="$1" ;;
            *) uri="$1" ;;
        esac
        shift
    done
    [ -n "$uri" ] || die "usage: discover.sh resolve <uri> [--from <file>]"
    local result
    result="$(resolve_uri "$uri" "$from_file")"
    [ -n "$result" ] && echo "$result"
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
            --entities) show_entities=true ;;
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
        result+=",\"entities\":$(ast_grep_entities "$abs_file" "$depth")"
    fi

    result+="}"
    echo "$result" | jq .
}

# ─────────────────────────────────────────────────────────
# build_live_files — uncached BFS from main.dart
# ─────────────────────────────────────────────────────────
build_live_files() {
    local main_dart="$LIB_DIR/main.dart"
    [ -f "$main_dart" ] || die "lib/main.dart not found"
    main_dart="$(realpath "$main_dart")"

    declare -A live
    local queue=()
    local idx=0

    live["$main_dart"]=1
    queue+=("$main_dart")

    while [ "$idx" -lt "${#queue[@]}" ]; do
        local current="${queue[$idx]}"
        ((idx++))
        [ -f "$current" ] || continue

        local current_rel
        current_rel="$(realpath --relative-to="$REPO_ROOT" "$current")"

        for directive in import export part; do
            while IFS= read -r uri; do
                [ -n "$uri" ] || continue
                local resolved
                resolved="$(resolve_uri "$uri" "$current_rel")"
                [ -n "$resolved" ] || continue
                local abs_resolved
                abs_resolved="$(realpath "$REPO_ROOT/$resolved" 2>/dev/null)"
                [ -f "$abs_resolved" ] || continue
                if [ -z "${live[$abs_resolved]+_}" ]; then
                    live["$abs_resolved"]=1
                    queue+=("$abs_resolved")
                fi
            done < <(ast_grep_uris "$current" "$directive")
        done
    done

    for f in "${!live[@]}"; do
        realpath --relative-to="$REPO_ROOT" "$f"
    done | sort

    echo "${#live[@]} live files" >&2
}

# ─────────────────────────────────────────────────────────
# Subcommand: live-files [--rebuild-cache]
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
        [ -z "${visited[$target_real]+_}" ] || return 1
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
    local file="$1"
    [ -n "$file" ] || die "usage: discover.sh importers <file>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local target_real
    target_real="$(realpath "$abs_file")"
    local repo_rel
    repo_rel="$(to_rel "$file")"

    local package_uri=""
    if [[ "$repo_rel" == lib/* ]]; then
        package_uri="package:${PACKAGE_NAME}/${repo_rel#lib/}"
    fi

    local results="[]"

    while IFS= read -r -d '' dart_file; do
        local dart_real
        dart_real="$(realpath "$dart_file")"
        [ "$dart_real" != "$target_real" ] || continue

        local dart_rel
        dart_rel="$(realpath --relative-to="$REPO_ROOT" "$dart_real")"

        for directive in import export; do
            while IFS= read -r uri; do
                [ -n "$uri" ] || continue
                local match=false

                # Check package: form
                if [ -n "$package_uri" ] && [ "$uri" = "$package_uri" ]; then
                    match=true
                fi

                # Check relative form
                if ! $match && [[ "$uri" != package:* ]] && [[ "$uri" != dart:* ]]; then
                    local resolved
                    resolved="$(resolve_uri "$uri" "$dart_rel")"
                    if [ -n "$resolved" ]; then
                        local resolved_real
                        resolved_real="$(realpath "$REPO_ROOT/$resolved" 2>/dev/null)"
                        [ "$resolved_real" = "$target_real" ] && match=true
                    fi
                fi

                if $match; then
                    results="$(echo "$results" | jq --arg f "$dart_rel" --arg d "$directive" --arg u "$uri" \
                        '. + [{file: $f, directive: $d, uri: $u}]')"
                fi
            done < <(ast_grep_uris "$dart_file" "$directive")
        done
    done < <(find "$LIB_DIR" -name "*.dart" -not -name "*.g.dart" -not -name "*.freezed.dart" -print0 | sort -z)

    local count
    count="$(echo "$results" | jq 'length')"
    echo "$results" | jq 'sort_by(.file)'
    echo "$count importers found" >&2
}

# ─────────────────────────────────────────────────────────
# Subcommand: usages
# ─────────────────────────────────────────────────────────
cmd_usages() {
    local pattern="" live_only=false asset_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --live-only) live_only=true ;;
            --assets) shift; asset_path="${1:-}"; [ -n "$asset_path" ] || die "--assets requires an asset path argument" ;;
            *) pattern="$1" ;;
        esac
        shift
    done

    # --assets mode: find what references a specific asset path
    if [ -n "$asset_path" ]; then
        _usages_asset "$asset_path"
        return
    fi

    [ -n "$pattern" ] || die "usage: discover.sh usages <pattern> [--live-only]\n       discover.sh usages --assets <asset-path>"

    local live_set=""
    if $live_only; then
        live_set="$(get_live_set 2>/dev/null)"
    fi

    # Structural pass: ast-grep with the caller's pattern
    local raw
    raw="$(ast-grep run -l dart -p "$pattern" "$LIB_DIR" --json 2>/dev/null)"
    [ -n "$raw" ] && [ "$raw" != "[]" ] || raw="[]"

    [ "$raw" != "[]" ] || { echo "[]"; echo "0 usages found" >&2; return; }

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
    local count
    count="$(echo "$formatted" | jq 'length')"
    echo "$count usages found" >&2
}

# --assets helper: given an asset path, find all live references to it.
# Reports two separate sections:
#   "constant_refs"  — usages via a constant field (e.g. AppIcons.bubbles)
#   "direct_refs"    — hardcoded string literals matching the path
_usages_asset() {
    local asset_path="$1"
    local live_set
    live_set="$(get_live_set 2>/dev/null)"

    # Step 1: find the constant field(s) whose value matches this asset path.
    # ast-grep pattern matches `static String <name> = "<path>";` declarations.
    local decl_raw
    decl_raw="$(ast-grep run -l dart -p 'static String $FIELD = "'"$asset_path"'";' "$LIB_DIR" --json 2>/dev/null)"
    [ -n "$decl_raw" ] && [ "$decl_raw" != "[]" ] || decl_raw="[]"

    local constant_results="[]"
    local constant_count=0

    if [ "$decl_raw" != "[]" ]; then
        local num_decls
        num_decls="$(echo "$decl_raw" | jq 'length')"

        local i=0
        while [ "$i" -lt "$num_decls" ]; do
            local file_abs rel_file field_name class_name
            file_abs="$(echo "$decl_raw" | jq -r ".[$i].file")"
            rel_file="$(realpath --relative-to="$REPO_ROOT" "$file_abs")"
            field_name="$(echo "$decl_raw" | jq -r ".[$i].metaVariables.single.FIELD.text")"

            # Find the enclosing class name
            class_name="$(ast-grep run -l dart -p 'class $NAME { $$$BODY }' "$file_abs" --json 2>/dev/null \
                | jq -r '.[0].metaVariables.single.NAME.text // empty' 2>/dev/null)"
            [ -n "$class_name" ] || { i=$((i + 1)); continue; }

            local qualified="${class_name}.${field_name}"
            echo "constant: ${qualified} (${rel_file})" >&2

            # Search for usages of this qualified field in live code
            local raw
            raw="$(ast-grep run -l dart -p "$qualified" "$LIB_DIR" --json 2>/dev/null)"
            [ -n "$raw" ] && [ "$raw" != "[]" ] || { i=$((i + 1)); continue; }

            # Filter to live files, exclude the declaration file itself
            local filtered
            filtered="$(echo "$raw" | jq --slurpfile lf <(echo "$live_set" | jq -R -s 'split("\n") | map(select(. != ""))') \
                --arg decl_file "$rel_file" \
                '[.[] | . as $m |
                    ($m.file | ltrimstr("'"$REPO_ROOT/"'")) as $rel |
                    select($rel != $decl_file) |
                    select($lf[0] | index($rel)) |
                    {file: $rel, line: (.range.start.line + 1), text: (.lines | split("\n")[0] | ltrimstr(" "))}
                ] | unique_by("\(.file):\(.line)") | sort_by(.file, .line)')"

            [ "$filtered" != "[]" ] || { i=$((i + 1)); continue; }
            constant_results="$(echo "$constant_results" "$filtered" | jq -s '.[0] + .[1]')"
            i=$((i + 1))
        done
        constant_count="$(echo "$constant_results" | jq 'length')"
    fi

    # Step 2: find direct string literal references to the asset path in live code.
    # ast-grep finds the exact string literal; jq filters out the declaration.
    local direct_results="[]"
    local direct_count=0

    local lit_raw
    lit_raw="$(ast-grep run -l dart -p "\"$asset_path\"" "$LIB_DIR" --json 2>/dev/null)"
    [ -n "$lit_raw" ] && [ "$lit_raw" != "[]" ] || lit_raw="[]"

    if [ "$lit_raw" != "[]" ]; then
        direct_results="$(echo "$lit_raw" | jq --slurpfile lf <(echo "$live_set" | jq -R -s 'split("\n") | map(select(. != ""))') \
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

subcmd="${1:-}"
shift 2>/dev/null || true

case "$subcmd" in
    resolve)    cmd_resolve "$@" ;;
    inspect)    cmd_inspect "$@" ;;
    live-files) cmd_live_files "$@" ;;
    is-live)    cmd_is_live "$@" ;;
    definition) cmd_definition "$@" ;;
    importers)  cmd_importers "$@" ;;
    usages)     cmd_usages "$@" ;;
    *)
        echo "usage: discover.sh <command> [args]" >&2
        echo "" >&2
        echo "commands:" >&2
        echo "  resolve <uri> [--from <file>]         Resolve import URI to repo-relative path" >&2
        echo "  inspect <file> [--imports] [--exports] [--parts] [--entities]" >&2
        echo "           [--depth names|signatures|full]" >&2
        echo "  definition <file> <symbol>             Find where a symbol used in <file> is defined" >&2
        echo "  live-files [--rebuild-cache]            List all files reachable from main.dart" >&2
        echo "  is-live <file>                         Check if a file is reachable from main.dart" >&2
        echo "  importers <file>                       Find all files that import/export <file>" >&2
        echo "  usages <pattern> [--live-only]             Find all references to an ast-grep pattern" >&2
        echo "  usages --assets <asset-path>               Check if an asset is referenced in live code" >&2
        exit 1
        ;;
esac
