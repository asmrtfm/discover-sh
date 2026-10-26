//! Per-file facts read straight off a Dart parse tree: the URIs of its
//! import/export/part directives and its top-level entities.
//!
//! The bash discover.sh found directives with the pattern `import '$URI';`,
//! which only matches single-quoted URIs with no trailing clauses. Here every
//! directive node is read directly, so `"double quoted"`, `as p`, `show`/`hide`,
//! `deferred as` and the alternatives of a conditional import are all seen.

use ast_grep_core::tree_sitter::{LanguageExt, StrDoc};
use ast_grep_core::{AstGrep, Node, Pattern};
use ast_grep_language::Dart;

pub type DartRoot = AstGrep<StrDoc<Dart>>;
type DartNode<'r> = Node<'r, StrDoc<Dart>>;

pub fn parse(src: &str) -> DartRoot {
  Dart.ast_grep(src)
}

/// The three linking directives that make up the import graph.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Directive {
  Import,
  Export,
  Part,
}

impl Directive {
  pub fn as_str(self) -> &'static str {
    match self {
      Directive::Import => "import",
      Directive::Export => "export",
      Directive::Part => "part",
    }
  }
}

/// A top-level declaration: a library member another file can reference.
#[derive(Debug)]
pub struct Entity {
  /// class | enum | mixin | extension | typedef | function | variable
  pub kind: &'static str,
  pub name: String,
  /// 1-based line of the node (for annotated declarations, the annotation's line).
  pub line: usize,
  /// The declaration's header line (the `--depth signatures` text).
  pub header: String,
  /// The whole declaration (the `--depth full` text).
  pub full: String,
}

#[derive(Debug, Default)]
pub struct Facts {
  pub imports: Vec<String>,
  pub exports: Vec<String>,
  pub parts: Vec<String>,
  /// Sorted by line.
  pub entities: Vec<Entity>,
}

impl Facts {
  pub fn uris(&self, directive: Directive) -> &[String] {
    match directive {
      Directive::Import => &self.imports,
      Directive::Export => &self.exports,
      Directive::Part => &self.parts,
    }
  }

  /// The first entity (by line) with this name.
  pub fn entity(&self, name: &str) -> Option<&Entity> {
    self.entities.iter().find(|e| e.name == name)
  }

  pub fn entity_names(&self) -> Vec<String> {
    self.entities.iter().map(|e| e.name.clone()).collect()
  }
}

/// Declaration node kinds and the keyword each is reported as, in the order
/// the bash version concatenated them (ties on a line keep this order).
const DECLARATION_KINDS: [(&str, &str); 5] = [
  ("class_declaration", "class"),
  ("enum_declaration", "enum"),
  ("mixin_declaration", "mixin"),
  ("extension_declaration", "extension"),
  ("type_alias", "typedef"),
];

pub fn extract(root: &DartRoot) -> Facts {
  let mut facts = Facts::default();
  let mut declarations: [Vec<Entity>; 5] = Default::default();
  let mut functions = Vec::new();
  let mut variables = Vec::new();

  // One pre-order walk; directives and entities come out in document order.
  for node in root.root().dfs() {
    let kind = node.kind();
    match kind.as_ref() {
      "library_import" => facts.imports.extend(uris_in(&node)),
      "library_export" => facts.exports.extend(uris_in(&node)),
      "part_directive" => facts.parts.extend(uris_in(&node)),
      // Top-level functions only: methods are indented, so column 0 marks top level.
      "function_signature" if node.start_pos().column(&node) == 0 => {
        functions.push(function_entity(&node))
      }
      "initialized_identifier" | "static_final_declaration" if is_top_level_variable(&node) => {
        variables.push(variable_entity(&node))
      }
      other => {
        if let Some(i) = DECLARATION_KINDS.iter().position(|(k, _)| *k == other) {
          declarations[i].push(declaration_entity(&node, DECLARATION_KINDS[i].1));
        }
      }
    }
  }

  let mut entities: Vec<Entity> = declarations
    .into_iter()
    .flatten()
    .chain(functions)
    .chain(variables)
    .collect();
  // Stable, so same-line entities keep the concatenation order above.
  entities.sort_by_key(|e| e.line);
  facts.entities = entities;
  facts
}

