//! discover-dart — deterministic Dart codebase navigation, in-process on
//! ast-grep's Dart support. A port of discover.sh: same subcommands, flags,
//! JSON shapes and stderr commentary, with each file parsed once instead of
//! once per query. The subcommands that only need the graph come from
//! discover-core; the Dart-specific ones are here.
//!
//! Subcommands:
//!   resolve <uri> [--from <file>]
//!   inspect <file> [--imports] [--exports] [--parts] [--entities] [--depth names|signatures|full]
//!   definition <file> <symbol>
//!   live-files
//!   dead-files [--rebuild]
//!   is-live <file>
//!   importers <file>
//!   trace <file>
//!   prune <file>
//!   usages <pattern> [--live-only]
//!   usages --assets <asset-path>

mod dart;
mod graph;
mod project;
mod usages;

use dart::Directive;
use discover_core::cli::{
  self, DefinitionOut, EntityOut, UsagesArgs, file_arg, out, out_json, parse_inspect, parse_resolve, parse_usages,
};
use graph::{DartLang, Graph};
use project::Project;
use serde::Serialize;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "usage: discover-dart [--rebuild-cache] <command> [args]

global flags:
  --rebuild-cache                        Wipe and rebuild all caches before running command

commands:
  resolve <uri> [--from <file>]          Resolve import URI to repo-relative path
  inspect <file> [--imports] [--exports] [--parts] [--entities]
           [--depth names|signatures|full]
  definition <file> <symbol>             Find where a symbol used in <file> is defined
  live-files                             List all files reachable from main.dart
  dead-files [--rebuild]                 List all dead files (verified by recursive trace)
  is-live <file>                         Check if a file is reachable from main.dart
  importers <file>                       Find all files that import/export <file>
  trace <file>                           Trace usage and liveness of a file's import chain
  prune <file>                           Remove a file entry from caches without rebuilding
  usages <pattern> [--live-only]         Find all references to an ast-grep pattern
  usages --assets <asset-path>           Check if an asset is referenced in live code";

fn main() -> ExitCode {
  cli::main(USAGE, |_| Ok(graph::open(Project::discover()?)), |graph, command, args| {
    match command {
      "resolve" => cmd_resolve(graph, args),
      "inspect" => cmd_inspect(graph, args),
      "definition" => cmd_definition(graph, args),
      "usages" => cmd_usages(graph, args),
      _ => unreachable!("checked against COMMANDS"),
    }
  })
}

// ─────────────────────────────────────────────────────────
// resolve
// ─────────────────────────────────────────────────────────
fn cmd_resolve(graph: &Graph, args: &[String]) -> Result<u8, String> {
  let (uri, from) = parse_resolve::<DartLang>(args, "<uri>")?;
  if let Some(resolved) = graph.project.resolve_uri(uri, from) {
    out(&resolved);
  }
  Ok(0)
}

// ─────────────────────────────────────────────────────────
// inspect
// ─────────────────────────────────────────────────────────
#[derive(Serialize)]
struct DirectiveOut {
  uri: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  resolved: Option<String>,
}

#[derive(Serialize)]
struct InspectOut<'a> {
  file: &'a str,
  #[serde(skip_serializing_if = "Option::is_none")]
  imports: Option<Vec<DirectiveOut>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  exports: Option<Vec<DirectiveOut>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  parts: Option<Vec<DirectiveOut>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  entities: Option<Vec<EntityOut<'a>>>,
}

