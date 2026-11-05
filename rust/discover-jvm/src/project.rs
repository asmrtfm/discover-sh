//! The project being navigated: root, source files, and the files that
//! declare framework entry points. Nothing project-specific is hardcoded:
//!   source files — the language's sources the project hasn't gitignored (tests and buildSrc excluded)
//!   entry points — $DISCOVER_ENTRY or `entries` in discover.conf, else every `main` function, Android
//!                  manifest components and META-INF/services providers

use crate::Jvm;
use discover_core::cache::Fnv;
use discover_core::project::{self, custom_entries, relative};
use std::fs;
use std::marker::PhantomData;
use std::path::{Path, PathBuf};

pub struct Project<J> {
  /// The directory the command is run from, canonical.
  pub root: PathBuf,
  pub cache_dir: PathBuf,
  lang: PhantomData<J>,
}

impl<J: Jvm> Project<J> {
  /// The project in the directory the command is run from, which must hold
  /// its Gradle or Maven build.
  pub fn discover() -> Result<Self, String> {
    let root = project::current_dir()?;
    project::require_manifest(
      &root,
      &["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", "pom.xml"],
    )?;
    let cache_dir = project::cache_dir(&root)?;
    Ok(Project {
      root,
      cache_dir,
      lang: PhantomData,
    })
  }

  pub fn rel(&self, path: &Path) -> String {
    relative(&self.root, path)
  }

  pub fn to_abs(&self, path: &str) -> PathBuf {
    project::to_abs(&self.root, path)
  }

  /// Repo-relative files matching git pathspecs: git's view when available,
  /// so build output and anything else the project ignores never enters the
  /// graph; otherwise a walk that at least skips build output.
  fn listing(&self, pathspecs: &[&str], matches: impl Fn(&str) -> bool) -> Vec<String> {
    if let Some(files) = project::git_listing(&self.root, pathspecs) {
      return files;
    }
    let mut found = Vec::new();
    project::walk(&self.root, &["build", ".gradle", ".git"], &mut |path, meta| {
      let rel = relative(&self.root, path);
      if meta.is_file() && matches(&rel) {
        found.push(rel);
      }
    });
    found
  }

  /// Keeps app code: drops test sources (src/test, src/androidTest,
  /// src/testFixtures, …) and Gradle build logic (buildSrc), neither of which
  /// is reachable from the app's entry points, and files that no longer exist.
  fn app_only(&self, files: Vec<String>) -> Vec<String> {
    let mut kept: Vec<String> = files
      .into_iter()
      .filter(|f| !is_test_or_build_logic(f))
      .filter(|f| self.root.join(f).is_file())
      .collect();
    kept.sort();
    kept
  }

  /// Repo-relative source files under analysis, sorted.
  pub fn relevant_files(&self) -> Vec<String> {
    let files = self.listing(&[J::PATHSPEC], |f| f.ends_with(J::EXT));
    self.app_only(files)
  }

  pub fn manifest_files(&self) -> Vec<String> {
    let files = self.listing(&["*AndroidManifest.xml"], |f| f.ends_with("AndroidManifest.xml"));
    self.app_only(files)
  }

  pub fn service_files(&self) -> Vec<String> {
    let files = self.listing(&["*META-INF/services/*"], |f| f.contains("META-INF/services/"));
    self.app_only(files)
  }

  /// XML files (resources and manifests) for resource reference lookups.
  pub fn xml_files(&self) -> Vec<String> {
    let files = self.listing(&["*.xml"], |f| f.ends_with(".xml"));
    self.app_only(files)
  }

  /// Fully-qualified class names the manifests declare as components.
  /// Relative names (`.Foo`, or no dot at all) are relative to the app's
  /// package: the manifest's `package` attribute, or the module's Gradle
  /// `namespace` in AGP 7+.
  pub fn manifest_components(&self) -> Vec<String> {
    let mut names = Vec::new();
    for manifest in self.manifest_files() {
      let Ok(text) = fs::read_to_string(self.root.join(&manifest)) else { continue };
      let body = strip_xml_comments(&text);
      let tags = tags(&body, &[
        "application",
        "activity",
        "activity-alias",
        "service",
        "receiver",
        "provider",
        "instrumentation",
      ]);
      let pkg = tags_named(&body, "manifest")
        .first()
        .and_then(|t| attribute(t, "package"))
        .or_else(|| self.gradle_namespace(&manifest))
        .unwrap_or_default();
      for tag in tags {
        let Some(name) = attribute(&tag, "android:name") else { continue };
        // Nested classes are written Outer$Inner in manifests.
        let name = name.replace('$', ".");
        names.push(if name.starts_with('.') {
          format!("{pkg}{name}")
        } else if name.contains('.') {
          name
        } else {
          format!("{pkg}.{name}")
        });
      }
    }
    names
  }

