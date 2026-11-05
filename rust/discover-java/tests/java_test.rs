use discover_java::java::{Java, extract, parse_import};
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
