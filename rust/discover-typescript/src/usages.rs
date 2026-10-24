//! `usages`: structural search over the sources with an ast-grep pattern,
//! and the `--assets` lookup of what references an asset file.

use crate::graph::Graph;
use crate::ts::{self, Directive, is_script};
use ast_grep_core::Pattern;
use ast_grep_language::SupportLang;
use discover_core::par::par_map;
use discover_core::usages::{Usage, file_line, line_text, sorted_unique};
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize)]
pub struct BindingUsage {
  pub file: String,
  pub line: usize,
  pub text: String,
  /// The name bound to the asset that this line uses.
  pub binding: String,
}

/// `usages <pattern> [--live-only]`: the pattern runs over every source with
/// that file's grammar (.tsx needs tsx, .ts must not use it). A pattern
/// that doesn't parse for a grammar finds nothing in those files.
pub fn pattern_usages(graph: &Graph, pattern: &str, live_only: bool) -> Result<Vec<Usage>, String> {
  let ts_pattern = Pattern::try_new(pattern, SupportLang::TypeScript).ok();
  let tsx_pattern = Pattern::try_new(pattern, SupportLang::Tsx).ok();
  let live: Option<HashSet<String>> = if live_only {
    Some(graph.live()?.into_iter().collect())
  } else {
    None
  };
  let files = graph.project.relevant_files();
  let hits: Vec<Vec<Usage>> = par_map(&files, |path| {
    let lang = ts::lang_for(path);
    let pattern = match lang {
      SupportLang::TypeScript => ts_pattern.as_ref(),
      _ => tsx_pattern.as_ref(),
    };
    let rel = graph.project.rel(path);
    let (Some(pattern), Ok(src)) = (pattern, fs::read_to_string(path)) else {
      return Vec::new();
    };
    if live.as_ref().is_some_and(|l| !l.contains(&rel)) {
      return Vec::new();
    }
    let root = ts::parse(&src, lang);
    root
      .root()
      .find_all(pattern)
      .map(|m| Usage {
        file: rel.clone(),
        line: m.get_node().start_pos().line() + 1,
        text: line_text(&src, m.get_node().start_pos().line() + 1),
      })
      .collect()
  });
  Ok(sorted_unique(hits.into_iter().flatten().collect(), file_line))
}

#[derive(Debug, Serialize)]
pub struct AssetRefs {
  /// Usages via a name bound to the asset (`import logo from …`,
  /// `const logo = require(…)`).
  pub binding_refs: Vec<BindingUsage>,
  /// The asset loaded or named inline: an unbound import()/require(), or a
  /// string literal of its path.
  pub direct_refs: Vec<Usage>,
}

/// `usages --assets <path>`. Assets reach TS code as modules —
/// `import logo from "./logo.svg"`, `require("../img/x.png")` (React
/// Native) — or as URL strings for files under public/, which web
/// toolchains serve from the site root.
pub fn asset_usages(graph: &Graph, asset: &str) -> Result<AssetRefs, String> {
  let asset_rel = fs::canonicalize(graph.project.to_abs(asset))
    .ok()
    .filter(|p| p.is_file())
    .map(|p| graph.project.rel(&p))
    .ok_or_else(|| format!("asset not found: {asset}"))?;
  let live = graph.live()?;
  let live_set: HashSet<&str> = live.iter().map(String::as_str).collect();

  // String literals that name the asset: its repo path and, for public/
  // files, the URL it is served at.
  let mut literals = vec![asset_rel.clone()];
  if let Some(served) = asset_rel.strip_prefix("public/") {
    literals.push(format!("/{served}"));
  }

  let mut binding_refs = Vec::new();
  let mut direct_refs = Vec::new();
  let mut importers = None;

  for rel in live.iter().filter(|r| is_script(r)) {
    let path = graph.project.root.join(rel);
    let Ok(src) = fs::read_to_string(&path) else { continue };
    let root = ts::parse(&src, ts::lang_for(&path));
    let facts = ts::extract(&root);

    // Literal path strings are always direct references.
    for line in ts::literal_lines(&root, &literals) {
      direct_refs.push(Usage {
        file: rel.clone(),
        line,
        text: line_text(&src, line),
      });
    }

    // Module references whose specifier resolves to this asset.
    let refs: Vec<&ts::Spec> = [Directive::Import, Directive::Export, Directive::Dynamic]
      .iter()
      .flat_map(|d| facts.specs(*d))
      .filter(|s| graph.project.resolve_uri(&s.text, rel).as_deref() == Some(asset_rel.as_str()))
      .collect();
    if refs.is_empty() {
      continue;
    }

    // Names this file binds to one of those references.
    let binds: Vec<&ts::Binding> = facts
      .bindings
      .iter()
      .filter(|b| matches!(b.id, "import-default" | "require-binding"))
      .filter(|b| refs.iter().any(|r| r.line == b.line && b.src.as_deref() == Some(r.text.as_str())))
      .collect();

    // Unbound references are direct.
    for r in refs.iter().filter(|r| !binds.iter().any(|b| b.line == r.line)) {
      direct_refs.push(Usage {
        file: rel.clone(),
        line: r.line,
        text: line_text(&src, r.line),
      });
    }

    // Bound references: every use of the bound name in live code, i.e. in
    // this file and in live importers that use it by that name.
    for bind in binds {
      let Some(name) = bind.local.as_deref() else { continue };
      eprintln!("binding: {name} ({rel}:{})", bind.line);
      let index = match &importers {
        Some(index) => index,
        None => importers.insert(graph.importers()?),
      };
      let mut scan: Vec<String> = vec![rel.clone()];
      scan.extend(
        index
          .get(rel)
          .into_iter()
          .flatten()
          .filter(|row| row.entities_used.iter().any(|e| e == name))
          .filter(|row| live_set.contains(row.file.as_str()))
          .map(|row| row.file.clone()),
      );
      for file in scan {
        let path: PathBuf = graph.project.root.join(&file);
        let Ok(src) = fs::read_to_string(&path) else { continue };
        let root = ts::parse(&src, ts::lang_for(&path));
        for line in ts::name_uses(&root, name) {
          // Skip the binding itself (its declaration line in its own file).
          if file == *rel && line == bind.line {
            continue;
          }
          binding_refs.push(BindingUsage {
            file: file.clone(),
            line,
            text: line_text(&src, line),
            binding: name.to_string(),
          });
        }
      }
    }
  }

  Ok(AssetRefs {
    binding_refs: sorted_unique(binding_refs, |u| (u.file.clone(), u.line)),
    direct_refs: sorted_unique(direct_refs, file_line),
  })
}
