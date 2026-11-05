//! discover-java — deterministic Java codebase navigation, in-process on
//! ast-grep's Java support. A port of the Java discover.sh: same
//! subcommands, flags, JSON shapes and stderr commentary. Everything but
//! reading a Java parse tree is shared with Kotlin in discover-jvm.
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

pub mod java;

use std::process::ExitCode;

/// How the discover binary identifies and runs Java.
pub const LANGUAGE: discover_core::cli::Language = discover_core::cli::Language {
  // Selects Java with --lang=java.
  name: "java",
  // Identifies Java source files.
  extensions: &["java"],
  // Lists no manifests, because build.gradle and pom.xml fit Kotlin too.
  manifests: &[],
  // Describes the default entry points in generated config files.
  entry_defaults: "files declaring `main`, Android manifest components, META-INF/services providers",
  // Runs the function below.
  main,
  // Lists the JVM commands, shared with Kotlin, for --help.
  usage: discover_jvm::cli::USAGE,
};

/// Runs the Java navigator.
pub fn main() -> ExitCode {
  discover_jvm::main::<java::Java>()
}
