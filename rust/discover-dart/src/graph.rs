//! Dart's side of the import graph: parsed facts per file, live files
//! (reachability from the entry points over import, export and part
//! directives), and the importers index (import and export edges, with the
//! target's entities each importer references). Caching, dead files and
//! trace come from discover-core.

use crate::dart::{self, Directive, Facts};
use crate::project::{Project, generated_extensions};
use ast_grep_core::Pattern;
use ast_grep_language::Dart;
use discover_core::cache::{Caches, Fnv};
use discover_core::graph::{EntityUse, Importers, Lang, Row};
use discover_core::memo::Memo;
use discover_core::par::par_map;
use discover_core::project::custom_entries;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// The default root of liveness, relative to the project root.
pub const ENTRY: &str = "lib/main.dart";

pub type Graph = discover_core::graph::Graph<DartLang>;

pub struct DartLang {
  pub project: Project,
  /// Parsed facts per canonical path, shared across threads.
  facts: Memo<PathBuf, Arc<Facts>>,
  /// Entity-name patterns, built once each (None when the name isn't a valid pattern).
  patterns: Memo<String, Option<Arc<Pattern>>>,
  /// Custom entry points when the project sets any, else just [`ENTRY`].
  entries: HashSet<String>,
}

/// The graph over a project, its caches stamped with the source listing and the entry points.
pub fn open(project: Project) -> Result<Graph, String> {
  let entries = custom_entries(&project.root)?.unwrap_or_else(|| vec![ENTRY.to_string()]);
  let fingerprint = fingerprint(&project.relevant_files(), &entries);
  let caches = Caches::new(project.cache_dir.clone(), "discover_rs_", fingerprint);
  let lang = DartLang {
    project,
    facts: Memo::default(),
    patterns: Memo::default(),
    entries: entries.into_iter().collect(),
  };
  Ok(Graph::new(lang, caches))
}

impl DartLang {
  /// Facts for a file, parsed on first use. Unreadable files have none.
  pub fn facts(&self, path: &Path) -> Arc<Facts> {
    self.facts.get(path, || {
      Arc::new(
        fs::read_to_string(path)
          .map(|src| dart::extract(&dart::parse(&src)))
          .unwrap_or_default(),
      )
    })
  }

  fn pattern(&self, name: &str) -> Option<Arc<Pattern>> {
    self
      .patterns
      .get(name, || Pattern::try_new(name, Dart).ok().map(Arc::new))
  }

  /// Resolves a URI from a repo-relative file to the target's canonical path.
  pub fn resolve(&self, uri: &str, from_rel: &str) -> Option<PathBuf> {
    let rel = self.project.resolve_uri(uri, from_rel)?;
    self.project.existing(&rel)
  }

  /// A file's entity names followed by those of its generated extensions
  /// (`*.g.dart`, `*.freezed.dart`), which are part of the same file.
  fn entity_names_with_generated(&self, path: &Path) -> Vec<String> {
    let mut names = self.facts(path).entity_names();
    for generated in generated_extensions(path) {
      names.extend(self.facts(&generated).entity_names());
    }
    names
  }

  /// The names a file makes visible to its importers: its own entities and,
  /// following `export` directives, those of every file it re-exports.
  fn namespace(&self, path: &Path) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let mut visited = HashSet::new();
    let mut stack = vec![path.to_path_buf()];
    while let Some(file) = stack.pop() {
      // Guards against export cycles.
      if !visited.insert(file.clone()) {
        continue;
      }
      names.extend(self.entity_names_with_generated(&file));
      let rel = self.project.rel(&file);
      stack.extend(
        self
          .facts(&file)
          .uris(Directive::Export)
          .iter()
          .filter_map(|uri| self.resolve(uri, &rel)),
      );
    }
    names
  }
}

/// The names a file's importers use from what it re-exports, gathered from
/// every file that imports it and, through files that export it in turn,
/// from theirs. `uses` maps a file to the names its direct importers use.
fn used_through_exports(
  file: &str,
  uses: &HashMap<String, BTreeSet<String>>,
  index: &Importers,
  visited: &mut HashSet<String>,
) -> BTreeSet<String> {
  // Guards against export cycles.
  if !visited.insert(file.to_string()) {
    return BTreeSet::new();
  }
  let mut names = uses.get(file).cloned().unwrap_or_default();
  for row in index.get(file).into_iter().flatten().filter(|r| r.directive == "export") {
    names.extend(used_through_exports(&row.file, uses, index, visited));
  }
  names
}

impl Lang for DartLang {
  // Names the command in usage messages.
  const NAME: &'static str = "discover --lang=dart";

  fn root(&self) -> &Path {
    &self.project.root
  }

  fn entries(&self) -> &HashSet<String> {
    &self.entries
  }

  fn sources(&self) -> Vec<String> {
    self.project.relevant_files().iter().map(|f| self.project.rel(f)).collect()
  }

  fn entity_names(&self, path: &Path) -> Vec<String> {
    self.entity_names_with_generated(path)
  }

  // ─────────────────────────────────────────────────────────
  // live files — breadth-first reachability from the entries
  // over import, export and part directives
  // ─────────────────────────────────────────────────────────