fn cmd_inspect(graph: &Graph, args: &[String]) -> Result<u8, String> {
  let parsed = parse_inspect(args, &["--imports", "--exports", "--parts"]);
  let file = parsed.file.ok_or(
    "usage: discover-dart inspect <file> [--imports] [--exports] [--parts] [--entities] [--depth names|signatures|full]",
  )?;
  let [imports, exports, parts] = parsed.sections[..] else {
    unreachable!("one flag per section")
  };
  let (entities, depth) = (parsed.entities, parsed.depth.as_str());
  let (path, rel) = file_arg(&graph.project.root, file)?;
  let facts = graph.facts(&path);

  // --entities name: plain text, one name per line, no JSON wrapper.
  if entities && depth == "name" {
    facts.entities.iter().for_each(|e| out(&e.name));
    return Ok(0);
  }

  let directive = |d: Directive| {
    facts
      .uris(d)
      .iter()
      .map(|uri| DirectiveOut {
        uri: uri.clone(),
        resolved: graph.project.resolve_uri(uri, &rel),
      })
      .collect::<Vec<_>>()
  };
  out_json(&InspectOut {
    file: &rel,
    imports: imports.then(|| directive(Directive::Import)),
    exports: exports.then(|| directive(Directive::Export)),
    parts: parts.then(|| directive(Directive::Part)),
    entities: entities.then(|| {
      facts
        .entities
        .iter()
        .map(|e| EntityOut::new(e.kind, &e.name, e.line, &e.header, &e.full, depth))
        .collect()
    }),
  });
  Ok(0)
}

// ─────────────────────────────────────────────────────────
// definition — local entities first, then each import,
// following re-exports; then part files
// ─────────────────────────────────────────────────────────
fn cmd_definition(graph: &Graph, args: &[String]) -> Result<u8, String> {
  let (Some(file), Some(symbol)) = (args.first(), args.get(1)) else {
    return Err("usage: discover-dart definition <file> <symbol>".into());
  };
  let (path, rel) = file_arg(&graph.project.root, file)?;
  let facts = graph.facts(&path);

  if let Some(e) = facts.entity(symbol) {
    out_json(&DefinitionOut {
      symbol,
      kind: e.kind,
      file: &rel,
      line: e.line,
      via: None,
      source: Some("local"),
    });
    return Ok(0);
  }

  let mut visited = HashSet::new();
  let searches = [(Directive::Import, Vec::new()), (Directive::Part, vec!["(part)".to_string()])];
  for (directive, via) in searches {
    for uri in facts.uris(directive) {
      let Some(resolved) = graph.project.resolve_uri(uri, &rel) else {
        continue;
      };
      if search_definition(graph, symbol, &graph.project.root.join(resolved), &via, &mut visited) {
        return Ok(0);
      }
    }
  }

  out_json(&serde_json::json!({ "symbol": symbol, "error": "not found in import graph" }));
  Ok(1)
}

/// Looks for `symbol` among a file's entities, then down its re-exports.
/// `via` is the chain of re-exporting files walked so far.
fn search_definition(
  graph: &Graph,
  symbol: &str,
  path: &Path,
  via: &[String],
  visited: &mut HashSet<PathBuf>,
) -> bool {
  let Ok(path) = std::fs::canonicalize(path) else {
    return false;
  };
  if !path.is_file() || !visited.insert(path.clone()) {
    return false;
  }
  let rel = graph.project.rel(&path);
  let facts = graph.facts(&path);
  if let Some(e) = facts.entity(symbol) {
    out_json(&DefinitionOut {
      symbol,
      kind: e.kind,
      file: &rel,
      line: e.line,
      via: Some(via),
      source: None,
    });
    return true;
  }
  for uri in facts.uris(Directive::Export) {
    let Some(target) = graph.resolve(uri, &rel) else {
      continue;
    };
    let mut chain = via.to_vec();
    chain.push(rel.clone());
    if search_definition(graph, symbol, &target, &chain, visited) {
      return true;
    }
  }
  false
}

// ─────────────────────────────────────────────────────────
// usages
// ─────────────────────────────────────────────────────────
fn cmd_usages(graph: &Graph, args: &[String]) -> Result<u8, String> {
  match parse_usages::<DartLang>(args)? {
    UsagesArgs::Assets(asset) => {
      let refs = usages::asset_usages(graph, asset)?;
      out_json(&refs);
      eprintln!(
        "{} constant ref(s), {} direct ref(s)",
        refs.constant_refs.len(),
        refs.direct_refs.len()
      );
    }
    UsagesArgs::Pattern { pattern, live_only } => {
      cli::print_usages(&usages::pattern_usages(graph, pattern, live_only)?);
    }
  }
  Ok(0)
}
