//! `usages`: structural search over lib/ with an ast-grep pattern, and the
//! `--assets` lookup of what references an asset path.

use crate::dart::{self, Hit};
use crate::graph::Graph;
use ast_grep_core::Pattern;
use ast_grep_language::Dart;
use discover_core::par::par_map;
use discover_core::usages::{Usage, file_line, sorted_unique};
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

/// The files `ast-grep run -l dart <pattern> lib/` searches: every *.dart
/// under lib/ (generated files included), skipping hidden and gitignored
/// paths, as walked paths (not canonicalized).
fn search_files(graph: &Graph) -> Vec<PathBuf> {
  let mut files: Vec<PathBuf> = ignore::WalkBuilder::new(&graph.project.lib)
    .build()
    .flatten()
    .filter(|e| e.file_type().is_some_and(|t| t.is_file()))
    .map(|e| e.into_path())
    .filter(|p| p.extension().is_some_and(|x| x == "dart"))
    .collect();
  files.sort();
  files
}

/// Every match of `pattern` under lib/, as (repo-relative file, hit).
fn search(graph: &Graph, pattern: &Pattern, capture: Option<&str>) -> Vec<(String, Hit)> {
  let root = format!("{}/", graph.project.root.display());
  let files = search_files(graph);
  par_map(&files, |path| {
    let Ok(src) = fs::read_to_string(path) else {
      return Vec::new();
    };
    let file = path.to_string_lossy();
    let file = file.strip_prefix(&root).unwrap_or(&file).to_string();
    dart::find_all(&dart::parse(&src), pattern, capture)
      .into_iter()
      .map(|hit| (file.clone(), hit))
      .collect()
  })
  .into_iter()
  .flatten()
  .collect()
}

/// One row per file:line, sorted by file then line.
fn format(hits: impl IntoIterator<Item = (String, Hit)>) -> Vec<Usage> {
  let rows: Vec<Usage> = hits
    .into_iter()
    .map(|(file, hit)| Usage {
      file,
      line: hit.line,
      text: hit.text,
    })
    .collect();
  sorted_unique(rows, file_line)
}

/// `usages <pattern> [--live-only]`. An invalid pattern finds nothing, as
/// it did when ast-grep's error was discarded.
pub fn pattern_usages(graph: &Graph, pattern: &str, live_only: bool) -> Result<Vec<Usage>, String> {
  let Ok(pattern) = Pattern::try_new(pattern, Dart) else {
    return Ok(Vec::new());
  };
  let hits = search(graph, &pattern, None);
  if !live_only {
    return Ok(format(hits));
  }
  let live: HashSet<String> = graph.live()?.into_iter().collect();
  Ok(format(hits.into_iter().filter(|(f, _)| live.contains(f))))
}

#[derive(Debug, Serialize)]
pub struct AssetRefs {
  /// Usages via a constant field holding the path (e.g. `AppIcons.bubbles`).
  pub constant_refs: Vec<Usage>,
  /// String literals of the path itself.
  pub direct_refs: Vec<Usage>,
}

/// `usages --assets <path>`: live references to an asset, through the
/// `static String <field> = '<path>'` constants that name it and as bare
/// string literals. Both quote styles are matched (the bash version only
/// matched double quotes).
pub fn asset_usages(graph: &Graph, asset: &str) -> Result<AssetRefs, String> {
  let live: HashSet<String> = graph.live()?.into_iter().collect();
  let literals = [format!("\"{asset}\""), format!("'{asset}'")];

  // Step 1: the constant fields whose value is this path, then live usages
  // of `<Class>.<field>` outside the declaring file.
  let mut constant_refs = Vec::new();
  let mut declarations: Vec<(String, Hit)> = Vec::new();
  for literal in &literals {
    if let Ok(p) = Pattern::try_new(&format!("static String $FIELD = {literal}"), Dart) {
      declarations.extend(search(graph, &p, Some("FIELD")));
    }
  }
  declarations.sort_by(|a, b| (&a.0, a.1.line).cmp(&(&b.0, b.1.line)));
  let class_pattern = Pattern::try_new("class $NAME { $$$BODY }", Dart).map_err(|e| e.to_string())?;
  for (decl_file, decl) in declarations {
    let Some(field) = decl.capture else { continue };
    // The enclosing class: the first class in the declaring file.
    let Ok(src) = fs::read_to_string(graph.project.root.join(&decl_file)) else {
      continue;
    };
    let Some(class) = dart::find_all(&dart::parse(&src), &class_pattern, Some("NAME"))
      .into_iter()
      .find_map(|h| h.capture)
    else {
      continue;
    };
    let qualified = format!("{class}.{field}");
    eprintln!("constant: {qualified} ({decl_file})");
    let Ok(p) = Pattern::try_new(&qualified, Dart) else {
      continue;
    };
    constant_refs.extend(format(
      search(graph, &p, None)
        .into_iter()
        .filter(|(f, _)| f != &decl_file && live.contains(f)),
    ));
  }

  // Step 2: the literal itself in live code, minus the declarations.
  let mut direct = Vec::new();
  for literal in &literals {
    if let Ok(p) = Pattern::try_new(literal, Dart) {
      direct.extend(
        search(graph, &p, None)
          .into_iter()
          .filter(|(f, h)| live.contains(f) && !h.lines.contains("static String")),
      );
    }
  }

  Ok(AssetRefs {
    constant_refs,
    direct_refs: format(direct),
  })
}
