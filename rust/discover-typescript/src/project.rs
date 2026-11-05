//! The project being navigated: root, source files, tsconfig path aliases,
//! module resolution and entry points. Nothing project-specific is
//! hardcoded; it is all read from the project:
//!   source files — TypeScript and JavaScript modules the project hasn't gitignored (declaration files and tests excluded)
//!   path aliases — tsconfig.json compilerOptions.paths / baseUrl, following `extends`
//!   entry points — $DISCOVER_ENTRY or `entries` in discover.conf, else what package.json and the docker files start, else the conventional index/server/app/main module at the root or in src/

use crate::ts::is_script;
use discover_core::project::{self, relative};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Project {
  /// The directory the command is run from, canonical.
  pub root: PathBuf,
  pub cache_dir: PathBuf,
  pub tsconfig: PathBuf,
  /// `paths` patterns with their absolute substitutions, in tsconfig order.
  aliases: Vec<(String, String)>,
  /// Absolute baseUrl, consulted after `paths`.
  base_url: Option<String>,
  /// Repo-relative entry points, the roots of liveness.
  pub entries: Vec<String>,
  pub entry_set: HashSet<String>,
}

impl Project {
  /// The project in the directory the command is run from, which must hold
  /// its package.json or tsconfig.json.
  pub fn discover() -> Result<Self, String> {
    let root = project::current_dir()?;
    project::require_manifest(&root, &["package.json", "tsconfig.json"])?;
    let cache_dir = project::cache_dir(&root)?;
    let tsconfig = root.join("tsconfig.json");
    let (aliases, base_url) = load_aliases(&tsconfig);
    let mut project = Project {
      root,
      cache_dir,
      tsconfig,
      aliases,
      base_url,
      entries: Vec::new(),
      entry_set: HashSet::new(),
    };
    project.detect_entries()?;
    Ok(project)
  }

  /// Repo-relative form of a canonical path (`realpath --relative-to`).
  pub fn rel(&self, path: &Path) -> String {
    relative(&self.root, path)
  }

  pub fn to_abs(&self, path: &str) -> PathBuf {
    project::to_abs(&self.root, path)
  }

  /// Canonical path of a repo-relative file, if it exists.
  pub fn existing(&self, rel: &str) -> Option<PathBuf> {
    project::existing(&self.root, rel)
  }

