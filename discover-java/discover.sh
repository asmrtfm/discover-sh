#!/usr/bin/env bash

# discover.sh — deterministic Java codebase navigation using ast-grep.
#
# Subcommands:
#   resolve <import> [--from <file>]
#   inspect <file> [--package] [--imports] [--entities] [--depth names|signatures|full]
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
# Java imports name types (com.example.Foo, or a static member such as
# com.example.Foo.bar), not files, and a file may use any type in its own
# package without importing it. So instead of mapping import strings to
# paths, discover indexes every source file's package and top-level types
# and resolves names against that index. A file depends on another when it
# imports one of its types, or uses one by name through its own package or
# a wildcard import.
#
# Nothing project-specific is hardcoded; it is all read from the project:
#   source files — *.java the project hasn't gitignored (tests and buildSrc excluded)
#   packages     — each file's `package` declaration
#   entry points — $DISCOVER_ENTRY, else every `main` method, Android
#                  manifest components and META-INF/services providers


# TODO: add something like knowledge's index updating directives
#       so we can selectively prune the cache and update the fingerprint instead of rebuilding after every change.

# The script lives one level below the project root (bin/ or scripts/), so the
# root is the parent of its own directory unless REPO_ROOT is already set.
SELF="$(realpath "${BASH_SOURCE[0]}")"
[[ -n $REPO_ROOT ]] || REPO_ROOT="$(dirname "${SELF%\/*}")"

LANG_ID="java"
SRC_GLOB='*.java'

# Overridable like REPO_ROOT, e.g. to keep caches out of a project's tmp/.
[[ -n $CACHE_DIR ]] || CACHE_DIR="$REPO_ROOT/tmp"

# Prefixed with the language so a multi-language project's caches don't collide.
INDEX_FILE="$CACHE_DIR/discover_${LANG_ID}_index.json"
EDGES_FILE="$CACHE_DIR/discover_${LANG_ID}_edges.jsonl"
CACHE_FILE="$CACHE_DIR/discover_${LANG_ID}_live_cache.txt"
DEAD_LIST="$CACHE_DIR/discover_${LANG_ID}_dead.txt"
IMPORTERS_CACHE_FILE="$CACHE_DIR/discover_${LANG_ID}_importers_cache.json"


die() { echo "error: $*" >&2; exit 1; }

# Every query shells out to ast-grep with stderr silenced, so a missing binary
# would otherwise produce empty results and poison the caches with them.
command -v ast-grep >/dev/null 2>&1 || die "ast-grep not found on PATH"

# The cache dir must exist before anything redirects into it: `fn > "$CACHE_FILE"`
# opens the target before fn's own mkdir runs.
mkdir -p "$CACHE_DIR" || die "cannot create cache dir: $CACHE_DIR"


# ─────────────────────────────────────────────────────────
# File listings. git's view is used when available so build
# output and anything else the project ignores never enters
# the graph. Prints repo-relative paths, NUL-delimited.
# ─────────────────────────────────────────────────────────
_source_listing() {
  local -i i
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$REPO_ROOT" ls-files -z -co --exclude-standard -- "$@" 2>/dev/null
  else
    # Without git there is no ignore list, so at least skip build output.
    local -a expr=()
    for ((i=1;i<=$#;i++)); do
      ((i == 1)) || expr[${#expr[@]}]="-o"
      expr[${#expr[@]}]="-path"
      expr[${#expr[@]}]="$REPO_ROOT/${!i}"
    done
    find "$REPO_ROOT" \( -name build -o -name .gradle -o -name .git \) -prune -o -type f \( "${expr[@]}" \) -printf '%P\0'
  fi
}

# Drops test sources (src/test, src/androidTest, src/testFixtures, …) and
# Gradle build logic (buildSrc): neither is reachable from the app's entry
# points. Also drops index entries git still lists after a file's deletion.
_app_only() {
  local f
  while IFS= read -r -d '' f; do
    [[ ! "$f" =~ (^|/)src/[^/]*[Tt]est[^/]*/ && ! "$f" =~ (^|/)buildSrc/ ]] || continue
    [[ ! -f "$REPO_ROOT/$f" ]] || printf '%s\0' "$f"
  done
}

# Absolute paths of the source files under analysis.
relavent_files() {
  local f
  while IFS= read -r -d '' f; do
    printf '%s\0' "$REPO_ROOT/$f"
  done < <(_source_listing "$SRC_GLOB" | _app_only) | sort -z
}

# Repo-relative paths of the files that declare framework entry points.
manifest_files() { _source_listing '*AndroidManifest.xml' | _app_only; }
service_files() { _source_listing '*META-INF/services/*' | _app_only; }

blank_() { [[ -z "$1" || "$1" == "[]" ]]; }
present_() { [[ -n "$1" && "$1" != "[]" ]]; }


