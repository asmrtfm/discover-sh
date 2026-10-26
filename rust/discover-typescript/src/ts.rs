//! Per-file facts read off a TypeScript/TSX parse tree in one walk: module
//! specifiers per directive, top-level entities, referenced names, and
//! import/export bindings (which name comes from which specifier).

use ast_grep_core::tree_sitter::{LanguageExt, StrDoc};
use ast_grep_core::{AstGrep, Node};
use ast_grep_language::SupportLang;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

pub type TsRoot = AstGrep<StrDoc<SupportLang>>;
type TsNode<'r> = Node<'r, StrDoc<SupportLang>>;

/// Grammar for a file. Plain .ts must use the typescript grammar (its
/// `<T>expr` casts clash with JSX); everything else, including JavaScript
/// entry points, parses with tsx, a superset of JS + JSX.
pub fn lang_for(path: &Path) -> SupportLang {
  match path.extension().and_then(|e| e.to_str()) {
    Some("ts" | "mts" | "cts") => SupportLang::TypeScript,
    _ => SupportLang::Tsx,
  }
}

/// Scripts are the only files with imports to follow; anything else an
/// import resolves to (JSON, images, styles) is a leaf in the graph.
pub fn is_script(path: &str) -> bool {
  [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"]
    .iter()
    .any(|ext| path.ends_with(ext))
}

pub fn parse(src: &str, lang: SupportLang) -> TsRoot {
  lang.ast_grep(src)
}

/// The linking directives that make up the import graph:
///   import  — `import … from "x"`, `import "x"`, `import type …`, `import x = require("x")`
///   export  — `export … from "x"`, `export * from "x"`
///   dynamic — `import("x")` and `require("x")` (lazy routes, React Native assets)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Directive {
  Import,
  Export,
  Dynamic,
}

impl Directive {
  pub fn as_str(self) -> &'static str {
    match self {
      Directive::Import => "import",
      Directive::Export => "export",
      Directive::Dynamic => "dynamic",
    }
  }
}

/// A module specifier and the 1-based line it sits on.
#[derive(Clone, Debug)]
pub struct Spec {
  pub text: String,
  pub line: usize,
}

#[derive(Debug)]
pub struct Entity {
  /// class | interface | type | enum | function | namespace | variable
  pub kind: &'static str,
  pub name: String,
  pub line: usize,
  pub header: String,
  pub full: String,
}

/// An import/export binding:
///   import-spec     — `import { A as B } from "x"`  (name A, local B)
///   import-default  — `import B from "x"`           (name "default", local B)
///   import-bare     — `import "x"`
///   export-spec     — `export { A as B } from "x"`  (name A, local B)
///   export-star     — `export * from "x"`, `export * as ns from "x"` (name "*")
///   default-export  — `export default <decl or identifier>` (name = its name)
///   require-binding — `const B = require("x")` / `= import("x")` (name = local = B)
#[derive(Clone, Debug)]
pub struct Binding {
  pub id: &'static str,
  pub name: Option<String>,
  pub local: Option<String>,
  pub src: Option<String>,
  pub line: usize,
}

#[derive(Debug, Default)]
pub struct Facts {
  pub imports: Vec<Spec>,
  pub exports: Vec<Spec>,
  pub dynamic: Vec<Spec>,
  /// Sorted by line.
  pub entities: Vec<Entity>,
  /// Distinct names referenced outside import statements: values, types,
  /// member access (`ns.Foo`) and JSX tags, each with the 1-based lines
  /// where it appears.
  pub idents: BTreeMap<String, BTreeSet<usize>>,
  pub bindings: Vec<Binding>,
}

impl Facts {
  pub fn specs(&self, directive: Directive) -> &[Spec] {
    match directive {
      Directive::Import => &self.imports,
      Directive::Export => &self.exports,
      Directive::Dynamic => &self.dynamic,
    }
  }

  pub fn entity(&self, name: &str) -> Option<&Entity> {
    self.entities.iter().find(|e| e.name == name)
  }

  pub fn entity_names(&self) -> Vec<String> {
    self.entities.iter().map(|e| e.name.clone()).collect()
  }

  /// The name this module's default export declares.
  pub fn default_export(&self) -> Option<&str> {
    self
      .bindings
      .iter()
      .find(|b| b.id == "default-export")
      .and_then(|b| b.name.as_deref())
  }
}

