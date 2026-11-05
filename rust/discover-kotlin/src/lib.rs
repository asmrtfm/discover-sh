//! discover-kotlin — deterministic Kotlin codebase navigation, in-process on
//! ast-grep's Kotlin support. A port of the Kotlin discover.sh: same
//! subcommands, flags, JSON shapes and stderr commentary. Everything but
//! reading a Kotlin parse tree is shared with Java in discover-jvm.
//!
//! Subcommands:
//!   resolve <import> [--from <file>]
//!   inspect <file> [--package] [--imports] [--entities] [--depth names|signatures|full]
//!   definition <file> <symbol>
//!   live-files
//!   dead-files [--rebuild]
//!   is-live <file>
//!   importers [--strict] <files ...>
//!   trace [--strict] <files ...>
//!   prune [--strict] <files ...>
//!   usages <pattern> [--live-only]
//!   usages --assets <asset-path>

pub mod kt;

use std::process::ExitCode;

/// How the discover binary identifies and runs Kotlin.
pub const LANGUAGE: discover_core::cli::Language = discover_core::cli::Language {
  // Selects Kotlin with --lang=kotlin.
  name: "kotlin",
  // Identifies Kotlin source files.
  extensions: &["kt"],
  // Lists no manifests, because build.gradle and pom.xml fit Java too.
  manifests: &[],
  // Describes the default entry points in generated config files.
  entry_defaults: "files declaring `main`, Android manifest components, META-INF/services providers",
  // Runs the function below.
  main,
  // Lists the JVM commands, shared with Java, for --help.
  usage: discover_jvm::cli::USAGE,
};

/// Runs the Kotlin navigator.
pub fn main() -> ExitCode {
  discover_jvm::main::<kt::Kotlin>()
}
