//! Project plumbing every language shares: finding the root and cache
//! directory, path conversions, file listing, and DISCOVER_ENTRY.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The directory the command is run from, canonical. Every path is
/// relative to it.
pub fn current_dir() -> Result<PathBuf, String> {
  let cwd = env::current_dir().map_err(|e| format!("cannot read working directory: {e}"))?;
  fs::canonicalize(&cwd).map_err(|e| format!("cannot resolve working directory {}: {e}", cwd.display()))
}

/// Errors unless `dir` holds one of the project's manifest files (e.g.
/// pubspec.yaml), i.e. unless the command was run from the project root.
pub fn require_manifest(dir: &Path, names: &[&str]) -> Result<(), String> {
  if names.iter().any(|n| dir.join(n).is_file()) {
    return Ok(());
  }
  Err(format!(
    "no {} in {}: run this from the project root",
    names.join(" or "),
    dir.display()
  ))
}

/// The cache directory, created if missing: $CACHE_DIR when set (e.g. to
/// keep caches out of a project's tmp/), else `<root>/tmp`.
pub fn cache_dir(root: &Path) -> Result<PathBuf, String> {
  let cache_dir = env::var_os("CACHE_DIR")
    .filter(|v| !v.is_empty())
    .map(PathBuf::from)
    .unwrap_or_else(|| root.join("tmp"));
  fs::create_dir_all(&cache_dir).map_err(|e| format!("cannot create cache dir: {}: {e}", cache_dir.display()))?;
  Ok(cache_dir)
}

/// A user-supplied path: absolute as given, else relative to the root.
pub fn to_abs(root: &Path, path: &str) -> PathBuf {
  if path.starts_with('/') {
    PathBuf::from(path)
  } else {
    root.join(path)
  }
}

/// Canonical path of a repo-relative file, if it exists.
pub fn existing(root: &Path, rel: &str) -> Option<PathBuf> {
  let path = fs::canonicalize(root.join(rel)).ok()?;
  path.is_file().then_some(path)
}

/// The real directory of an importing file given repo-relative (or, failing
/// that, as given), for resolving relative specifiers against.
pub fn importing_dir(root: &Path, from_file: &str) -> Option<PathBuf> {
  let mut from = root.join(from_file);
  if !from.is_file() {
    from = PathBuf::from(from_file);
  }
  let from = fs::canonicalize(&from).unwrap_or(from);
  from.parent().map(Path::to_path_buf)
}

pub fn in_git(root: &Path) -> bool {
  Command::new("git")
    .arg("-C")
    .arg(root)
    .args(["rev-parse", "--is-inside-work-tree"])
    .output()
    .is_ok_and(|o| o.status.success())
}

/// Repo-relative files matching git pathspecs (tracked plus untracked, minus
/// ignored), or None outside a git work tree.
pub fn git_listing(root: &Path, pathspecs: &[&str]) -> Option<Vec<String>> {
  if !in_git(root) {
    return None;
  }
  let files = Command::new("git")
    .arg("-C")
    .arg(root)
    .args(["ls-files", "-z", "-co", "--exclude-standard", "--"])
    .args(pathspecs)
    .output()
    .map(|o| {
      String::from_utf8_lossy(&o.stdout)
        .split('\0')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
    })
    .unwrap_or_default();
  Some(files)
}

/// Every non-directory entry under `dir` with its own (not followed)
/// metadata, skipping directories named in `skip`. Symlinked directories
/// are not descended into; symlinks are reported, for the caller to keep or
/// drop.
pub fn walk(dir: &Path, skip: &[&str], found: &mut dyn FnMut(&Path, &fs::Metadata)) {
  let Ok(entries) = fs::read_dir(dir) else { return };
  for entry in entries.flatten() {
    let path = entry.path();
    let Ok(meta) = fs::symlink_metadata(&path) else { continue };
    if meta.is_dir() {
      if !entry.file_name().to_str().is_some_and(|n| skip.contains(&n)) {
        walk(&path, skip, found);
      }
    } else {
      found(&path, &meta);
    }
  }
}

/// DISCOVER_ENTRY="<file> ..." as repo-relative paths, in order and without
/// repeats; None when unset. Every listed file must exist.
pub fn entries_from_env(root: &Path) -> Result<Option<Vec<String>>, String> {
  let Some(list) = env::var("DISCOVER_ENTRY").ok().filter(|v| !v.is_empty()) else {
    return Ok(None);
  };
  let mut entries: Vec<String> = Vec::new();
  for word in list.split_whitespace() {
    let abs = to_abs(root, word);
    if !abs.is_file() {
      return Err(format!("DISCOVER_ENTRY file not found: {word}"));
    }
    let rel = fs::canonicalize(&abs).map(|p| relative(root, &p)).unwrap_or_default();
    if !rel.is_empty() && !entries.contains(&rel) {
      entries.push(rel);
    }
  }
  Ok(Some(entries))
}

/// `path` relative to `base` (both canonical), with `..` where needed.
pub fn relative(base: &Path, path: &Path) -> String {
  let base: Vec<_> = base.components().collect();
  let target: Vec<_> = path.components().collect();
  let common = base.iter().zip(&target).take_while(|(a, b)| a == b).count();
  let mut out = PathBuf::new();
  for _ in common..base.len() {
    out.push("..");
  }
  for component in &target[common..] {
    out.push(component);
  }
  if out.as_os_str().is_empty() {
    ".".to_string()
  } else {
    out.to_string_lossy().into_owned()
  }
}

#[cfg(test)]
mod test {
  use super::*;

  #[test]
  fn relative_paths() {
    let base = Path::new("/a/b");
    assert_eq!(relative(base, Path::new("/a/b/lib/x.dart")), "lib/x.dart");
    assert_eq!(relative(base, Path::new("/a/c/x.dart")), "../c/x.dart");
    assert_eq!(relative(base, Path::new("/a/b")), ".");
  }
}
