//! Lookups the Dart subcommands share.

use crate::dart::Facts;
use crate::graph::Graph;
use crate::project::generated_extensions;
use std::sync::Arc;

/// The project's source files and their generated extensions (`*.g.dart`, `*.freezed.dart`) with their facts, in file order: where `definition` and `usages` look for declarations.
pub fn project_facts(graph: &Graph) -> Vec<(String, Arc<Facts>)> {
  graph
    .project
    .relevant_files()
    .into_iter()
    .flat_map(|base| {
      let mut files = vec![base.clone()];
      files.extend(generated_extensions(&base));
      files
    })
    .map(|path| (graph.project.rel(&path), graph.facts(&path)))
    .collect()
}