  /// Repo-relative TypeScript and JavaScript sources: git's view when available, so
  /// node_modules, build output and anything else the project ignores never
  /// enters the graph; otherwise a walk that at least skips installed packages.
  fn source_listing(&self) -> Vec<String> {
    const EXTS: [&str; 8] = [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"];
    if let Some(files) = project::git_listing(&self.root, &["*.ts", "*.tsx", "*.mts", "*.cts", "*.js", "*.jsx", "*.mjs", "*.cjs"]) {
      return files;
    }
    let mut found = Vec::new();
    project::walk(&self.root, &["node_modules", ".git"], &mut |path, meta| {
      let rel = relative(&self.root, path);
      if meta.is_file() && EXTS.iter().any(|e| rel.ends_with(e)) {
        found.push(rel);
      }
    });
    found
  }

  /// The source files under analysis, canonical and sorted. Declaration files
  /// carry no runtime code and tests are never reachable from an entry point,
  /// so both are excluded.
  pub fn relevant_files(&self) -> Vec<PathBuf> {
    let mut rels: Vec<String> = self
      .source_listing()
      .into_iter()
      .filter(|f| !is_excluded(f))
      .collect();
    rels.sort();
    rels
      .iter()
      .filter_map(|f| self.existing(f))
      .collect()
  }

  /// Files whose imports form the graph: the sources plus the entry points, which may be excluded from the sources (e.g. an entry under a test directory). Without them their edges would be missing from the importers index and everything below them would trace as dead.
  pub fn graph_files(&self) -> Vec<PathBuf> {
    let mut files = self.relevant_files();
    files.extend(self.entries.iter().filter_map(|e| self.existing(e)));
    files.sort();
    files.dedup();
    files
  }

  /// Resolves a module specifier to a repo-relative file. Nothing for node:
  /// builtins and packages (bare specifiers no tsconfig alias claims).
  pub fn resolve_uri(&self, uri: &str, from_file: &str) -> Option<String> {
    if uri.starts_with("node:") {
      return None;
    }
    if matches!(uri, "." | "..") || uri.starts_with("./") || uri.starts_with("../") {
      if from_file.is_empty() {
        return None;
      }
      let base = project::importing_dir(&self.root, from_file)?.join(uri);
      return self.resolve_module_path(&base.to_string_lossy());
    }
    if uri.starts_with('/') {
      return self.resolve_module_path(uri);
    }
    self.resolve_alias(uri)
  }

  /// TypeScript picks the `paths` pattern with the longest prefix before its
  /// `*` (an exact pattern beats any wildcard), then tries that pattern's
  /// substitutions in order. baseUrl is the last resort.
  fn resolve_alias(&self, uri: &str) -> Option<String> {
    let mut best: Option<(&str, String)> = None;
    let mut best_len: isize = -1;
    for (pattern, _) in &self.aliases {
      let Some(star_at) = pattern.find('*') else {
        if pattern == uri {
          best = Some((pattern, String::new()));
          break;
        }
        continue;
      };
      let (prefix, suffix) = (&pattern[..star_at], &pattern[star_at + 1..]);
      if !uri.starts_with(prefix) || !uri.ends_with(suffix) || uri.len() < prefix.len() + suffix.len() {
        continue;
      }
      if prefix.len() as isize > best_len {
        best_len = prefix.len() as isize;
        best = Some((pattern, uri[prefix.len()..uri.len() - suffix.len()].to_string()));
      }
    }

    if let Some((pattern, star)) = best {
      for (p, target) in &self.aliases {
        if p != pattern {
          continue;
        }
        if let Some(hit) = self.resolve_module_path(&target.replacen('*', &star, 1)) {
          return Some(hit);
        }
      }
    }
    let base = self.base_url.as_ref()?;
    self.resolve_module_path(&format!("{base}/{uri}"))
  }

  /// Applies TypeScript's extension rules to a candidate path:
  ///   - a .js/.jsx/.mjs/.cjs specifier maps to its TS source first
  ///   - an extensionless one tries each script extension, then a directory index
  ///   - any other existing file (JSON, images, styles) resolves as itself,
  ///     so imported assets show up in the graph
  pub fn resolve_module_path(&self, base: &str) -> Option<String> {
    if base.is_empty() {
      return None;
    }
    let mut candidates = Vec::new();
    if let Some(stem) = base.strip_suffix(".js") {
      candidates.push(format!("{stem}.ts"));
      candidates.push(format!("{stem}.tsx"));
    } else if let Some(stem) = base.strip_suffix(".jsx") {
      candidates.push(format!("{stem}.tsx"));
    } else if let Some(stem) = base.strip_suffix(".mjs") {
      candidates.push(format!("{stem}.mts"));
    } else if let Some(stem) = base.strip_suffix(".cjs") {
      candidates.push(format!("{stem}.cts"));
    }
    candidates.push(base.to_string());
    for ext in [".ts", ".tsx", ".js", ".jsx"] {
      candidates.push(format!("{base}{ext}"));
    }
    for ext in [".ts", ".tsx", ".js", ".jsx"] {
      candidates.push(format!("{base}/index{ext}"));
    }
    candidates
      .iter()
      .map(Path::new)
      .find(|p| p.is_file())
      .and_then(|p| fs::canonicalize(p).ok())
      .map(|p| self.rel(&p))
  }

  fn add_entry(&mut self, rel: String) {
    if !rel.is_empty() && self.entry_set.insert(rel.clone()) {
      self.entries.push(rel);
    }
  }

  /// Adds a path the project starts from, unless it isn't a source file the project keeps (`main` often points at build output).
  fn add_started(&mut self, target: &str, git: bool) {
    let Some(rel) = self.resolve_module_path(&self.root.join(target).to_string_lossy()) else {
      return;
    };
    if is_script(&rel) && !is_excluded(&rel) && !(git && self.git_ignored(&rel)) {
      self.add_entry(rel);
    }
  }

  /// Entry points, in order of precedence:
  ///   custom entries (DISCOVER_ENTRY or discover.conf), used instead of everything below
  ///   everything the project starts: package.json source/module/main/bin, the files package.json scripts run, Dockerfile CMD/ENTRYPOINT and docker-compose command
  ///   otherwise the first of index / server / app / main, at the root or in src/, that exists
  fn detect_entries(&mut self) -> Result<(), String> {
    if let Some(listed) = project::custom_entries(&self.root)? {
      listed.into_iter().for_each(|rel| self.add_entry(rel));
      return Ok(());
    }

    let git = project::in_git(&self.root);
    let pkg = fs::read_to_string(self.root.join("package.json"))
      .ok()
      .and_then(|t| serde_json::from_str::<Value>(&t).ok());
    let mut started: Vec<String> = pkg.as_ref().map(package_targets).unwrap_or_default();
    started.extend(docker_targets(&self.root));
    for target in started {
      self.add_started(&target, git);
    }
    if !self.entries.is_empty() {
      return Ok(());
    }

    for base in ["index", "src/index", "server", "src/server", "app", "src/app", "src/main", "main"] {
      if let Some(rel) = self.resolve_module_path(&self.root.join(base).to_string_lossy()) {
        if is_script(&rel) {
          self.add_entry(rel);
          break;
        }
      }
    }
    Ok(())
  }

  fn git_ignored(&self, rel: &str) -> bool {
    Command::new("git")
      .arg("-C")
      .arg(&self.root)
      .args(["check-ignore", "-q", rel])
      .status()
      .is_ok_and(|s| s.success())
  }
}

/// The files package.json says start the project: source/module/main, bin (a path or a map of command to path) and what its scripts run.
pub fn package_targets(pkg: &Value) -> Vec<String> {
  let mut targets: Vec<String> = ["source", "module", "main"]
    .iter()
    .filter_map(|k| pkg.get(k)?.as_str().map(str::to_string))
    .collect();
  match pkg.get("bin") {
    Some(Value::String(path)) => targets.push(path.clone()),
    Some(Value::Object(paths)) => targets.extend(paths.values().filter_map(Value::as_str).map(str::to_string)),
    _ => {}
  }
  let scripts = pkg.get("scripts").and_then(Value::as_object);
  for command in scripts.into_iter().flat_map(|s| s.values()).filter_map(Value::as_str) {
    targets.extend(runner_targets(command).into_iter().map(str::to_string));
  }
  targets
}

/// The file arguments of JS runtimes in a shell command. A word starting with `-` is a flag, not a file.
pub fn runner_targets(command: &str) -> Vec<&str> {
  let words: Vec<&str> = command.split_whitespace().collect();
  words
    .windows(2)
    .filter(|pair| matches!(pair[0], "node" | "nodemon" | "ts-node" | "tsx" | "bun") && !pair[1].starts_with('-'))
    .map(|pair| pair[1].trim_matches(['"', '\'', ';']))
    .collect()
}

/// Whether a file at the project root is a Dockerfile or a compose file.
pub fn is_docker_file(name: &str) -> bool {
  let compose = (name.starts_with("docker-compose") || name.starts_with("compose")) && (name.ends_with(".yml") || name.ends_with(".yaml"));
  compose || name == "Dockerfile" || name.starts_with("Dockerfile.") || name.ends_with(".Dockerfile")
}

/// What one Dockerfile or compose file line runs, with the exec-form and quoting characters blanked so `["node", "x.js"]` and `sh -c "node x.js"` read as plain words. None for any other line.
pub fn docker_command(line: &str) -> Option<String> {
  let line = line.trim();
  let lower = line.to_ascii_lowercase();
  let prefix = ["cmd ", "entrypoint ", "command:", "entrypoint:"].iter().find(|p| lower.starts_with(**p))?;
  Some(line[prefix.len()..].replace(['[', ']', ',', '"', '\''], " "))
}

/// The files the docker files at the project root run.
fn docker_targets(root: &Path) -> Vec<String> {
  let mut files: Vec<PathBuf> = fs::read_dir(root)
    .into_iter()
    .flatten()
    .flatten()
    .filter(|e| is_docker_file(&e.file_name().to_string_lossy()))
    .map(|e| e.path())
    .collect();
  // Sorted because directory order varies and entries feed the fingerprint.
  files.sort();
  let mut targets = Vec::new();
  for text in files.iter().filter_map(|f| fs::read_to_string(f).ok()) {
    for command in text.lines().filter_map(docker_command) {
      targets.extend(runner_targets(&command).into_iter().map(str::to_string));
    }
  }
  targets
}

/// Declaration files and tests (*.test.*, *.spec.*, __tests__/, __mocks__/, test/, tests/).
pub fn is_excluded(rel: &str) -> bool {
  [".d.ts", ".d.mts", ".d.cts"].iter().any(|e| rel.ends_with(e))
    || rel.contains(".test.")
    || rel.contains(".spec.")
    || ["__tests__/", "__mocks__/", "test/", "tests/"]
      .iter()
      .any(|d| rel.starts_with(d) || rel.contains(&format!("/{d}")))
}

// ─────────────────────────────────────────────────────────
// tsconfig path aliases — non-relative specifiers that still
// point into the project
// ─────────────────────────────────────────────────────────

/// Parses JSONC (comments, trailing commas), which tsconfig files are.
pub fn read_jsonc(path: &Path) -> Option<Value> {
  let text = fs::read_to_string(path).ok()?;
  serde_json::from_str(&strip_jsonc(&text)).ok()
}

/// Drops `//` and `/* */` comments and commas directly before a closing
/// bracket, leaving string literals intact.
pub fn strip_jsonc(src: &str) -> String {
  let chars: Vec<char> = src.chars().collect();
  let mut no_comments = String::with_capacity(src.len());
  let mut i = 0;
  while i < chars.len() {
    let c = chars[i];
    if c == '"' {
      let start = i;
      i += 1;
      while i < chars.len() && chars[i] != '"' {
        i += if chars[i] == '\\' { 2 } else { 1 };
      }
      i = (i + 1).min(chars.len());
      no_comments.extend(&chars[start..i]);
    } else if c == '/' && chars.get(i + 1) == Some(&'/') {
      while i < chars.len() && chars[i] != '\n' {
        i += 1;
      }
    } else if c == '/' && chars.get(i + 1) == Some(&'*') {
      i += 2;
      while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
        i += 1;
      }
      i = (i + 2).min(chars.len());
    } else {
      no_comments.push(c);
      i += 1;
    }
  }