# ─────────────────────────────────────────────────────────
# Cache validity. Unlike file-path languages, a JVM file's
# dependencies change when ANY file in its package gains or
# loses a declaration, so the fingerprint covers every source
# file's mtime and size (plus the entry-point declarations),
# not just the listing. Each cache is stamped with the
# fingerprint it was built from (<cache>.fp).
# ─────────────────────────────────────────────────────────
compute_fingerprint() {
  {
    relavent_files | xargs -0 -r stat -c '%Y %s %n'
    { manifest_files; service_files; } | while IFS= read -r -d '' f; do stat -c '%Y %s %n' "$REPO_ROOT/$f"; done
    echo "$DISCOVER_ENTRY"
  } | md5sum | cut -d' ' -f1
}

cache_is_valid() { [[ -f "$1" && -f "$1.fp" && "$(< "$1.fp")" == "$SOURCE_FP" ]]; }

stamp_cache() { echo "$SOURCE_FP" > "$1.fp"; }


# ─────────────────────────────────────────────────────────
# ast-grep rules
# ─────────────────────────────────────────────────────────

# Per-file facts for the index, one rule id per fact:
#   package  — the `package` declaration's name
#   import   — each import declaration (`static`, path, `.*`)
#   main     — a `main` method: static, or (Java 21+ compact source files)
#              declared at the top level
#   class/interface/enum/record/annotation — top-level type declarations
# Only top-level types are indexed; nested ones are reached through them
# (`import a.Outer.Inner` resolves to Outer's file).
INDEX_RULES='id: package
language: java
rule:
  any: [kind: scoped_identifier, kind: identifier]
  inside: { kind: package_declaration }
---
id: import
language: java
rule:
  kind: import_declaration
---
id: main
language: java
rule:
  kind: method_declaration
  has: { field: name, regex: ^main$ }
  any:
    - has: { kind: modifiers, regex: \bstatic\b }
    - inside: { kind: program }
---
id: class
language: java
rule:
  kind: class_declaration
  inside: { kind: program }
  has: { field: name, pattern: $NAME }
---
id: interface
language: java
rule:
  kind: interface_declaration
  inside: { kind: program }
  has: { field: name, pattern: $NAME }
---
id: enum
language: java
rule:
  kind: enum_declaration
  inside: { kind: program }
  has: { field: name, pattern: $NAME }
---
id: record
language: java
rule:
  kind: record_declaration
  inside: { kind: program }
  has: { field: name, pattern: $NAME }
---
id: annotation
language: java
rule:
  kind: annotation_type_declaration
  inside: { kind: program }
  has: { field: name, pattern: $NAME }'

# Rule ids of INDEX_RULES that are declarations (entities).
ENTITY_IDS='["class","interface","enum","record","annotation"]'

# References to project names: every identifier whose text is one of the
# names a cross-file reference could use (__NAMES__ is filled with them),
# outside the package and import declarations. Covers type positions
# (type_identifier) and expressions (`Foo.bar()`, static-imported members).
IDENT_RULES='id: ident
language: java
rule:
  any: [kind: identifier, kind: type_identifier]
  regex: ^(__NAMES__)$
  not:
    inside: { any: [kind: import_declaration, kind: package_declaration], stopBy: end }'

# String literal contents (for asset paths).
STRING_KIND="string_fragment"

# jq helpers shared by the index and entity extraction.
#   parse_import — `import static a.b.C.m;` → {spec, path, wildcard, alias, static}
#                  (Java has no import aliases; alias is always null)
#   entity_kind  — display kind for a declaration (the rule id says it all)
JQ_LANG='
def parse_import:
  (sub("^\\s*import\\s+"; "") | sub("\\s*;\\s*$"; "")) as $spec
  | ($spec | test("^static\\s")) as $static
  | ($spec | sub("^static\\s+"; "") | gsub("\\s"; "")) as $path
  | {spec: $spec, path: ($path | sub("\\.\\*$"; "")), wildcard: ($path | endswith(".*")), alias: null, static: $static};
def entity_kind($id; $header): $id;
'

