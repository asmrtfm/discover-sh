//! `usages`: structural search over the sources with an ast-grep pattern,
//! and the `--assets` lookup of what references an asset file.

use crate::graph::Graph;
use crate::{Jvm, parse};
use ast_grep_core::Pattern;
use discover_core::par::par_map;
use discover_core::usages::{Usage, file_line, line_text, sorted_unique};
use serde::Serialize;
use std::fs;

/// Runs a pattern over the given repo-relative files.
fn search<J: Jvm>(graph: &Graph<J>, pattern: &Pattern, files: &[String]) -> Vec<Usage> {
  let hits: Vec<Vec<Usage>> = par_map(files, |rel| {
    let Ok(src) = fs::read_to_string(graph.project.root.join(rel)) else {
      return Vec::new();
    };
    parse::<J>(&src)
      .root()
      .find_all(pattern)
      .map(|m| {
        let line = m.get_node().start_pos().line() + 1;
        Usage {
          file: rel.clone(),
          line,
          text: line_text(&src, line),
        }
      })
      .collect()
  });
  sorted_unique(hits.into_iter().flatten().collect(), file_line)
}

fn live_sources<J: Jvm>(graph: &Graph<J>) -> Result<Vec<String>, String> {
  Ok(graph.live()?.into_iter().filter(|f| f.ends_with(J::EXT)).collect())
}

/// `usages <pattern> [--live-only]`. An invalid pattern finds nothing.
pub fn pattern_usages<J: Jvm>(graph: &Graph<J>, pattern: &str, live_only: bool) -> Result<Vec<Usage>, String> {
  let Ok(pattern) = Pattern::try_new(pattern, J::LANG) else {
    return Ok(Vec::new());
  };
  let files = if live_only {
    live_sources(graph)?
  } else {
    graph.project.relevant_files()
  };
  Ok(search(graph, &pattern, &files))
}

#[derive(Debug, Serialize)]
pub struct AssetRefs {
  /// Android resources through their generated constant, R.<type>.<name>.
  pub constant_refs: Vec<Usage>,
  /// The same resources referenced from XML (@<type>/<name>) in resource
  /// files and manifests.
  pub xml_refs: Vec<Usage>,
  /// String literals naming the file: Android assets/ and JVM resources/ by
  /// their path inside that root (also matching longer forms such as
  /// file:///android_asset/<path> or a leading /), anything else by its
  /// repo-relative path.
  pub direct_refs: Vec<Usage>,
}

/// An Android resource file: `res/<type>[-qualifiers]/<name>.<ext>` → (type, name).
fn android_resource(rel: &str) -> Option<(String, String)> {
  let mut parts = rel.rsplit('/');
  let file = parts.next()?;
  let dir = parts.next()?;
  if parts.next()? != "res" {
    return None;
  }
  let res_type = dir.split('-').next()?;
  if res_type.is_empty() || !res_type.chars().all(|c| c.is_ascii_lowercase()) {
    return None;
  }
  // foo.9.png → foo
  let name = file.split('.').next()?;
  Some((res_type.to_string(), name.to_string()))
}

/// The path code uses for a non-resource file: relative to an `assets/` or
/// `resources/` root, else repo-relative.
fn literal_path(rel: &str) -> String {
  let segments: Vec<&str> = rel.split('/').collect();
  match segments.iter().position(|s| *s == "assets" || *s == "resources") {
    Some(i) if i + 1 < segments.len() => segments[i + 1..].join("/"),
    _ => rel.to_string(),
  }
}

/// `usages --assets <path>`: what references an asset in live code.
pub fn asset_usages<J: Jvm>(graph: &Graph<J>, asset: &str) -> Result<AssetRefs, String> {
  let asset_rel = fs::canonicalize(graph.project.to_abs(asset))
    .ok()
    .filter(|p| p.is_file())
    .map(|p| graph.project.rel(&p))
    .ok_or_else(|| format!("asset not found: {asset}"))?;
  let live = live_sources(graph)?;
  let mut refs = AssetRefs {
    constant_refs: Vec::new(),
    xml_refs: Vec::new(),
    direct_refs: Vec::new(),
  };

  if let Some((res_type, name)) = android_resource(&asset_rel) {
    if res_type == "values" {
      return Err("res/values files hold many resources; search one with: usages 'R.<type>.<name>'".into());
    }
    let constant = format!("R.{res_type}.{name}");
    eprintln!("constant: {constant}");
    if let Ok(pattern) = Pattern::try_new(&constant, J::LANG) {
      refs.constant_refs = search(graph, &pattern, &live);
    }

    // XML has no grammar here; the reference syntax is a fixed string that
    // must end at a non-name character.
    let needle = format!("@{res_type}/{name}");
    for file in graph.project.xml_files() {
      let is_resource_xml = file.starts_with("res/") || file.contains("/res/") || file.ends_with("AndroidManifest.xml");
      if !is_resource_xml {
        continue;
      }
      let Ok(text) = fs::read_to_string(graph.project.root.join(&file)) else { continue };
      for (i, line) in text.lines().enumerate() {
        let whole = line.match_indices(needle.as_str()).any(|(at, _)| {
          line[at + needle.len()..]
            .chars()
            .next()
            .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '_'))
        });
        if whole {
          refs.xml_refs.push(Usage {
            file: file.clone(),
            line: i + 1,
            text: line.trim_start().to_string(),
          });
        }
      }
    }
    refs.xml_refs.sort_by(|a, b| (&a.file, a.line).cmp(&(&b.file, b.line)));
  } else {
    let literal = literal_path(&asset_rel);
    let hits: Vec<Vec<Usage>> = par_map(&live, |rel| {
      let Ok(src) = fs::read_to_string(graph.project.root.join(rel)) else {
        return Vec::new();
      };
      J::literal_lines(&parse::<J>(&src), &literal)
        .into_iter()
        .map(|line| Usage {
          file: rel.clone(),
          line,
          text: line_text(&src, line),
        })
        .collect()
    });
    refs.direct_refs = sorted_unique(hits.into_iter().flatten().collect(), file_line);
  }
  Ok(refs)
}
