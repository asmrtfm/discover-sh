#!/usr/bin/env bash
# test-init.sh — tests for discover init multi-language support
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

INIT_SH="$DISCOVER_ROOT/lib/init.sh"
DISCOVER_BIN="$DISCOVER_ROOT/bin/discover"

# Scratch directory for init tests, inside the repo's test dir
SANDBOX="$TESTS_DIR/fixtures/init-sandbox"

setup_sandbox() {
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/.claude"
    mkdir -p "$SANDBOX/src"
    echo '{}' > "$SANDBOX/package.json"
    touch "$SANDBOX/src/index.ts"
    touch "$SANDBOX/src/Main.kt"
}

teardown_sandbox() {
    rm -rf "$SANDBOX"
}

# Trap to clean up on exit
trap teardown_sandbox EXIT

# ─────────────────────────────────────────────────────────
echo "=== init: first language creates lang-specific script ==="

setup_sandbox
(cd "$SANDBOX" && bash "$DISCOVER_BIN" init typescript --force 2>&1) >/dev/null

assert_eq "discover-typescript.sh exists" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/discover-typescript.sh" ] && echo true || echo false)"

assert_eq "test-discover-typescript.sh exists" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/test-discover-typescript.sh" ] && echo true || echo false)"

assert_eq "wrapper discover.sh exists" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/discover.sh" ] && echo true || echo false)"

assert_eq "skill in language subdir" \
    true \
    "$([ -f "$SANDBOX/.claude/skills/discover/typescript/SKILL.md" ] && echo true || echo false)"

# Router skill makes `discover/<lang>` routable
assert_eq "router skill exists" \
    true \
    "$([ -f "$SANDBOX/.claude/skills/discover/SKILL.md" ] && echo true || echo false)"

assert_contains "router references discover/<lang>" \
    'discover/<lang>' \
    "$(cat "$SANDBOX/.claude/skills/discover/SKILL.md")"

# ─────────────────────────────────────────────────────────
echo "=== init: second language coexists without --force ==="

(cd "$SANDBOX" && bash "$DISCOVER_BIN" init kotlin 2>&1) >/dev/null

assert_eq "discover-kotlin.sh exists" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/discover-kotlin.sh" ] && echo true || echo false)"

assert_eq "test-discover-kotlin.sh exists" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/test-discover-kotlin.sh" ] && echo true || echo false)"

assert_eq "typescript script still exists after kotlin init" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/discover-typescript.sh" ] && echo true || echo false)"

assert_eq "typescript test still exists after kotlin init" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/test-discover-typescript.sh" ] && echo true || echo false)"

assert_eq "kotlin skill in language subdir" \
    true \
    "$([ -f "$SANDBOX/.claude/skills/discover/kotlin/SKILL.md" ] && echo true || echo false)"

assert_eq "typescript skill still exists" \
    true \
    "$([ -f "$SANDBOX/.claude/skills/discover/typescript/SKILL.md" ] && echo true || echo false)"

# ─────────────────────────────────────────────────────────
echo "=== init: per-language guard blocks duplicate ==="

dup_out="$(cd "$SANDBOX" && bash "$DISCOVER_BIN" init kotlin 2>&1 || true)"

assert_contains "guard names the language" \
    "kotlin already installed" \
    "$dup_out"

assert_contains "guard names the lang-specific script" \
    "discover-kotlin.sh" \
    "$dup_out"

# ─────────────────────────────────────────────────────────
echo "=== init: --force overwrites only the target language ==="

# Record typescript script checksum before kotlin --force
ts_before="$(md5sum "$SANDBOX/scripts/discover/discover-typescript.sh" | cut -d' ' -f1)"

(cd "$SANDBOX" && bash "$DISCOVER_BIN" init kotlin --force 2>&1) >/dev/null

ts_after="$(md5sum "$SANDBOX/scripts/discover/discover-typescript.sh" | cut -d' ' -f1)"

