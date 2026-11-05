use ast_grep_language::SupportLang;
use discover_typescript::ts::{Facts, Spec, extract, parse};

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