# Shared jq: entity record from an ast-grep match. The header is the first
# line containing the name (annotations come first in the node). A
# declaration is private when `private` appears before its name; Java
# doesn't allow private top-level types, so this only guards against
# misparses and is normally false.
JQ_ENTITY="$JQ_LANG"'
def entity($depth):
  .metaVariables.single.NAME.text as $n
  | (.text | split("\n")) as $lines
  | (([$lines[] | select(contains($n))] | first) // $lines[0]) as $header
  | {
      kind: entity_kind(.ruleId; $header),
      name: $n,
      line: (.range.start.line + 1),
      private: (.text | split($n)[0] | test("\\bprivate\\b")),
      text: (
          if $depth == "full" then .text
          elif $depth == "signatures" then $header
          else null
          end
      )
  };
'

# Shared jq over the index ($I): lookup tables and name resolution.
#   $fqn  — fully-qualified name → [files declaring it] (public declarations only)
#   $pkgs — package → [files]
#   lookup($spec; $from) — resolves an import path (`a.b.C`, `a.b.*`) or,
#     with $from, a simple name as seen from that file. Emits
#     {file, via, fqn, name, member}: `via` says how the name became
#     visible (local | import | package | wildcard), `name` is the
#     declaration's own name, `member` the part of an import past the
#     declaration (a nested type or static member).
JQ_INDEX='
($I | to_entries) as $E
| (reduce $E[] as $e ({};
    reduce ($e.value.decls[] | select(.private | not)) as $d (.;
      .[(if $e.value.pkg == "" then "" else $e.value.pkg + "." end) + $d.name] += [$e.key]))) as $fqn
| (reduce $E[] as $e ({}; .[$e.value.pkg] += [$e.key])) as $pkgs
| def public_names($t): [$I[$t].decls[] | select(.private | not) | .name] | unique;
  def longest($path):
    ($path | split(".")) as $parts
    | [range($parts | length; 0; -1) as $n | $parts[:$n] | join(".") | select($fqn[.] != null)] | first;
  def qualified($path; $via):
    longest($path) as $cand
    | if $cand == null then empty else
        $fqn[$cand][] | {file: ., via: $via, fqn: $cand, name: ($cand | split(".") | last),
                         member: (if $cand == $path then null else $path[($cand | length) + 1:] end)}
      end;
  def in_package($pkg; $name):
    ($pkgs[$pkg] // [])[] | select(public_names(.) | index($name))
    | {file: ., via: "package", fqn: ((if $pkg == "" then "" else $pkg + "." end) + $name), name: $name, member: null};
  def lookup($spec; $from):
    if $from == "" or ($spec | contains(".")) then
      if ($spec | endswith(".*")) then
        ($spec | sub("\\.\\*$"; "")) as $p
        | (($pkgs[$p] // []) + ($fqn[$p] // []))[] | {file: ., via: "wildcard", fqn: $p, name: null, member: null}
      else qualified($spec; "import") end
    else
      $I[$from] as $me
      | [$me.decls[] | select(.name == $spec) | {file: $from, via: "local", fqn: $spec, name: $spec, member: null}] as $own
      | [$me.imports[] | select((.wildcard | not) and ((.alias // (.path | split(".") | last)) == $spec)) | qualified(.path; "import")] as $imported
      | [in_package($me.pkg; $spec) | select(.file != $from)] as $pkg
      | [$me.imports[] | select(.wildcard) | .path as $w
          | (in_package($w; $spec) | .via = "wildcard"),
            (($fqn[$w] // [])[] | {file: ., via: "wildcard", fqn: $w, name: ($w | split(".") | last), member: $spec})] as $wild
      | [$own, $imported, $pkg, $wild] | map(select(length > 0)) | first // [] | .[]
    end;
'


# ─────────────────────────────────────────────────────────
# Index: per source file, its package, imports, top-level
# declarations and whether it holds a `main`.
#   { "<file>": {pkg, imports: [...], decls: [{name, kind, line, private}], main} }
# Built with one ast-grep pass over all sources.
# ─────────────────────────────────────────────────────────
build_index() {
  echo "index: rebuilding" >&2
  local tmp_file="$(mktemp)"
  relavent_files | xargs -0 -r ast-grep scan --inline-rules "$INDEX_RULES" --json=stream 2>/dev/null > "$tmp_file"

  # Seed every file so files with no matches still appear (default package "").
  relavent_files | tr '\0' '\n' | jq -Rn --arg root "$REPO_ROOT/" --slurpfile m "$tmp_file" \
      --argjson eids "$ENTITY_IDS" "$JQ_ENTITY"'
    (reduce inputs as $f ({}; .[$f | ltrimstr($root)] = {pkg: "", imports: [], decls: [], main: false}))
    | reduce $m[] as $x (.;
        ($x.file | ltrimstr($root)) as $f
        | if .[$f] == null then .
          elif $x.ruleId == "package" then .[$f].pkg = ($x.text | gsub("[\\s`]"; ""))
          elif $x.ruleId == "import" then .[$f].imports += [$x.text | parse_import]
          elif $x.ruleId == "main" then .[$f].main = true
          elif ($eids | index($x.ruleId)) then .[$f].decls += [$x | entity("names") | del(.text)]
          else . end)
    | map_values(.decls |= sort_by(.line))'

  rm -f "$tmp_file"
}

_build_index() {
  rm -f "$INDEX_FILE" 2>/dev/null
  build_index > "$INDEX_FILE" && stamp_cache "$INDEX_FILE"
}

# Every lookup needs the index, so it is (re)built up front.
ensure_index() {
  cache_is_valid "$INDEX_FILE" || _build_index
}

# jq_index <jq-program> [jq args...] — runs a program with the index bound to
# $I and the JQ_INDEX helpers in scope. JQ_INDEX ends in definitions, which
# must be followed directly by an expression, so the program is appended
# without a pipe.
jq_index() {
  local prog="$1"; shift
  jq -n --slurpfile _i "$INDEX_FILE" "$@" '$_i[0] as $I | '"$JQ_INDEX $prog"
}


# ─────────────────────────────────────────────────────────
# Entry points — the JVM analog of lib/main.dart, the roots
# of liveness. DISCOVER_ENTRY (repo-relative files) overrides
# everything; otherwise every root the runtime itself starts
# from is one:
#   - files declaring a `main` function
#   - Android manifest components (application, activity,
#     service, receiver, provider, instrumentation), which the
#     OS instantiates by name
#   - META-INF/services providers, which ServiceLoader
#     instantiates by name
# Classes reached only through reflection or DI annotation
# scanning can't be seen — list them in DISCOVER_ENTRY.
# ─────────────────────────────────────────────────────────
declare -a ENTRY_FILES=()
declare -A ENTRY_SET=()

add_entry() {
  [[ -n "$1" && ! -v ENTRY_SET["$1"] ]] || return 0
  ENTRY_SET["$1"]=1
  ENTRY_FILES[${#ENTRY_FILES[@]}]="$REPO_ROOT/$1"
}

# Fully-qualified class names a manifest declares. Relative names (`.Foo`,
# or no dot at all) are relative to the app's package: the manifest's
# `package` attribute, or the module's Gradle `namespace` in AGP 7+.
manifest_components() {
  local m mod pkg body name
  while IFS= read -r -d '' m; do
    # One line, comments removed, so attributes split across lines and
    # commented-out components don't confuse the tag matching below.
    body="$(tr '\n' ' ' < "$REPO_ROOT/$m" | sed -E 's/<!--([^-]|-[^-])*-->//g')"
    pkg="$(grep -oE '<manifest[[:space:]][^>]*' <<< "$body" | grep -oE '[[:space:]]package="[^"]+"' | cut -d'"' -f2)"
    if [[ -z "$pkg" ]]; then
      # <module>/src/<sourceSet>/AndroidManifest.xml, or a legacy module-root manifest.
      case "$m" in
      src/*) mod="." ;;
      */src/*) mod="${m%%/src/*}" ;;
      *) mod="$(dirname "$m")" ;;
      esac
      pkg="$(cat "$REPO_ROOT/$mod/build.gradle" "$REPO_ROOT/$mod/build.gradle.kts" 2>/dev/null \
          | grep -oE "^[[:space:]]*namespace[[:space:]]*=?[[:space:]]*[\"'][^\"']+" | head -1 | sed -E "s/.*[\"']//")"
    fi
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      # Nested classes are written Outer$Inner in manifests.
      name="${name//\$/.}"
      case "$name" in
      .*) name="$pkg$name" ;;
      *.*) ;;
      *) name="$pkg.$name" ;;
      esac
      echo "$name"
    done < <(grep -oE '<(application|activity|activity-alias|service|receiver|provider|instrumentation)[[:space:]][^>]*' <<< "$body" \
        | grep -oE 'android:name="[^"]+"' | cut -d'"' -f2)
  done < <(manifest_files)
}

# Fully-qualified class names listed in META-INF/services files.
service_providers() {
  local f
  while IFS= read -r -d '' f; do
    sed -e 's/#.*//' -e 's/[[:space:]]//g' -e 's/\$/./g' "$REPO_ROOT/$f" | grep -v '^$'
  done < <(service_files)
}

detect_entries() {
  local rel
  local -a words=()
  local -i i

  if [[ -n "$DISCOVER_ENTRY" ]]; then
    read -ra words <<< "$DISCOVER_ENTRY"
    for ((i=0;i<${#words[@]};i++)); do
      [[ -f "$(to_abs "${words[$i]}")" ]] || die "DISCOVER_ENTRY file not found: ${words[$i]}"
      add_entry "$(to_rel "${words[$i]}")"
    done
    return
  fi

  # Names that aren't declared in the project (library components such as
  # androidx's FileProvider) simply don't resolve.
  while IFS= read -r rel; do
    add_entry "$rel"
  done < <({ manifest_components; service_providers; } | jq -R . | jq -s -c . \
      | jq_index '([$I | to_entries[] | select(.value.main) | .key] + [$names[0][] | $fqn[.] // [] | .[]]) | unique[]' \
          --slurpfile names /dev/stdin -r)
}

require_entries() {
  ((${#ENTRY_FILES[@]} > 0)) || die "no entry point found (set DISCOVER_ENTRY to the repo-relative entry file(s))"
}


# ─────────────────────────────────────────────────────────
# Edges: every dependency between source files, one JSON
# object per line:
#   {file, target, directive, uri, entities_used}
# directive is how the target became visible to the file:
#   import  — an explicit import (wildcards included)
#   package — the same package, no import needed
# entities_used are the target's declarations the file
# actually references. Explicit single-name imports are edges
# even when unused (stale); package and wildcard visibility
# only counts when something is used.
# Built from the index plus one ast-grep pass collecting the
# project names each file references.
# ─────────────────────────────────────────────────────────
build_edges() {
  echo "edges: rebuilding" >&2
  local names used_file="$(mktemp)" rule_file="$(mktemp --suffix=.yml)"

  # Every name a cross-file reference could use: top-level types, and the
  # leaf of each explicit import (static members and nested types included,
  # which aren't indexed declarations themselves).
  names="$(jq -r '[.[] | (.decls[] | select(.private | not) | .name),
      (.imports[] | select(.wildcard | not) | (.alias // (.path | split(".") | last)))]
      | map(select(test("^\\w+$"))) | unique | join("|")' "$INDEX_FILE")"

  if [[ -n "$names" ]]; then
    # The rule goes through a file: with every project name in its regex it
    # can outgrow the kernel's 128 KB limit on a single argument, and the
    # failed launch would be silent (stderr is discarded) and drop every
    # package/wildcard edge.
    echo "${IDENT_RULES//__NAMES__/$names}" > "$rule_file"
    # file → {name: true} for each project name it references.
    relavent_files | xargs -0 -r ast-grep scan --rule "$rule_file" --json=stream 2>/dev/null \
      | jq -n --arg root "$REPO_ROOT/" 'reduce inputs as $m ({}; .[$m.file | ltrimstr($root)][$m.text] = true)' > "$used_file"
  else
    echo "{}" > "$used_file"
  fi

  jq_index '
    $used[0] as $U
    | [ $E[] | .key as $file | .value as $me | ($U[$file] // {}) as $u
        | (
            # Explicit imports: the declaration (or the one holding the imported member).
            ( $me.imports[] | select(.wildcard | not) | . as $imp
              | ($imp.alias // ($imp.path | split(".") | last)) as $local
              | qualified($imp.path; "import") | select(.file != $file) | . as $hit
              | {file: $file, target: $hit.file, directive: "import", uri: $imp.spec,
                 entities_used: ([public_names($hit.file)[] | select($u[.])] + (if $u[$local] then [$hit.name] else [] end) | unique)} ),
            # Wildcard imports: a whole package (counts only when used), or a
            # declaration`s members (always counts, its members are not indexed).
            ( $me.imports[] | select(.wildcard) | . as $imp
              | ((($fqn[$imp.path] // []) | map({t: ., always: true})) + (($pkgs[$imp.path] // []) | map({t: ., always: false})))[]
              | select(.t != $file) | . as $c
              | [public_names($c.t)[] | select($u[.])] as $hit
              | select($c.always or ($hit | length > 0))
              | {file: $file, target: $c.t, directive: "import", uri: $imp.spec, entities_used: $hit} ),
            # Same package, no import: counts only when used.
            ( ($pkgs[$me.pkg] // [])[] | select(. != $file) | . as $t
              | [public_names($t)[] | select($u[.])] as $hit
              | select($hit | length > 0)
              | {file: $file, target: $t, directive: "package", uri: $me.pkg, entities_used: $hit} )
          ) ]
    # One edge per (file, target), merging how it was reached.
    | group_by([.file, .target])[]
    | {file: .[0].file, target: .[0].target,
       directive: (map(.directive) | unique | join(",")),
       uri: (map(.uri) | unique | join(", ")),
       entities_used: (map(.entities_used[]) | unique)}
  ' --slurpfile used "$used_file" -c

  rm -f "$used_file" "$rule_file"
}

_build_edges() {
  rm -f "$EDGES_FILE" 2>/dev/null
  build_edges > "$EDGES_FILE" && stamp_cache "$EDGES_FILE"
}

get_edges() {
  [[ "$FORCE_REBUILD" != "true" && "$BUST_CACHE" != "true" ]] || rm -f "$EDGES_FILE" 2>/dev/null
  cache_is_valid "$EDGES_FILE" || _build_edges
}


# ─────────────────────────────────────────────────────────
# build_live_files — reachability from the entry points
# ─────────────────────────────────────────────────────────
build_live_cache() {
  echo "Building live-files cache" >&2
  require_entries
  get_edges

  # file → newline-separated targets
  local -A adj=()
  local f t
  while IFS=$'\t' read -r f t; do
    adj["$f"]+="$t"$'\n'
  done < <(jq -r '"\(.file)\t\(.target)"' "$EDGES_FILE")

  local -A live=()
  local -a queue=()
  local -i i
  for ((i=0;i<${#ENTRY_FILES[@]};i++)); do
    f="$(to_rel "${ENTRY_FILES[$i]}")"
    live["$f"]=1
    queue[${#queue[@]}]="$f"
  done

  local -i idx=0
  local current
  while (( idx < ${#queue[@]} )); do
    current="${queue[$idx]}"
    ((idx++))
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      if [[ ! -v live["$t"] ]]; then
        live["$t"]=1
        queue[${#queue[@]}]="$t"
      fi
    done <<< "${adj[$current]}"
  done

  printf '%s\n' "${!live[@]}" | sort

  echo "${#live[@]} live files" >&2
}


# Group the edges by target into the importers index:
#   { "<target>": [{file, directive, uri, entities_used}, ...] }
build_importers_cache() {
  echo "importers: rebuilding" >&2
  get_edges
  jq -s 'group_by(.target)
    | map({key: .[0].target, value: [.[] | {file, directive, uri, entities_used}]})
    | from_entries' "$EDGES_FILE"
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
# list of files that depend on it. Same fingerprint as every
# other cache (see compute_fingerprint).
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
# (The index is rebuilt before this runs, since every
# lookup — including entry detection — depends on it.)
# ─────────────────────────────────────────────────────────
build_all_caches() {
  _build_edges
  _build_live_cache
  _build_importers_cache
  _build_dead_cache
  (($? != 0)) || echo "Done." >&2
}



# ─────────────────────────────────────────────────────────
# resolve_uri <import> [<from-file-repo-relative>]
# Prints the repo-relative file(s) declaring an import path
# (`com.example.Foo`, `com.example.*`), or — with a from-file
# — a simple name as that file sees it. Prints nothing for
# names the project doesn't declare (stdlib, libraries).
# ─────────────────────────────────────────────────────────
resolve_uri() {
  jq_index '[lookup($spec; $from) | .file] | unique[]' --arg spec "$1" --arg from "$2" -r
}

# ─────────────────────────────────────────────────────────
# ast_grep_entities <absolute-file-path> <depth>
# Outputs JSON array of entities. depth: names | signatures | full
# ─────────────────────────────────────────────────────────
ast_grep_entities() {
    local file="$1" depth="${2:-names}"
    local raw="$(ast-grep scan --inline-rules "$INDEX_RULES" "$file" --json 2>/dev/null)"
    present_ "$raw" || { echo "[]"; return; }

    echo "$raw" | jq --arg depth "$depth" --argjson eids "$ENTITY_IDS" "$JQ_ENTITY"'
        [.[] | select(.ruleId as $id | $eids | index($id)) | entity($depth)]
        | sort_by(.line) | if .[0].text == null then [.[] | del(.text)] else . end'
}

# ─────────────────────────────────────────────────────────
# to_abs <file>
# ─────────────────────────────────────────────────────────
to_abs() { [[ "$1" == /* ]] && echo "$1" || echo "$REPO_ROOT/$1"; }

to_rel() { realpath --relative-to="$REPO_ROOT" "$(to_abs "$1")" 2>/dev/null; }

# Escape a string for use inside an ast-grep (Rust) regex.
regex_escape() { sed 's/[][\.*^$+?(){}|]/\\&/g' <<< "$1"; }

# Absolute paths of the live source files, NUL-delimited.
live_source_files() {
  local rel
  while IFS= read -r rel; do
    [[ "$rel" == $SRC_GLOB ]] && printf '%s\0' "$REPO_ROOT/$rel"
  done < <(get_live_cache 2>/dev/null)
}

# Formats ast-grep matches as [{file, line, text}] (repo-relative, sorted).
format_matches() {
  jq -s --arg root "$REPO_ROOT/" '[.[] | {
      file: (.file | ltrimstr($root)),
      line: (.range.start.line + 1),
      text: (.lines | split("\n")[0] | ltrimstr(" "))
  }] | unique_by("\(.file):\(.line)") | sort_by(.file, .line)'
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
  [[ -n "$uri" ]] || die "usage: discover.sh resolve <import> [--from <file>]"
  [[ -z "$from_file" ]] || from_file="$(to_rel "$from_file")"
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
    local file="" show_package=false show_imports=false show_entities=false depth="names"
    while [ $# -gt 0 ]; do
        case "$1" in
            --package)  show_package=true ;;
            --imports)  show_imports=true ;;
            --entities)
                show_entities=true
                case "${2:-}" in name|names|signatures|full) depth="$2"; shift ;; esac
                ;;
            --depth)    shift; depth="$1" ;;
            *) file="$1" ;;
        esac
        shift
    done
    [ -n "$file" ] || die "usage: discover.sh inspect <file> [--package] [--imports] [--entities] [--depth names|signatures|full]"

    if ! $show_package && ! $show_imports && ! $show_entities; then
        show_package=true; show_imports=true; show_entities=true
    fi

    local abs_file
    abs_file="$(to_abs "$file")"
    [ -f "$abs_file" ] || die "file not found: $file"

    local repo_rel
    repo_rel="$(to_rel "$file")"

    # --entities name: plain text, one name per line, no JSON wrapper
    if $show_entities && [[ "$depth" == "name" ]]; then
        ast_grep_entities "$abs_file" names | jq -r '.[].name'
        return
    fi

    # Package and imports come from the index; each import lists the
    # file(s) it resolves to (none for stdlib and libraries).
    local entities="null"
    ! $show_entities || entities="$(ast_grep_entities "$abs_file" "$depth")"
    jq_index '
        ($I[$f] // {pkg: null, imports: []}) as $me
        | {file: $f}
          + (if $sp then {package: $me.pkg} else {} end)
          + (if $si then {imports: [$me.imports[] | {uri: .spec}
                + ([lookup(if .wildcard then .path + ".*" else .path end; "") | .file] | unique
                   | if length == 0 then {} elif length == 1 then {resolved: .[0]} else {resolved: .} end)]}
             else {} end)
          + (if $ents != null then {entities: $ents} else {} end)
    ' --arg f "$repo_rel" --argjson sp "$show_package" --argjson si "$show_imports" --argjson ents "$entities"
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
# A Java name has no re-export chain to follow: it is
# declared in the file itself, imported (single-type or
# static), visible through the file's own package, or
# through an on-demand (`.*`) import. `via` reports which,
# in that precedence order.
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

    # Resolve through the index. An imported member (`import a.B.member`,
    # a wildcard over a declaration's members) reports the declaration
    # that holds it.
    local result
    result="$(jq_index '
        [lookup($sym; $from) | select(.via != "local") | . as $hit
         | ($I[$hit.file].decls[] | select(.name == ($hit.name // $sym))) as $d
         | {symbol: $sym, kind: $d.kind, file: $hit.file, line: $d.line, via: $hit.via}
           + (if $hit.member != null then {member_of: $d.name} else {} end)]
        | first // empty
    ' --arg sym "$symbol" --arg from "$repo_rel")"

    if [ -n "$result" ]; then
        echo "$result"
        return 0
    fi

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
# its dependency chain upward toward the entry points. Each
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
# Subcommand: prune — remove one file from every cache
# (after deleting it), so nothing has to be rebuilt.
# ─────────────────────────────────────────────────────────
cmd_prune() {
    local f="${1:?usage: discover.sh prune <file>}"
    # Drop the exact line from the live-files and dead-files lists.
    [[ -f "$CACHE_FILE" ]] && grep -vxF "$f" "$CACHE_FILE" > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
    [[ -f "$DEAD_LIST" ]] && grep -vxF "$f" "$DEAD_LIST" > "$DEAD_LIST.tmp"; [[ ! -f "$DEAD_LIST.tmp" ]] || mv "$DEAD_LIST.tmp" "$DEAD_LIST"
    # Remove as a target key and as an importer (.file) in other entries.
    [[ -f "$IMPORTERS_CACHE_FILE" ]] && jq --arg f "$f" 'del(.[$f]) | map_values([.[] | select(.file != $f)]) | with_entries(select(.value | length > 0))' "$IMPORTERS_CACHE_FILE" > "$IMPORTERS_CACHE_FILE.tmp" && mv "$IMPORTERS_CACHE_FILE.tmp" "$IMPORTERS_CACHE_FILE"
    # Remove from the index and from both ends of every edge.
    [[ -f "$INDEX_FILE" ]] && jq --arg f "$f" 'del(.[$f])' "$INDEX_FILE" > "$INDEX_FILE.tmp" && mv "$INDEX_FILE.tmp" "$INDEX_FILE"
    [[ -f "$EDGES_FILE" ]] && jq -c --arg f "$f" 'select(.file != $f and .target != $f)' "$EDGES_FILE" > "$EDGES_FILE.tmp" && mv "$EDGES_FILE.tmp" "$EDGES_FILE"
    # Stamp a fresh fingerprint so patched caches aren't treated as stale.
    SOURCE_FP="$(compute_fingerprint)"
    local c
    for c in "$INDEX_FILE" "$EDGES_FILE" "$CACHE_FILE" "$DEAD_LIST" "$IMPORTERS_CACHE_FILE"; do
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

  # Structural pass: ast-grep with the caller's pattern, over all sources
  # or only the live ones.
  local formatted
  if $live_only; then
    formatted="$(live_source_files | xargs -0 -r ast-grep run -l "$LANG_ID" -p "$pattern" --json=stream 2>/dev/null | format_matches)"
  else
    formatted="$(relavent_files | xargs -0 -r ast-grep run -l "$LANG_ID" -p "$pattern" --json=stream 2>/dev/null | format_matches)"
  fi

  # Results on stdout so they can be piped; the count is commentary.
  echo "$formatted"
  echo "$(echo "$formatted" | jq 'length') usages found" >&2
}

# --assets helper: given an asset path, find all live references to it.
# Reports three separate sections:
#   "constant_refs" — Android resources (res/<type>[-qualifiers]/<name>.<ext>)
#                     through their generated constant, R.<type>.<name>
#   "xml_refs"      — the same resources referenced from XML (@<type>/<name>)
#                     in resource files and manifests
#   "direct_refs"   — string literals naming the file: Android assets/ and JVM
#                     resources/ by their path inside that root (also matching
#                     longer forms such as file:///android_asset/<path> or a
#                     leading /), anything else by its repo-relative path
_usages_asset() {
  local asset_rel
  asset_rel="$(to_rel "$1")"
  [[ -f "$REPO_ROOT/$asset_rel" ]] || die "asset not found: $1"

  local res_type="" res_name="" literal=""
  if [[ "$asset_rel" =~ (^|/)res/([a-z]+)(-[^/]*)?/([^/]+)$ ]]; then
    res_type="${BASH_REMATCH[2]}"
    # foo.9.png → foo
    res_name="${BASH_REMATCH[4]%%.*}"
    [[ "$res_type" != values ]] || die "res/values files hold many resources; search one with: usages 'R.<type>.<name>'"
  elif [[ "$asset_rel" =~ (^|/)(assets|resources)/(.+)$ ]]; then
    literal="${BASH_REMATCH[3]}"
  else
    literal="$asset_rel"
  fi

  local constant_results="[]" xml_results="[]" direct_results="[]"

  if [[ -n "$res_type" ]]; then
    echo "constant: R.${res_type}.${res_name}" >&2
    constant_results="$(live_source_files | xargs -0 -r ast-grep run -l "$LANG_ID" -p "R.${res_type}.${res_name}" --json=stream 2>/dev/null | format_matches)"

    # XML has no grammar here; the reference syntax is a fixed string.
    local f
    xml_results="$(
      while IFS= read -r -d '' f; do
        [[ "$f" == */res/* || "$f" == res/* || "$f" == *AndroidManifest.xml ]] || continue
        grep -nF "@${res_type}/${res_name}" "$REPO_ROOT/$f" 2>/dev/null \
          | grep -E "@${res_type}/${res_name}([^A-Za-z0-9_]|\$)" \
          | jq -R --arg f "$f" 'capture("^(?<line>[0-9]+):(?<text>.*)$") | {file: $f, line: (.line | tonumber), text: (.text | ltrimstr(" ") | sub("^\\s+"; ""))}'
      done < <(_source_listing '*.xml' | _app_only) | jq -s 'sort_by(.file, .line)'
    )"
  else
    local rule="id: literal
language: ${LANG_ID}
rule:
  kind: ${STRING_KIND}
  regex: (^|/)$(regex_escape "$literal")\$"
    direct_results="$(live_source_files | xargs -0 -r ast-grep scan --inline-rules "$rule" --json=stream 2>/dev/null | format_matches)"
  fi

  # Output as distinct sections
  jq -n --argjson constant "$constant_results" --argjson xml "$xml_results" --argjson direct "$direct_results" \
      '{constant_refs: $constant, xml_refs: $xml, direct_refs: $direct}'

  echo "$(echo "$constant_results" | jq 'length') constant ref(s), $(echo "$xml_results" | jq 'length') xml ref(s), $(echo "$direct_results" | jq 'length') direct ref(s)" >&2
}


# ─────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────

# The index underlies every lookup, entry detection included, so it is
# brought up to date (or rebuilt for --rebuild-cache) before anything else.
SOURCE_FP="$(compute_fingerprint)"
[[ "$1" != "--rebuild-cache" ]] || rm -f "$INDEX_FILE"
ensure_index
detect_entries

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
        echo "  DISCOVER_ENTRY=\"<file> ...\"            Entry point(s), overriding main/manifest/services detection" >&2
        echo "" >&2
        echo "commands:" >&2
        echo "  resolve <import> [--from <file>]       Resolve an import (or, with --from, a name) to file(s)" >&2
        echo "  inspect <file> [--package] [--imports] [--entities]" >&2
        echo "           [--depth names|signatures|full]" >&2
        echo "  definition <file> <symbol>             Find where a symbol used in <file> is defined" >&2
        echo "  live-files                             List all files reachable from the entry points" >&2
        echo "  dead-files [--rebuild]                 List all dead files (verified by recursive trace)" >&2
        echo "  is-live <file>                         Check if a file is reachable from the entry points" >&2
        echo "  importers <file>                       Find all files that depend on <file>" >&2
        echo "  trace <file>                           Trace usage and liveness of a file's dependency chain" >&2
        echo "  prune <file>                           Remove a file entry from caches without rebuilding" >&2
        echo "  usages <pattern> [--live-only]         Find all references to an ast-grep pattern" >&2
        echo "  usages --assets <asset-path>           Check if an asset is referenced in live code" >&2
        exit 1
esac
