//! Dart's side of the import graph: parsed facts per file, live files
//! (reachability from lib/main.dart over import, export and part
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
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// The root of liveness, relative to the project root.
pub const ENTRY: &str = "lib/main.dart";

pub type Graph = discover_core::graph::Graph<DartLang>;

pub struct DartLang {
  pub project: Project,
  /// Parsed facts per canonical path, shared across threads.
  facts: Memo<PathBuf, Arc<Facts>>,
  /// Entity-name patterns, built once each (None when the name isn't a valid pattern).
  patterns: Memo<String, Option<Arc<Pattern>>>,
  /// Just [`ENTRY`].
  entries: HashSet<String>,
}

/// The graph over a project, its caches stamped with the source listing.
pub fn open(project: Project) -> Graph {
  let fingerprint = fingerprint(&project.relevant_files());
  let caches = Caches::new(project.cache_dir.clone(), "discover_rs_", fingerprint);
  let lang = DartLang {
    project,
    facts: Memo::default(),
    patterns: Memo::default(),
    entries: HashSet::from([ENTRY.to_string()]),
  };
  Graph::new(lang, caches)
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
}

impl Lang for DartLang {
  const NAME: &'static str = "discover-dart";

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
  // live files — breadth-first reachability from lib/main.dart
  // over import, export and part directives
  // ─────────────────────────────────────────────────────────

  fn compute_live(&self, _caches: &Caches) -> Result<Vec<String>, String> {
    let main = self
      .project
      .existing(ENTRY)
      .ok_or("lib/main.dart not found")?;

    let mut live: HashSet<PathBuf> = HashSet::from([main.clone()]);
    // Level by level so each frontier is parsed in parallel.
    let mut frontier = vec![main];
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
  // export it, with the target's entities each one references
  // ─────────────────────────────────────────────────────────

  fn compute_importers(&self, _caches: &Caches) -> Result<Importers, String> {
    let files = self.project.relevant_files();

    // One parse per importer: its directives and every entity-name check.
    let edges: Vec<Vec<(String, Row)>> = par_map(&files, |file| {
      let Ok(src) = fs::read_to_string(file) else {
        return Vec::new();
      };
      let root = dart::parse(&src);
      let facts = dart::extract(&root);
      let file_rel = self.project.rel(file);
      let mut rows = Vec::new();
      for directive in [Directive::Import, Directive::Export] {
        for uri in facts.uris(directive) {
          let Some(target) = self.resolve(uri, &file_rel) else {
            continue;
          };
          // Each of the target's entities the importer references, with the lines where it does.
          let entities_used = self
            .entity_names_with_generated(&target)
            .into_iter()
            .filter_map(|name| {
              let pattern = self.pattern(&name)?;
              let lines = dart::references(&root, &pattern);
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

/// FNV-1a over the file listing: changes when a file is added or removed.
fn fingerprint(files: &[PathBuf]) -> String {
  let mut hash = Fnv::default();
  for file in files {
    hash.feed(file.as_os_str().as_encoded_bytes());
  }
  hash.hex()
}
