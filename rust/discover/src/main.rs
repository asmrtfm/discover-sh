//! discover — deterministic codebase navigation. Routes to a language's navigator with `--lang=<lang>`, or to the language detected for the project.

// Imports the language description, the argument parser and the LANG global it sets.
use discover_core::cli::{LANG, Language, parse_args, write_config};
// Imports the type main returns as the process's exit status.
use std::process::ExitCode;

/// Lists every language this binary can run.
const LANGS: &[Language] = &[discover_dart::LANGUAGE, discover_java::LANGUAGE, discover_kotlin::LANGUAGE, discover_typescript::LANGUAGE];

fn main() -> ExitCode {
  // Handles `discover config`, which needs no language or project graph.
  if std::env::args().nth(1).as_deref() == Some("config") {
    return write_config(LANGS);
  }
  // Sets the command-line globals, including LANG.
  parse_args(LANGS);
  // Finds the language named by LANG.
  match LANGS.iter().find(|lang| LANG.get().is_some_and(|name| name == lang.name)) {
    // Runs that language's navigator.
    Some(lang) => (lang.main)(),
    // Handles a language that is unknown or couldn't be detected.
    None => {
      // Collects the valid language names.
      let names: Vec<&str> = LANGS.iter().map(|lang| lang.name).collect();
      // Prints the valid languages.
      eprintln!("error: could not determine the language; use --lang=<{}>", names.join("|"));
      // Exits with a failure status.
      ExitCode::FAILURE
    }
  }
}
