//! The dependency graph's cached views, built on what a language crate
//! computes: live files (reachability from the entry points), the importers
//! reverse index, and dead files (verified by a recursive trace and
//! cross-checked against the live list).

use crate::cache::{Caches, Slot};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::ops::Deref;
use std::path::Path;

/// The importer side of one edge in the importers index.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Row {
  pub file: String,
  pub directive: String,
  pub uri: String,
  /// The target's entities this importer references, each with the lines in the importer where it is used.
  pub entities_used: Vec<EntityUse>,
}

/// One of the target's entities that an importer uses, and every 1-based line in the importer where it is used, ascending and without duplicates.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntityUse {
  pub name: String,
  pub lines: Vec<usize>,
}

impl EntityUse {
  /// Builds the sorted list of entity uses from a name → lines map.
  pub fn from_map(map: BTreeMap<String, std::collections::BTreeSet<usize>>) -> Vec<EntityUse> {
    map
      .into_iter()
      .map(|(name, lines)| EntityUse { name, lines: lines.into_iter().collect() })
      .collect()
  }
}

/// target (repo-relative) → the files that depend on it.
pub type Importers = BTreeMap<String, Vec<Row>>;

/// What a language contributes to the graph.
pub trait Lang {
  /// The command that runs this language, used in usage messages (e.g. `discover --lang=dart`).
  const NAME: &'static str;

  /// Canonical project root.
  fn root(&self) -> &Path;

  /// Repo-relative entry points, the roots of liveness.
  fn entries(&self) -> &HashSet<String>;

  /// Repo-relative source files under analysis, in the order dead files
  /// are reported.
  fn sources(&self) -> Vec<String>;

  /// Names of a file's top-level entities, in declaration order.
  fn entity_names(&self, path: &Path) -> Vec<String>;

  /// Whether a file is source code that `trace` can follow. Assets are not;
  /// `usages --assets` looks those up.
  fn is_source(&self, _path: &Path) -> bool {
    true
  }

  /// Every file reachable from the entry points, repo-relative and sorted.
  fn compute_live(&self, caches: &Caches) -> Result<Vec<String>, String>;

  /// The importers index, built from scratch.
  fn compute_importers(&self, caches: &Caches) -> Result<Importers, String>;

  /// --rebuild-cache: rebuilds the language's own caches, before live.
  fn rebuild(&self, _caches: &Caches) -> Result<(), String> {
    Ok(())
  }

  /// prune: drops a file from the language's own caches, after live and
  /// importers have been pruned.
  fn prune(&mut self, _caches: &mut Caches, _file: &str) -> Result<(), String> {
    Ok(())
  }
}

pub struct Graph<L> {
  pub lang: L,
  pub caches: Caches,
  live: Slot,
  importers: Slot,
  dead: Slot,
}

/// The language's own fields and methods are reachable through the graph.
impl<L> Deref for Graph<L> {
  type Target = L;
  fn deref(&self) -> &L {
    &self.lang
  }
}

impl<L: Lang> Graph<L> {
  pub fn new(lang: L, caches: Caches) -> Self {
    Graph {
      live: caches.slot("live_cache.txt"),
      importers: caches.slot("importers_cache.json"),
      dead: caches.slot("dead.txt"),
      lang,
      caches,
    }
  }

  pub fn build_live(&self) -> Result<Vec<String>, String> {
    eprintln!("Building live-files cache");
    let lines = self.lang.compute_live(&self.caches)?;
    eprintln!("{} live files", lines.len());
    self.caches.put_lines(&self.live, &lines)?;
    Ok(lines)
  }

  pub fn live(&self) -> Result<Vec<String>, String> {
    match self.caches.lines(&self.live) {
      Some(lines) => Ok(lines),
      None => self.build_live(),
    }
  }

  pub fn build_importers(&self) -> Result<Importers, String> {
    eprintln!("importers: rebuilding");
    let index = self.lang.compute_importers(&self.caches)?;
    self.caches.put_json(&self.importers, &index)?;
    Ok(index)
  }

  pub fn importers(&self) -> Result<Importers, String> {
    match self.caches.json(&self.importers) {
      Some(index) => Ok(index),
      None => self.build_importers(),
    }
  }

  // ─────────────────────────────────────────────────────────
  // dead files — sources the recursive trace can't connect to
  // an entry point, cross-checked against the live list
  // ─────────────────────────────────────────────────────────

