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
//!   importers <file>
//!   trace <file>
//!   prune <file>
//!   usages <pattern> [--live-only]
//!   usages --assets <asset-path>

mod kt;

use std::process::ExitCode;

fn main() -> ExitCode {
  discover_jvm::main::<kt::Kotlin>()
}
