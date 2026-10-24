//! discover-typescript — deterministic TypeScript codebase navigation,
//! in-process on ast-grep's TypeScript/TSX support. A port of the
//! TypeScript discover.sh: same subcommands, flags, JSON shapes and stderr
//! commentary, with each file parsed once instead of once per query. The
//! subcommands that only need the graph come from discover-core; the
//! TypeScript-specific ones are here.
//!
//! Subcommands:
//!   resolve <specifier> [--from <file>]
//!   inspect <file> [--imports] [--exports] [--dynamic] [--entities] [--depth names|signatures|full]
//!   definition <file> <symbol>
//!   live-files
//!   dead-files [--rebuild]
//!   is-live <file>
//!   importers <file>
//!   trace <file>
//!   prune <file>
//!   usages <pattern> [--live-only]
//!   usages --assets <asset-path>

mod graph;
mod project;
mod ts;
mod usages;

use discover_core::cli::{
  self, DefinitionOut, EntityOut, UsagesArgs, file_arg, out, out_json, parse_inspect, parse_resolve, parse_usages,
};
use graph::{Graph, TsLang};
use project::Project;
use serde::Serialize;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use ts::{Directive, is_script};

const USAGE: &str = "usage: discover-typescript [--rebuild-cache] <command> [args]

global flags:
  --rebuild-cache                        Wipe and rebuild all caches before running command

environment:
  DISCOVER_ENTRY=\"<file> ...\"            Entry point(s), overriding package.json / index detection

commands:
  resolve <specifier> [--from <file>]    Resolve import specifier to repo-relative path
  inspect <file> [--imports] [--exports] [--dynamic] [--entities]
           [--depth names|signatures|full]
  definition <file> <symbol>             Find where a symbol used in <file> is defined
  live-files                             List all files reachable from the entry points
  dead-files [--rebuild]                 List all dead files (verified by recursive trace)
  is-live <file>                         Check if a file is reachable from the entry points
  importers <file>                       Find all files that import/export/load <file>
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
  let (uri, from) = parse_resolve::<TsLang>(args, "<specifier>")?;
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
  dynamic: Option<Vec<DirectiveOut>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  entities: Option<Vec<EntityOut<'a>>>,
}