/// URI strings under a directive. A conditional import has one `uri` for its
/// default and one per `if (...)` alternative; all of them are dependencies.
fn uris_in(directive: &DartNode<'_>) -> Vec<String> {
  directive
    .dfs()
    .filter(|n| n.kind() == "uri")
    .map(|n| unquote(&n.text()).to_string())
    .collect()
}

/// The contents of a Dart string literal: strips a raw `r` prefix and single,
/// double or triple quotes.
fn unquote(literal: &str) -> &str {
  let s = literal.trim();
  let s = s.strip_prefix('r').unwrap_or(s);
  for quote in ["'''", "\"\"\"", "'", "\""] {
    if let Some(inner) = s.strip_prefix(quote).and_then(|t| t.strip_suffix(quote)) {
      return inner;
    }
  }
  s
}

/// A variable declarator directly inside a top-level declaration:
///   const/final:    top_level_variable_declaration > static_final_declaration_list > static_final_declaration
///   var/typed/late: top_level_variable_declaration > initialized_identifier_list > initialized_identifier
/// Direct-parent chains only, so locals inside a top-level initializer are not picked up.
fn is_top_level_variable(node: &DartNode<'_>) -> bool {
  let list_kind = match node.kind().as_ref() {
    "initialized_identifier" => "initialized_identifier_list",
    _ => "static_final_declaration_list",
  };
  node
    .parent()
    .filter(|list| list.kind() == list_kind)
    .and_then(|list| list.parent())
    .is_some_and(|decl| decl.kind() == "top_level_variable_declaration")
}

fn first_line(text: &str) -> &str {
  text.split('\n').next().unwrap_or("")
}

/// Whether `line` contains `keyword` as a word that starts the declaration
/// header (at line start or after whitespace, followed by whitespace).
fn has_keyword(line: &str, keyword: &str) -> bool {
  line.match_indices(keyword).any(|(i, _)| {
    let before_ok = line[..i].chars().next_back().is_none_or(char::is_whitespace);
    let after_ok = line[i + keyword.len()..].chars().next().is_some_and(char::is_whitespace);
    before_ok && after_ok
  })
}

fn declaration_entity(node: &DartNode<'_>, keyword: &'static str) -> Entity {
  let full = node.text().to_string();
  // A typedef's name is a bare type_identifier (or, old-style, an identifier)
  // rather than a `name` field.
  let name = node
    .field("name")
    .or_else(|| node.children().find(|c| c.kind() == "type_identifier"))
    .or_else(|| {
      (keyword == "typedef")
        .then(|| node.children().find(|c| c.kind() == "identifier"))
        .flatten()
    })
    .map(|n| n.text().to_string())
    .unwrap_or_else(|| "?".to_string());
  // Leading annotations (`@JsonSerializable()`, `@riverpod`) belong to the
  // node, so the header is the first line with the keyword, not line one.
  let header = full
    .split('\n')
    .find(|l| has_keyword(l, keyword))
    .unwrap_or_else(|| first_line(&full))
    .to_string();
  Entity {
    kind: keyword,
    name,
    line: node.start_pos().line() + 1,
    header,
    full,
  }
}

fn function_entity(node: &DartNode<'_>) -> Entity {
  let full = node.text().to_string();
  Entity {
    kind: "function",
    name: node
      .field("name")
      .map(|n| n.text().to_string())
      .unwrap_or_else(|| "?".to_string()),
    line: node.start_pos().line() + 1,
    header: first_line(&full).to_string(),
    full,
  }
}

fn variable_entity(node: &DartNode<'_>) -> Entity {
  let full = node.text().to_string();
  // The declarator's text starts with the declared name.
  let name: String = full
    .chars()
    .take_while(|c| c.is_alphanumeric() || *c == '_')
    .collect();
  Entity {
    kind: "variable",
    name: if name.is_empty() { "?".to_string() } else { name },
    line: node.start_pos().line() + 1,
    header: first_line(&full).to_string(),
    full,
  }
}

