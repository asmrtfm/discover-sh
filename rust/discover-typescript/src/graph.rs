//! TypeScript's side of the import graph: parsed facts per file, live files
//! (reachability from the entry points over import, export and dynamic
//! directives), and the importers index. Caching, dead files and trace come
//! from discover-core.
//!
//! Besides entity names, an importer's `entities_used` carries markers for
//! references that have no name to match:
//!   "default"       — a default-import binding that the importer uses
//!   "*"             — `export * from` re-exports everything
//!   "(side-effect)" — `import "./x"` runs the module for its effects
//!   "(dynamic)"     — import()/require(), consumed at runtime

use crate::project::Project;
use crate::ts::{self, Directive, Facts, is_script};
use discover_core::cache::{Caches, Fnv};
use discover_core::graph::{Importers, Lang, Row};
use discover_core::memo::Memo;
use discover_core::par::par_map;
use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub type Graph = discover_core::graph::Graph<TsLang>;

pub struct TsLang {
  pub project: Project,
  /// Parsed facts per canonical path, shared across threads.
  facts: Memo<PathBuf, Arc<Facts>>,
}

/// The graph over a project, its caches stamped with the source listing,
/// the entry points and tsconfig.json.
pub fn open(project: Project) -> Graph {
  let fingerprint = fingerprint(&project);
  let caches = Caches::new(project.cache_dir.clone(), "discover_rs_typescript_", fingerprint);
  Graph::new(
    TsLang {
      project,
      facts: Memo::default(),
    },
    caches,
  )
}

impl TsLang {
  /// Facts for a file, parsed on first use. Non-scripts and unreadable
  /// files have none.
  pub fn facts(&self, path: &Path) -> Arc<Facts> {
    self.facts.get(path, || {
      Arc::new(if is_script(&path.to_string_lossy()) {
        fs::read_to_string(path)
          .map(|src| ts::extract(&ts::parse(&src, ts::lang_for(path))))
          .unwrap_or_default()
      } else {
        Facts::default()
      })
    })
  }

  /// Resolves a specifier from a repo-relative file to the target's canonical path.
  pub fn resolve(&self, uri: &str, from_rel: &str) -> Option<PathBuf> {
    let rel = self.project.resolve_uri(uri, from_rel)?;
    self.project.existing(&rel)
  }
}

impl Lang for TsLang {
  const NAME: &'static str = "discover-typescript";

  fn root(&self) -> &Path {
    &self.project.root
  }

  fn entries(&self) -> &HashSet<String> {
    &self.project.entry_set
  }

  fn sources(&self) -> Vec<String> {
    self.project.relevant_files().iter().map(|f| self.project.rel(f)).collect()
  }

  fn entity_names(&self, path: &Path) -> Vec<String> {
    self.facts(path).entity_names()
  }

  // ─────────────────────────────────────────────────────────
  // live files — breadth-first reachability from the entry
  // points over import, export and dynamic directives
  // ─────────────────────────────────────────────────────────

  fn compute_live(&self, _caches: &Caches) -> Result<Vec<String>, String> {
    if self.project.entries.is_empty() {
      return Err("no entry point found (set DISCOVER_ENTRY to the repo-relative entry file(s))".into());
    }

    let mut frontier: Vec<PathBuf> = self
      .project
      .entries
      .iter()
      .filter_map(|e| self.project.existing(e))
      .collect();
    let mut live: HashSet<PathBuf> = frontier.iter().cloned().collect();
    // Level by level so each frontier is parsed in parallel.
    while !frontier.is_empty() {
      let found: Vec<Vec<PathBuf>> = par_map(&frontier, |current| {
        let current_rel = self.project.rel(current);
        let facts = self.facts(current);
        [Directive::Import, Directive::Export, Directive::Dynamic]
          .iter()
          .flat_map(|d| facts.specs(*d).to_vec())
          .filter_map(|spec| self.resolve(&spec.text, &current_rel))
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
  // importers — reverse index: target → files that import,
  // re-export or load it, with what each one uses
  // ─────────────────────────────────────────────────────────

  fn compute_importers(&self, _caches: &Caches) -> Result<Importers, String> {
    let files = self.project.graph_files();

    let edges: Vec<Vec<(String, Row)>> = par_map(&files, |file| {
      let facts = self.facts(file);
      let file_rel = self.project.rel(file);
      let mut rows = Vec::new();
      for directive in [Directive::Import, Directive::Export, Directive::Dynamic] {
        for spec in facts.specs(directive) {
          let Some(target) = self.resolve(&spec.text, &file_rel) else {
            continue;
          };
          let entities_used = if directive == Directive::Dynamic {
            vec!["(dynamic)".to_string()]
          } else {
            used_entities(&facts, &self.facts(&target), &spec.text, directive)
          };
          rows.push((
            self.project.rel(&target),
            Row {
              file: file_rel.clone(),
              directive: directive.as_str().to_string(),
              uri: spec.text.clone(),
              entities_used,
            },
          ));
        }
      }
      rows
    });

    // Grouped by target; rows keep file order within a target.
    let mut index = Importers::new();
    for (target, row) in edges.into_iter().flatten() {
      index.entry(target).or_default().push(row);
    }
    Ok(index)
  }
}

/// Which of the target's entities an importer uses through one specifier:
/// entity names it references, plus the markers documented at the top.
fn used_entities(importer: &Facts, target: &Facts, uri: &str, directive: Directive) -> Vec<String> {
  let mine: Vec<_> = importer
    .bindings
    .iter()
    .filter(|b| b.src.as_deref() == Some(uri))
    .collect();
  let mut used: BTreeSet<String> = target
    .entity_names()
    .into_iter()
    .filter(|n| importer.idents.contains(n))
    .collect();
  if directive == Directive::Export && mine.iter().any(|b| b.id == "export-star") {
    used.insert("*".to_string());
  }
  if directive == Directive::Import {
    if mine.iter().any(|b| b.id == "import-bare") {
      used.insert("(side-effect)".to_string());
    }
    let default_used = mine.iter().any(|b| {
      b.id == "import-default" && b.local.as_ref().is_some_and(|l| importer.idents.contains(l))
    });
    if default_used {
      used.insert("default".to_string());
    }
  }
  used.into_iter().collect()
}

/// FNV-1a over the source listing, the entry points and tsconfig.json
/// (aliases change what imports resolve to). Changes when a file is added
/// or removed; import-content changes need --rebuild-cache.
fn fingerprint(project: &Project) -> String {
  let mut hash = Fnv::default();
  for file in project.relevant_files() {
    hash.feed(file.as_os_str().as_encoded_bytes());
  }
  for entry in &project.entries {
    hash.feed(entry.as_bytes());
  }
  hash.feed(&fs::read(&project.tsconfig).unwrap_or_default());
  hash.hex()
}
