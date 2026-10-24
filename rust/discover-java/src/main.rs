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
//!   importers <file>
//!   trace <file>
//!   prune <file>
//!   usages <pattern> [--live-only]
//!   usages --assets <asset-path>

mod java;

use std::process::ExitCode;

fn main() -> ExitCode {
  discover_jvm::main::<java::Java>()
}
