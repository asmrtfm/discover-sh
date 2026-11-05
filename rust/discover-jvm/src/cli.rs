//! The JVM navigators' command line: the shared subcommands from
//! discover-core plus resolve, inspect, definition and usages over the
//! declaration index.

use crate::graph::{self, Graph, JvmLang, decls};
use crate::project::Project;
use crate::usages;
use crate::{Decl, Jvm};
use discover_core::cli::{
  self, EntityOut, UsagesArgs, file_arg, out, out_json, parse_inspect, parse_resolve, parse_usages,
};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::process::ExitCode;

/// The help text for the commands implemented in this crate, which core prints after its shared help.
pub const USAGE: &str = "  resolve <import> [--from <file>]       Resolve an import (or, with --from, a name) to file(s)
  inspect <file> [--package] [--imports] [--entities]
           [--depth names|signatures|full]
  definition <file> <symbol>             Find where a symbol used in <file> is defined
  usages <pattern> [--live-only]         Find all references to an ast-grep pattern
  usages --assets <asset-path>           Check if an asset is referenced in live code

environment:
  DISCOVER_ENTRY=\"<file> ...\"            Entry point(s), overriding discover.conf and the defaults";

/// Runs the navigator for language `J`.
pub fn main<J: Jvm>() -> ExitCode {
  // The index underlies every lookup, entry detection included, so it is
  // brought up to date (or rebuilt for --rebuild-cache) before anything else.
  cli::main(
    // Passes this crate's help text, which core prints after its shared help.
    USAGE,
    |rebuild| graph::open(Project::<J>::discover()?, rebuild),
    |graph, command, args| match command {
      "resolve" => cmd_resolve(graph, args),
      "inspect" => cmd_inspect(graph, args),
      "definition" => cmd_definition(graph, args),
      "usages" => cmd_usages(graph, args),
      // attributes is Dart only for now: no output, exit 1.
      "attributes" => Ok(1),
      _ => unreachable!("checked against COMMANDS"),
    },
  )
}

// ─────────────────────────────────────────────────────────
// resolve — the file(s) declaring an import path
// (`com.example.Foo`, `com.example.*`), or — with a
// from-file — a simple name as that file sees it. Nothing
// for names the project doesn't declare.
// ─────────────────────────────────────────────────────────
fn cmd_resolve<J: Jvm>(graph: &Graph<J>, args: &[String]) -> Result<u8, String> {
  let (uri, from) = parse_resolve::<JvmLang<J>>(args, "<import>")?;
  let mut from = from.to_string();
  if !from.is_empty() {
    from = std::fs::canonicalize(graph.project.to_abs(&from))
      .map(|p| graph.project.rel(&p))
      .unwrap_or(from);
  }
  let files: BTreeSet<String> = graph.tables().lookup(uri, &from).into_iter().map(|h| h.file).collect();
  files.iter().for_each(|f| out(f));
  Ok(0)
}

// ─────────────────────────────────────────────────────────
// inspect — package and imports from the index (each import
// with the file(s) it resolves to; none for stdlib and
// libraries), entities from the file itself
// ─────────────────────────────────────────────────────────
fn entity_out<'a>(d: &'a Decl, depth: &str) -> EntityOut<'a> {
  EntityOut::new(&d.kind, &d.name, d.line, &d.header, &d.full, depth)
}

fn cmd_inspect<J: Jvm>(graph: &Graph<J>, args: &[String]) -> Result<u8, String> {
  let parsed = parse_inspect(args, &["--package", "--imports"]);
  let file = parsed.file.ok_or(format!(
    "usage: {} inspect <file> [--package] [--imports] [--entities] [--depth names|signatures|full]",
    J::NAME
  ))?;
  let [package, imports] = parsed.sections[..] else {
    unreachable!("one flag per section")
  };
  let (entities_on, depth) = (parsed.entities, parsed.depth.as_str());
  let (path, rel) = file_arg(&graph.project.root, file)?;

  // --depth names: plain text, one name per line, no JSON wrapper.
  if entities_on && depth == "names" {
    decls::<J>(&path).iter().for_each(|d| out(&d.name));
    return Ok(0);
  }

  let entry = graph.index.get(&rel);
  let mut result = serde_json::Map::new();
  result.insert("file".into(), json!(rel));
  if package {
    result.insert("package".into(), json!(entry.map(|e| e.pkg.clone())));
  }
  if imports {
    let tables = graph.tables();
    let list: Vec<Value> = entry
      .map(|e| e.imports.as_slice())
      .unwrap_or_default()
      .iter()
      .map(|imp| {
        let spec = if imp.wildcard { format!("{}.*", imp.path) } else { imp.path.clone() };
        let files: BTreeSet<String> = tables.lookup(&spec, "").into_iter().map(|h| h.file).collect();
        let mut row = serde_json::Map::new();
        row.insert("uri".into(), json!(imp.spec));
        match files.len() {
          0 => {}
          1 => {
            row.insert("resolved".into(), json!(files.into_iter().next()));
          }
          _ => {
            row.insert("resolved".into(), json!(files));
          }
        }
        Value::Object(row)
      })
      .collect();
    result.insert("imports".into(), Value::Array(list));
  }
  if entities_on {
    let decls = decls::<J>(&path);
    let list: Vec<EntityOut> = decls.iter().map(|d| entity_out(d, depth)).collect();
    result.insert("entities".into(), serde_json::to_value(list).expect("serializable"));
  }
  out_json(&OrderedObject(result, &["file", "package", "imports", "entities"]));
  Ok(0)
}