  let chars: Vec<char> = no_comments.chars().collect();
  let mut out = String::with_capacity(no_comments.len());
  let mut i = 0;
  while i < chars.len() {
    let c = chars[i];
    if c == '"' {
      let start = i;
      i += 1;
      while i < chars.len() && chars[i] != '"' {
        i += if chars[i] == '\\' { 2 } else { 1 };
      }
      i = (i + 1).min(chars.len());
      out.extend(&chars[start..i]);
      continue;
    }
    if c == ',' {
      let next = chars[i + 1..].iter().find(|c| !c.is_whitespace());
      if matches!(next, Some('}' | ']')) {
        i += 1;
        continue;
      }
    }
    out.push(c);
    i += 1;
  }
  out
}

/// The absolute path of an inherited config. Relative values are file paths
/// (".json" optional); anything else names a package, looked up in the
/// nearest node_modules walking up from the extending config.
fn resolve_extends(spec: &str, dir: &Path) -> Option<PathBuf> {
  let mut candidates = Vec::new();
  if spec.starts_with("./") || spec.starts_with("../") || spec.starts_with('/') {
    let path = if spec.starts_with('/') { PathBuf::from(spec) } else { dir.join(spec) };
    candidates.push(path.clone());
    candidates.push(PathBuf::from(format!("{}.json", path.display())));
  } else {
    for nm in dir.ancestors() {
      let base = nm.join("node_modules").join(spec);
      candidates.push(base.clone());
      candidates.push(PathBuf::from(format!("{}.json", base.display())));
      candidates.push(base.join("tsconfig.json"));
    }
  }
  candidates
    .into_iter()
    .find(|p| p.is_file())
    .and_then(|p| fs::canonicalize(p).ok())
}

