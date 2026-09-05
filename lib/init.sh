#!/usr/bin/env bash
# init.sh — generate a complete discover skill package in the nearest .claude dir.
#
# Called by the `discover` CLI:
#   discover init [<lang>] [--entry <file>] [--package <name>] [--src-dir <dir>] [--force]
#
# Produces:
#   <project>/scripts/discover.sh                          — standalone script
#   <project>/scripts/test-discover.sh                     — project-level smoke tests
#   <nearest-.claude>/skills/discover/<lang>/SKILL.md      — language subskill
#   <nearest-.claude>/skills/discover/<lang>/USAGE.md      — ast-grep usage guide (if available)
#
# Auto-detects project-specific settings (entry point, package name) from
# manifest files when flags are not explicitly provided.

DISCOVER_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────
# Auto-detect language from project files
#
# Scans for manifest files and file extensions. Each lang config
# defines FILE_EXT — we check for the presence of matching files.
# Manifest files take priority (unambiguous), then file extensions.
# ─────────────────────────────────────────────────────────
LANG_MANIFEST_MAP=(
    "pubspec.yaml:dart"
    "shard.yml:crystal"
    "Package.swift:swift"
    "package.json:typescript"
    "Gemfile:ruby"
)

LANG_EXT_MAP=(
    ".dart:dart"
    ".cr:crystal"
    ".swift:swift"
    ".kt:kotlin"
    ".ts:typescript"
    ".tsx:typescript"
    ".rb:ruby"
    ".sh:bash"
)

