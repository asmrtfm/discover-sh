//! The declaration index and name resolution.
//!
//! JVM imports name declarations (com.example.Foo, or a member such as
//! com.example.Foo.bar), not files, and a file may use anything declared in
//! its own package without importing it. So instead of mapping import
//! strings to paths, every source file's package and top-level declarations
//! are indexed and names resolve against that. A file depends on another
//! when it imports one of its declarations, or uses one by name through its
//! own package or a wildcard (`.*`) import.

use crate::{Decl, Facts, Import};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// Per source file: its package, imports, top-level declarations, whether it
/// holds a `main`, and the project names it references.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct FileIndex {
  pub pkg: String,
  pub imports: Vec<Import>,
  pub decls: Vec<Decl>,
  pub main: bool,
  pub idents: BTreeSet<String>,
}

impl From<Facts> for FileIndex {
  fn from(f: Facts) -> Self {
    FileIndex {
      pkg: f.package,
      imports: f.imports,
      decls: f.decls,
      main: f.main,
      idents: f.idents,
    }
  }
}

/// repo-relative file → its index entry.
pub type Index = BTreeMap<String, FileIndex>;

/// How a name became visible to a file.
#[derive(Clone, Debug)]
pub struct Hit {
  pub file: String,
  /// local | import | package | wildcard
  pub via: &'static str,
  /// The declaration's own name.
  pub name: Option<String>,
  /// The part of an import past the declaration (e.g. a companion member).
  pub member: Option<String>,
}

/// One dependency between source files.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Edge {
  pub file: String,
  pub target: String,
  /// import | package | import,package — how the target became visible.
  pub directive: String,
  pub uri: String,
  /// The target's declarations the file actually references.
  pub entities_used: Vec<String>,
}

pub struct Tables<'a> {
  pub index: &'a Index,
  /// Fully-qualified name → files declaring it (public declarations only).
  fqn: HashMap<String, Vec<String>>,
  /// Package → files.
  pkgs: HashMap<String, Vec<String>>,
}

fn qualify(pkg: &str, name: &str) -> String {
  if pkg.is_empty() { name.to_string() } else { format!("{pkg}.{name}") }
}

impl<'a> Tables<'a> {
  pub fn new(index: &'a Index) -> Self {
    let mut fqn: HashMap<String, Vec<String>> = HashMap::new();
    let mut pkgs: HashMap<String, Vec<String>> = HashMap::new();
    for (file, entry) in index {
      for d in entry.decls.iter().filter(|d| !d.private) {
        fqn.entry(qualify(&entry.pkg, &d.name)).or_default().push(file.clone());
      }
      pkgs.entry(entry.pkg.clone()).or_default().push(file.clone());
    }
    Tables { index, fqn, pkgs }
  }

  pub fn files_declaring(&self, fqn: &str) -> &[String] {
    self.fqn.get(fqn).map_or(&[], Vec::as_slice)
  }

  fn package_files(&self, pkg: &str) -> &[String] {
    self.pkgs.get(pkg).map_or(&[], Vec::as_slice)
  }

  pub fn public_names(&self, file: &str) -> BTreeSet<&str> {
    self
      .index
      .get(file)
      .map(|e| e.decls.iter().filter(|d| !d.private).map(|d| d.name.as_str()).collect())
      .unwrap_or_default()
  }

  /// The longest prefix of a dotted path that names a declaration.
  fn longest(&self, path: &str) -> Option<String> {
    let parts: Vec<&str> = path.split('.').collect();
    (1..=parts.len())
      .rev()
      .map(|n| parts[..n].join("."))
      .find(|cand| self.fqn.contains_key(cand))
  }

  fn qualified(&self, path: &str, via: &'static str) -> Vec<Hit> {
    let Some(cand) = self.longest(path) else {
      return Vec::new();
    };
    let name = cand.rsplit('.').next().unwrap_or(&cand).to_string();
    let member = (cand != path).then(|| path[cand.len() + 1..].to_string());
    self
      .files_declaring(&cand)
      .iter()
      .map(|file| Hit {
        file: file.clone(),
        via,
        name: Some(name.clone()),
        member: member.clone(),
      })
      .collect()
  }

  fn in_package(&self, pkg: &str, name: &str, via: &'static str) -> Vec<Hit> {
    self
      .package_files(pkg)
      .iter()
      .filter(|f| self.public_names(f).contains(name))
      .map(|file| Hit {
        file: file.clone(),
        via,
        name: Some(name.to_string()),
        member: None,
      })
      .collect()
  }

