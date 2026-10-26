//! Per-file facts read off a Java parse tree in one walk: package, imports,
//! top-level types, whether it holds a `main`, and the names it references.

use ast_grep_core::Node;
use ast_grep_core::tree_sitter::StrDoc;
use ast_grep_language::SupportLang;
use discover_jvm::{Decl, Facts, Import, Jvm, Root};

type JavaNode<'r> = Node<'r, StrDoc<SupportLang>>;

pub struct Java;

impl Jvm for Java {
  const NAME: &'static str = "discover-java";
  const CACHE_PREFIX: &'static str = "discover_rs_java_";
  const LANG: SupportLang = SupportLang::Java;
  const EXT: &'static str = ".java";
  const PATHSPEC: &'static str = "*.java";

  fn extract(root: &Root) -> Facts {
    extract(root)
  }

  /// Also matches a leading `/` (classpath resources).
  fn literal_lines(root: &Root, literal: &str) -> Vec<usize> {
    literal_lines(root, literal)
  }
}

/// `import static a.b.C.m;` → path `a.b.C.m`, static; `import a.b.*;` → path
/// `a.b`, wildcard. Java has no import aliases; `alias` is always None.
pub fn parse_import(text: &str) -> Import {
  let spec = text.trim();
  let spec = spec.strip_prefix("import").unwrap_or(spec).trim();
  let spec = spec.strip_suffix(';').unwrap_or(spec).trim().to_string();
  let (is_static, rest) = match spec.strip_prefix("static") {
    Some(rest) if rest.starts_with(char::is_whitespace) => (true, rest),
    _ => (false, spec.as_str()),
  };
  let path: String = rest.chars().filter(|c| !c.is_whitespace()).collect();
  let (path, wildcard) = match path.strip_suffix(".*") {
    Some(p) => (p.to_string(), true),
    None => (path, false),
  };
  Import {
    spec,
    path,
    wildcard,
    alias: None,
    is_static,
  }
}

fn line_of(node: &JavaNode<'_>) -> usize {
  node.start_pos().line() + 1
}

/// Display kind of a top-level type declaration. Only top-level types are
/// indexed; nested ones are reached through them (`import a.Outer.Inner`
/// resolves to Outer's file).
fn declaration_kind(node: &JavaNode<'_>) -> Option<&'static str> {
  match node.kind().as_ref() {
    "class_declaration" => Some("class"),
    "interface_declaration" => Some("interface"),
    "enum_declaration" => Some("enum"),
    "record_declaration" => Some("record"),
    "annotation_type_declaration" => Some("annotation"),
    _ => None,
  }
}

/// A `main` method: static, or (Java 21+ compact source files) declared at
/// the top level.
fn is_main(node: &JavaNode<'_>) -> bool {
  if node.kind() != "method_declaration" || !node.field("name").is_some_and(|n| n.text() == "main") {
    return false;
  }
  let is_static = node
    .children()
    .filter(|c| c.kind() == "modifiers")
    .any(|m| m.text().split_whitespace().any(|w| w == "static"));
  is_static || node.parent().is_some_and(|p| p.kind() == "program")
}

/// Java doesn't allow private top-level types, so a declaration's `private`
/// only guards against misparses and is normally false.
pub fn extract(root: &Root) -> Facts {
  let mut facts = Facts::default();
  for node in root.root().dfs() {
    match node.kind().as_ref() {
      "package_declaration" => {
        if let Some(id) = node
          .children()
          .find(|c| matches!(c.kind().as_ref(), "scoped_identifier" | "identifier"))
        {
          facts.package = id.text().chars().filter(|c| !c.is_whitespace()).collect();
        }
      }
      "import_declaration" => facts.imports.push(parse_import(&node.text())),
      // Type positions and expressions (`Foo.bar()`, static-imported members).
      "identifier" | "type_identifier" => {
        let in_header = node
          .ancestors()
          .any(|a| matches!(a.kind().as_ref(), "import_declaration" | "package_declaration"));
        if !in_header {
          facts
            .idents
            .entry(node.text().to_string())
            .or_default()
            .insert(node.start_pos().line() + 1);
        }
      }
      _ => {}
    }
    if is_main(&node) {
      facts.main = true;
    }
    if !node.parent().is_some_and(|p| p.kind() == "program") {
      continue;
    }
    let (Some(kind), Some(name)) = (declaration_kind(&node), node.field("name")) else {
      continue;
    };
    let name = name.text().to_string();
    let full = node.text().to_string();
    // The header is the first line with the name (annotations come first).
    let header = full
      .split('\n')
      .find(|l| l.contains(name.as_str()))
      .unwrap_or_else(|| full.split('\n').next().unwrap_or(""))
      .to_string();
    let before = full.split(name.as_str()).next().unwrap_or("");
    let private = before
      .split(|c: char| !c.is_alphanumeric() && c != '_')
      .any(|w| w == "private");
    facts.decls.push(Decl {
      kind: kind.to_string(),
      name,
      line: line_of(&node),
      private,
      header,
      full,
    });
  }
  facts.decls.sort_by_key(|d| d.line);
  facts
}

/// Lines (1-based) of string contents matching an asset path: the path
/// itself, or ending in `/<path>` (e.g. a leading `/` for classpath resources).
pub fn literal_lines(root: &Root, literal: &str) -> Vec<usize> {
  let suffix = format!("/{literal}");
  root
    .root()
    .dfs()
    .filter(|n| n.kind() == "string_fragment")
    .filter(|n| {
      let text = n.text();
      text == literal || text.ends_with(suffix.as_str())
    })
    .map(|n| line_of(&n))
    .collect()
}

#[cfg(test)]
mod test {
  use super::*;
  use discover_jvm::parse;

  #[test]
  fn parses_imports() {
    let i = parse_import("import static x.Y.z;");
    assert_eq!((i.path.as_str(), i.is_static, i.wildcard), ("x.Y.z", true, false));
    assert_eq!(i.local(), "z");
    let i = parse_import("import c.d.*;");
    assert_eq!((i.path.as_str(), i.wildcard), ("c.d", true));
    let i = parse_import("import static a.B.*;");
    assert_eq!((i.path.as_str(), i.is_static, i.wildcard), ("a.B", true, true));
  }

  #[test]
  fn extracts_facts() {
    let f = extract(&parse::<Java>(
      r#"package a.b;

import e.F;

@Ann
public class C {
  public static void main(String[] a) { F.g(); new Helper(); }
  class Nested {}
}
interface I {}
enum E { X }
record R(int x) {}
@interface Marker {}
"#,
    ));
    assert_eq!(f.package, "a.b");
    let got: Vec<(&str, &str)> = f.decls.iter().map(|d| (d.kind.as_str(), d.name.as_str())).collect();
    assert_eq!(
      got,
      [
        ("class", "C"),
        ("interface", "I"),
        ("enum", "E"),
        ("record", "R"),
        ("annotation", "Marker"),
      ]
    );
    assert_eq!(f.decls[0].header, "public class C {");
    assert!(f.main);
    assert!(f.idents.contains_key("F") && f.idents.contains_key("Helper"));
    // Names in the package and import declarations are not references.
    assert!(!f.idents.contains_key("e") && !f.idents.contains_key("b"));
  }
}