  fn compute_live(&self, _caches: &Caches) -> Result<Vec<String>, String> {
    let mut frontier: Vec<PathBuf> = self.entries.iter().filter_map(|e| self.project.existing(e)).collect();
    if frontier.is_empty() {
      return Err(format!("{ENTRY} not found (list the entry points under entries in discover.conf, see: discover config)"));
    }

    let mut live: HashSet<PathBuf> = frontier.iter().cloned().collect();
    // Level by level so each frontier is parsed in parallel.
    while !frontier.is_empty() {
      let found: Vec<Vec<PathBuf>> = par_map(&frontier, |current| {
        let current_rel = self.project.rel(current);
        let facts = self.facts(current);
        [Directive::Import, Directive::Export, Directive::Part]
          .iter()
          .flat_map(|d| facts.uris(*d).to_vec())
          .filter_map(|uri| self.resolve(&uri, &current_rel))
          .collect()
      });
      frontier = found
        .into_iter()
        .flatten()
        .filter(|p| live.insert(p.clone()))
        .collect();
    }

    let mut lines: Vec<String> = live.iter().map(|p| self.project.rel(p)).collect();
    lines.sort();
    Ok(lines)
  }

  // ─────────────────────────────────────────────────────────
  // importers — reverse index: target → files that import or
  // export it, with the target's entities each one references.
  // An exporter also counts the entities its own importers use
  // through the export (following further exports), each with
  // the export directive's line.
  // ─────────────────────────────────────────────────────────

  fn compute_importers(&self, _caches: &Caches) -> Result<Importers, String> {
    let files = self.project.relevant_files();

    // One parse per importer: its directives, every entity-name check, and
    // the re-exported names it uses from each file it imports.
    type Scan = (Vec<(String, Row)>, Vec<(String, BTreeSet<String>)>);
    let scans: Vec<Scan> = par_map(&files, |file| {
      let Ok(src) = fs::read_to_string(file) else {
        return (Vec::new(), Vec::new());
      };
      let root = dart::parse(&src);
      let facts = dart::extract(&root);
      let file_rel = self.project.rel(file);
      let references = |name: &str| self.pattern(name).map(|p| dart::references(&root, &p)).unwrap_or_default();
      let mut rows = Vec::new();
      let mut reexport_uses = Vec::new();
      for directive in [Directive::Import, Directive::Export] {
        for uri in facts.uris(directive) {
          let Some(target) = self.resolve(uri, &file_rel) else {
            continue;
          };
          let own = self.entity_names_with_generated(&target);
          // Names the imported file passes along from what it re-exports.
          if directive == Directive::Import && !self.facts(&target).exports.is_empty() {
            let used: BTreeSet<String> = self
              .namespace(&target)
              .into_iter()
              .filter(|name| !own.contains(name) && !references(name).is_empty())
              .collect();
            if !used.is_empty() {
              reexport_uses.push((self.project.rel(&target), used));
            }
          }
          // Each of the target's entities the importer references, with the lines where it does.
          let entities_used = own
            .into_iter()
            .filter_map(|name| {
              let lines = references(&name);
              (!lines.is_empty()).then_some(EntityUse { name, lines })
            })
            .collect();
          rows.push((
            self.project.rel(&target),
            Row {
              file: file_rel.clone(),
              directive: directive.as_str().to_string(),
              uri: uri.clone(),
              entities_used,
            },
          ));
        }
      }
      (rows, reexport_uses)
    });

    // Grouped by target; rows keep file order within a target.
    let mut index = Importers::new();
    // file → re-exported names its direct importers use.
    let mut uses: HashMap<String, BTreeSet<String>> = HashMap::new();
    for (rows, reexport_uses) in scans {
      for (target, row) in rows {
        index.entry(target).or_default().push(row);
      }
      for (imported, names) in reexport_uses {
        uses.entry(imported).or_default().extend(names);
      }
    }

    // Exporters: the target's names used through the export, at the export's line.
    let mut found: Vec<(String, usize, Vec<(String, usize)>)> = Vec::new();
    for (target, rows) in &index {
      let Some(target_path) = self.project.existing(target) else {
        continue;
      };
      let namespace = self.namespace(&target_path);
      for (i, row) in rows.iter().enumerate().filter(|(_, r)| r.directive == "export") {
        let used = used_through_exports(&row.file, &uses, &index, &mut HashSet::new());
        let Some(exporter) = self.project.existing(&row.file) else {
          continue;
        };
        let facts = self.facts(&exporter);
        let export_lines: Vec<usize> = facts
          .exports
          .iter()
          .zip(&facts.export_lines)
          .filter(|(uri, _)| **uri == row.uri)
          .map(|(_, line)| *line)
          .collect();
        let hits: Vec<(String, usize)> = used
          .intersection(&namespace)
          .flat_map(|name| export_lines.iter().map(move |line| (name.clone(), *line)))
          .collect();
        if !hits.is_empty() {
          found.push((target.clone(), i, hits));
        }
      }
    }
    for (target, i, hits) in found {
      let used = &mut index.get_mut(&target).expect("found in index")[i].entities_used;
      for (name, line) in hits {
        match used.iter_mut().find(|u| u.name == name) {
          Some(entry) => {
            entry.lines.push(line);
            entry.lines.sort_unstable();
            entry.lines.dedup();
          }
          None => used.push(EntityUse { name, lines: vec![line] }),
        }
      }
    }
    Ok(index)
  }
}

/// FNV-1a over the file listing and the entry points: changes when a file is added or removed or the entry points change.
fn fingerprint(files: &[PathBuf], entries: &[String]) -> String {
  let mut hash = Fnv::default();
  for file in files {
    hash.feed(file.as_os_str().as_encoded_bytes());
  }
  for entry in entries {
    hash.feed(entry.as_bytes());
  }
  hash.hex()
}
