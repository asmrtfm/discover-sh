//! Per-file facts read off a Kotlin parse tree in one walk: package, imports,
//! top-level declarations, whether it holds a `main`, and the names it
//! references.

use ast_grep_core::Node;
use ast_grep_core::tree_sitter::StrDoc;
use ast_grep_language::SupportLang;
use discover_jvm::{Decl, Facts, Import, Jvm, Root};

type KtNode<'r> = Node<'r, StrDoc<SupportLang>>;

pub struct Kotlin;

impl Jvm for Kotlin {
  // Names the command in usage messages.
  const NAME: &'static str = "discover --lang=kotlin";
  const CACHE_PREFIX: &'static str = "discover_rs_kotlin_";
  const LANG: SupportLang = SupportLang::Kotlin;
  const EXT: &'static str = ".kt";
  const PATHSPEC: &'static str = "*.kt";

  fn extract(root: &Root) -> Facts {
    extract(root)
  }

  /// Also matches longer forms such as file:///android_asset/<path>.
  fn literal_lines(root: &Root, literal: &str) -> Vec<usize> {
    literal_lines(root, literal)
  }
}

/// `import a.b.C as D` → path `a.b.C`, alias `D`; `import a.b.*` → path `a.b`, wildcard.
pub fn parse_import(text: &str) -> Import {
  let spec = text.trim();
  let spec = spec.strip_prefix("import").unwrap_or(spec).trim();
  let spec = spec.strip_suffix(';').unwrap_or(spec).trim().to_string();
  let words: Vec<&str> = spec.split_whitespace().collect();
  let (path_part, alias) = match words.iter().rposition(|w| *w == "as") {
    Some(i) if i + 1 == words.len() - 1 => (words[..i].concat(), Some(words[i + 1].to_string())),
    _ => (words.concat(), None),
  };
  let path: String = path_part.chars().filter(|c| *c != '`').collect();
  let (path, wildcard) = match path.strip_suffix(".*") {
    Some(p) => (p.to_string(), true),
    None => (path, false),
  };
  Import {
    spec,
    path,
    wildcard,
    alias,
    is_static: false,
  }
}

fn line_of(node: &KtNode<'_>) -> usize {
  node.start_pos().line() + 1
}

/// Rule id of a top-level declaration node and the node holding its name.
/// Names are direct children: a class's supertypes and type parameters, a
/// function's receiver and parameters all sit deeper in the tree.
/// Destructuring declarations (`val (a, b) = …`) have no single name.
fn declaration<'r>(node: &KtNode<'r>) -> Option<(&'static str, KtNode<'r>)> {
  let child = |kind: &str| node.children().find(|c| c.kind() == kind);
  match node.kind().as_ref() {
    "class_declaration" => Some(("class", child("type_identifier")?)),
    "object_declaration" => Some(("object", child("type_identifier")?)),
    "type_alias" => Some(("typealias", child("type_identifier")?)),
    "function_declaration" => Some(("function", child("simple_identifier")?)),
    "property_declaration" => {
      let var = child("variable_declaration")?;
      let name = var.children().find(|c| c.kind() == "simple_identifier")?;
      Some(("property", name))
    }
    _ => None,
  }
}

/// Display kind (class | interface | enum | object | typealias | function |
/// val | var): class_declaration covers interfaces and enums; properties
/// are reported by their binding keyword.
fn display_kind(id: &str, header: &str) -> String {
  let has_word = |w: &str| header.split(|c: char| !c.is_alphanumeric() && c != '_').any(|t| t == w);
  match id {
    "class" if has_word("interface") => "interface",
    "class" if header.split_whitespace().collect::<Vec<_>>().windows(2).any(|w| w == ["enum", "class"]) => "enum",
    "property" if has_word("var") => "var",
    "property" => "val",
    other => other,
  }
  .to_string()
}

/// A `main` function: top-level, or @JvmStatic inside an object/companion.
fn is_main(node: &KtNode<'_>) -> bool {
  if node.kind() != "function_declaration" {
    return false;
  }
  if !node.children().any(|c| c.kind() == "simple_identifier" && c.text() == "main") {
    return false;
  }
  if node.parent().is_some_and(|p| p.kind() == "source_file") {
    return true;
  }
  let jvm_static = node
    .children()
    .filter(|c| c.kind() == "modifiers")
    .any(|m| m.dfs().any(|n| n.kind() == "annotation" && n.text().contains("JvmStatic")));
  jvm_static
    && node
      .ancestors()
      .any(|a| matches!(a.kind().as_ref(), "object_declaration" | "companion_object"))
}

pub fn extract(root: &Root) -> Facts {
  let mut facts = Facts::default();
  for node in root.root().dfs() {
    match node.kind().as_ref() {
      "package_header" => {
        if let Some(id) = node.children().find(|c| c.kind() == "identifier") {
          facts.package = id.text().chars().filter(|c| !c.is_whitespace() && *c != '`').collect();
        }
      }
      "import_header" => facts.imports.push(parse_import(&node.text())),
      "simple_identifier" | "type_identifier" => {
        let in_header = node
          .ancestors()
          .any(|a| matches!(a.kind().as_ref(), "import_header" | "package_header"));
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
    if !node.parent().is_some_and(|p| p.kind() == "source_file") {
      continue;
    }
    if let Some((id, name_node)) = declaration(&node) {
      let name = name_node.text().to_string();
      let full = node.text().to_string();
      let header = full
        .split('\n')
        .find(|l| l.contains(name.as_str()))
        .unwrap_or_else(|| full.split('\n').next().unwrap_or(""))
        .to_string();
      // Private when `private` appears before the name (modifiers, annotations).
      let before = full.split(name.as_str()).next().unwrap_or("");
      let private = before
        .split(|c: char| !c.is_alphanumeric() && c != '_')
        .any(|w| w == "private");
      facts.decls.push(Decl {
        kind: display_kind(id, &header),
        name,
        line: line_of(&node),
        private,
        header,
        full,
      });
    }
  }
  facts.decls.sort_by_key(|d| d.line);
  facts
}

/// Lines (1-based) of string contents matching an asset path: the path
/// itself, or ending in `/<path>` (e.g. file:///android_asset/<path>).
pub fn literal_lines(root: &Root, literal: &str) -> Vec<usize> {
  let suffix = format!("/{literal}");
  root
    .root()
    .dfs()
    .filter(|n| n.kind() == "string_content")
    .filter(|n| {
      let text = n.text();
      text == literal || text.ends_with(suffix.as_str())
    })
    .map(|n| line_of(&n))
    .collect()
}
