use ast_grep_core::Pattern;
use ast_grep_language::Dart;
use discover_dart::dart::{Facts, extract, parse, references};

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