fn cmd_inspect(graph: &Graph, args: &[String]) -> Result<u8, String> {
  let parsed = parse_inspect(args, &["--imports", "--exports", "--dynamic"]);
  let file = parsed.file.ok_or(
    "usage: discover-typescript inspect <file> [--imports] [--exports] [--dynamic] [--entities] [--depth names|signatures|full]",
  )?;
  let [imports, exports, dynamic] = parsed.sections[..] else {
    unreachable!("one flag per section")
  };
  let (entities, depth) = (parsed.entities, parsed.depth.as_str());
  let (path, rel) = file_arg(&graph.project.root, file)?;
  if !is_script(&rel) {
    return Err(format!("not a TypeScript/JavaScript module: {file}"));
  }
  let facts = graph.facts(&path);

  // --entities name: plain text, one name per line, no JSON wrapper.
  if entities && depth == "name" {
    facts.entities.iter().for_each(|e| out(&e.name));
    return Ok(0);
  }

  let directive = |d: Directive| {
    facts
      .specs(d)
      .iter()
      .map(|s| DirectiveOut {
        uri: s.text.clone(),
        resolved: graph.project.resolve_uri(&s.text, &rel),
      })
      .collect::<Vec<_>>()
  };
  out_json(&InspectOut {
    file: &rel,
    imports: imports.then(|| directive(Directive::Import)),
    exports: exports.then(|| directive(Directive::Export)),
    dynamic: dynamic.then(|| directive(Directive::Dynamic)),
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
// definition — local entities first; then the import that
// binds the symbol; then every import by name; then dynamic
// imports. Re-exports are followed through `export … from`,
// `export * from` and import-then-export.
// ─────────────────────────────────────────────────────────
fn cmd_definition(graph: &Graph, args: &[String]) -> Result<u8, String> {
  let (Some(file), Some(symbol)) = (args.first(), args.get(1)) else {
    return Err("usage: discover-typescript definition <file> <symbol>".into());
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

  // Searched by (file, name): a barrel can be searched once per name it re-exports.
  let mut visited = HashSet::new();
  let mut search = |target: &str, name: &str, via: &[String]| {
    search_definition(graph, symbol, &graph.project.root.join(target), name, via, &mut visited)
  };

  // The symbol is an import binding in this file: follow exactly that import.
  for b in facts.bindings.iter().filter(|b| {
    matches!(b.id, "import-spec" | "import-default") && b.local.as_deref() == Some(symbol.as_str())
  }) {
    let (Some(src), Some(name)) = (&b.src, &b.name) else { continue };
    if let Some(resolved) = graph.project.resolve_uri(src, &rel) {
      if search(&resolved, name, &[]) {
        return Ok(0);
      }
    }
  }

  // Otherwise search each import by name (covers namespace access, `ns.Foo`),
  // then dynamically loaded modules.
  let searches = [(Directive::Import, Vec::new()), (Directive::Dynamic, vec!["(dynamic)".to_string()])];
  for (directive, via) in searches {
    for spec in facts.specs(directive) {
      let Some(resolved) = graph.project.resolve_uri(&spec.text, &rel) else {
        continue;
      };
      if search(&resolved, symbol, &via) {
        return Ok(0);
      }
    }
  }

  out_json(&serde_json::json!({ "symbol": symbol, "error": "not found in import graph" }));
  Ok(1)
}

/// Looks for `name` (what the module itself calls the symbol) in a file's
/// entities, then through its re-exports. `via` is the chain of
/// re-exporting files walked so far.
fn search_definition(
  graph: &Graph,
  symbol: &str,
  path: &Path,
  name: &str,
  via: &[String],
  visited: &mut HashSet<(PathBuf, String)>,
) -> bool {
  let Ok(path) = std::fs::canonicalize(path) else {
    return false;
  };
  if !path.is_file() || !is_script(&path.to_string_lossy()) {
    return false;
  }
  if !visited.insert((path.clone(), name.to_string())) {
    return false;
  }
  let rel = graph.project.rel(&path);
  let facts = graph.facts(&path);

  // A default import names whatever this module's default export declares.
  let name = if name == "default" {
    match facts.default_export() {
      Some(n) => n.to_string(),
      None => return false,
    }
  } else {
    name.to_string()
  };

  if let Some(e) = facts.entity(&name) {
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

  // Follow re-exports: `export { X } from`, `export * from` (which never
  // carries a default export), and `import { X } …; export { X }`.
  let mut next: Vec<(String, String)> = Vec::new();
  for b in &facts.bindings {
    let Some(src) = &b.src else { continue };
    match b.id {
      "export-star" if name != "default" => next.push((src.clone(), name.clone())),
      "export-spec" | "import-spec" | "import-default" if b.local.as_deref() == Some(name.as_str()) => {
        if let Some(orig) = &b.name {
          next.push((src.clone(), orig.clone()));
        }
      }
      _ => {}
    }
  }
  for (src, orig) in next {
    let Some(target) = graph.resolve(&src, &rel) else { continue };
    let mut chain = via.to_vec();
    chain.push(rel.clone());
    if search_definition(graph, symbol, &target, &orig, &chain, visited) {
      return true;
    }
  }
  false
}

// ─────────────────────────────────────────────────────────
// usages
// ─────────────────────────────────────────────────────────
fn cmd_usages(graph: &Graph, args: &[String]) -> Result<u8, String> {
  match parse_usages::<TsLang>(args)? {
    UsagesArgs::Assets(asset) => {
      let refs = usages::asset_usages(graph, asset)?;
      out_json(&refs);
      eprintln!(
        "{} binding ref(s), {} direct ref(s)",
        refs.binding_refs.len(),
        refs.direct_refs.len()
      );
    }
    UsagesArgs::Pattern { pattern, live_only } => {
      cli::print_usages(&usages::pattern_usages(graph, pattern, live_only)?);
    }
  }
  Ok(0)
}
