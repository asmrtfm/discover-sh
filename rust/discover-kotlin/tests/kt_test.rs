use discover_jvm::parse;
use discover_kotlin::kt::{Kotlin, extract, parse_import};

#[test]
fn parses_imports() {
  let i = parse_import("import com.x.Foo as Bar");
  assert_eq!((i.path.as_str(), i.wildcard, i.alias.as_deref()), ("com.x.Foo", false, Some("Bar")));
  assert_eq!(i.local(), "Bar");
  let i = parse_import("import com.y.*");
  assert_eq!((i.path.as_str(), i.wildcard), ("com.y", true));
  let i = parse_import("import a.b.`fun`");
  assert_eq!(i.path, "a.b.fun");
}

#[test]
fn extracts_facts() {
  let f = extract(&parse::<Kotlin>(
    r#"package com.a.b

import com.x.Foo as Bar

object O
interface I
enum class E { A }
typealias T = String
val p = 1
private var q = 2
fun main() { val local = 1; Bar.baz(); Foo() }
class C {
    companion object {
        fun helper() {}
    }
}
"#,
  ));
  assert_eq!(f.package, "com.a.b");
  let got: Vec<(&str, &str, bool)> = f
    .decls
    .iter()
    .map(|d| (d.kind.as_str(), d.name.as_str(), d.private))
    .collect();
  assert_eq!(
    got,
    [
      ("object", "O", false),
      ("interface", "I", false),
      ("enum", "E", false),
      ("typealias", "T", false),
      ("val", "p", false),
      ("var", "q", true),
      ("function", "main", false),
      ("class", "C", false),
    ]
  );
  assert!(f.main);
  assert!(f.idents.contains_key("Bar") && f.idents.contains_key("Foo"));
  // Names in the import header are not references.
  assert!(!f.idents.contains_key("x"));
}

#[test]
fn jvm_static_main_in_companion() {
  let src = "class C {\n    companion object {\n        @JvmStatic\n        fun main(args: Array<String>) {}\n    }\n}\n";
  assert!(extract(&parse::<Kotlin>(src)).main);
  let src = "class C {\n    companion object {\n        fun main(args: Array<String>) {}\n    }\n}\n";
  assert!(!extract(&parse::<Kotlin>(src)).main);
}
