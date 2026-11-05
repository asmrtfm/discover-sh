//! The JVM side of the graph and its own caches: the declaration index,
//! entry points, and the dependency edges that live files and the importers
//! index are built from. Caching of those views, dead files and trace come
//! from discover-core.

use crate::index::{Edge, Index, Tables};
use crate::project::Project;
use crate::{Decl, Jvm, parse};
use discover_core::cache::{self, Caches, Slot, read_lines, to_json};
use discover_core::graph::{Importers, Lang, Row};
use discover_core::par::par_map;
use discover_core::project::custom_entries;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::Path;

pub type Graph<J> = discover_core::graph::Graph<JvmLang<J>>;

pub struct JvmLang<J> {
  pub project: Project<J>,
  pub index: Index,
  /// Repo-relative entry points, the roots of liveness.
  pub entries: Vec<String>,
  pub entry_set: HashSet<String>,
  edges: Slot,
}

/// Loads (or builds) the index, which every lookup — entry detection
/// included — depends on, then detects the entry points. `rebuild` forces
/// the index (--rebuild-cache).
pub fn open<J: Jvm>(project: Project<J>, rebuild: bool) -> Result<Graph<J>, String> {
  let caches = Caches::new(project.cache_dir.clone(), J::CACHE_PREFIX, project.fingerprint());
  let index = match caches.read_json::<Index>(&caches.path("index.json")) {
    Some(index) if !rebuild && !caches.force() => index,
    _ => build_index(&project, &caches)?,
  };
  let mut lang = JvmLang {
    project,
    index,
    entries: Vec::new(),
    entry_set: HashSet::new(),
    edges: caches.slot("edges.json"),
  };
  lang.detect_entries()?;
  Ok(Graph::new(lang, caches))
}

// ─────────────────────────────────────────────────────────
// index — per source file: package, imports, top-level
// declarations, `main`, and the names it references
// ─────────────────────────────────────────────────────────

fn build_index<J: Jvm>(project: &Project<J>, caches: &Caches) -> Result<Index, String> {
  eprintln!("index: rebuilding");
  let files = project.relevant_files();
  let entries = par_map(&files, |rel| {
    let facts = fs::read_to_string(project.root.join(rel))
      .map(|src| J::extract(&parse::<J>(&src)))
      .unwrap_or_default();
    (rel.clone(), facts.into())
  });
  let index: Index = entries.into_iter().collect();
  caches.write(&caches.path("index.json"), &to_json(&index)?)?;
  Ok(index)
}

/// Top-level declarations of a file, with header and full text.
pub fn decls<J: Jvm>(path: &Path) -> Vec<Decl> {
  fs::read_to_string(path)
    .map(|src| J::extract(&parse::<J>(&src)).decls)
    .unwrap_or_default()
}

impl<J: Jvm> JvmLang<J> {
  pub fn tables(&self) -> Tables<'_> {
    Tables::new(&self.index)
  }

  // ─────────────────────────────────────────────────────────
  // entry points — DISCOVER_ENTRY or `entries` in discover.conf
  // (repo-relative files) replace the defaults; otherwise every root the runtime
  // itself starts from: files declaring a `main`, Android
  // manifest components (instantiated by the OS by name) and
  // META-INF/services providers (instantiated by ServiceLoader).
  // Classes reached only through reflection or DI annotation
  // scanning can't be seen — list them in discover.conf.
  // ─────────────────────────────────────────────────────────

  fn detect_entries(&mut self) -> Result<(), String> {
    if let Some(listed) = custom_entries(&self.project.root)? {
      self.entry_set = listed.iter().cloned().collect();
      self.entries = listed;
      return Ok(());
    }

    let mut found: BTreeSet<String> = BTreeSet::new();
    let tables = Tables::new(&self.index);
    found.extend(self.index.iter().filter(|(_, e)| e.main).map(|(f, _)| f.clone()));
    // Names not declared in the project (library components such as
    // androidx's FileProvider) simply don't resolve.
    let names = self
      .project
      .manifest_components()
      .into_iter()
      .chain(self.project.service_providers());
    for name in names {
      found.extend(tables.files_declaring(&name).iter().cloned());
    }
    self.entry_set = found.iter().cloned().collect();
    self.entries = found.into_iter().collect();
    Ok(())
  }

  fn require_entries(&self) -> Result<(), String> {
    if self.entries.is_empty() {
      return Err("no entry point found (list them under entries in discover.conf, see: discover config)".into());
    }
    Ok(())
  }

  // ─────────────────────────────────────────────────────────
  // edges — every dependency between source files
  // ─────────────────────────────────────────────────────────

  fn build_edges(&self, caches: &Caches) -> Result<Vec<Edge>, String> {
    eprintln!("edges: rebuilding");
    let edges = self.tables().edges();
    caches.put_json(&self.edges, &edges)?;
    Ok(edges)
  }

  fn edges(&self, caches: &Caches) -> Result<Vec<Edge>, String> {
    match caches.json(&self.edges) {
      Some(edges) => Ok(edges),
      None => self.build_edges(caches),
    }
  }
}

