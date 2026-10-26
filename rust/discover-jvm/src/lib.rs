//! The JVM navigators' shared half. Java and Kotlin resolve names the same
//! way — imports name declarations, not files, and a package's
//! declarations are visible without importing — and start from the same
//! entry points, so everything but reading a parse tree lives here. A
//! language crate implements [`Jvm`] and calls [`main`].

pub mod cli;
pub mod graph;
pub mod index;
pub mod project;
pub mod usages;

use ast_grep_core::AstGrep;
use ast_grep_core::tree_sitter::{LanguageExt, StrDoc};
use ast_grep_language::SupportLang;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub use cli::main;

pub type Root = AstGrep<StrDoc<SupportLang>>;

/// Identifier text → the 1-based lines where it appears.
pub type Idents = BTreeMap<String, BTreeSet<usize>>;

/// What a JVM language contributes: its names and how to read its parse tree.
pub trait Jvm: Send + Sync + 'static {
  /// The binary's name, e.g. `discover-java`.
  const NAME: &'static str;
  /// Prefix of every cache file name, e.g. `discover_rs_java_`.
  const CACHE_PREFIX: &'static str;
  const LANG: SupportLang;
  /// Source file extension, e.g. `.java`.
  const EXT: &'static str;
  /// Git pathspec selecting source files, e.g. `*.java`.
  const PATHSPEC: &'static str;

  /// Per-file facts, read off the parse tree in one walk.
  fn extract(root: &Root) -> Facts;

  /// Lines (1-based) of string contents naming an asset path: the path
  /// itself, or ending in `/<path>`.
  fn literal_lines(root: &Root, literal: &str) -> Vec<usize>;
}

pub fn parse<J: Jvm>(src: &str) -> Root {
  J::LANG.ast_grep(src)
}

/// One import: `import a.b.C as D` → path `a.b.C`, alias `D`; `import a.b.*`
/// → path `a.b`, wildcard; `import static a.b.C.m` → path `a.b.C.m`, static.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Import {
  /// The import as written, minus the `import` keyword (and Java's `;`).
  pub spec: String,
  pub path: String,
  pub wildcard: bool,
  /// Kotlin `as` alias; Java has none.
  pub alias: Option<String>,
  /// Java `import static`; always false for Kotlin.
  #[serde(rename = "static", default)]
  pub is_static: bool,
}

impl Import {
  /// The simple name this import binds in the file (alias or last segment).
  pub fn local(&self) -> &str {
    self
      .alias
      .as_deref()
      .unwrap_or_else(|| self.path.rsplit('.').next().unwrap_or(&self.path))
  }
}

/// A top-level declaration.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Decl {
  pub name: String,
  /// The language's display kind (class, interface, enum, record, object, …).
  pub kind: String,
  pub line: usize,
  /// Private declarations are invisible outside their file.
  pub private: bool,
  /// The declaration's header line (`--depth signatures`).
  #[serde(skip)]
  pub header: String,
  /// The whole declaration (`--depth full`).
  #[serde(skip)]
  pub full: String,
}

#[derive(Debug, Default)]
pub struct Facts {
  pub package: String,
  pub imports: Vec<Import>,
  /// Sorted by line.
  pub decls: Vec<Decl>,
  pub main: bool,
  /// Distinct identifier texts outside the package and import declarations, each with the 1-based lines where it appears.
  pub idents: Idents,
}
