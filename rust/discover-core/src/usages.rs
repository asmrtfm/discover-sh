//! Result rows for `usages` and the helpers every language formats them with.

use serde::Serialize;
use std::collections::HashSet;
use std::hash::Hash;

#[derive(Clone, Debug, Serialize)]
pub struct Usage {
  pub file: String,
  pub line: usize,
  pub text: String,
}

/// A source line as reported in results: one leading space removed
/// (jq's `ltrimstr(" ")` in the bash version).
pub fn line_text(src: &str, line: usize) -> String {
  let text = src.lines().nth(line - 1).unwrap_or("");
  text.strip_prefix(' ').unwrap_or(text).to_string()
}

/// Sorted by `key` (file then line), keeping the first row per key.
pub fn sorted_unique<T, K: Ord + Hash>(mut rows: Vec<T>, key: impl Fn(&T) -> K) -> Vec<T> {
  rows.sort_by_key(|r| key(r));
  let mut seen = HashSet::new();
  rows.retain(|r| seen.insert(key(r)));
  rows
}

/// The usual key: one row per file:line.
pub fn file_line(u: &Usage) -> (String, usize) {
  (u.file.clone(), u.line)
}