/// The 1-based lines, ascending and without duplicates, where a pattern matches outside the file's directives. Used to find where an importer references an entity by name: a `show Foo` combinator names Foo without using it.
pub fn references(root: &DartRoot, pattern: &Pattern) -> Vec<usize> {
  let lines: std::collections::BTreeSet<usize> = root
    .root()
    .find_all(pattern)
    .filter(|m| {
      !m.get_node()
        .ancestors()
        .any(|a| a.kind() == "import_or_export")
    })
    .map(|m| m.get_node().start_pos().line() + 1)
    .collect();
  lines.into_iter().collect()
}

/// One pattern match, shaped like ast-grep's JSON output fields the bash
/// version read: the 1-based line, the match's first source line with one
/// leading space removed (jq's `ltrimstr(" ")`), and the full source lines.
pub struct Hit {
  pub line: usize,
  pub text: String,
  pub lines: String,
  /// Text of the requested metavariable, when one was asked for.
  pub capture: Option<String>,
}

pub fn find_all(root: &DartRoot, pattern: &Pattern, capture: Option<&str>) -> Vec<Hit> {
  root
    .root()
    .find_all(pattern)
    .map(|m| {
      let ctx = m.display_context(0, 0);
      let lines = format!("{}{}{}", ctx.leading, ctx.matched, ctx.trailing);
      let first = first_line(&lines);
      let text = first.strip_prefix(' ').unwrap_or(first).to_string();
      let capture = capture.and_then(|var| m.get_env().get_match(var).map(|n| n.text().to_string()));
      Hit {
        line: m.get_node().start_pos().line() + 1,
        text,
        lines,
        capture,
      }
    })
    .collect()
}

#[cfg(test)]
mod test {
  use super::*;

  fn facts(src: &str) -> Facts {
    extract(&parse(src))
  }

  #[test]
  fn reads_every_directive_form() {
    let f = facts(
      r#"
import 'package:a/b.dart';
import "c.dart" as c show X hide Y;
import 'd.dart' if (dart.library.io) 'e.dart';
import 'f.dart' deferred as f;
export 'g.dart' show Z;
part 'h.dart';
"#,
    );
    assert_eq!(f.imports, ["package:a/b.dart", "c.dart", "d.dart", "e.dart", "f.dart"]);
    assert_eq!(f.exports, ["g.dart"]);
    assert_eq!(f.parts, ["h.dart"]);
  }

  #[test]
  fn part_of_is_not_a_part() {
    assert!(facts("part of 'lib.dart';").parts.is_empty());
  }

  #[test]
  fn extracts_top_level_entities() {
    let f = facts(
      r#"@JsonSerializable()
class A extends B {}
enum E { a }
mixin M on B {}
extension X on String {}
typedef F = void Function();
final fooProvider = 1, bar = 2;
String? z;
void main() { var local = 1; }
class C { void method() {} }
"#,
    );
    let got: Vec<(&str, &str, usize)> = f
      .entities
      .iter()
      .map(|e| (e.kind, e.name.as_str(), e.line))
      .collect();
    assert_eq!(
      got,
      [
        ("class", "A", 1),
        ("enum", "E", 3),
        ("mixin", "M", 4),
        ("extension", "X", 5),
        ("typedef", "F", 6),
        ("variable", "fooProvider", 7),
        ("variable", "bar", 7),
        ("variable", "z", 8),
        ("function", "main", 9),
        ("class", "C", 10),
      ]
    );
    assert_eq!(f.entities[0].header, "class A extends B {}");
  }

  #[test]
  fn show_combinator_is_not_a_reference() {
    let root = parse("import 'a.dart' show Foo;\nvoid f() {}\n");
    let pattern = Pattern::try_new("Foo", Dart).unwrap();
    assert!(references(&root, &pattern).is_empty());
    // The use on line 2 is reported; the combinator on line 1 is not.
    let root = parse("import 'a.dart' show Foo;\nvoid f() { Foo(); }\n");
    assert_eq!(references(&root, &pattern), vec![2]);
  }
}
