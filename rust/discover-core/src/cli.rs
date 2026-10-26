//! The command line every navigator shares: argument handling, output, and
//! the subcommands that only need the graph (live-files, dead-files,
//! is-live, importers, trace, prune). A language adds resolve, inspect,
//! definition and usages.

use crate::graph::{EntityUse, Graph, Lang, Row, Trace};
use crate::project::{relative, to_abs};
use crate::usages::Usage;
use serde::Serialize;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const COMMANDS: &[&str] = &[
  "resolve",
  "inspect",
  "live-files",
  "dead-files",
  "is-live",
  "definition",
  "importers",
  "trace",
  "prune",
  "usages",
];

/// Writes a line to stdout; a closed pipe (`| head`) ends the run quietly.
pub fn out(line: &str) {
  let mut stdout = io::stdout().lock();
  if writeln!(stdout, "{line}").is_err() {
    std::process::exit(0);
  }
}

/// Pretty JSON, indented like jq's default output.
pub fn out_json<T: Serialize>(value: &T) {
  out(&serde_json::to_string_pretty(value).expect("serializable"));
}

/// Runs a navigator: `[--rebuild-cache] <command> [args]`. `open` builds the
/// graph (told whether --rebuild-cache was given); `commands` handles the
/// language's own subcommands (resolve, inspect, definition, usages).
pub fn main<L: Lang>(
  usage: &str,
  open: impl FnOnce(bool) -> Result<Graph<L>, String>,
  commands: impl FnOnce(&Graph<L>, &str, &[String]) -> Result<u8, String>,
) -> ExitCode {
  match run(usage, open, commands) {
    Ok(code) => ExitCode::from(code),
    Err(msg) => {
      eprintln!("error: {msg}");
      ExitCode::FAILURE
    }
  }
}

fn run<L: Lang>(
  usage: &str,
  open: impl FnOnce(bool) -> Result<Graph<L>, String>,
  commands: impl FnOnce(&Graph<L>, &str, &[String]) -> Result<u8, String>,
) -> Result<u8, String> {
  let mut args: Vec<String> = std::env::args().skip(1).collect();
  let rebuild = args.first().is_some_and(|a| a == "--rebuild-cache");
  if rebuild {
    args.remove(0);
  }
  let command = if args.is_empty() { String::new() } else { args.remove(0) };
  if !COMMANDS.contains(&command.as_str()) && !(rebuild && command.is_empty()) {
    eprintln!("{usage}");
    return Ok(1);
  }

  let mut graph = open(rebuild)?;
  if rebuild {
    graph.build_all()?;
    // With no subcommand, the rebuild was the whole request.
    if command.is_empty() {
      return Ok(0);
    }
  }

  match command.as_str() {
    "live-files" => {
      graph.live()?.iter().for_each(|l| out(l));
      Ok(0)
    }
    "dead-files" => {
      if args.first().is_some_and(|a| a == "--rebuild") {
        graph.build_dead()?;
      }
      graph.dead()?.iter().for_each(|l| out(l));
      Ok(0)
    }
    "is-live" => cmd_is_live(&graph, &args),
    "importers" => cmd_importers(&graph, &args),
    "trace" => cmd_trace(&graph, &args),
    "prune" => {
      let file = args.first().ok_or(format!("usage: {} prune <file>", L::NAME))?;
      graph.prune(file)?;
      Ok(0)
    }
    other => commands(&graph, other, &args),
  }
}

/// An existing file argument as (canonical path, repo-relative path).
pub fn file_arg(root: &Path, file: &str) -> Result<(PathBuf, String), String> {
  let abs = to_abs(root, file);
  if !abs.is_file() {
    return Err(format!("file not found: {file}"));
  }
  let canonical = std::fs::canonicalize(&abs).map_err(|e| format!("{file}: {e}"))?;
  let rel = relative(root, &canonical);
  Ok((canonical, rel))
}

// ─────────────────────────────────────────────────────────
// argument parsing for the language subcommands
// ─────────────────────────────────────────────────────────

/// `resolve <what> [--from <file>]` → (what, from); from is "" when absent.
/// `what` names the argument in the usage message (`<uri>`, `<import>`, …).
pub fn parse_resolve<'a, L: Lang>(args: &'a [String], what: &str) -> Result<(&'a str, &'a str), String> {
  let mut uri = "";
  let mut from = "";
  let mut it = args.iter();
  while let Some(arg) = it.next() {
    match arg.as_str() {
      "--from" => from = it.next().map_or("", String::as_str),
      other => uri = other,
    }
  }
  if uri.is_empty() {
    return Err(format!("usage: {} resolve {what} [--from <file>]", L::NAME));
  }
  Ok((uri, from))
}

pub struct InspectArgs<'a> {
  /// Whether each of the language's section flags was given, in order.
  pub sections: Vec<bool>,
  pub entities: bool,
  /// name | names | signatures | full
  pub depth: String,
  pub file: Option<&'a str>,
}