  /// Resolves an import path (`a.b.C`, `a.b.*`) or, with `from`, a simple
  /// name as seen from that file: declared there, imported, in its own
  /// package, or through a wildcard import — the first of those that finds
  /// anything.
  pub fn lookup(&self, spec: &str, from: &str) -> Vec<Hit> {
    if from.is_empty() || spec.contains('.') {
      if let Some(pkg) = spec.strip_suffix(".*") {
        return self
          .package_files(pkg)
          .iter()
          .chain(self.files_declaring(pkg))
          .map(|file| Hit {
            file: file.clone(),
            via: "wildcard",
            name: None,
            member: None,
          })
          .collect();
      }
      return self.qualified(spec, "import");
    }

    let Some(me) = self.index.get(from) else {
      return Vec::new();
    };
    let own: Vec<Hit> = me
      .decls
      .iter()
      .filter(|d| d.name == spec)
      .map(|_| Hit {
        file: from.to_string(),
        via: "local",
        name: Some(spec.to_string()),
        member: None,
      })
      .collect();
    let imported: Vec<Hit> = me
      .imports
      .iter()
      .filter(|i| !i.wildcard && i.local() == spec)
      .flat_map(|i| self.qualified(&i.path, "import"))
      .collect();
    let same_package: Vec<Hit> = self
      .in_package(&me.pkg, spec, "package")
      .into_iter()
      .filter(|h| h.file != from)
      .collect();
    let wild: Vec<Hit> = me
      .imports
      .iter()
      .filter(|i| i.wildcard)
      .flat_map(|i| {
        let mut hits = self.in_package(&i.path, spec, "wildcard");
        // A wildcard over a declaration's members (e.g. an object's).
        let name = i.path.rsplit('.').next().unwrap_or(&i.path).to_string();
        hits.extend(self.files_declaring(&i.path).iter().map(|file| Hit {
          file: file.clone(),
          via: "wildcard",
          name: Some(name.clone()),
          member: Some(spec.to_string()),
        }));
        hits
      })
      .collect();
    [own, imported, same_package, wild]
      .into_iter()
      .find(|tier| !tier.is_empty())
      .unwrap_or_default()
  }

  /// Every dependency between source files, one per (file, target), sorted.
  /// Explicit single-name imports are edges even when unused (stale);
  /// package and wildcard visibility only counts when something is used.
  pub fn edges(&self) -> Vec<Edge> {
    let mut raw: Vec<Edge> = Vec::new();
    for (file, me) in self.index {
      let used = |t: &str| -> Vec<String> {
        self
          .public_names(t)
          .into_iter()
          .filter(|n| me.idents.contains(*n))
          .map(str::to_string)
          .collect()
      };

      // Explicit imports: the declaration (or the one holding the imported member).
      for imp in me.imports.iter().filter(|i| !i.wildcard) {
        let local = imp.local();
        for hit in self.qualified(&imp.path, "import") {
          if &hit.file == file {
            continue;
          }
          let mut entities = used(&hit.file);
          if me.idents.contains(local) {
            entities.extend(hit.name.clone());
          }
          raw.push(Edge {
            file: file.clone(),
            target: hit.file,
            directive: "import".into(),
            uri: imp.spec.clone(),
            entities_used: entities,
          });
        }
      }

      // Wildcard imports: a whole package (counts only when used), or a
      // declaration's members (always counts; members are not indexed).
      for imp in me.imports.iter().filter(|i| i.wildcard) {
        let targets = self
          .files_declaring(&imp.path)
          .iter()
          .map(|t| (t, true))
          .chain(self.package_files(&imp.path).iter().map(|t| (t, false)));
        for (target, always) in targets {
          if target == file {
            continue;
          }
          let hit = used(target);
          if always || !hit.is_empty() {
            raw.push(Edge {
              file: file.clone(),
              target: target.clone(),
              directive: "import".into(),
              uri: imp.spec.clone(),
              entities_used: hit,
            });
          }
        }
      }

      // Same package, no import: counts only when used.
      for target in self.package_files(&me.pkg) {
        if target == file {
          continue;
        }
        let hit = used(target);
        if !hit.is_empty() {
          raw.push(Edge {
            file: file.clone(),
            target: target.clone(),
            directive: "package".into(),
            uri: me.pkg.clone(),
            entities_used: hit,
          });
        }
      }
    }

    // One edge per (file, target), merging how it was reached.
    let mut merged: BTreeMap<(String, String), (BTreeSet<String>, BTreeSet<String>, BTreeSet<String>)> =
      BTreeMap::new();
    for e in raw {
      let slot = merged.entry((e.file, e.target)).or_default();
      slot.0.insert(e.directive);
      slot.1.insert(e.uri);
      slot.2.extend(e.entities_used);
    }
    merged
      .into_iter()
      .map(|((file, target), (directives, uris, used))| Edge {
        file,
        target,
        directive: directives.into_iter().collect::<Vec<_>>().join(","),
        uri: uris.into_iter().collect::<Vec<_>>().join(", "),
        entities_used: used.into_iter().collect(),
      })
      .collect()
  }
}
