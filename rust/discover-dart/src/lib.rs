//! discover-dart — deterministic Dart codebase navigation, in-process on
//! ast-grep's Dart support. A port of discover.sh: same subcommands, flags,
//! JSON shapes and stderr commentary, with each file parsed once instead of
//! once per query. The subcommands that only need the graph come from
//! discover-core; the Dart-specific ones are here.
//!
//! Subcommands:
//!   resolve <uri> [--from <file>]
//!   inspect <file> [--imports] [--exports] [--parts] [--entities] [--depth names|signatures|full]
//!   definition <symbol> [<file>] [-v|--verbose] [-p|--pretty]
//!   live-files
//!   dead-files [--rebuild]
//!   is-live <file>
//!   importers [--strict] <files ...>
//!   trace [--strict] <files ...>
//!   prune [--strict] <files ...>
//!   usages <pattern> [--live-only] [-v|--verbose]
//!   usages --assets <asset-path>
//!   attributes <class> <file>

mod common;
pub mod dart;
mod graph;
mod project;
mod usages;

use dart::Directive;
use discover_core::cli::{
  self, DefinitionArgs, DefinitionOut, EntityOut, UsagesArgs, file_arg, out, out_definition, out_json,
  out_pretty_definition, parse_definition, parse_inspect, parse_resolve, parse_usages,
};
use graph::{DartLang, Graph};
use project::Project;
use serde::Serialize;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "  resolve <uri> [--from <file>]          Resolve import URI to repo-relative path
  inspect <file> [--imports] [--exports] [--parts] [--entities]
           [--depth names|signatures|full]
  definition <symbol> [<file>] [-v|--verbose] [-p|--pretty]
                                         Find where a symbol used in <file> is defined;
                                         without <file>, every definition in the project
                                         (--verbose adds each definition's code;
                                         --pretty prints the code as written, not JSON)
  usages <pattern> [--live-only] [-v|--verbose]
                                         Find all references to an ast-grep pattern
                                         (--verbose keeps the symbol's own definition)
  usages --assets <asset-path>           Check if an asset is referenced in live code";

/// How the discover binary identifies and runs Dart.
pub const LANGUAGE: cli::Language = cli::Language {
  // Selects Dart with --lang=dart.
  name: "dart",
  // Identifies Dart source files.
  extensions: &["dart"],
  // Identifies a Dart project.
  manifests: &["pubspec.yaml"],
  // Describes the default entry points in generated config files.
  entry_defaults: "lib/main.dart",
  // Runs the function below.
  main,
  // Lists the Dart commands for --help.
  usage: USAGE,
};

/// Runs the Dart navigator.
pub fn main() -> ExitCode {
  cli::main(USAGE, |_| graph::open(Project::discover()?), |graph, command, args| {
    match command {
      "resolve" => cmd_resolve(graph, args),
      "inspect" => cmd_inspect(graph, args),
      "definition" => cmd_definition(graph, args),
      "usages" => cmd_usages(graph, args),
      "attributes" => cmd_attributes(graph, args),
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
// attributes — the instance fields of a class: one name per
// line, or with --verbose a JSON array of { <name>: <type> }
// ─────────────────────────────────────────────────────────
fn cmd_attributes(graph: &Graph, args: &[String]) -> Result<u8, String> {
  // Takes the class name and the file that defines it.
  let [class, file] = args else {
    return Err("usage: discover --lang=dart attributes <class> <file>".into());
  };
  let (path, _) = file_arg(&graph.project.root, file)?;
  // Parses the one file; the cached facts don't keep class members.
  let src = std::fs::read_to_string(&path).map_err(|e| format!("{file}: {e}"))?;
  let root = dart::parse(&src);
  let attributes = dart::attributes(&root, class).ok_or_else(|| format!("class {class} not found in {file}"))?;
  if cli::VERBOSE.load(std::sync::atomic::Ordering::Relaxed) {
    // One single-key object per field, name to type, in source order.
    let typed: Vec<std::collections::BTreeMap<&str, &str>> =
      attributes.iter().map(|a| std::collections::BTreeMap::from([(a.name.as_str(), a.ty.as_str())])).collect();
    out_json(&typed);
  } else {
    // Plain text, one name per line.
    attributes.iter().for_each(|a| out(&a.name));
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

  // --depth names: plain text, one name per line, no JSON wrapper.
  if entities && depth == "names" {
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
// definition — with a file: local entities first, then each
// import, following re-exports; then part files. Without one:
// every definition of the symbol in the project
// ─────────────────────────────────────────────────────────
fn cmd_definition(graph: &Graph, args: &[String]) -> Result<u8, String> {
  let DefinitionArgs { symbol, file, verbose, pretty } = parse_definition::<DartLang>(args)?;
  let Some(file) = file else {
    return all_definitions(graph, symbol, verbose, pretty);
  };
  let (path, rel) = file_arg(&graph.project.root, file)?;
  let facts = graph.facts(&path);

  if let Some(e) = facts.definition(symbol) {
    let def = DefinitionOut {
      symbol,
      kind: e.kind,
      file: &rel,
      line: e.line,
      via: None,
      source: Some("local"),
      code: verbose.then_some(e.full.as_str()),
    };
    out_definition(&def, pretty);
    return Ok(0);
  }

  let mut visited = HashSet::new();
  let searches = [(Directive::Import, Vec::new()), (Directive::Part, vec!["(part)".to_string()])];
  for (directive, via) in searches {
    for uri in facts.uris(directive) {
      let Some(resolved) = graph.project.resolve_uri(uri, &rel) else {
        continue;
      };
      let path = graph.project.root.join(resolved);
      if search_definition(graph, symbol, &path, &via, (verbose, pretty), &mut visited) {
        return Ok(0);
      }
    }
  }

  out_json(&serde_json::json!({ "symbol": symbol, "error": "not found in import graph" }));
  Ok(1)
}

/// Every declaration of `symbol` in the project's source files and their
/// generated extensions (`*.g.dart`, `*.freezed.dart`), in file order.
fn all_definitions(graph: &Graph, symbol: &str, verbose: bool, pretty: bool) -> Result<u8, String> {
  let files = common::project_facts(graph);

  let found: Vec<DefinitionOut> = files
    .iter()
    .flat_map(|(rel, facts)| {
      facts.definitions.iter().filter(|e| e.name == symbol).map(move |e| DefinitionOut {
        symbol,
        kind: e.kind,
        file: rel,
        line: e.line,
        via: None,
        source: None,
        code: verbose.then_some(e.full.as_str()),
      })
    })
    .collect();

  if found.is_empty() {
    out_json(&serde_json::json!({ "symbol": symbol, "error": "not found in project" }));
    return Ok(1);
  }
  if pretty {
    found.iter().for_each(out_pretty_definition);
  } else {
    out_json(&found);
  }
  eprintln!("{} definition(s) found", found.len());
  Ok(0)
}

/// Looks for `symbol` among a file's entities, then down its re-exports.
/// `via` is the chain of re-exporting files walked so far; `output` is
/// `(verbose, pretty)`.
fn search_definition(
  graph: &Graph,
  symbol: &str,
  path: &Path,
  via: &[String],
  output: (bool, bool),
  visited: &mut HashSet<PathBuf>,
) -> bool {
  let (verbose, pretty) = output;
  let Ok(path) = std::fs::canonicalize(path) else {
    return false;
  };
  if !path.is_file() || !visited.insert(path.clone()) {
    return false;
  }
  let rel = graph.project.rel(&path);
  let facts = graph.facts(&path);
  if let Some(e) = facts.definition(symbol) {
    let def = DefinitionOut {
      symbol,
      kind: e.kind,
      file: &rel,
      line: e.line,
      via: Some(via),
      source: None,
      code: verbose.then_some(e.full.as_str()),
    };
    out_definition(&def, pretty);
    return true;
  }
  for uri in facts.uris(Directive::Export) {
    let Some(target) = graph.resolve(uri, &rel) else {
      continue;
    };
    let mut chain = via.to_vec();
    chain.push(rel.clone());
    if search_definition(graph, symbol, &target, &chain, output, visited) {
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