#[derive(Default)]
struct Collected {
  base_url: Option<PathBuf>,
  paths: Option<(serde_json::Map<String, Value>, PathBuf)>,
  seen: HashSet<PathBuf>,
}

/// Walks the `extends` chain; the nearest config to set an option wins.
fn collect(cfg: &Path, acc: &mut Collected) {
  if !acc.seen.insert(cfg.to_path_buf()) {
    return;
  }
  let Some(json) = read_jsonc(cfg) else { return };
  let dir = cfg.parent().unwrap_or(Path::new("/")).to_path_buf();
  let options = json.get("compilerOptions");

  if acc.base_url.is_none() {
    if let Some(base) = options.and_then(|o| o.get("baseUrl")).and_then(Value::as_str) {
      acc.base_url = Some(normalize(&dir.join(base)));
    }
  }
  if acc.paths.is_none() {
    if let Some(paths) = options.and_then(|o| o.get("paths")).and_then(Value::as_object) {
      acc.paths = Some((paths.clone(), dir.clone()));
    }
  }
  if acc.base_url.is_some() && acc.paths.is_some() {
    return;
  }

  // `extends` is a string or (TS 5+) an array whose later entries override
  // earlier ones, so walk it last-to-first.
  let parents: Vec<String> = match json.get("extends") {
    Some(Value::String(s)) => vec![s.clone()],
    Some(Value::Array(a)) => a.iter().rev().filter_map(Value::as_str).map(str::to_string).collect(),
    _ => Vec::new(),
  };
  for parent in parents {
    if let Some(path) = resolve_extends(&parent, &dir) {
      collect(&path, acc);
    }
  }
}