fn line_of(node: &TsNode<'_>) -> usize {
  node.start_pos().line() + 1
}

fn first_line(text: &str) -> &str {
  text.split('\n').next().unwrap_or("")
}

/// The fragment of a string node (`"x"` → `x`); empty strings have none.
fn fragment<'r>(string: &TsNode<'r>) -> Option<TsNode<'r>> {
  if string.kind() != "string" {
    return None;
  }
  string.children().find(|c| c.kind() == "string_fragment")
}

/// The `source` string of an import/export statement (or require clause).
fn source<'r>(node: &TsNode<'r>) -> Option<TsNode<'r>> {
  node.field("source").and_then(|s| fragment(&s))
}

/// `import("x")` / `require("x")`: the first argument's string fragment.
fn loaded_module<'r>(call: &TsNode<'r>) -> Option<TsNode<'r>> {
  let function = call.field("function")?;
  let loads = function.kind() == "import" || (function.kind() == "identifier" && function.text() == "require");
  if !loads {
    return None;
  }
  let first = call.field("arguments")?.children().find(|c| c.is_named())?;
  fragment(&first)
}

/// Directly in the module, or directly under a top-level `export`.
fn is_top(parent: Option<TsNode<'_>>) -> bool {
  match parent {
    Some(p) if p.kind() == "program" => true,
    Some(p) if p.kind() == "export_statement" => p.parent().is_some_and(|g| g.kind() == "program"),
    _ => false,
  }
}

