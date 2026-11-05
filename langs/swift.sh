#!/usr/bin/env bash
# Language config: Swift
#
# Swift's compilation model is module-based, not file-based. All .swift files
# in a target/module see each other implicitly — there are no intra-module
# imports. This config implements two-level navigation:
#   1. Module level: parse Package.swift or .pbxproj for the dependency DAG
#   2. File level: within a module, all files are peers (no import resolution)
#
# Supports three project shapes:
#   - SPM (Package.swift exists): full module graph via `swift package dump-package`
#   - Xcode multi-target (.pbxproj, no Package.swift): lightweight target parsing
#   - Single-target fallback: all files in SRC_DIR are one implicit module

LANG_ID="swift"
FILE_EXT=".swift"
FILE_EXCLUDE_GLOBS=""
SRC_DIR_REL="Sources"
ENTRY_POINT_REL=""  # set per-project
PACKAGE_NAME=""
CTX7_LIBRARIES="swift"
LSP_PLUGIN="swift-lsp@claude-plugins-official"
LSP_BINARY="sourcekit-lsp"
LSP_INSTALL=""  # bundled with Swift toolchain

# ─────────────────────────────────────────────────────────
# Skill metadata — used by `discover init` to fill SKILL.md.template
# ─────────────────────────────────────────────────────────
SKILL_LANG_NAME="Swift"
SKILL_IMPORT_VERB="import"
SKILL_MOTIVATION="Swift's module-based imports mean all files in a target see each other — grep can't tell you which target owns a file or whether an \`import MyModule\` resolves locally. discover.sh maps the module graph and extracts entities structurally."
SKILL_RESOLVE_EXAMPLE_1="MyModule"
SKILL_RESOLVE_RESULT_1="Sources/MyModule/MyModule.swift"
SKILL_RESOLVE_EXAMPLE_2="NetworkKit"
SKILL_RESOLVE_FROM_2="Sources/App/AppDelegate.swift"
SKILL_RESOLVE_RESULT_2="Sources/NetworkKit/Client.swift"
SKILL_EXAMPLE_FILE="Sources/App/AppDelegate.swift"
SKILL_EXAMPLE_SYMBOL="AppDelegate"
SKILL_USAGE_EXAMPLE_1='URLSession.shared.$METHOD($$$ARGS)'
SKILL_USAGE_EXAMPLE_2='guard let $VAR = $EXPR else { $$$BODY }'

# Swift-specific SKILL.md overrides.
# Swift has no file-level imports within a target — all files in a module see
# each other implicitly. The generic import-graph descriptions are misleading.
SKILL_LIVE_FILES_DESC="Lists all .swift files in modules reachable from the app target. In Swift, all files within a module/target see each other implicitly — there are no file-level imports to trace. For single-target projects, every file is live."
SKILL_IS_LIVE_DESC="Check whether a file belongs to a module reachable from the app target. For single-target projects this is always true — use \`usages\` and call-chain tracing instead to detect dead code."
SKILL_USAGES_LIVE_DESC="\`--live-only\` filters to files in reachable modules. For single-target projects this has no effect (all files are in scope). To verify callsites are actually active, use \`trace\` instead — it follows the call chain upward through containing functions automatically."
SKILL_EXTRA_SUBCOMMANDS='### trace

Trace the call chain upward from each callsite of a symbol. For each place the symbol is called, identifies the containing function, finds callers of *that* function, and repeats — building a chain that shows whether the callsite is reachable or dead code. This is the correct way to verify reachability in Swift (where `--live-only` only checks module membership).

```bash
bash {{SCRIPT_PATH}} trace getDrinksBatch
bash {{SCRIPT_PATH}} trace resolveRelationships --max-depth 5
```

Output per callsite includes: the file/line, the containing function (qualified as `Type.method`), the caller chain, and a status (`end` = chain terminated, `cycle` = recursion detected, `max_depth` = limit hit). A chain ending with "no callers found" means either a framework entry point or dead code — inspect the top of the chain to decide which.'
SKILL_RULES='- Use `usages` instead of grep for structural search — it matches AST nodes, not text.
- Use `trace` to verify whether callsites are reachable. It follows the call chain upward from each callsite, identifying the containing function at each level, until it reaches an entry point or dead-ends. A chain ending with "no callers found" means either a framework entry point (the system calls it) or dead code.
- Use `definition` before assuming which file a symbol comes from — Swift has no file-level namespacing, so the same name can exist in multiple modules.
- Use `modules` and `module-of` to understand the target/module graph.
- `--live-only` only filters by module membership, NOT by call-graph reachability. For single-target projects it filters nothing. Use `trace` instead.
- Never claim a callsite is "verified live" just because `usages --live-only` returned it — that only means the file is in a reachable module. Use `trace` for actual verification.'