assert_eq "typescript script unchanged after kotlin --force" \
    "$ts_before" \
    "$ts_after"

assert_eq "kotlin script still exists after --force" \
    true \
    "$([ -f "$SANDBOX/scripts/discover/discover-kotlin.sh" ] && echo true || echo false)"

# ─────────────────────────────────────────────────────────
echo "=== init: rails framework detection ==="

# Set up a Rails-like sandbox
RAILS_SANDBOX="$TESTS_DIR/fixtures/rails-sandbox"
rm -rf "$RAILS_SANDBOX"
mkdir -p "$RAILS_SANDBOX/.claude"
mkdir -p "$RAILS_SANDBOX/bin"
mkdir -p "$RAILS_SANDBOX/config"
mkdir -p "$RAILS_SANDBOX/app/models"
touch "$RAILS_SANDBOX/Gemfile"
touch "$RAILS_SANDBOX/bin/rails"
echo "module RailsSandbox; end" > "$RAILS_SANDBOX/config/application.rb"
echo "class User; end" > "$RAILS_SANDBOX/app/models/user.rb"

(cd "$RAILS_SANDBOX" && bash "$DISCOVER_BIN" init ruby --force 2>&1) >/dev/null

# Framework script lands in discover subdirectory
assert_eq "rails framework script exists" \
    true \
    "$([ -f "$RAILS_SANDBOX/bin/discover/discover-rails.sh" ] && echo true || echo false)"

# Language script also in discover subdirectory
assert_eq "ruby lang script exists" \
    true \
    "$([ -f "$RAILS_SANDBOX/bin/discover/discover-ruby.sh" ] && echo true || echo false)"

# Framework skill in its own skill directory
assert_eq "rails skill exists" \
    true \
    "$([ -f "$RAILS_SANDBOX/.claude/skills/discover/rails/SKILL.md" ] && echo true || echo false)"

# Framework skill references the correct script path
rails_skill="$(cat "$RAILS_SANDBOX/.claude/skills/discover/rails/SKILL.md")"
assert_contains "rails skill references discover subdirectory" \
    "bin/discover/discover-rails.sh" \
    "$rails_skill"

# Framework script derives REPO_ROOT correctly from bin/discover/
rails_repo_root="$(cd "$RAILS_SANDBOX" && bash -c 'source bin/discover/discover-rails.sh --help 2>&1; echo "$REPO_ROOT"' 2>/dev/null || true)"

# Verify REPO_ROOT resolves by checking the script doesn't error on --help
rails_help="$(cd "$RAILS_SANDBOX" && bash bin/discover/discover-rails.sh --help 2>&1 || true)"
assert_not_contains "rails script does not error on missing dir" \
    "No such file" \
    "$rails_help"

# No scripts leaked into bin/ directly (only bin/discover/)
assert_eq "no discover-rails.sh in bin/ root" \
    false \
    "$([ -f "$RAILS_SANDBOX/bin/discover-rails.sh" ] && echo true || echo false)"

assert_eq "no discover-ruby.sh in bin/ root" \
    false \
    "$([ -f "$RAILS_SANDBOX/bin/discover-ruby.sh" ] && echo true || echo false)"

rm -rf "$RAILS_SANDBOX"

# ─────────────────────────────────────────────────────────
echo "=== wrapper: langs lists installed languages ==="

langs_out="$(cd "$SANDBOX" && bash scripts/discover/discover.sh langs 2>&1)"

assert_contains "langs lists kotlin" "kotlin" "$langs_out"
assert_contains "langs lists typescript" "typescript" "$langs_out"

# ─────────────────────────────────────────────────────────
echo "=== wrapper: auto-detect from file extension ==="

# The wrapper should detect typescript from .ts file arg
detect_out="$(cd "$SANDBOX" && bash scripts/discover/discover.sh inspect src/index.ts 2>&1)"

assert_contains "auto-detect routes .ts to typescript" \
    '"file":' \
    "$detect_out"

# ─────────────────────────────────────────────────────────
echo "=== wrapper: --lang flag dispatches correctly ==="