  /// `namespace` from the build file of the module holding a manifest
  /// (<module>/src/<sourceSet>/AndroidManifest.xml, or a legacy module-root one).
  fn gradle_namespace(&self, manifest: &str) -> Option<String> {
    let module = if manifest.starts_with("src/") {
      ".".to_string()
    } else if let Some(i) = manifest.find("/src/") {
      manifest[..i].to_string()
    } else {
      Path::new(manifest).parent()?.to_string_lossy().into_owned()
    };
    ["build.gradle", "build.gradle.kts"].iter().find_map(|f| {
      let text = fs::read_to_string(self.root.join(&module).join(f)).ok()?;
      text.lines().find_map(|line| {
        let rest = line.trim_start().strip_prefix("namespace")?;
        let rest = rest.trim_start().strip_prefix('=').unwrap_or(rest).trim_start();
        let quote = rest.chars().next().filter(|c| *c == '"' || *c == '\'')?;
        rest[1..].split(quote).next().map(str::to_string)
      })
    })
  }

  /// Fully-qualified class names listed in META-INF/services files.
  pub fn service_providers(&self) -> Vec<String> {
    let mut names = Vec::new();
    for file in self.service_files() {
      let Ok(text) = fs::read_to_string(self.root.join(&file)) else { continue };
      for line in text.lines() {
        let line = line.split('#').next().unwrap_or("");
        let name: String = line.chars().filter(|c| !c.is_whitespace()).collect();
        if !name.is_empty() {
          names.push(name.replace('$', "."));
        }
      }
    }
    names
  }

  /// Fingerprint of everything the graph is built from: every source file's
  /// mtime and size (a file's dependencies change when ANY file in its
  /// package gains or loses a declaration), the entry-point declarations,
  /// and any custom entry points.
  pub fn fingerprint(&self) -> String {
    let mut hash = Fnv::default();
    let files = self
      .relevant_files()
      .into_iter()
      .chain(self.manifest_files())
      .chain(self.service_files());
    for file in files {
      if let Ok(meta) = fs::metadata(self.root.join(&file)) {
        let mtime = meta
          .modified()
          .ok()
          .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
          .map_or(0, |d| d.as_nanos());
        hash.feed(format!("{mtime} {} {file}", meta.len()).as_bytes());
      }
    }
    hash.feed(custom_entries(&self.root).ok().flatten().unwrap_or_default().join("\n").as_bytes());
    hash.hex()
  }
}

/// A file under a test source set (a directory `src/<…[Tt]est…>/`) or
/// under `buildSrc/`. Only directories count, not the file name itself.
pub fn is_test_or_build_logic(rel: &str) -> bool {
  let segments: Vec<&str> = rel.split('/').collect();
  let dirs = &segments[..segments.len().saturating_sub(1)];
  let test_source_set = dirs
    .windows(2)
    .any(|w| w[0] == "src" && (w[1].contains("test") || w[1].contains("Test")));
  test_source_set || dirs.contains(&"buildSrc")
}

/// The XML with comments removed, so commented-out components don't count.
pub fn strip_xml_comments(xml: &str) -> String {
  let mut out = String::with_capacity(xml.len());
  let mut rest = xml;
  while let Some(start) = rest.find("<!--") {
    out.push_str(&rest[..start]);
    rest = match rest[start..].find("-->") {
      Some(end) => &rest[start + end + 3..],
      None => "",
    };
  }
  out.push_str(rest);
  out
}

/// Opening tags (`<name …`, up to `>`) for any of the given element names.
pub fn tags(xml: &str, names: &[&str]) -> Vec<String> {
  names.iter().flat_map(|n| tags_named(xml, n)).collect()
}

pub fn tags_named(xml: &str, name: &str) -> Vec<String> {
  let open = format!("<{name}");
  let mut found = Vec::new();
  let mut rest = xml;
  while let Some(i) = rest.find(&open) {
    let after = &rest[i + open.len()..];
    // `<activity` must not match `<activity-alias`.
    if after.starts_with(char::is_whitespace) {
      let end = after.find('>').unwrap_or(after.len());
      found.push(after[..end].to_string());
    }
    rest = after;
  }
  found
}

/// The value of `attr="…"` in a tag's attribute text.
pub fn attribute(tag: &str, attr: &str) -> Option<String> {
  let key = format!("{attr}=\"");
  let mut rest = tag;
  while let Some(i) = rest.find(&key) {
    let before_ok = rest[..i].chars().next_back().is_none_or(char::is_whitespace);
    let value = &rest[i + key.len()..];
    if before_ok {
      return value.split('"').next().map(str::to_string);
    }
    rest = value;
  }
  None
}
