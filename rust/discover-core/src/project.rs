//! Project plumbing every language shares: finding the root and cache
//! directory, path conversions, file listing, discover.conf and custom entry points.

use serde::Deserialize;
use std::collections::BTreeMap;
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

/// What discover.conf sets for one project: just a language, or a language and entry points.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum ProjectConfig {
  /// `"/path/to/project": dart`
  Lang(String),
  /// `"/path/to/project": { lang: dart, entries: [lib/main.dart] }`
  Full { lang: Option<String>, entries: Option<Vec<String>> },
}

impl ProjectConfig {
  /// The language this config sets, if any.
  pub fn lang(&self) -> Option<String> {
    match self {
      ProjectConfig::Lang(lang) => Some(lang.clone()),
      ProjectConfig::Full { lang, .. } => lang.clone(),
    }
  }

  /// The entry points this config lists; an empty list counts as none.
  pub fn entries(&self) -> Option<&[String]> {
    match self {
      ProjectConfig::Lang(_) => None,
      ProjectConfig::Full { entries, .. } => entries.as_deref().filter(|e| !e.is_empty()),
    }
  }
}

/// The config for the current directory, or None when no file sets one. Each discover.conf is a YAML mapping (JSON is valid YAML) of project directory to [`ProjectConfig`]; `./discover.conf` is read before the one in the XDG config directory.
pub fn project_config() -> Option<ProjectConfig> {
  // The directory as given and as resolved, so a key written either way matches through a symlink.
  let raw = env::current_dir().ok()?;
  let keys = [raw.clone(), fs::canonicalize(&raw).unwrap_or(raw)];
  // Uses $XDG_CONFIG_HOME as the config directory, falling back to ~/.config.
  let config_dir = env::var_os("XDG_CONFIG_HOME")
    .map(PathBuf::from)
    .or_else(|| env::var_os("HOME").map(|home| Path::new(&home).join(".config")));
  // Lists the config files in the order they are read.
  let paths = [Some(PathBuf::from("discover.conf")), config_dir.map(|dir| dir.join("discover.conf"))];
  // Returns the first config found, going through the paths that could be built.
  paths.iter().flatten().find_map(|path| {
    // Reads the file, moving on to the next one when it doesn't exist.
    let text = fs::read_to_string(path).ok()?;
    // Parses the file; one holding only comments is an empty mapping.
    match serde_yaml::from_str::<Option<BTreeMap<String, ProjectConfig>>>(&text) {
      // Looks up the current directory under either spelling.
      Ok(projects) => {
        let mut projects = projects?;
        keys.iter().find_map(|key| projects.remove(key.to_str()?))
      }
      // Warns about a file that isn't valid and moves on.
      Err(e) => {
        eprintln!("warning: ignoring {}: {e}", path.display());
        None
      }
    }
  })
}

/// Entry points the project chose, which are used instead of the language's defaults: DISCOVER_ENTRY="<file> ..." first, else `entries` in discover.conf. Repo-relative, in order and without repeats; None when neither is set. Every listed file must exist.
pub fn custom_entries(root: &Path) -> Result<Option<Vec<String>>, String> {
  // Reads the environment first, because it overrides the config file for one run.
  let listed: Vec<String> = match env::var("DISCOVER_ENTRY").ok().filter(|v| !v.is_empty()) {
    Some(list) => list.split_whitespace().map(str::to_string).collect(),
    None => match project_config().as_ref().and_then(ProjectConfig::entries) {
      Some(entries) => entries.to_vec(),
      None => return Ok(None),
    },
  };
  let mut entries: Vec<String> = Vec::new();
  for word in &listed {
    let abs = to_abs(root, word);
    if !abs.is_file() {
      return Err(format!("entry point not found: {word}"));
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
