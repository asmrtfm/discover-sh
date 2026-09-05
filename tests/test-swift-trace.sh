#!/usr/bin/env bash
# test-swift-trace.sh — tests for Swift call-chain tracing (cmd_trace)
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_lang swift

FIXTURE_DIR="$TESTS_DIR/fixtures/swift-trace"

# Override REPO_ROOT to point at the trace fixture
export REPO_ROOT="$FIXTURE_DIR"
export SRC_DIR="$FIXTURE_DIR"

echo "=== _swift_containing_function ==="

# Recipe.swift line 7 (0-indexed) is inside resolveRelationships (lines 5-9)
container="$(_swift_containing_function "$FIXTURE_DIR/Models/Recipe.swift" 7)"
assert_eq "finds resolveRelationships as container" \
    "resolveRelationships" "$container"

# APIService.swift line 6 (0-indexed) is inside getDrinksBatch
container="$(_swift_containing_function "$FIXTURE_DIR/Services/APIService.swift" 6)"
assert_eq "finds getDrinksBatch definition as container" \
    "getDrinksBatch" "$container"

# Top-level line (line 0 = import) should return empty
container="$(_swift_containing_function "$FIXTURE_DIR/Models/Recipe.swift" 0)"
assert_eq "top-level line returns empty" "" "$container"

echo "=== _swift_containing_type ==="

# Recipe.swift line 7 is inside class Recipe
type_name="$(_swift_containing_type "$FIXTURE_DIR/Models/Recipe.swift" 7)"
assert_eq "finds Recipe as containing type" "Recipe" "$type_name"

# Top-level in APIService.swift: line 3 (static let) is inside APIService
type_name="$(_swift_containing_type "$FIXTURE_DIR/Services/APIService.swift" 5)"
assert_eq "finds APIService as containing type" "APIService" "$type_name"

echo "=== trace: finds all callsites ==="

trace_output="$(cmd_trace getDrinksBatch --json 2>/dev/null)"

# Should find 5 callsites (not the definition)
callsite_count="$(echo "$trace_output" | jq 'length')"
assert_eq "5 callsites traced" "5" "$callsite_count"

echo "=== trace: skips definitions ==="

# The definition in APIService.swift should NOT appear as a callsite
has_definition="$(echo "$trace_output" | jq '[.[] | select(.callsite.file | endswith("APIService.swift"))] | length')"
assert_eq "no APIService.swift callsites (definition skipped)" "0" "$has_definition"

echo "=== trace: identifies dead code ==="

# UnusedHelper.processLegacyDrinks has no callers
dead_status="$(echo "$trace_output" | jq -r '[.[] | select(.callsite.file | endswith("UnusedHelper.swift"))][0].status')"
assert_eq "dead code detected as end" "end" "$dead_status"

dead_note="$(echo "$trace_output" | jq -r '[.[] | select(.callsite.file | endswith("UnusedHelper.swift"))][0].chain[0].note')"
assert_contains "dead code note says no callers" "no callers" "$dead_note"

echo "=== trace: follows call chain upward ==="

# Recipe.swift → resolveRelationships → merge → synchronizeVenueDrinks → synchronizeVenueData
recipe_chain="$(echo "$trace_output" | jq '[.[] | select(.callsite.file | endswith("Recipe.swift"))][0]')"

recipe_depth="$(echo "$recipe_chain" | jq '.depth')"
assert_eq "recipe chain depth is 3" "3" "$recipe_depth"

recipe_first="$(echo "$recipe_chain" | jq -r '.chain[0].function')"
assert_eq "first in chain is resolveRelationships" "resolveRelationships" "$recipe_first"

recipe_second="$(echo "$recipe_chain" | jq -r '.chain[0].called_by')"
assert_contains "resolveRelationships called by merge" "merge" "$recipe_second"

echo "=== trace: qualified function names ==="

# Callsite container should include type name
recipe_container="$(echo "$recipe_chain" | jq -r '.callsite.in_function')"
assert_eq "container is Type.method" "Recipe.resolveRelationships" "$recipe_container"

echo "=== trace: VenueService chain ==="

# VenueService.synchronizeVenueDrinks → synchronizeVenueData
venue_chain="$(echo "$trace_output" | jq '[.[] | select(.callsite.file | endswith("VenueService.swift"))][0]')"
venue_depth="$(echo "$venue_chain" | jq '.depth')"
assert_eq "venue chain depth is 1" "1" "$venue_depth"

venue_caller="$(echo "$venue_chain" | jq -r '.chain[0].called_by')"
assert_contains "synchronizeVenueDrinks called by synchronizeVenueData" \
    "synchronizeVenueData" "$venue_caller"

report