/// `inspect <file> [<section flags>] [--entities [depth]] [--depth <depth>]`.
/// With no section and no --entities, everything is selected.
pub fn parse_inspect<'a>(args: &'a [String], section_flags: &[&str]) -> InspectArgs<'a> {
  let mut sections = vec![false; section_flags.len()];
  let mut entities = false;
  let mut depth = "names".to_string();
  let mut file = None;
  let mut i = 0;
  while i < args.len() {
    let arg = args[i].as_str();
    if let Some(at) = section_flags.iter().position(|f| *f == arg) {
      sections[at] = true;
    } else {
      match arg {
        "--entities" => {
          entities = true;
          if let Some(d) = args
            .get(i + 1)
            .filter(|d| matches!(d.as_str(), "name" | "names" | "signatures" | "full"))
          {
            depth = d.clone();
            i += 1;
          }
        }
        "--depth" => {
          i += 1;
          depth = args.get(i).cloned().unwrap_or_default();
        }
        other => file = Some(other),
      }
    }
    i += 1;
  }
  if !(entities || sections.iter().any(|s| *s)) {
    sections.iter_mut().for_each(|s| *s = true);
    entities = true;
  }
  InspectArgs {
    sections,
    entities,
    depth,
    file,
  }
}

pub enum UsagesArgs<'a> {
  Pattern { pattern: &'a str, live_only: bool },
  Assets(&'a str),
}

/// `usages <pattern> [--live-only]` or `usages --assets <asset-path>`.
pub fn parse_usages<'a, L: Lang>(args: &'a [String]) -> Result<UsagesArgs<'a>, String> {
  let mut pattern = "";
  let mut asset = None;
  let mut live_only = false;
  let mut it = args.iter();
  while let Some(arg) = it.next() {
    match arg.as_str() {
      "--live-only" => live_only = true,
      "--assets" => {
        asset = Some(
          it.next()
            .filter(|a| !a.is_empty())
            .ok_or("--assets requires an asset path argument")?
            .as_str(),
        )
      }
      other => pattern = other,
    }
  }
  if let Some(asset) = asset {
    return Ok(UsagesArgs::Assets(asset));
  }
  if pattern.is_empty() {
    let name = L::NAME;
    return Err(format!(
      "usage: {name} usages <pattern> [--live-only]\n       {name} usages --assets <asset-path>"
    ));
  }
  Ok(UsagesArgs::Pattern { pattern, live_only })
}

/// Pattern results on stdout so they can be piped; the count is commentary.
pub fn print_usages(found: &[Usage]) {
  out_json(&found);
  eprintln!("{} usages found", found.len());
}

// ─────────────────────────────────────────────────────────
// output shapes shared by the language subcommands
// ─────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct EntityOut<'a> {
  pub kind: &'a str,
  pub name: &'a str,
  pub line: usize,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub text: Option<&'a str>,
}

impl<'a> EntityOut<'a> {
  /// `text` is the header for signatures depth, the whole declaration for
  /// full depth, and omitted otherwise.
  pub fn new(kind: &'a str, name: &'a str, line: usize, header: &'a str, full: &'a str, depth: &str) -> Self {
    let text = match depth {
      "full" => Some(full),
      "signatures" => Some(header),
      _ => None,
    };
    EntityOut { kind, name, line, text }
  }
}

#[derive(Serialize)]
pub struct DefinitionOut<'a> {
  pub symbol: &'a str,
  pub kind: &'a str,
  pub file: &'a str,
  pub line: usize,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub via: Option<&'a [String]>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub source: Option<&'a str>,
  /// The whole declaration, with `--verbose`.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub code: Option<&'a str>,
}

pub struct DefinitionArgs<'a> {
  pub symbol: &'a str,
  /// The file the symbol is used in; without it every definition in the
  /// project is reported.
  pub file: Option<&'a str>,
  /// `-v` / `--verbose`: include each definition's code.
  pub verbose: bool,
  /// `-p` / `--pretty`: print each definition as a header line and its code
  /// as written instead of JSON. Implies `verbose`.
  pub pretty: bool,
}

/// `definition <symbol> [<file>] [-v|--verbose] [-p|--pretty]`.
pub fn parse_definition<'a, L: Lang>(args: &'a [String]) -> Result<DefinitionArgs<'a>, String> {
  let usage = || format!("usage: {} definition <symbol> [<file>] [-v|--verbose] [-p|--pretty]", L::NAME);
  let mut verbose = false;
  let mut pretty = false;
  let mut positional = Vec::new();
  for arg in args {
    match arg.as_str() {
      "-v" | "--verbose" => verbose = true,
      "-p" | "--pretty" => pretty = true,
      other => positional.push(other),
    }
  }
  // Pretty output is the code, so it needs the code.
  verbose |= pretty;
  match positional[..] {
    [symbol] => Ok(DefinitionArgs { symbol, file: None, verbose, pretty }),
    [symbol, file] => Ok(DefinitionArgs { symbol, file: Some(file), verbose, pretty }),
    _ => Err(usage()),
  }
}

