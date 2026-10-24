//! The project being navigated: where it lives, what it calls itself, which
//! files are under analysis, and how a directive's URI maps to a file.

use discover_core::project::{self, relative};
use std::fs;
use std::path::{Path, PathBuf};

pub struct Project {
  /// The directory the command is run from, canonical.
  pub root: PathBuf,
  pub lib: PathBuf,
  /// pubspec.yaml `name:`; `package:<name>/…` URIs resolve into lib/.
  pub package: Option<String>,
  pub cache_dir: PathBuf,
}

impl Project {
  /// The project in the directory the command is run from, which must hold
  /// its pubspec.yaml.
  pub fn discover() -> Result<Self, String> {
    let root = project::current_dir()?;
    project::require_manifest(&root, &["pubspec.yaml"])?;
    let lib = root.join("lib");
    let package = read_package_name(&root.join("pubspec.yaml"));
    let cache_dir = project::cache_dir(&root)?;
    Ok(Project {
      root,
      lib,
      package,
      cache_dir,
    })
  }

  /// Repo-relative form of a canonical path (`realpath --relative-to`).
  pub fn rel(&self, path: &Path) -> String {
    relative(&self.root, path)
  }

  /// Canonical path of a repo-relative file, if it exists.
  pub fn existing(&self, rel: &str) -> Option<PathBuf> {
    project::existing(&self.root, rel)
  }

  /// The source files under analysis: every *.dart under lib/ except
  /// generated *.g.dart / *.freezed.dart, sorted, as canonical paths.
  /// Like `find`, symlinked directories are not descended into.
  pub fn relevant_files(&self) -> Vec<PathBuf> {
    let mut found = Vec::new();
    project::walk(&self.lib, &[], &mut |path, _| {
      let name = path.file_name().unwrap_or_default().to_string_lossy();
      if name.ends_with(".dart") && !name.ends_with(".g.dart") && !name.ends_with(".freezed.dart") {
        found.push(path.to_path_buf());
      }
    });
    found.sort();
    found
      .into_iter()
      .filter_map(|p| fs::canonicalize(p).ok())
      .collect()
  }

  /// Resolves a directive URI to a repo-relative file. Nothing for `dart:`
  /// libraries and other packages: external code is never scanned.
  pub fn resolve_uri(&self, uri: &str, from_file: &str) -> Option<String> {
    if uri.starts_with("dart:") {
      return None;
    }
    if let Some(rest) = uri.strip_prefix("package:") {
      let package = self.package.as_deref()?;
      let rel = rest.strip_prefix(package)?.strip_prefix('/')?;
      return self.existing_file(&self.lib.join(rel));
    }
    if from_file.is_empty() {
      return None;
    }
    // Relative to the importing file's (real) directory.
    self.existing_file(&project::importing_dir(&self.root, from_file)?.join(uri))
  }

  fn existing_file(&self, path: &Path) -> Option<String> {
    let path = fs::canonicalize(path).ok()?;
    path.is_file().then(|| self.rel(&path))
  }
}

/// The top-level `name:` of pubspec.yaml.
fn read_package_name(pubspec: &Path) -> Option<String> {
  let text = fs::read_to_string(pubspec).ok()?;
  text.lines().find_map(|line| {
    let value = line.strip_prefix("name:")?.trim();
    let value = value.trim_matches(|c| c == '"' || c == '\'');
    (!value.is_empty()).then(|| value.to_string())
  })
}