impl<J: Jvm> Lang for JvmLang<J> {
  const NAME: &'static str = J::NAME;

  fn root(&self) -> &Path {
    &self.project.root
  }

  fn entries(&self) -> &HashSet<String> {
    &self.entry_set
  }

  fn sources(&self) -> Vec<String> {
    self.project.relevant_files()
  }

  fn entity_names(&self, path: &Path) -> Vec<String> {
    decls::<J>(path).into_iter().map(|d| d.name).collect()
  }

  // ─────────────────────────────────────────────────────────
  // live files — reachability from the entry points
  // ─────────────────────────────────────────────────────────

  fn compute_live(&self, caches: &Caches) -> Result<Vec<String>, String> {
    self.require_entries()?;
    let mut adjacency: HashMap<String, Vec<String>> = HashMap::new();
    for e in self.edges(caches)? {
      adjacency.entry(e.file).or_default().push(e.target);
    }

    let mut live: HashSet<String> = self.entries.iter().cloned().collect();
    let mut queue: Vec<String> = self.entries.clone();
    while let Some(current) = queue.pop() {
      for target in adjacency.get(&current).into_iter().flatten() {
        if live.insert(target.clone()) {
          queue.push(target.clone());
        }
      }
    }

    let mut lines: Vec<String> = live.into_iter().collect();
    lines.sort();
    Ok(lines)
  }

  // ─────────────────────────────────────────────────────────
  // importers — the edges grouped by target
  // ─────────────────────────────────────────────────────────

  fn compute_importers(&self, caches: &Caches) -> Result<Importers, String> {
    let mut index = Importers::new();
    for e in self.edges(caches)? {
      index.entry(e.target).or_default().push(Row {
        file: e.file,
        directive: e.directive,
        uri: e.uri,
        entities_used: e.entities_used,
      });
    }
    Ok(index)
  }

  /// --rebuild-cache (after the index, rebuilt by [`open`]): edges, before
  /// live and importers, which are built from them.
  fn rebuild(&self, caches: &Caches) -> Result<(), String> {
    self.build_edges(caches).map(|_| ())
  }

  /// prune: remove one file (after deleting it) from the rest of the caches
  /// — the dead list, the index and both ends of every edge — then re-stamp
  /// every cache with a fresh fingerprint, so nothing has to be rebuilt.
  fn prune(&mut self, caches: &mut Caches, file: &str) -> Result<(), String> {
    let dead = caches.path("dead.txt");
    if dead.is_file() {
      let kept: Vec<String> = read_lines(&dead).into_iter().filter(|l| l != file).collect();
      fs::write(&dead, cache::join_lines(&kept)).map_err(|e| e.to_string())?;
    }
    self.index.remove(file);
    fs::write(caches.path("index.json"), to_json(&self.index)?).map_err(|e| e.to_string())?;
    if let Some(edges) = fs::read_to_string(self.edges.path())
      .ok()
      .and_then(|t| serde_json::from_str::<Vec<Edge>>(&t).ok())
    {
      let kept: Vec<Edge> = edges.into_iter().filter(|e| e.file != file && e.target != file).collect();
      fs::write(self.edges.path(), to_json(&kept)?).map_err(|e| e.to_string())?;
    }

    // Stamp a fresh fingerprint so patched caches aren't treated as stale.
    caches.set_fingerprint(self.project.fingerprint());
    let all = [
      caches.path("index.json"),
      self.edges.path().to_path_buf(),
      caches.path("live_cache.txt"),
      caches.path("dead.txt"),
      caches.path("importers_cache.json"),
    ];
    for cache in all.iter().filter(|c| c.is_file()) {
      caches.stamp(cache)?;
    }
    Ok(())
  }
}
