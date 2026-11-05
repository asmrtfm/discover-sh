//! On-disk caches, each stamped with the fingerprint it was built from
//! (`<cache>.fp`), so one cache's check never makes another look current.

use serde::Serialize;
use serde::de::DeserializeOwned;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

/// One cache file and whether it has already been force-rebuilt this run.
pub struct Slot {
  path: PathBuf,
  forced: AtomicBool,
}

impl Slot {
  pub fn path(&self) -> &Path {
    &self.path
  }
}

/// `--no-rebuild`: set by the CLI before any [`Caches`] is created.
static SKIP_REBUILD: AtomicBool = AtomicBool::new(false);

/// Makes every [`Caches`] created afterwards use the caches on disk as they
/// are, ignoring stamps and forcing; a cache is still built when it is
/// missing or doesn't parse.
pub fn skip_rebuild() {
  SKIP_REBUILD.store(true, Ordering::Relaxed);
}

pub struct Caches {
  dir: PathBuf,
  /// Prepended to every cache file name, e.g. `discover_rs_kotlin_`.
  prefix: String,
  /// Fingerprint of what the caches are built from; see [`Fnv`].
  fingerprint: String,
  /// FORCE_REBUILD / BUST_CACHE: rebuild each cache (once per run) regardless of stamps.
  force: bool,
  /// `--no-rebuild`: any existing cache counts as current; see [`skip_rebuild`].
  skip: bool,
}

impl Caches {
  pub fn new(dir: PathBuf, prefix: &str, fingerprint: String) -> Self {
    let skip = SKIP_REBUILD.load(Ordering::Relaxed);
    // Skipping wins over the environment's forcing.
    let force = !skip
      && ["FORCE_REBUILD", "BUST_CACHE"]
        .iter()
        .any(|v| std::env::var(v).is_ok_and(|s| s == "true"));
    Caches {
      dir,
      prefix: prefix.to_string(),
      fingerprint,
      force,
      skip,
    }
  }

  pub fn slot(&self, name: &str) -> Slot {
    Slot {
      path: self.path(name),
      forced: AtomicBool::new(false),
    }
  }

  /// A cache file's path, for caches that don't need a [`Slot`].
  pub fn path(&self, name: &str) -> PathBuf {
    self.dir.join(format!("{}{name}", self.prefix))
  }

  pub fn force(&self) -> bool {
    self.force
  }

  /// Replaces the fingerprint new stamps are written with (after prune
  /// changes what the caches describe).
  pub fn set_fingerprint(&mut self, fingerprint: String) {
    self.fingerprint = fingerprint;
  }

  /// Whether a cache file is current: stamped with the current fingerprint,
  /// or, with `--no-rebuild`, merely present.
  pub fn is_valid(&self, cache: &Path) -> bool {
    cache.is_file()
      && (self.skip || fs::read_to_string(stamp_path(cache)).is_ok_and(|s| s.trim() == self.fingerprint))
  }

  /// Whether a cache must be rebuilt now: forced (once per run), or stale.
  fn needs_build(&self, slot: &Slot) -> bool {
    (self.force && !slot.forced.load(Ordering::Relaxed)) || !self.is_valid(&slot.path)
  }

  /// A line-list cache's contents, or None when it must be rebuilt.
  pub fn lines(&self, slot: &Slot) -> Option<Vec<String>> {
    (!self.needs_build(slot)).then(|| read_lines(&slot.path))
  }

  /// A JSON cache's contents, or None when it must be rebuilt or doesn't parse.
  pub fn json<T: DeserializeOwned>(&self, slot: &Slot) -> Option<T> {
    if self.needs_build(slot) {
      return None;
    }
    self.read_json(&slot.path)
  }

  /// A JSON cache's contents if it is current and parses, ignoring forcing.
  pub fn read_json<T: DeserializeOwned>(&self, cache: &Path) -> Option<T> {
    if !self.is_valid(cache) {
      return None;
    }
    serde_json::from_str(&fs::read_to_string(cache).ok()?).ok()
  }

  /// Writes a line-list cache, stamps it, and marks it rebuilt for this run.
  pub fn put_lines(&self, slot: &Slot, lines: &[String]) -> Result<(), String> {
    self.write(&slot.path, &join_lines(lines))?;
    slot.forced.store(true, Ordering::Relaxed);
    Ok(())
  }

  /// Writes a JSON cache, stamps it, and marks it rebuilt for this run.
  pub fn put_json<T: Serialize>(&self, slot: &Slot, value: &T) -> Result<(), String> {
    self.write(&slot.path, &to_json(value)?)?;
    slot.forced.store(true, Ordering::Relaxed);
    Ok(())
  }

  /// Writes a cache file and stamps it with the current fingerprint.
  pub fn write(&self, cache: &Path, contents: &str) -> Result<(), String> {
    fs::write(cache, contents).map_err(|e| format!("cannot write {}: {e}", cache.display()))?;
    self.stamp(cache)
  }

  pub fn stamp(&self, cache: &Path) -> Result<(), String> {
    fs::write(stamp_path(cache), format!("{}\n", self.fingerprint))
      .map_err(|e| format!("cannot write {}: {e}", stamp_path(cache).display()))
  }
}

pub fn to_json<T: Serialize>(value: &T) -> Result<String, String> {
  serde_json::to_string(value).map_err(|e| e.to_string())
}

fn stamp_path(cache: &Path) -> PathBuf {
  let mut name = cache.as_os_str().to_os_string();
  name.push(".fp");
  PathBuf::from(name)
}

pub fn read_lines(path: &Path) -> Vec<String> {
  fs::read_to_string(path)
    .unwrap_or_default()
    .lines()
    .filter(|l| !l.is_empty())
    .map(str::to_string)
    .collect()
}

pub fn join_lines(lines: &[String]) -> String {
  let mut text = lines.join("\n");
  if !lines.is_empty() {
    text.push('\n');
  }
  text
}

/// FNV-1a, fed one NUL-terminated item at a time; the hex digest is a
/// cache fingerprint.
pub struct Fnv(u64);

impl Default for Fnv {
  fn default() -> Self {
    Fnv(0xcbf2_9ce4_8422_2325)
  }
}

impl Fnv {
  pub fn feed(&mut self, bytes: &[u8]) {
    for byte in bytes.iter().chain(&[0]) {
      self.0 ^= u64::from(*byte);
      self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
    }
  }

  pub fn hex(&self) -> String {
    format!("{:016x}", self.0)
  }
}