/// Serializes a map with its keys in a fixed order (serde_json's map sorts).
struct OrderedObject<'a>(serde_json::Map<String, Value>, &'a [&'a str]);

impl Serialize for OrderedObject<'_> {
  fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
    use serde::ser::SerializeMap;
    let mut map = s.serialize_map(None)?;
    for key in self.1 {
      if let Some(v) = self.0.get(*key) {
        map.serialize_entry(key, v)?;
      }
    }
    map.end()
  }
}

// ─────────────────────────────────────────────────────────
// definition — a JVM name has no re-export chain to follow:
// it is declared in the file itself, imported (including
// Java's static imports), visible through the file's own
// package, or through a wildcard (`.*`) import. `via`
// reports which, in that order.
// ─────────────────────────────────────────────────────────
fn cmd_definition<J: Jvm>(graph: &Graph<J>, args: &[String]) -> Result<u8, String> {
  let (Some(file), Some(symbol)) = (args.first(), args.get(1)) else {
    return Err(format!("usage: {} definition <file> <symbol>", J::NAME));
  };
  let (path, rel) = file_arg(&graph.project.root, file)?;

  if let Some(d) = decls::<J>(&path).iter().find(|d| &d.name == symbol) {
    out_json(&json!({ "symbol": symbol, "kind": d.kind, "file": rel, "line": d.line, "source": "local" })
      .as_object()
      .map(|m| OrderedObject(m.clone(), &["symbol", "kind", "file", "line", "source"]))
      .expect("object"));
    return Ok(0);
  }

  // An imported member (`import a.B.member`, a wildcard over a declaration's
  // members) reports the declaration that holds it.
  for hit in graph.tables().lookup(symbol, &rel) {
    if hit.via == "local" {
      continue;
    }
    let wanted = hit.name.as_deref().unwrap_or(symbol);
    let Some(d) = graph
      .index
      .get(&hit.file)
      .and_then(|e| e.decls.iter().find(|d| d.name == wanted))
    else {
      continue;
    };
    let mut m = serde_json::Map::new();
    m.insert("symbol".into(), json!(symbol));
    m.insert("kind".into(), json!(d.kind));
    m.insert("file".into(), json!(hit.file));
    m.insert("line".into(), json!(d.line));
    m.insert("via".into(), json!(hit.via));
    if hit.member.is_some() {
      m.insert("member_of".into(), json!(d.name));
    }
    out_json(&OrderedObject(m, &["symbol", "kind", "file", "line", "via", "member_of"]));
    return Ok(0);
  }

  out_json(&OrderedObject(
    json!({ "symbol": symbol, "error": "not found in import graph" })
      .as_object()
      .cloned()
      .expect("object"),
    &["symbol", "error"],
  ));
  Ok(1)
}

// ─────────────────────────────────────────────────────────
// usages
// ─────────────────────────────────────────────────────────
fn cmd_usages<J: Jvm>(graph: &Graph<J>, args: &[String]) -> Result<u8, String> {
  match parse_usages::<JvmLang<J>>(args)? {
    UsagesArgs::Assets(asset) => {
      let refs = usages::asset_usages(graph, asset)?;
      out_json(&refs);
      eprintln!(
        "{} constant ref(s), {} xml ref(s), {} direct ref(s)",
        refs.constant_refs.len(),
        refs.xml_refs.len(),
        refs.direct_refs.len()
      );
    }
    UsagesArgs::Pattern { pattern, live_only } => {
      cli::print_usages(&usages::pattern_usages(graph, pattern, live_only)?);
    }
  }
  Ok(0)
}