# ─────────────────────────────────────────────────────────
# Module graph data (populated lazily by _swift_load_modules)
# ─────────────────────────────────────────────────────────
_SWIFT_MODULES_LOADED=false
unset _SWIFT_MODULE_DIRS _SWIFT_MODULE_DEPS _SWIFT_MODULE_TYPES
declare -A _SWIFT_MODULE_DIRS=()       # module_name → source_dir (relative)
declare -A _SWIFT_MODULE_DEPS=()       # module_name → space-separated dep names
declare -A _SWIFT_MODULE_TYPES=()      # module_name → executable|library|test
_SWIFT_PROJECT_TYPE=""                  # spm|xcode|single

# ─────────────────────────────────────────────────────────
# Module graph loading — detects project type and populates module maps
# ─────────────────────────────────────────────────────────
_swift_load_modules() {
    $_SWIFT_MODULES_LOADED && return
    _SWIFT_MODULES_LOADED=true

    if [ -f "$REPO_ROOT/Package.swift" ]; then
        _swift_load_spm
    elif compgen -G "$REPO_ROOT"/*.xcodeproj/project.pbxproj >/dev/null 2>&1; then
        _swift_load_xcode
    else
        _swift_load_single_target
    fi
}

# P1: Parse Package.swift via swift package dump-package
_swift_load_spm() {
    _SWIFT_PROJECT_TYPE="spm"
    local manifest
    manifest="$(cd "$REPO_ROOT" && swift package dump-package 2>/dev/null)"
    [ -n "$manifest" ] || { _swift_load_single_target; return; }

    local target_count
    target_count="$(echo "$manifest" | jq '.targets | length' 2>/dev/null)"
    [ "${target_count:-0}" -gt 0 ] || { _swift_load_single_target; return; }

    # Parse each target
    local i=0
    while [ "$i" -lt "$target_count" ]; do
        local name type path deps
        name="$(echo "$manifest" | jq -r ".targets[$i].name")"
        type="$(echo "$manifest" | jq -r ".targets[$i].type")"
        path="$(echo "$manifest" | jq -r ".targets[$i].path // empty")"

        # Default path convention
        if [ -z "$path" ]; then
            case "$type" in
                test) path="Tests/$name" ;;
                *)    path="Sources/$name" ;;
            esac
        fi

        # Map type to our categories
        case "$type" in
            executable) _SWIFT_MODULE_TYPES["$name"]="executable" ;;
            test)       _SWIFT_MODULE_TYPES["$name"]="test" ;;
            *)          _SWIFT_MODULE_TYPES["$name"]="library" ;;
        esac

        _SWIFT_MODULE_DIRS["$name"]="$path"

        # Extract dependencies (target deps only, not external packages)
        deps="$(echo "$manifest" | jq -r "
            [.targets[$i].dependencies[]? |
                (.byName[0] // .target[0] // .product[0] // empty)
            ] | join(\" \")
        " 2>/dev/null)"
        _SWIFT_MODULE_DEPS["$name"]="${deps:-}"

        ((i++))
    done
}

# P3: Lightweight .pbxproj parsing for Xcode-only projects
_swift_load_xcode() {
    _SWIFT_PROJECT_TYPE="xcode"
    local pbxproj
    pbxproj="$(compgen -G "$REPO_ROOT"/*.xcodeproj/project.pbxproj | head -1)"
    [ -f "$pbxproj" ] || { _swift_load_single_target; return; }

    # Extract PBXNativeTarget entries: name and productType
    # Format in pbxproj: <ID> /* <name> */ = {isa = PBXNativeTarget; ... productType = "..."; ...};
    local in_targets=false
    local current_name="" current_type=""

    while IFS= read -r line; do
        # Detect target names from comment-annotated references
        if [[ "$line" =~ isa\ =\ PBXNativeTarget ]]; then
            in_targets=true
        fi
        if $in_targets; then
            if [[ "$line" =~ name\ =\ \"?([^\";\}]+)\"? ]]; then
                current_name="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ productType\ =\ \"([^\"]+)\" ]]; then
                current_type="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" == *"};"* ]] && [ -n "$current_name" ]; then
                # Determine module type from productType
                local mod_type="library"
                case "$current_type" in
                    *application*)         mod_type="executable" ;;
                    *app-extension*|*widget*) mod_type="extension" ;;
                    *framework*)           mod_type="library" ;;
                    *unit-test*|*ui-test*) mod_type="test" ;;
                esac

                _SWIFT_MODULE_TYPES["$current_name"]="$mod_type"

                # Infer source directory — common Xcode conventions
                local src_dir=""
                for candidate in "$current_name" "${current_name// /}" "${current_name}Sources"; do
                    if [ -d "$REPO_ROOT/$candidate" ]; then
                        src_dir="$candidate"
                        break
                    fi
                done
                [ -n "$src_dir" ] && _SWIFT_MODULE_DIRS["$current_name"]="$src_dir"

                current_name=""
                current_type=""
                in_targets=false
            fi
        fi
    done < "$pbxproj"

    # Parse target dependencies from PBXTargetDependency sections
    while IFS= read -r line; do
        if [[ "$line" =~ target\ =\ [A-F0-9]+\ /\*\ ([^*]+)\ \*/ ]]; then
            local dep_name="${BASH_REMATCH[1]}"
            # Find which target owns this dependency (look backwards for the parent)
            for mod in "${!_SWIFT_MODULE_TYPES[@]}"; do
                if [ -n "${_SWIFT_MODULE_DIRS[$mod]+_}" ]; then
                    _SWIFT_MODULE_DEPS["$mod"]="${_SWIFT_MODULE_DEPS[$mod]:-} $dep_name"
                fi
            done
        fi
    done < <(grep -A2 "isa = PBXTargetDependency" "$pbxproj" 2>/dev/null)

    # If no modules found, fall back to single-target
    [ ${#_SWIFT_MODULE_DIRS[@]} -gt 0 ] || _swift_load_single_target
}

# P0: Single-target fallback — all files in SRC_DIR are one module
_swift_load_single_target() {
    _SWIFT_PROJECT_TYPE="single"
    local module_name="${PACKAGE_NAME:-app}"
    _SWIFT_MODULE_DIRS["$module_name"]="$SRC_DIR_REL"
    _SWIFT_MODULE_DEPS["$module_name"]=""
    _SWIFT_MODULE_TYPES["$module_name"]="executable"
}

# ─────────────────────────────────────────────────────────
# Module graph queries
# ─────────────────────────────────────────────────────────

# Returns the module name that owns a file (by its relative path)
_swift_module_of_file() {
    local file_rel="$1"
    _swift_load_modules
    for mod in "${!_SWIFT_MODULE_DIRS[@]}"; do
        local dir="${_SWIFT_MODULE_DIRS[$mod]}"
        if [[ "$file_rel" == "$dir"/* ]] || [[ "$file_rel" == "$dir" ]]; then
            echo "$mod"
            return
        fi
    done
}

# Returns all .swift files in a module's source directory
_swift_module_files() {
    local module_name="$1"
    _swift_load_modules
    local dir="${_SWIFT_MODULE_DIRS[$module_name]}"
    [ -n "$dir" ] || return
    find "$REPO_ROOT/$dir" -name "*.swift" -type f 2>/dev/null | sort | while IFS= read -r f; do
        realpath --relative-to="$REPO_ROOT" "$f" 2>/dev/null
    done
}

# Returns all modules reachable from a starting module (transitive deps)
_swift_reachable_modules() {
    local start="$1"
    _swift_load_modules
    declare -A visited
    local queue=("$start") idx=0
    visited["$start"]=1
    while [ "$idx" -lt "${#queue[@]}" ]; do
        local current="${queue[$idx]}"
        ((idx++))
        for dep in ${_SWIFT_MODULE_DEPS[$current]:-}; do
            if [ -z "${visited[$dep]+_}" ] && [ -n "${_SWIFT_MODULE_DIRS[$dep]+_}" ]; then
                visited["$dep"]=1
                queue+=("$dep")
            fi
        done
    done
    printf '%s\n' "${!visited[@]}"
}

# Returns the app/executable module (entry target for live-files)
_swift_app_module() {
    _swift_load_modules
    for mod in "${!_SWIFT_MODULE_TYPES[@]}"; do
        if [ "${_SWIFT_MODULE_TYPES[$mod]}" = "executable" ]; then
            echo "$mod"
            return
        fi
    done
    # Fallback: first module
    printf '%s\n' "${!_SWIFT_MODULE_DIRS[@]}" | head -1
}

# ─────────────────────────────────────────────────────────
# Swift import resolution
#
# `import Foundation`   → external module, unresolvable
# `import MyModule`     → local module if it exists in the module graph
# `@testable import X`  → same as above
#
# Within a module/target, all .swift files see each other — no per-file imports.
# ─────────────────────────────────────────────────────────
resolve_import() {
    local specifier="$1" from_file="$2"

    # Strip @testable prefix
    specifier="${specifier#@testable }"

    _swift_load_modules

    # Check if it's a local module in the graph
    if [ -n "${_SWIFT_MODULE_DIRS[$specifier]+_}" ]; then
        _swift_module_files "$specifier"
        return
    fi

    # Legacy fallback: check for Sources/<name>/ directory
    local module_dir="$REPO_ROOT/Sources/$specifier"
    if [ -d "$module_dir" ]; then
        find "$module_dir" -name "*.swift" -print0 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
            realpath --relative-to="$REPO_ROOT" "$f" 2>/dev/null
        done
        return
    fi

    # External module — no resolution
}

# ─────────────────────────────────────────────────────────
# ast-grep pattern for Swift imports
# ─────────────────────────────────────────────────────────
ast_grep_imports() {
    local file="$1"
    ast-grep run -l swift -p 'import $MODULE' "$file" --json 2>/dev/null \
        | jq -r '.[].metaVariables.single.MODULE.text' 2>/dev/null
}

# ─────────────────────────────────────────────────────────
# P0: Override build_live_files — module-aware
#
# All files in all reachable modules from the app target are live.
# For single-target: all files in SRC_DIR are live.
# ─────────────────────────────────────────────────────────
build_live_files() {
    _swift_load_modules

    local app_mod
    app_mod="$(_swift_app_module)"

    local count=0
    while IFS= read -r mod; do
        [ -n "$mod" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            echo "$f"
            ((count++))
        done < <(_swift_module_files "$mod")
    done < <(_swift_reachable_modules "$app_mod")

    echo "$count live files" >&2
}

# ─────────────────────────────────────────────────────────
# P0+P2: Override cmd_definition — module-aware symbol search
#
# Search order:
#   1. Local file
#   2. All other files in the same module (intra-module peers)
#   3. Public/open symbols in imported modules (cross-module)
#   4. Transitive public re-exports (@_exported import)
# ─────────────────────────────────────────────────────────
cmd_definition() {
    local file="$1" symbol="$2"
    [ -n "$file" ] && [ -n "$symbol" ] || die "usage: discover.sh definition <file> <symbol>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    # Step 1: check local file
    local local_match
    local_match="$(ast_grep_entities "$abs_file" names | jq -r --arg sym "$symbol" '.[] | select(.name == $sym) | "\(.kind)\t\(.line)"' | head -1)"
    if [ -n "$local_match" ]; then
        local kind="${local_match%%	*}"
        local line="${local_match#*	}"
        jq -n --arg sym "$symbol" --arg kind "$kind" --arg file "$repo_rel" --argjson line "$line" \
            '{symbol: $sym, kind: $kind, file: $file, line: $line, scope: "local"}'
        return 0
    fi

    _swift_load_modules
    local my_module
    my_module="$(_swift_module_of_file "$repo_rel")"

    # Step 2: scan all other files in the same module
    if [ -n "$my_module" ]; then
        local found
        found="$(_swift_search_module_for_symbol "$my_module" "$symbol" "$abs_file")"
        if [ -n "$found" ]; then
            echo "$found" | jq --arg scope "same-module" '. + {scope: $scope}'
            return 0
        fi
    fi

    # Step 3: scan imported modules (public/open only)
    local imports
    imports="$(ast_grep_imports "$abs_file")"
    while IFS= read -r imported_mod; do
        [ -n "$imported_mod" ] || continue
        # Only search local modules
        [ -n "${_SWIFT_MODULE_DIRS[$imported_mod]+_}" ] || continue
        local found
        found="$(_swift_search_module_for_symbol "$imported_mod" "$symbol" "" "public")"
        if [ -n "$found" ]; then
            echo "$found" | jq --arg scope "imported-module" --arg mod "$imported_mod" '. + {scope: $scope, module: $mod}'
            return 0
        fi
    done <<< "$imports"

    # Step 4: transitive deps of the owning module
    if [ -n "$my_module" ]; then
        while IFS= read -r dep_mod; do
            [ -n "$dep_mod" ] || continue
            [ "$dep_mod" != "$my_module" ] || continue
            local found
            found="$(_swift_search_module_for_symbol "$dep_mod" "$symbol" "" "public")"
            if [ -n "$found" ]; then
                echo "$found" | jq --arg scope "transitive-dep" --arg mod "$dep_mod" '. + {scope: $scope, module: $mod}'
                return 0
            fi
        done < <(_swift_reachable_modules "$my_module")
    fi

    jq -n --arg sym "$symbol" '{symbol: $sym, error: "not found in module graph"}'
    return 1
}

# Search a module for a symbol definition, optionally filtering by access control
_swift_search_module_for_symbol() {
    local module_name="$1" symbol="$2" exclude_file="$3" access_filter="${4:-}"
    local exclude_real=""
    [ -z "$exclude_file" ] || exclude_real="$(realpath "$exclude_file" 2>/dev/null)"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        local abs_f="$REPO_ROOT/$f"
        if [ -n "$exclude_real" ] && [ "$(realpath "$abs_f" 2>/dev/null)" = "$exclude_real" ]; then
            continue
        fi

        local match
        match="$(ast_grep_entities "$abs_f" signatures | jq -r --arg sym "$symbol" '.[] | select(.name == $sym) | "\(.kind)\t\(.line)\t\(.text // "")"' | head -1)"
        if [ -n "$match" ]; then
            local kind line text
            kind="$(echo "$match" | cut -f1)"
            line="$(echo "$match" | cut -f2)"
            text="$(echo "$match" | cut -f3)"

            # P2: access control filtering for cross-module lookups
            if [ -n "$access_filter" ] && [ "$access_filter" = "public" ]; then
                # Check if the declaration is public or open
                if [[ "$text" != *public* ]] && [[ "$text" != *open* ]]; then
                    continue
                fi
            fi

            jq -n --arg sym "$symbol" --arg kind "$kind" --arg file "$f" --argjson line "$line" \
                '{symbol: $sym, kind: $kind, file: $file, line: $line}'
            return 0
        fi
    done < <(_swift_module_files "$module_name")
    return 1
}

# ─────────────────────────────────────────────────────────
# P2: Override cmd_importers — module-aware
#
# Two modes:
#   Default: which modules depend on the module containing <file>?
#   --symbol <name>: which files reference a specific symbol from <file>?
# ─────────────────────────────────────────────────────────
cmd_importers() {
    local file="" symbol_filter=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --symbol) shift; symbol_filter="$1" ;;
            *) file="$1" ;;
        esac
        shift
    done
    [ -n "$file" ] || die "usage: discover.sh importers <file> [--symbol <name>]"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    _swift_load_modules
    local target_module
    target_module="$(_swift_module_of_file "$repo_rel")"

    if [ -z "$target_module" ]; then
        echo "[]"
        echo "0 importers found" >&2
        return
    fi

    local results="[]"

    if [ -n "$symbol_filter" ]; then
        # Symbol-level: find files that reference the symbol in importing modules
        for mod in "${!_SWIFT_MODULE_DEPS[@]}"; do
            # Check if this module depends on the target module
            local depends=false
            for dep in ${_SWIFT_MODULE_DEPS[$mod]:-}; do
                [ "$dep" = "$target_module" ] && { depends=true; break; }
            done
            $depends || continue

            # Scan files in the importing module for references
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                if grep -q "$symbol_filter" "$REPO_ROOT/$f" 2>/dev/null; then
                    results="$(echo "$results" | jq --arg f "$f" --arg mod "$mod" \
                        '. + [{file: $f, module: $mod}]')"
                fi
            done < <(_swift_module_files "$mod")
        done

        # Also check same-module files (intra-module references)
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ "$f" != "$repo_rel" ] || continue
            if grep -q "$symbol_filter" "$REPO_ROOT/$f" 2>/dev/null; then
                results="$(echo "$results" | jq --arg f "$f" --arg mod "$target_module" \
                    '. + [{file: $f, module: $mod, scope: "same-module"}]')"
            fi
        done < <(_swift_module_files "$target_module")
    else
        # Module-level: which modules depend on target_module?
        for mod in "${!_SWIFT_MODULE_DEPS[@]}"; do
            for dep in ${_SWIFT_MODULE_DEPS[$mod]:-}; do
                if [ "$dep" = "$target_module" ]; then
                    local dir="${_SWIFT_MODULE_DIRS[$mod]:-}"
                    results="$(echo "$results" | jq --arg mod "$mod" --arg dir "$dir" \
                        '. + [{module: $mod, source_dir: $dir}]')"
                    break
                fi
            done
        done

        # For single-target: show same-module files that reference entities from this file
        if [ "$_SWIFT_PROJECT_TYPE" = "single" ]; then
            local entities
            entities="$(ast_grep_entities "$abs_file" names | jq -r '.[].name' 2>/dev/null)"
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                [ "$f" != "$repo_rel" ] || continue
                while IFS= read -r entity_name; do
                    [ -n "$entity_name" ] || continue
                    if grep -q "$entity_name" "$REPO_ROOT/$f" 2>/dev/null; then
                        results="$(echo "$results" | jq --arg f "$f" --arg sym "$entity_name" \
                            '. + [{file: $f, references: $sym}]')"
                        break
                    fi
                done <<< "$entities"
            done < <(_swift_module_files "$target_module")
        fi
    fi

    local count
    count="$(echo "$results" | jq 'length')"
    echo "$results" | jq 'sort_by(.module // .file)'
    echo "$count importers found" >&2
}

# ─────────────────────────────────────────────────────────
# P1: New subcommand — modules
# ─────────────────────────────────────────────────────────
cmd_modules() {
    local json_mode=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json_mode=true ;;
            *) die "unknown flag: $1" ;;
        esac
        shift
    done

    _swift_load_modules

    if $json_mode; then
        local arr="[]"
        for mod in "${!_SWIFT_MODULE_DIRS[@]}"; do
            local dir="${_SWIFT_MODULE_DIRS[$mod]}"
            local type="${_SWIFT_MODULE_TYPES[$mod]:-library}"
            local deps="${_SWIFT_MODULE_DEPS[$mod]:-}"
            local file_count=0
            if [ -d "$REPO_ROOT/$dir" ]; then
                file_count="$(find "$REPO_ROOT/$dir" -name "*.swift" -type f 2>/dev/null | wc -l)"
            fi
            local deps_json
            deps_json="$(echo "$deps" | tr ' ' '\n' | jq -R -s 'split("\n") | map(select(. != ""))')"
            arr="$(echo "$arr" | jq --arg name "$mod" --arg type "$type" --arg dir "$dir" \
                --argjson fc "$file_count" --argjson deps "$deps_json" \
                '. + [{name: $name, type: $type, source_dir: $dir, file_count: $fc, dependencies: $deps}]')"
        done
        echo "$arr" | jq 'sort_by(.name)'
    else
        for mod in $(printf '%s\n' "${!_SWIFT_MODULE_DIRS[@]}" | sort); do
            local type="${_SWIFT_MODULE_TYPES[$mod]:-library}"
            local deps="${_SWIFT_MODULE_DEPS[$mod]:-}"
            local deps_list
            if [ -n "$deps" ]; then
                deps_list="[$(echo "$deps" | sed 's/ /, /g')]"
            else
                deps_list="[]"
            fi
            echo "$mod ($type) → $deps_list"
        done
    fi
}

# ─────────────────────────────────────────────────────────
# P1: New subcommand — module-of
# ─────────────────────────────────────────────────────────
cmd_module_of() {
    local file="$1"
    [ -n "$file" ] || die "usage: discover.sh module-of <file>"

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    local mod
    mod="$(_swift_module_of_file "$repo_rel")"
    if [ -n "$mod" ]; then
        echo "$mod"
    else
        echo "unknown (file not in any module's source directory)" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────
# Call-chain tracing helpers
#
# Swift has no file-level imports within a target, so --live-only on usages
# only checks module membership (always true for single-target). To actually
# verify a callsite is reachable, we trace through containing functions.
# ─────────────────────────────────────────────────────────

# Given an absolute file path and a 0-indexed line number, return the name of
# the function or initializer that contains that line. Returns empty if the
# line is at the top level or inside a non-function context (property, etc.).
_swift_containing_function() {
    local file="$1" target_line="$2"

    # Collect function_declaration and init_declaration ranges
    local fn_raw init_raw all_funcs="[]"

    fn_raw="$(ast-grep run -l swift --kind function_declaration "$file" --json 2>/dev/null)"
    if [ -n "$fn_raw" ] && [ "$fn_raw" != "[]" ]; then
        # Scan all lines for `func` — attributes like @MainActor can push it
        # past the first line of the function_declaration node.
        all_funcs="$(echo "$fn_raw" | jq '[.[] | {
            name: ([.text | split("\n")[] | capture("func\\s+(?<n>\\w+)")?] | map(select(. != null)) | .[0].n),
            start: .range.start.line,
            end: .range.end.line
        } | select(.name != null)]')"
    fi

    init_raw="$(ast-grep run -l swift --kind init_declaration "$file" --json 2>/dev/null)"
    if [ -n "$init_raw" ] && [ "$init_raw" != "[]" ]; then
        local init_funcs
        init_funcs="$(echo "$init_raw" | jq '[.[] | {
            name: "init",
            start: .range.start.line,
            end: .range.end.line
        }]')"
        all_funcs="$(echo "$all_funcs" "$init_funcs" | jq -s '.[0] + .[1]')"
    fi

    # Find the innermost function whose range contains target_line
    echo "$all_funcs" | jq -r --argjson line "$target_line" '
        [.[] | select(.start <= $line and .end >= $line)] |
        sort_by(.end - .start) | .[0].name // empty
    '
}

# Given an absolute file path and a 0-indexed line, return the enclosing
# type name (class/struct/enum/actor/extension) or empty if top-level.
_swift_containing_type() {
    local file="$1" target_line="$2"
    local types_raw
    types_raw="$(ast-grep run -l swift --kind class_declaration "$file" --json 2>/dev/null)"
    [ -n "$types_raw" ] && [ "$types_raw" != "[]" ] || return
    echo "$types_raw" | jq -r --argjson line "$target_line" '
        [.[] |
            (.text | split("\n")[0] |
                capture("(?<kw>struct|class|enum|actor|extension)\\s+(?<n>\\w+)")) as $cap |
            select($cap != null) |
            select(.range.start.line <= $line and .range.end.line >= $line) |
            {name: $cap.n, start: .range.start.line, end: .range.end.line}
        ] | sort_by(.end - .start) | .[0].name // empty
    '
}

# ─────────────────────────────────────────────────────────
# Subcommand: trace — call-chain verification
#
# Given a symbol, finds all callsites (excluding definitions) and traces
# upward through containing functions to build a caller chain. Each level
# asks: "what function contains this call, and who calls that function?"
#
# This is the correct way to verify reachability in Swift, where file-level
# import tracing is meaningless (all files in a target see each other).
#
# Usage:
#   discover-swift.sh trace <symbol> [--max-depth N] [--json]
# ─────────────────────────────────────────────────────────
cmd_trace() {
    local symbol="" max_depth=8 json_mode=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --max-depth) shift; max_depth="$1" ;;
            --json)      json_mode=true ;;
            *) symbol="$1" ;;
        esac
        shift
    done
    [ -n "$symbol" ] || die "usage: discover.sh trace <symbol> [--max-depth N] [--json]"

    # Find all occurrences of the symbol
    local raw
    raw="$(ast-grep run -l swift -p "$symbol" "$REPO_ROOT" --json 2>/dev/null)"
    [ -n "$raw" ] && [ "$raw" != "[]" ] || {
        echo "[]"
        $json_mode || echo "0 callsites found" >&2
        return
    }

    local results="[]"
    local callsite_count=0

    # Process each occurrence — skip definitions, trace callsites
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        local file line text
        file="$(echo "$entry" | jq -r '.file')"
        line="$(echo "$entry" | jq -r '.range.start.line')"
        text="$(echo "$entry" | jq -r '.lines | split("\n")[0]')"
        local trimmed_text="${text#"${text%%[![:space:]]*}"}"
        local rel_file="${file#$REPO_ROOT/}"

        # Skip definitions: lines that start with `func <symbol>`
        if [[ "$trimmed_text" =~ ^(public|open|internal|private|fileprivate|package|static|class|override|@[a-zA-Z]+\ )*(func|init)\ +"$symbol" ]]; then
            continue
        fi

        # Find the containing function for this callsite
        local container
        container="$(_swift_containing_function "$file" "$line")"
        local container_type
        container_type="$(_swift_containing_type "$file" "$line")"
        local qualified="${container_type:+${container_type}.}${container:-top-level}"

        # Trace upward through callers
        local chain="[]"
        local current_func="$container"
        local current_file="$file"
        local status="traced"
        local depth=0

        # Track visited to avoid cycles (key = function name)
        declare -A _trace_seen=()

        while [ -n "$current_func" ] && [ "$depth" -lt "$max_depth" ]; do
            [ -z "${_trace_seen[$current_func]+_}" ] || { status="cycle"; break; }
            _trace_seen["$current_func"]=1

            # Search for callers of current_func across the repo
            local caller_raw
            caller_raw="$(ast-grep run -l swift -p "$current_func" "$REPO_ROOT" --json 2>/dev/null)"

            if [ -z "$caller_raw" ] || [ "$caller_raw" = "[]" ]; then
                status="end"
                chain="$(echo "$chain" | jq --arg f "$current_func" \
                    '. + [{function: $f, note: "no references found"}]')"
                break
            fi

            # Find a caller that is NOT a definition of current_func
            local found_caller=false
            while IFS= read -r caller_entry; do
                [ -n "$caller_entry" ] || continue
                local c_file c_line c_text
                c_file="$(echo "$caller_entry" | jq -r '.file')"
                c_line="$(echo "$caller_entry" | jq -r '.range.start.line')"
                c_text="$(echo "$caller_entry" | jq -r '.lines | split("\n")[0]')"
                local c_trimmed="${c_text#"${c_text%%[![:space:]]*}"}"

                # Skip definitions
                if [[ "$c_trimmed" =~ ^(public|open|internal|private|fileprivate|package|static|class|override|@[a-zA-Z]+\ )*(func|init)\ +"$current_func" ]]; then
                    continue
                fi

                local c_func
                c_func="$(_swift_containing_function "$c_file" "$c_line")"

                # Skip self-references (same function calling itself = recursion)
                [ "$c_func" != "$current_func" ] || continue
                # Must have a containing function
                [ -n "$c_func" ] || continue

                local c_type
                c_type="$(_swift_containing_type "$c_file" "$c_line")"
                local c_rel="${c_file#$REPO_ROOT/}"

                chain="$(echo "$chain" | jq \
                    --arg f "$current_func" \
                    --arg caller "$c_func" \
                    --arg caller_type "${c_type:-}" \
                    --arg caller_file "$c_rel" \
                    --argjson caller_line "$((c_line + 1))" \
                    '. + [{
                        function: $f,
                        called_by: (if $caller_type != "" then ($caller_type + "." + $caller) else $caller end),
                        in_file: $caller_file,
                        at_line: $caller_line
                    }]')"

                current_func="$c_func"
                current_file="$c_file"
                found_caller=true
                break
            done < <(echo "$caller_raw" | jq -c '.[]')

            if ! $found_caller; then
                # No non-definition, non-self callers found.
                # This function exists but nothing calls it — could be a
                # framework entry point or dead code.
                status="end"
                chain="$(echo "$chain" | jq --arg f "$current_func" \
                    '. + [{function: $f, note: "no callers found (entry point or dead code)"}]')"
                break
            fi

            ((depth++))
        done

        if [ "$depth" -ge "$max_depth" ]; then
            status="max_depth"
        fi

        unset _trace_seen

        results="$(echo "$results" | jq \
            --arg file "$rel_file" \
            --argjson line "$((line + 1))" \
            --arg text "$trimmed_text" \
            --arg container "$qualified" \
            --argjson chain "$chain" \
            --arg status "$status" \
            --argjson depth "$depth" \
            '. + [{
                callsite: {file: $file, line: $line, text: $text, in_function: $container},
                chain: $chain,
                status: $status,
                depth: $depth
            }]')"
        ((callsite_count++))
    done < <(echo "$raw" | jq -c '.[]')

    echo "$results" | jq '.'
    $json_mode || echo "$callsite_count callsites traced" >&2
}

# ─────────────────────────────────────────────────────────
# Override inspect_sections to include module info
# ─────────────────────────────────────────────────────────
inspect_sections() { echo "module imports entities"; }

emit_inspect_section() {
    local section="$1" abs_file="$2" repo_rel="$3"
    if [ "$section" = "module" ]; then
        _swift_load_modules
        local mod
        mod="$(_swift_module_of_file "$repo_rel")"
        if [ -n "$mod" ]; then
            local deps="${_SWIFT_MODULE_DEPS[$mod]:-}"
            local deps_json
            deps_json="$(echo "$deps" | tr ' ' '\n' | jq -R -s 'split("\n") | map(select(. != ""))')"
            jq -n --arg name "$mod" --argjson deps "$deps_json" \
                '{name: $name, dependencies: $deps}'
        else
            echo "null"
        fi
    else
        return 1
    fi
}

# ─────────────────────────────────────────────────────────
# Entity extraction
# ─────────────────────────────────────────────────────────
ast_grep_entities() {
    local file="$1" depth="${2:-names}"
    local all_json="[]"

    # Swift's tree-sitter grammar uses class_declaration for struct, enum,
    # class, actor, and extension. We dispatch on the leading keyword.
    local decl_raw
    decl_raw="$(ast-grep run -l swift --kind class_declaration "$file" --json 2>/dev/null)"
    if [ -n "$decl_raw" ] && [ "$decl_raw" != "[]" ]; then
        local decl_extracted
        decl_extracted="$(echo "$decl_raw" | jq --arg depth "$depth" '
            [.[] | (.text | split("\n")[0]) as $first_line |
                ($first_line | capture("^(?<access>open |public |internal |fileprivate |private |package )?(?:final )?(?<kw>struct|enum|class|actor|extension)\\s+(?<n>\\w+)")) as $cap |
                select($cap != null) |
                {
                    kind: $cap.kw,
                    name: $cap.n,
                    line: (.range.start.line + 1),
                    text: (
                        if $depth == "full" then .text
                        elif $depth == "signatures" then $first_line
                        else null
                        end
                    )
                }
            ]
        ' 2>/dev/null)"

        if [ -n "$decl_extracted" ] && [ "$decl_extracted" != "[]" ]; then
            all_json="$(echo "$all_json" "$decl_extracted" | jq -s '.[0] + .[1]')"
        fi
    fi

    # Protocols use a separate AST kind
    local proto_raw
    proto_raw="$(ast-grep run -l swift --kind protocol_declaration "$file" --json 2>/dev/null)"
    if [ -n "$proto_raw" ] && [ "$proto_raw" != "[]" ]; then
        local proto_extracted
        proto_extracted="$(echo "$proto_raw" | jq --arg depth "$depth" '
            [.[] | {
                kind: "protocol",
                name: (.text | split("\n")[0] | capture("protocol\\s+(?<n>\\w+)") | .n // "?"),
                line: (.range.start.line + 1),
                text: (
                    if $depth == "full" then .text
                    elif $depth == "signatures" then (.text | split("\n")[0])
                    else null
                    end
                )
            }]
        ' 2>/dev/null)"

        if [ -n "$proto_extracted" ] && [ "$proto_extracted" != "[]" ]; then
            all_json="$(echo "$all_json" "$proto_extracted" | jq -s '.[0] + .[1]')"
        fi
    fi

    # Top-level functions (column 0 only)
    local fn_raw
    fn_raw="$(ast-grep run -l swift --kind function_declaration "$file" --json 2>/dev/null)"
    if [ -n "$fn_raw" ] && [ "$fn_raw" != "[]" ]; then
        local fn_extracted
        fn_extracted="$(echo "$fn_raw" | jq --arg depth "$depth" '
            [.[] | select(.range.start.column == 0) | {
                kind: "func",
                name: (.text | split("\n")[0] | capture("func\\s+(?<n>\\w+)") | .n // "?"),
                line: (.range.start.line + 1),
                text: (
                    if $depth == "full" then .text
                    elif $depth == "signatures" then (.text | split("\n")[0])
                    else null
                    end
                )
            }]
        ' 2>/dev/null)"

        if [ -n "$fn_extracted" ] && [ "$fn_extracted" != "[]" ]; then
            all_json="$(echo "$all_json" "$fn_extracted" | jq -s '.[0] + .[1]')"
        fi
    fi

    echo "$all_json" | jq 'sort_by(.line) | if .[0].text == null then [.[] | del(.text)] else . end'
}