  pub fn build_dead(&self) -> Result<Vec<String>, String> {
    eprintln!("Building dead-files cache");
    let importers = self.importers()?;
    let live: HashSet<String> = self.live()?.into_iter().collect();
    let mut trace = Trace::new(&importers, self.lang.entries());

    let mut dead = Vec::new();
    let mut disagreements = 0;
    for rel in self.lang.sources() {
      let trace_dead = !trace.reachable(&rel);
      let bfs_dead = !live.contains(&rel);
      if trace_dead != bfs_dead {
        eprintln!("DISAGREEMENT: {rel} — trace says dead={trace_dead}, is-live says dead={bfs_dead}");
        disagreements += 1;
      }
      if trace_dead {
        dead.push(rel);
      }
    }
    eprintln!("{disagreements} disagreement(s)");

    self.caches.put_lines(&self.dead, &dead)?;
    Ok(dead)
  }

  pub fn dead(&self) -> Result<Vec<String>, String> {
    match self.caches.lines(&self.dead) {
      Some(lines) => Ok(lines),
      None => self.build_dead(),
    }
  }

  /// --rebuild-cache: the language's own caches, then live, importers, and
  /// dead (which reads both).
  pub fn build_all(&self) -> Result<(), String> {
    self.lang.rebuild(&self.caches)?;
    self.build_live()?;
    self.build_importers()?;
    self.build_dead()?;
    eprintln!("Done.");
    Ok(())
  }

  /// Every file the live list, dead list or importers index mentions, read from disk as they are: deleting a file changes the fingerprint, so the checked accessors would rebuild the very caches prune is about to patch.
  pub fn cached_files(&self) -> HashSet<String> {
    let mut files: HashSet<String> = crate::cache::read_lines(self.live.path()).into_iter().collect();
    files.extend(crate::cache::read_lines(self.dead.path()));
    if let Some(index) = std::fs::read_to_string(self.importers.path())
      .ok()
      .and_then(|t| serde_json::from_str::<Importers>(&t).ok())
    {
      for (target, rows) in index {
        files.insert(target);
        files.extend(rows.into_iter().map(|r| r.file));
      }
    }
    files
  }

  /// prune: drop one file from the live list and the importers index (as a
  /// target and as an importer), re-stamp both, then let the language prune
  /// its own caches.
  pub fn prune(&mut self, file: &str) -> Result<(), String> {
    let live = self.live.path();
    if live.is_file() {
      let kept: Vec<String> = crate::cache::read_lines(live).into_iter().filter(|l| l != file).collect();
      self.caches.write(live, &crate::cache::join_lines(&kept))?;
    }
    let importers = self.importers.path();
    if let Some(mut index) = std::fs::read_to_string(importers)
      .ok()
      .and_then(|t| serde_json::from_str::<Importers>(&t).ok())
    {
      index.remove(file);
      for rows in index.values_mut() {
        rows.retain(|r| r.file != file);
      }
      index.retain(|_, rows| !rows.is_empty());
      self.caches.write(importers, &crate::cache::to_json(&index)?)?;
    }
    self.lang.prune(&mut self.caches, file)
  }
}

/// Recursive reachability over the importers index, independent of the live
/// list. Reachable results are memoized; unreachable ones are not, since a
/// file can look unreachable only because an ancestor was on the current
/// recursion stack (cycle detection), and a later walk may find it live.
pub struct Trace<'a> {
  importers: &'a Importers,
  entries: &'a HashSet<String>,
  live: HashSet<String>,
  visiting: HashSet<String>,
}

impl<'a> Trace<'a> {
  pub fn new(importers: &'a Importers, entries: &'a HashSet<String>) -> Self {
    Trace {
      importers,
      entries,
      live: HashSet::new(),
      visiting: HashSet::new(),
    }
  }

  pub fn reachable(&mut self, file: &str) -> bool {
    if self.entries.contains(file) || self.live.contains(file) {
      return true;
    }
    if !self.visiting.insert(file.to_string()) {
      return false;
    }
    let importers = self.importers;
    let found = importers
      .get(file)
      .is_some_and(|rows| rows.iter().any(|r| self.reachable(&r.file)));
    self.visiting.remove(file);
    if found {
      self.live.insert(file.to_string());
    }
    found
  }
}