/// `paths` rows (pattern → absolute substitution, tsconfig order) and baseUrl.
/// Substitutions are relative to baseUrl when one is in effect, otherwise to
/// the config that declared `paths`.
fn load_aliases(tsconfig: &Path) -> (Vec<(String, String)>, Option<String>) {
  let mut acc = Collected::default();
  if let Ok(cfg) = fs::canonicalize(tsconfig) {
    collect(&cfg, &mut acc);
  }
  let base_url = acc.base_url.as_ref().map(|p| p.to_string_lossy().into_owned());
  let mut aliases = Vec::new();
  if let Some((paths, dir)) = &acc.paths {
    let base = acc.base_url.clone().unwrap_or_else(|| dir.clone());
    for (pattern, targets) in paths {
      for target in targets.as_array().into_iter().flatten().filter_map(Value::as_str) {
        aliases.push((pattern.clone(), format!("{}/{}", base.display(), target)));
      }
    }
  }
  (aliases, base_url)
}

/// Lexical `..`/`.` cleanup (realpath -m for paths that may not exist).
fn normalize(path: &Path) -> PathBuf {
  let mut out = PathBuf::new();
  for c in path.components() {
    match c {
      std::path::Component::ParentDir => {
        out.pop();
      }
      std::path::Component::CurDir => {}
      other => out.push(other),
    }
  }
  out
}