auto_detect_lang() {
    local root="$1"

    # Pass 1: manifest files (highest confidence)
    for entry in "${LANG_MANIFEST_MAP[@]}"; do
        local manifest="${entry%%:*}" lang="${entry#*:}"
        if [ -f "$root/$manifest" ]; then
            echo "$lang"
            return 0
        fi
    done

    # Pass 2: Kotlin uses build.gradle or pom.xml with src/main/kotlin
    if [ -d "$root/src/main/kotlin" ]; then
        echo "kotlin"
        return 0
    fi

    # Pass 3: file extension scan (first match wins, skip vendored dirs)
    for entry in "${LANG_EXT_MAP[@]}"; do
        local ext="${entry%%:*}" lang="${entry#*:}"
        local found
        found="$(find "$root" -maxdepth 3 -name "*${ext}" \
            -not -path "*/node_modules/*" \
            -not -path "*/.build/*" \
            -not -path "*/build/*" \
            -not -path "*/.dart_tool/*" \
            -not -path "*/vendor/*" \
            -not -path "*/.git/*" \
            -print -quit 2>/dev/null)"
        if [ -n "$found" ]; then
            echo "$lang"
            return 0
        fi
    done

    return 1
}

# ─────────────────────────────────────────────────────────
# Find script install directory (scripts/ or bin/ in project root)
# ─────────────────────────────────────────────────────────
find_script_dir() {
    local root="$1"
    local base
    if [ -d "$root/scripts" ]; then
        base="$root/scripts"
    elif [ -d "$root/bin" ]; then
        base="$root/bin"
    else
        base="$root/scripts"
    fi
    echo "$base/discover"
}

# ─────────────────────────────────────────────────────────
# Auto-detect project settings from manifest files
# ─────────────────────────────────────────────────────────
detect_dart() {
    local root="$1"
    local pubspec="$root/pubspec.yaml"
    if [ -f "$pubspec" ]; then
        DETECTED_PACKAGE="$(grep -oP '^name:\s*\K\S+' "$pubspec" 2>/dev/null || true)"
    fi
    if [ -f "$root/lib/main.dart" ]; then
        DETECTED_ENTRY="lib/main.dart"
    fi
}

detect_crystal() {
    local root="$1"
    local shard="$root/shard.yml"
    if [ -f "$shard" ]; then
        local name
        name="$(grep -oP '^name:\s*\K\S+' "$shard" 2>/dev/null || true)"
        if [ -n "$name" ] && [ -f "$root/src/$name.cr" ]; then
            DETECTED_ENTRY="src/$name.cr"
            DETECTED_PACKAGE="$name"
        fi
    fi
}

detect_ruby() {
    local root="$1"

    # Detect Rails projects — source lives under app/, not lib/
    if [ -f "$root/bin/rails" ] && [ -f "$root/config/application.rb" ]; then
        DETECTED_FRAMEWORK="rails"
        DETECTED_ENTRY="config/application.rb"
        DETECTED_PACKAGE="$(basename "$root")"
        # Rails autoloads app/ — override SRC_DIR_REL
        SRC_DIR_REL="app"
        return
    fi

    # Try gemspec first
    local gemspec
    gemspec="$(find "$root" -maxdepth 1 -name "*.gemspec" -print -quit 2>/dev/null)"
    if [ -n "$gemspec" ]; then
        local name
        name="$(basename "$gemspec" .gemspec)"
        DETECTED_PACKAGE="$name"
        if [ -f "$root/lib/$name.rb" ]; then
            DETECTED_ENTRY="lib/$name.rb"
        fi
    fi
    # Fall back to Gemfile/directory name
    if [ -z "$DETECTED_ENTRY" ]; then
        local dir_name
        dir_name="$(basename "$root")"
        if [ -f "$root/lib/$dir_name.rb" ]; then
            DETECTED_ENTRY="lib/$dir_name.rb"
        fi
    fi
}

detect_typescript() {
    local root="$1"
    local pkg="$root/package.json"
    if [ -f "$pkg" ]; then
        DETECTED_PACKAGE="$(jq -r '.name // empty' "$pkg" 2>/dev/null || true)"

        # Detect React projects — react in dependencies or devDependencies
        local has_react
        has_react="$(jq -r '(.dependencies.react // .devDependencies.react) // empty' "$pkg" 2>/dev/null || true)"
        if [ -n "$has_react" ]; then
            DETECTED_FRAMEWORK="react"
        fi

        # Look for common entry points
        local main
        main="$(jq -r '.main // empty' "$pkg" 2>/dev/null || true)"
        if [ -n "$main" ]; then
            # Convert .js entry to .ts equivalent
            local ts_main="${main%.js}.ts"
            [ -f "$root/$ts_main" ] && DETECTED_ENTRY="$ts_main"
        fi
        if [ -z "$DETECTED_ENTRY" ]; then
            for candidate in src/index.ts src/main.ts index.ts src/index.tsx src/main.tsx; do
                if [ -f "$root/$candidate" ]; then
                    DETECTED_ENTRY="$candidate"
                    break
                fi
            done
        fi
    fi
}

detect_bash() {
    local root="$1"
    # Look for a main script or common entry points
    for candidate in main.sh app.sh run.sh entrypoint.sh; do
        if [ -f "$root/$candidate" ]; then
            DETECTED_ENTRY="$candidate"
            break
        fi
    done
    # Also check bin/ and scripts/
    if [ -z "$DETECTED_ENTRY" ]; then
        for dir in bin scripts; do
            if [ -d "$root/$dir" ]; then
                local main_script
                main_script="$(find "$root/$dir" -maxdepth 1 -name "*.sh" -print -quit 2>/dev/null)"
                if [ -n "$main_script" ]; then
                    DETECTED_ENTRY="$(realpath --relative-to="$root" "$main_script" 2>/dev/null)"
                    break
                fi
            fi
        done
    fi
    # Package name from directory name
    DETECTED_PACKAGE="$(basename "$root")"
}

detect_kotlin() {
    local root="$1"
    # Gradle (Kotlin or Groovy DSL)
    for manifest in "$root/build.gradle.kts" "$root/build.gradle"; do
        if [ -f "$manifest" ]; then
            DETECTED_PACKAGE="$(basename "$root")"
            break
        fi
    done
    # Maven
    if [ -z "$DETECTED_PACKAGE" ] && [ -f "$root/pom.xml" ]; then
        DETECTED_PACKAGE="$(grep -oP '<artifactId>\K[^<]+' "$root/pom.xml" 2>/dev/null | head -1 || true)"
    fi
    # Entry point: look for Main.kt
    local src_root="$root/src/main/kotlin"
    if [ -d "$src_root" ]; then
        local main_kt
        main_kt="$(find "$src_root" -name "Main.kt" -print -quit 2>/dev/null)"
        if [ -n "$main_kt" ]; then
            DETECTED_ENTRY="$(realpath --relative-to="$root" "$main_kt" 2>/dev/null)"
        fi
    fi
}

detect_swift() {
    local root="$1"
    local package_swift="$root/Package.swift"
    if [ -f "$package_swift" ]; then
        # SPM: look for an executable target with a main.swift or App.swift
        local target
        for dir in "$root"/Sources/*/; do
            [ -d "$dir" ] || continue
            if [ -f "$dir/main.swift" ] || [ -f "$dir/App.swift" ]; then
                target="$(basename "$dir")"
                DETECTED_ENTRY="Sources/$target/main.swift"
                [ -f "$dir/main.swift" ] || DETECTED_ENTRY="Sources/$target/App.swift"
                DETECTED_PACKAGE="$target"
                break
            fi
        done
        return
    fi

    # Xcode project: find the app target's source directory from .pbxproj
    local pbxproj
    pbxproj="$(compgen -G "$root"/*.xcodeproj/project.pbxproj 2>/dev/null | head -1)"
    if [ -n "$pbxproj" ] && [ -f "$pbxproj" ]; then
        # Extract the first PBXNativeTarget with productType = application
        local app_name=""
        local in_target=false current_name="" current_type=""
        while IFS= read -r line; do
            if [[ "$line" =~ isa\ =\ PBXNativeTarget ]]; then
                in_target=true
            fi
            if $in_target; then
                if [[ "$line" =~ name\ =\ \"?([^\";\}]+)\"? ]]; then
                    current_name="${BASH_REMATCH[1]}"
                fi
                if [[ "$line" =~ productType\ =\ \"([^\"]+)\" ]]; then
                    current_type="${BASH_REMATCH[1]}"
                fi
                if [[ "$line" == *"};"* ]] && [ -n "$current_name" ]; then
                    if [[ "$current_type" == *application* ]]; then
                        app_name="$current_name"
                        break
                    fi
                    current_name=""
                    current_type=""
                    in_target=false
                fi
            fi
        done < "$pbxproj"

        if [ -n "$app_name" ]; then
            DETECTED_PACKAGE="$app_name"
            # Find the source directory matching the app target name
            for candidate in "$app_name" "${app_name// /}" "${app_name}Sources"; do
                if [ -d "$root/$candidate" ]; then
                    SRC_DIR_REL="$candidate"
                    break
                fi
            done
            # Look for SwiftUI App.swift or @main entry point
            if [ -n "$SRC_DIR_REL" ] && [ -d "$root/$SRC_DIR_REL" ]; then
                local app_swift
                app_swift="$(grep -rl '@main\|@UIApplicationMain' "$root/$SRC_DIR_REL" --include="*.swift" 2>/dev/null | head -1)"
                if [ -n "$app_swift" ]; then
                    DETECTED_ENTRY="$(realpath --relative-to="$root" "$app_swift" 2>/dev/null)"
                fi
            fi
        fi
    fi
}

# ─────────────────────────────────────────────────────────
# Default for inspect_sections if the lang config doesn't define it
# (mirrors the default in core.sh)
# ─────────────────────────────────────────────────────────
if ! declare -f inspect_sections >/dev/null 2>&1; then
    inspect_sections() { echo "imports entities"; }
fi

# ─────────────────────────────────────────────────────────
# Build inspect flags string from inspect_sections()
# ─────────────────────────────────────────────────────────
build_inspect_flags() {
    local flags=""
    for section in $(inspect_sections); do
        flags+=" --${section}"
    done
    echo "${flags# }"
}

# ─────────────────────────────────────────────────────────
# Build Context7 lookup commands from CTX7_LIBRARIES
# ─────────────────────────────────────────────────────────
build_ctx7_commands() {
    if [ -z "${CTX7_LIBRARIES:-}" ]; then
        echo "# No Context7 libraries configured for this language."
        return
    fi
    local cmds=""
    for lib in $CTX7_LIBRARIES; do
        cmds+="npx ctx7@latest library \"${lib}\" \"<your question>\""$'\n'
        cmds+="npx ctx7@latest docs \"<library-id>\" \"<your question>\""$'\n'
    done
    printf '%s' "${cmds%$'\n'}"
}

# ─────────────────────────────────────────────────────────
# Render SKILL.md from template + lang metadata
# ─────────────────────────────────────────────────────────
render_skill_md() {
    local template="$1" script_path="$2" test_script_path="$3" wrapper_path="${4:-}"
    local inspect_flags
    inspect_flags="$(build_inspect_flags)"
    local import_section
    import_section="$(inspect_sections | awk '{print $1}')"
    local ctx7_commands
    ctx7_commands="$(build_ctx7_commands)"

    # Defaults for language-specific sections (import-graph languages).
    # Lang configs can override SKILL_LIVE_FILES_DESC, SKILL_IS_LIVE_DESC,
    # SKILL_USAGES_LIVE_DESC, SKILL_EXTRA_SUBCOMMANDS, and SKILL_RULES to
    # match their compilation model.
    local live_desc="${SKILL_LIVE_FILES_DESC:-BFS from the entry point following all ${SKILL_IMPORT_VERB}s. Outputs every reachable file, one per line.}"
    local is_live_desc="${SKILL_IS_LIVE_DESC:-Check whether a single file is reachable from the entry point.}"
    local usages_live_desc="${SKILL_USAGES_LIVE_DESC:-\`--live-only\` filters to files reachable from the entry point.}"
    local extra_subcmds="${SKILL_EXTRA_SUBCOMMANDS:-}"
    local rules="${SKILL_RULES:-}"
    if [ -z "$rules" ]; then
        rules="- Use \`discover.sh\` before claiming any symbol, file, or code path is live or dead.
- Use \`definition\` before assuming which file a class comes from — duplicate names exist.
- Use \`is-live\` or \`live-files\` before recommending changes to a file — it may be dead code.
- Use \`usages --live-only\` instead of grep when finding who calls something.
- Never treat a grep match as reachability evidence."
    fi

    # Simple substitutions via sed
    local result
    result="$(sed \
        -e "s|{{LANG_NAME}}|${SKILL_LANG_NAME}|g" \
        -e "s|{{IMPORT_VERB}}|${SKILL_IMPORT_VERB}|g" \
        -e "s|{{MOTIVATION}}|${SKILL_MOTIVATION}|g" \
        -e "s|{{SCRIPT_PATH}}|${script_path}|g" \
        -e "s|{{WRAPPER_PATH}}|${wrapper_path}|g" \
        -e "s|{{TEST_SCRIPT_PATH}}|${test_script_path}|g" \
        -e "s|{{INSPECT_FLAGS}}|${inspect_flags}|g" \
        -e "s|{{IMPORT_SECTION}}|${import_section}|g" \
        -e "s|{{EXAMPLE_FILE}}|${SKILL_EXAMPLE_FILE}|g" \
        -e "s|{{EXAMPLE_SYMBOL}}|${SKILL_EXAMPLE_SYMBOL}|g" \
        -e "s|{{RESOLVE_EXAMPLE_1}}|${SKILL_RESOLVE_EXAMPLE_1}|g" \
        -e "s|{{RESOLVE_RESULT_1}}|${SKILL_RESOLVE_RESULT_1}|g" \
        -e "s|{{RESOLVE_EXAMPLE_2}}|${SKILL_RESOLVE_EXAMPLE_2}|g" \
        -e "s|{{RESOLVE_FROM_2}}|${SKILL_RESOLVE_FROM_2}|g" \
        -e "s|{{RESOLVE_RESULT_2}}|${SKILL_RESOLVE_RESULT_2}|g" \
        -e "s|{{USAGE_EXAMPLE_1}}|${SKILL_USAGE_EXAMPLE_1}|g" \
        -e "s|{{USAGE_EXAMPLE_2}}|${SKILL_USAGE_EXAMPLE_2}|g" \
        "$template")"

    # Multi-line substitutions (sed can't handle newlines in replacement text)
    # Final sed pass catches {{SCRIPT_PATH}} refs introduced by awk variables
    # (e.g. SKILL_EXTRA_SUBCOMMANDS may reference {{SCRIPT_PATH}} in code blocks)
    echo "$result" | awk \
        -v ctx7="$ctx7_commands" \
        -v live="$live_desc" \
        -v is_live="$is_live_desc" \
        -v usages_live="$usages_live_desc" \
        -v extra="$extra_subcmds" \
        -v rules_block="$rules" \
    '{
        if (index($0, "{{CTX7_COMMANDS}}"))       { sub(/{{CTX7_COMMANDS}}/,       ctx7) }
        if (index($0, "{{LIVE_FILES_DESC}}"))     { sub(/{{LIVE_FILES_DESC}}/,     live) }
        if (index($0, "{{IS_LIVE_DESC}}"))        { sub(/{{IS_LIVE_DESC}}/,        is_live) }
        if (index($0, "{{USAGES_LIVE_DESC}}"))    { sub(/{{USAGES_LIVE_DESC}}/,    usages_live) }
        if (index($0, "{{EXTRA_SUBCOMMANDS}}"))   { sub(/{{EXTRA_SUBCOMMANDS}}/,   extra) }
        if (index($0, "{{RULES}}"))               { sub(/{{RULES}}/,              rules_block) }
        print
    }' | sed "s|{{SCRIPT_PATH}}|${script_path}|g"
}

# ─────────────────────────────────────────────────────────
# OpenSpec integration — optionally inject discover-awareness
# into openspec skills (install openspec first if needed)
# ─────────────────────────────────────────────────────────
DISCOVER_AWARENESS_BLOCK='## Discover Integration

At the start of this invocation, check if `scripts/discover.sh` exists in the project root. If it does, any reference to the codebase — files, relationships, definitions, reachability — is a hallucination until validated via discover.

Use `bash scripts/discover.sh --help` to learn available subcommands. Do not fall back to grep and present unvalidated results as fact — if a discover query fails, report the failure transparently.

If `scripts/discover.sh` does not exist, operate normally with no warning.

---'

inject_discover_awareness() {
    local skill_file="$1"
    [ -f "$skill_file" ] || return 1
    # Skip if already injected
    grep -q "## Discover Integration" "$skill_file" && return 0
    # Inject after the first --- separator that ends the frontmatter
    local tmp="${skill_file}.tmp"
    awk -v block="$DISCOVER_AWARENESS_BLOCK" '
        /^---$/ && !found_end { found_end=1; print; next }
        found_end && !injected {
            injected=1
            print ""
            print block
            print ""
        }
        { print }
    ' "$skill_file" > "$tmp" && mv "$tmp" "$skill_file"
}

maybe_install_ctx7() {
    local claude_dir="$1"

    # Skip if skill already installed in this project
    [ -f "$claude_dir/skills/ctx7/SKILL.md" ] && return 0

    command -v npx >/dev/null 2>&1 || return 0

    read -rep "install ctx7 (Context7 doc lookups)? " answer </dev/tty
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) return 0 ;;
    esac

    # Install npm package globally if not present
    if ! npx ctx7@latest --version >/dev/null 2>&1; then
        echo "  ctx7 → installing globally..." >&2
        npm install -g ctx7 2>/dev/null \
            && echo "  ctx7 → installed" >&2 \
            || echo "  ctx7 → install failed, use 'npx ctx7@latest' instead" >&2
    fi

    # Install skill into project
    local ctx7_template="$DISCOVER_ROOT/templates/ctx7-SKILL.md"
    if [ -f "$ctx7_template" ]; then
        mkdir -p "$claude_dir/skills/ctx7"
        cp "$ctx7_template" "$claude_dir/skills/ctx7/SKILL.md"
        echo "  ctx7 → skill installed at $claude_dir/skills/ctx7/SKILL.md" >&2
    fi
}

maybe_inject_openspec() {
    local claude_dir="$1"
    local project_root
    project_root="$(dirname "$claude_dir")"

    # Check if discover awareness is already injected into all openspec skills
    local already_injected=true
    local has_openspec_skills=false
    for skill_name in openspec-explore openspec-propose openspec-apply-change; do
        local skill_file="$claude_dir/skills/$skill_name/SKILL.md"
        if [ -f "$skill_file" ]; then
            has_openspec_skills=true
            if ! grep -q "## Discover Integration" "$skill_file"; then
                already_injected=false
                break
            fi
        fi
    done

    # Skip if openspec is installed and discover awareness is already in all skills
    if $has_openspec_skills && $already_injected; then
        echo "  openspec → already integrated" >&2
        return 0
    fi

    # Skip prompt if openspec dir exists and skills already have the block
    if [ -d "$project_root/openspec" ] && $has_openspec_skills && $already_injected; then
        return 0
    fi

    read -rep "install openspec? " answer </dev/tty
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) return 0 ;;
    esac

    # Install openspec if not already present
    if [ ! -d "$project_root/openspec" ]; then
        if command -v openspec >/dev/null 2>&1; then
            echo "  openspec → initializing..." >&2
            (cd "$project_root" && openspec init)
        else
            echo "  openspec → 'openspec' not found on PATH, skipping" >&2
            return 0
        fi
    fi

    # Inject discover-awareness into existing openspec skills
    local injected=0
    for skill_name in openspec-explore openspec-propose openspec-apply-change; do
        local skill_file="$claude_dir/skills/$skill_name/SKILL.md"
        if inject_discover_awareness "$skill_file"; then
            echo "  openspec → injected discover block into $skill_name" >&2
            injected=$((injected + 1))
        fi
    done

    if [ "$injected" -eq 0 ]; then
        echo "  openspec → no openspec skills found to inject into" >&2
    fi
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
init_main() {
    local lang="" override_entry="" override_package="" override_src_dir="" force=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --entry)   shift; override_entry="$1" ;;
            --package) shift; override_package="$1" ;;
            --src-dir) shift; override_src_dir="$1" ;;
            --force|-f) force=true ;;
            *) lang="$1" ;;
        esac
        shift
    done

    # Auto-detect language from project files when not specified
    if [ -z "$lang" ]; then
        lang="$(auto_detect_lang "$PWD")" \
            || die "could not detect language — specify one: $(ls "$DISCOVER_ROOT/langs/"*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' ' ')"
        echo "  detect → $lang (from project files)" >&2
    fi

    # Validate lang config exists
    local lang_config="$DISCOVER_ROOT/langs/${lang}.sh"
    [ -f "$lang_config" ] || die "no lang config for '${lang}' — available: $(ls "$DISCOVER_ROOT/langs/"*.sh 2>/dev/null | xargs -I{} basename {} .sh | tr '\n' ' ')"

    # Source lang config to get metadata and function definitions
    source "$lang_config"

    # Find nearest .claude via the global find-claude-dir utility
    local claude_dir
    claude_dir="$(find-claude-dir)" || die "no .claude directory found"

    local project_root
    project_root="$(dirname "$claude_dir")"

    # Auto-detect project settings from manifests
    DETECTED_ENTRY=""
    DETECTED_PACKAGE=""
    DETECTED_FRAMEWORK=""

    if declare -f "detect_${lang}" >/dev/null 2>&1; then
        "detect_${lang}" "$project_root"
    fi

    # Explicit flags override auto-detection; auto-detection overrides lang defaults
    local entry="${override_entry:-${DETECTED_ENTRY:-$ENTRY_POINT_REL}}"
    local package="${override_package:-${DETECTED_PACKAGE:-$PACKAGE_NAME}}"
    local src_dir="${override_src_dir:-$SRC_DIR_REL}"

    # Script goes in project's scripts/ or bin/; SKILL.md goes in .claude/skills/discover/
    local script_dir
    script_dir="$(find_script_dir "$project_root")"
    local script_rel
    script_rel="$(realpath --relative-to="$project_root" "$script_dir")"
    local script_path="$script_rel/discover-${lang}.sh"
    local test_script_path="$script_rel/test-discover-${lang}.sh"

    # Each language is a subskill under discover: .claude/skills/discover/<lang>/
    local skill_dir="$claude_dir/skills/discover/${lang}"

    # Guard against overwriting an existing installation (current or legacy flat path)
    local legacy_dir="${script_dir%/discover}"
    local existing=""
    if [ -f "$script_dir/discover-${lang}.sh" ]; then
        existing="$script_dir/discover-${lang}.sh"
    elif [ -f "$legacy_dir/discover-${lang}.sh" ]; then
        existing="$legacy_dir/discover-${lang}.sh"
    fi
    if [ "$force" != true ] && [ -n "$existing" ]; then
        echo "discover: ${lang} already installed at $existing" >&2
        echo "  use --force to overwrite" >&2
        exit 1
    fi
    # Clean up legacy flat files when reinstalling with --force
    if [ "$force" = true ] && [ -f "$legacy_dir/discover-${lang}.sh" ]; then
        rm -f "$legacy_dir/discover-${lang}.sh"
        rm -f "$legacy_dir/test-discover-${lang}.sh"
        rm -f "$legacy_dir/discover.sh"
    fi

    mkdir -p "$script_dir"
    mkdir -p "$skill_dir"

    # Generate language-specific discover-<lang>.sh into the project's script directory
    local gen_args=("$lang_config" --output "$script_dir/discover-${lang}.sh")
    [ -n "$entry" ]   && gen_args+=(--entry "$entry")
    [ -n "$package" ] && gen_args+=(--package "$package")
    [ -n "$src_dir" ] && [ "$src_dir" != "$SRC_DIR_REL" ] && gen_args+=(--src-dir "$src_dir")

    bash "$DISCOVER_ROOT/lib/generate.sh" "${gen_args[@]}"

    # Generate language-specific test-discover-<lang>.sh
    local test_template="$DISCOVER_ROOT/templates/test-discover.sh.template"
    if [ -f "$test_template" ]; then
        sed \
            -e "s|{{SCRIPT_DIR}}|${script_rel}|g" \
            -e "s|{{LANG_ID}}|${lang}|g" \
            -e "s|{{ENTRY_POINT}}|${entry}|g" \
            -e "s|{{SRC_DIR}}|${src_dir}|g" \
            -e "s|{{FILE_EXT}}|${FILE_EXT}|g" \
            "$test_template" > "$script_dir/test-discover-${lang}.sh"
        chmod +x "$script_dir/test-discover-${lang}.sh"
    fi

    # Generate or update the common discover.sh wrapper
    local wrapper_template="$DISCOVER_ROOT/templates/discover-wrapper.sh.template"
    if [ -f "$wrapper_template" ]; then
        cp "$wrapper_template" "$script_dir/discover.sh"
        chmod +x "$script_dir/discover.sh"
    fi

    # Install parent router skill at .claude/skills/discover/SKILL.md
    # (this is what makes `Skill(discover/<lang>)` routable)
    local router_template="$DISCOVER_ROOT/templates/discover-router-SKILL.md.template"
    local router_target="$claude_dir/skills/discover/SKILL.md"
    local wrapper_path="$script_rel/discover.sh"
    if [ -f "$router_template" ]; then
        sed "s|{{WRAPPER_PATH}}|${wrapper_path}|g" "$router_template" > "$router_target"
    fi

    # Render language SKILL.md into .claude/skills/discover/<lang>/
    local template="$DISCOVER_ROOT/templates/SKILL.md.template"
    [ -f "$template" ] || die "SKILL.md.template not found at $DISCOVER_ROOT"

    render_skill_md "$template" "$script_path" "$test_script_path" "$wrapper_path" > "$skill_dir/SKILL.md"

    # Copy language-specific usage guide if available
    local usage_guide="$DISCOVER_ROOT/langs/${lang}-usage.md"
    if [ -f "$usage_guide" ]; then
        cp "$usage_guide" "$skill_dir/USAGE.md"
    fi

    # Install framework overlay if detected
    if [ -n "$DETECTED_FRAMEWORK" ]; then
        local fw_dir="$DISCOVER_ROOT/frameworks/$DETECTED_FRAMEWORK"
        if [ -d "$fw_dir" ]; then
            local fw_script_name="discover-${DETECTED_FRAMEWORK}.sh"
            local fw_script_path="$script_rel/$fw_script_name"

            # Copy framework companion script
            cp "$fw_dir/$fw_script_name" "$script_dir/$fw_script_name"
            chmod +x "$script_dir/$fw_script_name"

            # Render framework SKILL.md into its own skill directory
            local fw_skill_dir="$claude_dir/skills/discover/${DETECTED_FRAMEWORK}"
            mkdir -p "$fw_skill_dir"
            sed "s|{{SCRIPT_PATH}}|${fw_script_path}|g" "$fw_dir/SKILL.md" > "$fw_skill_dir/SKILL.md"

            echo "  framework → ${DETECTED_FRAMEWORK}" >&2
            echo "  fw-script → $script_dir/$fw_script_name" >&2
            echo "  fw-skill  → $fw_skill_dir/SKILL.md" >&2
        fi
    fi

    # Configure LSP if plugin info is available
    if [ -n "${LSP_PLUGIN:-}" ]; then
        local settings_file="$claude_dir/settings.json"
        if [ -f "$settings_file" ]; then
            if ! jq -e ".enabledPlugins[\"${LSP_PLUGIN}\"]" "$settings_file" >/dev/null 2>&1; then
                jq ".enabledPlugins[\"${LSP_PLUGIN}\"] = true" "$settings_file" > "${settings_file}.tmp" \
                    && mv "${settings_file}.tmp" "$settings_file"
                echo "  lsp    → enabled ${LSP_PLUGIN}" >&2
            else
                echo "  lsp    → ${LSP_PLUGIN} (already enabled)" >&2
            fi
        else
            echo '{}' | jq "{enabledPlugins: {\"${LSP_PLUGIN}\": true}}" > "$settings_file"
            echo "  lsp    → enabled ${LSP_PLUGIN} (created settings.json)" >&2
        fi
    elif [ -n "${LSP_BINARY:-}" ]; then
        echo "  lsp    → no Claude Code plugin; ensure '${LSP_BINARY}' is installed" >&2
    fi

    # Offer optional integrations
    maybe_install_ctx7 "$claude_dir"
    maybe_inject_openspec "$claude_dir"

    echo "discover: ${SKILL_LANG_NAME}" >&2
    echo "  script → $script_dir/discover-${lang}.sh" >&2
    echo "  wrapper→ $script_dir/discover.sh" >&2
    echo "  tests  → $script_dir/test-discover-${lang}.sh" >&2
    echo "  router → $router_target" >&2
    echo "  skill  → $skill_dir/SKILL.md" >&2
    [ -f "$skill_dir/USAGE.md" ] && echo "  usage  → $skill_dir/USAGE.md" >&2
}

init_main "$@"