lang_out="$(cd "$SANDBOX" && bash scripts/discover/discover.sh --lang kotlin --help 2>&1)"

assert_contains "--lang kotlin reaches kotlin script" \
    "discover.sh" \
    "$lang_out"

# ─────────────────────────────────────────────────────────
echo "=== wrapper: unknown language errors cleanly ==="

unknown_out="$(cd "$SANDBOX" && bash scripts/discover/discover.sh --lang nonexistent inspect foo.xyz 2>&1 || true)"

assert_contains "unknown lang error" "no discover script" "$unknown_out"

# ─────────────────────────────────────────────────────────
echo "=== skill: references lang-specific script path ==="

ts_skill="$(cat "$SANDBOX/.claude/skills/discover/typescript/SKILL.md")"

assert_contains "typescript skill references discover-typescript.sh" \
    "discover-typescript.sh" \
    "$ts_skill"

assert_contains "typescript skill references wrapper" \
    "discover.sh" \
    "$ts_skill"

kt_skill="$(cat "$SANDBOX/.claude/skills/discover/kotlin/SKILL.md")"

assert_contains "kotlin skill references discover-kotlin.sh" \
    "discover-kotlin.sh" \
    "$kt_skill"

# ─────────────────────────────────────────────────────────
echo "=== test script: references lang-specific script ==="

ts_test="$(cat "$SANDBOX/scripts/discover/test-discover-typescript.sh")"

assert_contains "typescript test references discover-typescript.sh" \
    'discover-typescript.sh' \
    "$ts_test"

assert_not_contains "typescript test does not reference bare discover.sh as NAV" \
    'NAV="$SCRIPT_DIR/discover.sh"' \
    "$ts_test"

kt_test="$(cat "$SANDBOX/scripts/discover/test-discover-kotlin.sh")"

assert_contains "kotlin test references discover-kotlin.sh" \
    'discover-kotlin.sh' \
    "$kt_test"

# ─────────────────────────────────────────────────────────
echo "=== no old-style discover.sh overwrite ==="

# The wrapper should NOT contain language-specific config
wrapper_content="$(cat "$SANDBOX/scripts/discover/discover.sh")"

assert_not_contains "wrapper has no LANG_ID assignment" \
    'LANG_ID=' \
    "$wrapper_content"

assert_contains "wrapper is the dispatch script" \
    "multi-language" \
    "$wrapper_content"

# ─────────────────────────────────────────────────────────
echo "=== swift: skill uses module-graph descriptions ==="

# Set up a minimal Xcode-style Swift project
setup_sandbox
rm -f "$SANDBOX/package.json" "$SANDBOX/src/index.ts" "$SANDBOX/src/Main.kt"
mkdir -p "$SANDBOX/MyApp.xcodeproj"
# Minimal .pbxproj with a PBXNativeTarget (application)
cat > "$SANDBOX/MyApp.xcodeproj/project.pbxproj" <<'PBXPROJ'
{
    objects = {
        AABBCCDD = {isa = PBXNativeTarget; name = "MyApp"; productType = "com.apple.product-type.application"; };
    };
}
PBXPROJ
mkdir -p "$SANDBOX/MyApp"
echo '@main struct MyAppApp: App { var body: some Scene { WindowGroup {} } }' > "$SANDBOX/MyApp/MyApp.swift"

(cd "$SANDBOX" && bash "$DISCOVER_BIN" init swift --force 2>&1) >/dev/null

swift_skill="$(cat "$SANDBOX/.claude/skills/discover/swift/SKILL.md")"

# Verify Swift-specific descriptions replace generic import-graph descriptions
assert_contains "swift skill warns about module membership" \
    "module membership" \
    "$swift_skill"

assert_contains "swift skill describes call-chain tracing" \
    "call chain" \
    "$swift_skill"

assert_not_contains "swift skill does not claim BFS from entry point" \
    "BFS from the entry point" \
    "$swift_skill"

report