/// Entity kind for a declaration node at top level, if it is one.
fn entity_kind(node: &TsNode<'_>) -> Option<&'static str> {
  let kind = match node.kind().as_ref() {
    "class_declaration" | "abstract_class_declaration" => "class",
    "interface_declaration" => "interface",
    "type_alias_declaration" => "type",
    "enum_declaration" => "enum",
    "function_declaration" | "generator_function_declaration" => "function",
    // Namespaces sit in an expression_statement unless exported.
    "internal_module" => {
      let parent = node.parent();
      let top = is_top(parent.clone())
        || parent.is_some_and(|p| p.kind() == "expression_statement" && is_top(p.parent()));
      return top.then_some("namespace");
    }
    // Destructured declarators are skipped: their "name" is a pattern.
    "variable_declarator" => {
      let named = node.field("name").is_some_and(|n| n.kind() == "identifier");
      let top = node.parent().is_some_and(|p| {
        matches!(p.kind().as_ref(), "lexical_declaration" | "variable_declaration") && is_top(p.parent())
      });
      return (named && top).then_some("variable");
    }
    _ => return None,
  };
  is_top(node.parent()).then_some(kind)
}

/// `A as B` binds B; a `type` modifier on the specifier is not part of the name.
fn spec_local(text: &str) -> String {
  let text = text.trim();
  let text = match text.strip_prefix("type") {
    Some(rest) if rest.starts_with(char::is_whitespace) => rest.trim_start(),
    _ => text,
  };
  let words: Vec<&str> = text.split_whitespace().collect();
  match words.iter().position(|w| *w == "as") {
    Some(_) => words.last().copied().unwrap_or(text).to_string(),
    None => text.to_string(),
  }
}

pub fn extract(root: &TsRoot) -> Facts {
  let mut facts = Facts::default();
  let mut entities = Vec::new();

  for node in root.root().dfs() {
    let kind = node.kind();
    match kind.as_ref() {
      "import_statement" => {
        if let Some(src) = source(&node) {
          facts.imports.push(Spec {
            text: src.text().to_string(),
            line: line_of(&src),
          });
        }
        import_bindings(&node, &mut facts.bindings);
      }
      "import_require_clause" => {
        if let Some(src) = source(&node) {
          facts.imports.push(Spec {
            text: src.text().to_string(),
            line: line_of(&src),
          });
        }
      }
      "export_statement" => {
        if let Some(src) = source(&node) {
          facts.exports.push(Spec {
            text: src.text().to_string(),
            line: line_of(&src),
          });
        }
        export_bindings(&node, &mut facts.bindings);
      }
      "call_expression" => {
        if let Some(src) = loaded_module(&node) {
          facts.dynamic.push(Spec {
            text: src.text().to_string(),
            line: line_of(&src),
          });
        }
      }
      "identifier" | "type_identifier" | "property_identifier" | "shorthand_property_identifier" => {
        if !node.ancestors().any(|a| a.kind() == "import_statement") {
          facts.idents.entry(node.text().to_string()).or_default().insert(line_of(&node));
        }
      }
      _ => {}
    }
    if kind == "variable_declarator" {
      require_binding(&node, &mut facts.bindings);
    }
    if let Some(entity_kind) = entity_kind(&node) {
      if let Some(name) = node.field("name") {
        let name = name.text().to_string();
        let full = node.text().to_string();
        let header = full
          .split('\n')
          .find(|l| l.contains(name.as_str()))
          .unwrap_or_else(|| first_line(&full))
          .to_string();
        entities.push(Entity {
          kind: entity_kind,
          name,
          line: line_of(&node),
          header,
          full,
        });
      }
    }
  }

  // Stable: same-line entities (`export const C = 1, D = 2`) keep document order.
  entities.sort_by_key(|e| e.line);
  facts.entities = entities;
  facts.bindings.sort_by_key(|b| b.line);
  facts
}

fn import_bindings(stmt: &TsNode<'_>, out: &mut Vec<Binding>) {
  let src = source(stmt).map(|s| s.text().to_string());
  let has_clause = stmt
    .children()
    .any(|c| matches!(c.kind().as_ref(), "import_clause" | "import_require_clause"));
  if !has_clause {
    if src.is_some() {
      out.push(Binding {
        id: "import-bare",
        name: None,
        local: None,
        src,
        line: line_of(stmt),
      });
    }
    return;
  }
  let Some(src) = src else { return };
  for clause in stmt.children().filter(|c| c.kind() == "import_clause") {
    for part in clause.children() {
      match part.kind().as_ref() {
        "identifier" => out.push(Binding {
          id: "import-default",
          name: Some("default".to_string()),
          local: Some(part.text().to_string()),
          src: Some(src.clone()),
          line: line_of(&part),
        }),
        "named_imports" => {
          for spec in part.children().filter(|c| c.kind() == "import_specifier") {
            let Some(name) = spec.field("name") else { continue };
            out.push(Binding {
              id: "import-spec",
              name: Some(name.text().to_string()),
              local: Some(spec_local(&spec.text())),
              src: Some(src.clone()),
              line: line_of(&spec),
            });
          }
        }
        _ => {}
      }
    }
  }
}

fn export_bindings(stmt: &TsNode<'_>, out: &mut Vec<Binding>) {
  if let Some(src) = source(stmt).map(|s| s.text().to_string()) {
    match stmt.children().find(|c| c.kind() == "export_clause") {
      Some(clause) => {
        for spec in clause.children().filter(|c| c.kind() == "export_specifier") {
          let Some(name) = spec.field("name") else { continue };
          out.push(Binding {
            id: "export-spec",
            name: Some(name.text().to_string()),
            local: Some(spec_local(&spec.text())),
            src: Some(src.clone()),
            line: line_of(&spec),
          });
        }
      }
      None => out.push(Binding {
        id: "export-star",
        name: Some("*".to_string()),
        local: None,
        src: Some(src),
        line: line_of(stmt),
      }),
    }
  }

  // `export default function App()`, `export default Foo;`
  let is_default = stmt
    .text()
    .strip_prefix("export")
    .is_some_and(|rest| rest.starts_with(char::is_whitespace) && rest.trim_start().starts_with("default"));
  if is_default && stmt.parent().is_some_and(|p| p.kind() == "program") {
    let name = stmt
      .field("declaration")
      .and_then(|d| d.field("name"))
      .or_else(|| stmt.field("value").filter(|v| v.kind() == "identifier"));
    if let Some(name) = name {
      out.push(Binding {
        id: "default-export",
        name: Some(name.text().to_string()),
        local: Some(name.text().to_string()),
        src: None,
        line: line_of(stmt),
      });
    }
  }
}

fn require_binding(decl: &TsNode<'_>, out: &mut Vec<Binding>) {
  let Some(name) = decl.field("name").filter(|n| n.kind() == "identifier") else {
    return;
  };
  let Some(src) = decl
    .field("value")
    .filter(|v| v.kind() == "call_expression")
    .and_then(|call| loaded_module(&call))
  else {
    return;
  };
  out.push(Binding {
    id: "require-binding",
    name: Some(name.text().to_string()),
    local: Some(name.text().to_string()),
    src: Some(src.text().to_string()),
    line: line_of(decl),
  });
}

/// Lines (1-based) where `name` is used as an identifier outside import
/// statements: the uses of an asset binding.
pub fn name_uses(root: &TsRoot, name: &str) -> Vec<usize> {
  root
    .root()
    .dfs()
    .filter(|n| matches!(n.kind().as_ref(), "identifier" | "property_identifier" | "shorthand_property_identifier"))
    .filter(|n| n.text() == name)
    .filter(|n| !n.ancestors().any(|a| a.kind() == "import_statement"))
    .map(|n| line_of(&n))
    .collect()
}

/// Lines (1-based) of string fragments exactly equal to one of `literals`.
pub fn literal_lines(root: &TsRoot, literals: &[String]) -> Vec<usize> {
  root
    .root()
    .dfs()
    .filter(|n| n.kind() == "string_fragment")
    .filter(|n| literals.iter().any(|l| n.text() == l.as_str()))
    .map(|n| line_of(&n))
    .collect()
}

#[cfg(test)]
mod test {
  use super::*;

  fn facts(src: &str, lang: SupportLang) -> Facts {
    extract(&parse(src, lang))
  }

  #[test]
  fn reads_specifiers_per_directive() {
    let f = facts(
      r#"
import React, { lazy } from 'react';
import type { Props } from "./types";
import "./side.css";
import fs = require("./legacy");
export * from './barrel';
export { X } from "./x.js";
const Page = lazy(() => import('./Page'));
const img = require('../img.png');
"#,
      SupportLang::Tsx,
    );
    let texts = |s: &[Spec]| s.iter().map(|x| x.text.clone()).collect::<Vec<_>>();
    assert_eq!(texts(&f.imports), ["react", "./types", "./side.css", "./legacy"]);
    assert_eq!(texts(&f.exports), ["./barrel", "./x.js"]);
    assert_eq!(texts(&f.dynamic), ["./Page", "../img.png"]);
  }

  #[test]
  fn extracts_top_level_entities() {
    let f = facts(
      r#"@dec
export class K {}
export default function App() { const inner = 1; return null; }
export const C = 1, D = () => 2;
let { a, b } = obj;
namespace N { export const z = 1; }
export interface I { x: number }
export type T = string;
enum E { A }
abstract class Ab {}
function* gen() {}
"#,
      SupportLang::Tsx,
    );
    let got: Vec<(&str, &str)> = f.entities.iter().map(|e| (e.kind, e.name.as_str())).collect();
    assert_eq!(
      got,
      [
        ("class", "K"),
        ("function", "App"),
        ("variable", "C"),
        ("variable", "D"),
        ("namespace", "N"),
        ("interface", "I"),
        ("type", "T"),
        ("enum", "E"),
        ("class", "Ab"),
        ("function", "gen"),
      ]
    );
  }

  #[test]
  fn reads_bindings() {
    let f = facts(
      r#"import Main, { A as B, C } from './x';
import './side.css';
export { default as Button, D } from './Button';
export * from './all';
export default function App() {}
"#,
      SupportLang::Tsx,
    );
    let got: Vec<(&str, Option<&str>, Option<&str>, Option<&str>)> = f
      .bindings
      .iter()
      .map(|b| (b.id, b.name.as_deref(), b.local.as_deref(), b.src.as_deref()))
      .collect();
    assert_eq!(
      got,
      [
        ("import-default", Some("default"), Some("Main"), Some("./x")),
        ("import-spec", Some("A"), Some("B"), Some("./x")),
        ("import-spec", Some("C"), Some("C"), Some("./x")),
        ("import-bare", None, None, Some("./side.css")),
        ("export-spec", Some("default"), Some("Button"), Some("./Button")),
        ("export-spec", Some("D"), Some("D"), Some("./Button")),
        ("export-star", Some("*"), None, Some("./all")),
        ("default-export", Some("App"), Some("App"), None),
      ]
    );
  }

  #[test]
  fn names_in_imports_are_not_references() {
    let f = facts("import { Foo } from './foo';\nconst x = <Bar />;\n", SupportLang::Tsx);
    assert!(!f.idents.contains_key("Foo"));
    // Bar is referenced on line 2.
    assert_eq!(f.idents.get("Bar").map(|l| l.iter().copied().collect::<Vec<_>>()), Some(vec![2]));
  }
}