/// `--pretty` output for one definition: a `file:line kind symbol` header
/// (with the re-export chain, when there is one), then its code as written.
pub fn out_pretty_definition(def: &DefinitionOut) {
  let mut header = format!("{}:{} {} {}", def.file, def.line, def.kind, def.symbol);
  if let Some(via) = def.via.filter(|v| !v.is_empty()) {
    header.push_str(&format!(" (via {})", via.join(" -> ")));
  }
  out(&header);
  out(def.code.unwrap_or_default());
  out("");
}

/// One definition, as JSON or with `--pretty`.
pub fn out_definition(def: &DefinitionOut, pretty: bool) {
  if pretty {
    out_pretty_definition(def);
  } else {
    out_json(def);
  }
}

// ─────────────────────────────────────────────────────────
// is-live
// ─────────────────────────────────────────────────────────
fn cmd_is_live<L: Lang>(graph: &Graph<L>, args: &[String]) -> Result<u8, String> {
  let file = args.first().ok_or(format!("usage: {} is-live <file>", L::NAME))?;
  let (_, rel) = file_arg(graph.root(), file)?;
  if graph.live()?.contains(&rel) {
    out(&format!("LIVE: {rel}"));
    Ok(0)
  } else {
    out(&format!("DEAD: {rel}"));
    Ok(1)
  }
}

// ─────────────────────────────────────────────────────────
// importers
// ─────────────────────────────────────────────────────────
fn cmd_importers<L: Lang>(graph: &Graph<L>, args: &[String]) -> Result<u8, String> {
  let file = args.first().ok_or(format!("usage: {} importers <file>", L::NAME))?;
  let (_, rel) = file_arg(graph.root(), file)?;
  let mut rows: Vec<Row> = graph.importers()?.remove(&rel).unwrap_or_default();
  rows.sort_by(|a, b| a.file.cmp(&b.file));
  rows.iter().for_each(|r| out(&r.file));
  Ok(0)
}

// ─────────────────────────────────────────────────────────
// trace — tags each importer of a file:
//   active — live importer that uses the target's entities
//   stale  — live importer that doesn't use any entities
//   zombie — dead importer (the dependency exists but the chain is dead)
// The file is dead when no importer is active, then the
// verdict is cross-checked against is-live.
// ─────────────────────────────────────────────────────────
#[derive(Serialize)]
struct TracedRow {
  file: String,
  directive: String,
  uri: String,
  entities_used: Vec<EntityUse>,
  status: &'static str,
}

#[derive(Serialize)]
struct TraceOut {
  file: String,
  entities: Vec<String>,
  importers: Vec<TracedRow>,
  dead: bool,
  active_count: usize,
  #[serde(skip_serializing_if = "Option::is_none")]
  warning: Option<String>,
}

fn cmd_trace<L: Lang>(graph: &Graph<L>, args: &[String]) -> Result<u8, String> {
  let file = args.first().ok_or(format!("usage: {} trace <file>", L::NAME))?;
  let (path, rel) = file_arg(graph.root(), file)?;
  if !graph.is_source(&path) {
    return Err(format!(
      "not a source file: {file} (trace is for code; for assets use: {} usages --assets <path>)",
      L::NAME
    ));
  }
  let entities = graph.entity_names(&path);
  let index = graph.importers()?;
  let mut trace = Trace::new(&index, graph.entries());

  let mut importers: Vec<TracedRow> = index
    .get(&rel)
    .map(Vec::as_slice)
    .unwrap_or_default()
    .iter()
    .map(|row| {
      let status = if !trace.reachable(&row.file) {
        "zombie"
      } else if row.entities_used.is_empty() {
        "stale"
      } else {
        "active"
      };
      TracedRow {
        file: row.file.clone(),
        directive: row.directive.clone(),
        uri: row.uri.clone(),
        entities_used: row.entities_used.clone(),
        status,
      }
    })
    .collect();
  importers.sort_by(|a, b| a.file.cmp(&b.file));

  let active_count = importers.iter().filter(|r| r.status == "active").count();
  // An entry point has no importers by definition, yet is live.
  let dead = active_count == 0 && !graph.entries().contains(&rel);
  let bfs_dead = !graph.live()?.contains(&rel);
  let warning = (dead != bfs_dead).then(|| {
    let w = format!("DISAGREEMENT: trace says dead={dead} but is-live says dead={bfs_dead}");
    eprintln!("WARNING: {w}");
    w
  });

  out_json(&TraceOut {
    file: rel,
    entities,
    importers,
    dead,
    active_count,
    warning,
  });
  Ok(0)
}
