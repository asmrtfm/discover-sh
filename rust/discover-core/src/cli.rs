//! The command line every navigator shares: argument handling, output, and
//! the subcommands that only need the graph (live-files, dead-files,
//! is-live, importers, trace, prune). A language adds resolve, inspect,
//! definition and usages.

use crate::graph::{EntityUse, Graph, Lang, Row, Trace};
use crate::project::{relative, to_abs};
use crate::usages::Usage;
use serde::Serialize;
// Holds the per-language source file counts during language detection.
use std::collections::BTreeMap;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

/// Holds the name of the subcommand that `run` dispatches to.
static SUBCOMMAND: OnceLock<String> = OnceLock::new();

/// Holds whether `run` found `--strict` in the command-line arguments. Starts false.
static STRICT: AtomicBool = AtomicBool::new(false);

/// Holds whether `-v` or `--verbose` was found in the command-line arguments. Starts false.
pub static VERBOSE: AtomicBool = AtomicBool::new(false);

/// Holds whether `--live-only` was found in the command-line arguments. Starts false. Commands that list files read it to keep only live ones.
pub static LIVE_ONLY: AtomicBool = AtomicBool::new(false);

/// Holds the language named by `--lang=<lang>`, which the discover binary routes on.
pub static LANG: OnceLock<String> = OnceLock::new();

/// Holds the arguments left over for the subcommand.
static ARGS: OnceLock<Vec<String>> = OnceLock::new();

/// Holds whether `--rebuild-cache` was found in the command-line arguments. Starts false.
static REBUILD: AtomicBool = AtomicBool::new(false);

/// Holds whether `--no-rebuild` was found in the command-line arguments. Starts false.
static NO_REBUILD: AtomicBool = AtomicBool::new(false);

const COMMANDS: &[&str] = &[
  "resolve",
  "inspect",
  "live-files",
  "dead-files",
  "is-live",
  "definition",
  "importers",
  "trace",
  "prune",
  "usages",
  // Dart and TypeScript only for now; the other languages accept it and exit 1 without output.
  "attributes",
];

/// The workspace version and the time of the build, written into the binary
/// at compile time by build.rs.
pub const VERSION: &str = env!("DISCOVER_VERSION");

/// Writes a line to stdout; a closed pipe (`| head`) ends the run quietly.
pub fn out(line: &str) {
  let mut stdout = io::stdout().lock();
  if writeln!(stdout, "{line}").is_err() {
    std::process::exit(0);
  }
}

/// Pretty JSON, indented like jq's default output.
pub fn out_json<T: Serialize>(value: &T) {
  out(&serde_json::to_string_pretty(value).expect("serializable"));
}

/// Runs a navigator: `<command> [args]`, with `--rebuild-cache` or `--no-rebuild` allowed anywhere. `open` builds the
/// graph (told whether --rebuild-cache was given); `commands` handles the
/// language's own subcommands (resolve, inspect, definition, usages).
pub fn main<L: Lang>(
  usage: &str,
  open: impl FnOnce(bool) -> Result<Graph<L>, String>,
  commands: impl FnOnce(&Graph<L>, &str, &[String]) -> Result<u8, String>,
) -> ExitCode {
  match run(usage, open, commands) {
    Ok(code) => ExitCode::from(code),
    Err(msg) => {
      eprintln!("error: {msg}");
      ExitCode::FAILURE
    }
  }
}

/// What a language exposes so that the discover binary can identify it and run it.
pub struct Language {
  /// The value of `--lang=<lang>` that selects this language.
  pub name: &'static str,
  /// The file extensions of this language's source files, without the dot.
  pub extensions: &'static [&'static str],
  /// The manifest files at a project's root that identify this language.
  pub manifests: &'static [&'static str],
  /// This language's default entry points, as the comment `discover config` generates.
  pub entry_defaults: &'static str,
  /// Runs this language's navigator.
  pub main: fn() -> ExitCode,
  /// The help text for this language's own commands, printed after the shared help.
  pub usage: &'static str,
}

/// Names the directories that the source scan skips.
const SKIPPED_DIRS: &[&str] = &[".build", ".dart_tool", ".git", "build", "node_modules", "vendor"];

/// Returns the name of the language whose extensions include the path's extension, or None when no language does.
fn lang_of(langs: &[Language], path: &Path) -> Option<&'static str> {
  // Reads the path's extension.
  let ext = path.extension()?.to_str()?;
  // Finds the language that claims the extension and returns its name.
  langs.iter().find(|lang| lang.extensions.contains(&ext)).map(|lang| lang.name)
}

/// Adds one to `counts` for every source file under `dir`, recursing into every directory not in `SKIPPED_DIRS`.
fn count_langs(langs: &[Language], dir: &Path, counts: &mut BTreeMap<&'static str, usize>) {
  // Lists the directory, treating an unreadable one as empty.
  let entries = std::fs::read_dir(dir).into_iter().flatten().flatten();
  // Visits every entry in the directory.
  for entry in entries {
    // Gets the entry's full path.
    let path = entry.path();
    // Handles a real directory; symlinks aren't followed, so a link cycle can't loop forever.
    if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
      // Reads the directory's own name.
      let name = entry.file_name();
      // Recurses unless the directory is on the skip list.
      if !name.to_str().is_some_and(|name| SKIPPED_DIRS.contains(&name)) {
        // Counts the files inside the directory.
        count_langs(langs, &path, counts);
      }
    // Handles a file with a known source extension.
    } else if let Some(lang) = lang_of(langs, &path) {
      // Adds one to that language's count.
      *counts.entry(lang).or_default() += 1;
    }
  }
}

/// Returns the best guess at the language: a file argument's extension, then a manifest in the current directory, then the most common source extension in the project.
fn detect_lang(langs: &[Language], args: &[String]) -> Option<&'static str> {
  // Returns the language of the first argument with a known extension.
  if let Some(lang) = args.iter().find_map(|arg| lang_of(langs, Path::new(arg))) {
    // Stops at the file argument, which is the strongest signal.
    return Some(lang);
  }
  // Finds the first language with one of its manifests in the current directory.
  if let Some(lang) = langs.iter().find(|lang| lang.manifests.iter().any(|manifest| Path::new(manifest).is_file())) {
    // Stops at the manifest, which identifies the project.
    return Some(lang.name);
  }
  // Holds the number of source files found for each language.
  let mut counts = BTreeMap::new();
  // Counts the source files from the current directory down.
  count_langs(langs, Path::new("."), &mut counts);
  // Returns the language with the most files, or None when there are none.
  counts.into_iter().max_by_key(|(_, count)| *count).map(|(lang, _)| lang)
}

/// `-h` / `--help`: prints the help page to stdout and exits 0, without opening a project. With a known language (`--lang=` anywhere on the command line, discover.conf, or detection), the page ends with that language's commands; otherwise it ends with every language's commands, each under its name.
fn help(langs: &[Language]) -> ! {
  // Reads the whole command line, since --lang= may come after --help.
  let args: Vec<String> = std::env::args().skip(1).collect();
  // Takes the language from --lang=, then discover.conf, then detection, like parse_args.
  let name = args
    .iter()
    .find_map(|arg| arg.strip_prefix("--lang=").map(str::to_string))
    .or_else(|| crate::project::project_config().and_then(|config| config.lang()))
    .or_else(|| detect_lang(langs, &args).map(str::to_string));
  // Builds the page for the known language, or for all of them.
  let text = match name.as_deref().and_then(|name| langs.iter().find(|lang| lang.name == name)) {
    // Ends the shared help with this language's commands.
    Some(lang) => format!("{}\n{}", shared_usage(&format!("discover --lang={}", lang.name)), lang.usage),
    // Ends the shared help with each language's commands, headed by the flag that selects it.
    None => {
      let mut text = shared_usage("discover");
      for lang in langs {
        text.push_str(&format!("\n\n{} commands (--lang={}):\n{}", lang.name, lang.name, lang.usage));
      }
      text
    }
  };
  out(&text);
  // Exits without running anything else.
  std::process::exit(0)
}

/// Writes a commented `./discover.conf` for the current directory, naming the detected language and every language's default entry points. An existing file is left alone.
pub fn write_config(langs: &[Language]) -> ExitCode {
  // Refuses to overwrite, because the file holds the user's choices.
  if Path::new("discover.conf").exists() {
    eprintln!("error: discover.conf already exists");
    return ExitCode::FAILURE;
  }
  // Reads the directory the file is keyed by.
  let cwd = match crate::project::current_dir() {
    Ok(cwd) => cwd.to_string_lossy().into_owned(),
    Err(e) => {
      eprintln!("error: {e}");
      return ExitCode::FAILURE;
    }
  };
  // Lists one comment line per language.
  let defaults: Vec<String> = langs.iter().map(|lang| format!("#   {}: {}", lang.name, lang.entry_defaults)).collect();
  // Leaves `lang` commented out when nothing identifies the project.
  let lang = match detect_lang(langs, &[]) {
    Some(lang) => format!("  lang: {lang}"),
    None => "  # lang: <language>".to_string(),
  };
  // Quotes the key as JSON, which is also valid YAML, so any path is safe.
  let key = serde_json::to_string(&cwd).expect("a string serializes");
  let text = format!(
    "# discover configuration: one block per project directory. JSON is also accepted.\n#\n# lang     Which navigator to run. Omit it to detect the language from the project.\n# entries  Repo-relative files where the program starts, the roots of liveness.\n#          Listing any replaces the defaults below completely, so list every entry point.\n#          DISCOVER_ENTRY=\"<file> ...\" overrides this list for a single run.\n#\n# Default entry points, used when `entries` is not set:\n{}\n{key}:\n{lang}\n  # entries:\n  #   - path/to/entry\n",
    defaults.join("\n")
  );
  // Writes the file and reports the outcome.
  match std::fs::write("discover.conf", text) {
    Ok(()) => {
      println!("wrote discover.conf");
      ExitCode::SUCCESS
    }
    Err(e) => {
      eprintln!("error: cannot write discover.conf: {e}");
      ExitCode::FAILURE
    }
  }
}

/// Sets the command-line globals from the arguments. The discover binary calls this once, before anything else runs.
pub fn parse_args(langs: &[Language]) {
  // Collects the arguments that belong to the subcommand.
  let mut args: Vec<String> = Vec::new();
  // Visits every argument after the binary's name.
  for arg in std::env::args().skip(1) {
    // Once set, a word matching a subcommand name is an argument, so `usages trace` searches for `trace`. Global flags are recognized in any position.
    let no_subcommand_yet = SUBCOMMAND.get().is_none();
    // Sorts the argument into a global or the subcommand's arguments.
    match arg.as_str() {
      // Turns on strict mode.
      "--strict" => STRICT.store(true, Ordering::Relaxed),
      // Turns on verbose mode.
      "-v" | "--verbose" => VERBOSE.store(true, Ordering::Relaxed),
      // Prints the help page and exits; no project or caches involved.
      "-h" | "--help" => help(langs),
      // Records that file listings should keep only live files.
      "--live-only" => LIVE_ONLY.store(true, Ordering::Relaxed),
      // Records the language, keeping the first one given.
      flag if flag.starts_with("--lang=") => {
        // Stores the text after `--lang=`; a later --lang is ignored.
        let _ = LANG.set(flag.trim_start_matches("--lang=").to_string());
      }
      // --version: the build's baked-in version; no project or caches involved.
      "--version" | "-V" => {
        // Prints the binary's name and version.
        out(&format!("discover {VERSION}"));
        // Exits without running anything else.
        std::process::exit(0);
      }
      // Records that the caches should be rebuilt.
      "--rebuild-cache" => REBUILD.store(true, Ordering::Relaxed),
      // Records that the caches on disk should be used as they are.
      "--no-rebuild" => NO_REBUILD.store(true, Ordering::Relaxed),
      // Records the first word that names a subcommand.
      name if no_subcommand_yet && COMMANDS.contains(&name) => {
        // Stores the subcommand, which can only be unset here because of the guard.
        SUBCOMMAND.set(arg.clone()).expect("set once, guarded by no_subcommand_yet");
      }
      // Passes everything else to the subcommand.
      _ => args.push(arg),
    }
  }
  // Detects the language when --lang wasn't given.
  if LANG.get().is_none() {
    // Tries the config file first, then detection, keeping whichever finds a language.
    if let Some(lang) = crate::project::project_config().and_then(|config| config.lang()).or_else(|| detect_lang(langs, &args).map(str::to_string)) {
      // Sets LANG, which is known to be empty here.
      let _ = LANG.set(lang);
    }
  }
  // Stores the subcommand's arguments.
  ARGS.set(args).expect("parse_args runs once");
}

fn run<L: Lang>(
  usage: &str,
  open: impl FnOnce(bool) -> Result<Graph<L>, String>,
  commands: impl FnOnce(&Graph<L>, &str, &[String]) -> Result<u8, String>,
) -> Result<u8, String> {
  // Reads whether --rebuild-cache was given.
  let rebuild = REBUILD.load(Ordering::Relaxed);
  // Reads whether --no-rebuild was given.
  let no_rebuild = NO_REBUILD.load(Ordering::Relaxed);
  // Reads the subcommand's arguments.
  let args = ARGS.get().map_or(&[][..], Vec::as_slice);
  if rebuild && no_rebuild {
    return Err("--rebuild-cache and --no-rebuild cannot be combined".into());
  }
  // --no-rebuild: use the caches on disk as they are (see cache::skip_rebuild).
  if no_rebuild {
    crate::cache::skip_rebuild();
  }
  let command = SUBCOMMAND.get().map_or("", String::as_str);
  if command.is_empty() && !rebuild {
    // Prints the shared help, then the language's own commands.
    eprintln!("{}\n{usage}", shared_usage(L::NAME));
    return Ok(1);
  }

  let mut graph = open(rebuild)?;
  if rebuild {
    graph.build_all()?;
    // With no subcommand, the rebuild was the whole request.
    if command.is_empty() {
      return Ok(0);
    }
  }

  match command {
    "live-files" => {
      graph.live()?.iter().for_each(|l| out(l));
      Ok(0)
    }
    "dead-files" => {
      if args.first().is_some_and(|a| a == "--rebuild") {
        graph.build_dead()?;
      }
      graph.dead()?.iter().for_each(|l| out(l));
      Ok(0)
    }
    "is-live" => cmd_is_live(&graph, &args),
    "importers" => cmd_importers(&graph, &args),
    "trace" => cmd_trace(&graph, &args),
    "prune" => cmd_prune(&mut graph, &args),
    other => commands(&graph, other, &args),
  }
}

/// Returns the help page's synopsis, description, global flags, language detection and the commands implemented in this file. Every navigator prints it before its own commands, so the commands section comes last.
fn shared_usage(name: &str) -> String {
  // Fills the binary's name into the shared help text.
  format!(
    "synopsis:
  {name} [global flags] <command> [args]

description:
  Navigates a project through its import graph: resolves imports, inspects files, finds definitions, importers and usages, and sorts files into live and dead.

  Live means reachable. Starting from the entry points, discover follows imports forward; every file it reaches is live. A file is live as soon as one live file imports it, whether or not anything it defines is used. live-files, is-live and --live-only all use this list.

  Dead is confirmed from the opposite direction. trace starts at the file and walks its importers backward, through their importers and so on, looking for a chain that ends at an entry point. A file with no such chain is dead. dead-files runs this backward walk over every source file and prints a DISAGREEMENT line for each file where its verdict differs from the live list. trace on a given file goes deeper: it also checks which of the file's entities each importer uses, and calls the file dead when no live importer uses any of them.

global flags (allowed anywhere on the command line):
  --rebuild-cache                        Wipe and rebuild all caches before running command
  --no-rebuild                           Use the caches on disk even if stale (builds only missing ones)
  --live-only                            Limit usages to live files
  --strict                               Treat a skipped path as an error, so nothing runs (importers, trace, prune)
  -v, --verbose                          Print more detail where a command supports it
  -V, --version                          Print the version and build time
  --lang=<lang>                          Use this language (dart, java, kotlin or typescript) instead of detecting it

language detection, used without --lang; the first that gives an answer wins:
  1. discover.conf                       A JSON object mapping project directories to languages, read from ./discover.conf, then $XDG_CONFIG_HOME/discover.conf or ~/.config/discover.conf
  2. File arguments                      The extension of the first file argument with a known extension
  3. Manifests                           A manifest in the current directory, such as pubspec.yaml or package.json
  4. Source scan                         The most common source file extension in the project

commands:
  live-files                             List all live files
  dead-files [--rebuild]                 List all dead files, found by the backward walk
  is-live <file>                         Check if a file is live
  importers <files ...>                  Find all files that import <file>
                                         A path that doesn't exist is skipped with a warning; with --strict, it is an error and nothing runs.
  trace <files ...>                      Show which of the entities in <file> are used by its importers, and whether <file> is dead
                                         A path that doesn't exist is skipped with a warning; with --strict, it is an error and nothing runs. A path that isn't a source file is always skipped with a warning.
  prune <files ...>                      Remove deleted files' paths from the caches, so the deletion doesn't trigger a rebuild on the next run
                                         A path that still exists is skipped with a warning; with --strict, it is an error and nothing runs. A path that isn't in the caches is always skipped with a warning.
  attributes <class> <file>              List the instance fields of <class>, defined in <file>, one name per line; with --verbose, a JSON array of {{ <field>: <type> }} objects
                                         Dart and TypeScript only for now; other languages print nothing and exit 1. In TypeScript/JavaScript, <class> can also be a Mongoose model, whose schema fields are listed.",
    name = name
  )
}

/// Returns the strings whose existence as a file equals `constraint`, and prints a warning containing `msg` for each of the others.
fn collect_files(constraint: bool, msg: &str, strings: &[String]) -> Vec<String> {
  // Holds the strings that satisfy the constraint.
  let mut files = Vec::with_capacity(strings.len());
  // Builds the current working directory prefix, or None when it can't be read.
  let cwd = std::env::current_dir().ok().map(|dir| format!("{}/", dir.display()));
  // Visits every string, in argument order.
  for maybe_file in strings {
    // Removes a leading `./`, or else a leading working directory, leaving any other string as it is.
    let stripped = maybe_file
      // Tries the `./` prefix first.
      .strip_prefix("./")
      // Tries the working directory prefix when `./` wasn't there.
      .or_else(|| maybe_file.strip_prefix(cwd.as_deref()?))
      // Falls back to the string as given.
      .unwrap_or(maybe_file);
    // Compares whether the path is a file with the constraint.
    if Path::new(stripped).is_file() == constraint {
      // Keeps an owned copy of the stripped form of a string that satisfies the constraint.
      files.push(stripped.to_string());
    } else {
      // Warns about a string that doesn't satisfy the constraint.
      eprintln!("warning: {maybe_file} {msg}");
    }
  }
  // Returns the strings that were kept.
  files
}

/// Returns the same strings as `collect_files`, or an error if any string failed the constraint.
fn collect_files_strict(constraint: bool, msg: &str, strings: &[String]) -> Result<Vec<String>, String> {
  // Filters the strings, which prints a warning for every failure.
  let files = collect_files(constraint, msg, strings);
  // Detects a failure by comparing how many strings were kept with how many were given.
  if files.len() != strings.len() {
    // Returns the error, with a hint saying how to disable the constraint.
    return Err("--strict: nothing was run\nhint: run without --strict to skip the paths above and continue with the rest".into());
  }
  // Returns the strings, all of which passed.
  Ok(files)
}

/// An existing file argument as (canonical path, repo-relative path).
pub fn file_arg(root: &Path, file: &str) -> Result<(PathBuf, String), String> {
  let abs = to_abs(root, file);
  if !abs.is_file() {
    return Err(format!("file not found: {file}"));
  }
  let canonical = std::fs::canonicalize(&abs).map_err(|e| format!("{file}: {e}"))?;
  let rel = relative(root, &canonical);
  Ok((canonical, rel))
}

// ─────────────────────────────────────────────────────────
// argument parsing for the language subcommands
// ─────────────────────────────────────────────────────────

/// `resolve <what> [--from <file>]` → (what, from); from is "" when absent.
/// `what` names the argument in the usage message (`<uri>`, `<import>`, …).
pub fn parse_resolve<'a, L: Lang>(args: &'a [String], what: &str) -> Result<(&'a str, &'a str), String> {
  let mut uri = "";
  let mut from = "";
  let mut it = args.iter();
  while let Some(arg) = it.next() {
    match arg.as_str() {
      "--from" => from = it.next().map_or("", String::as_str),
      other => uri = other,
    }
  }
  if uri.is_empty() {
    return Err(format!("usage: {} resolve {what} [--from <file>]", L::NAME));
  }
  Ok((uri, from))
}

pub struct InspectArgs<'a> {
  /// Whether each of the language's section flags was given, in order.
  pub sections: Vec<bool>,
  pub entities: bool,
  /// name | names | signatures | full
  pub depth: String,
  pub file: Option<&'a str>,
}

/// `inspect <file> [<section flags>] [--entities] [--depth names|signatures|full]`, in any order.
/// With no section and no --entities, everything is selected.
pub fn parse_inspect<'a>(args: &'a [String], section_flags: &[&str]) -> InspectArgs<'a> {
  let mut sections = vec![false; section_flags.len()];
  let mut entities = false;
  // Empty without --depth: entities print as JSON with kind, name and line.
  let mut depth = String::new();
  let mut file = None;
  let mut i = 0;
  while i < args.len() {
    let arg = args[i].as_str();
    if let Some(at) = section_flags.iter().position(|f| *f == arg) {
      sections[at] = true;
    } else {
      match arg {
        "--entities" => entities = true,
        "--depth" => {
          i += 1;
          depth = args.get(i).cloned().unwrap_or_default();
        }
        other => file = Some(other),
      }
    }
    i += 1;
  }
  if !(entities || sections.iter().any(|s| *s)) {
    sections.iter_mut().for_each(|s| *s = true);
    entities = true;
  }
  InspectArgs {
    sections,
    entities,
    depth,
    file,
  }
}

pub enum UsagesArgs<'a> {
  Pattern { pattern: &'a str, live_only: bool },
  Assets(&'a str),
}

/// `usages <pattern> [--live-only]` or `usages --assets <asset-path>`. `--live-only` is a global flag, read from [`LIVE_ONLY`].
pub fn parse_usages<'a, L: Lang>(args: &'a [String]) -> Result<UsagesArgs<'a>, String> {
  let mut pattern = "";
  let mut asset = None;
  // Reads the global --live-only flag, which parse_args already consumed.
  let live_only = LIVE_ONLY.load(Ordering::Relaxed);
  let mut it = args.iter();
  while let Some(arg) = it.next() {
    match arg.as_str() {
      "--assets" => {
        asset = Some(
          it.next()
            .filter(|a| !a.is_empty())
            .ok_or("--assets requires an asset path argument")?
            .as_str(),
        )
      }
      other => pattern = other,
    }
  }
  if let Some(asset) = asset {
    return Ok(UsagesArgs::Assets(asset));
  }
  if pattern.is_empty() {
    let name = L::NAME;
    return Err(format!(
      "usage: {name} usages <pattern> [--live-only] [-v|--verbose]\n       {name} usages --assets <asset-path>"
    ));
  }
  Ok(UsagesArgs::Pattern { pattern, live_only })
}

/// Pattern results on stdout so they can be piped; the count is commentary.
pub fn print_usages(found: &[Usage]) {
  out_json(&found);
  eprintln!("{} usages found", found.len());
}

// ─────────────────────────────────────────────────────────
// output shapes shared by the language subcommands
// ─────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct EntityOut<'a> {
  pub kind: &'a str,
  pub name: &'a str,
  pub line: usize,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub text: Option<&'a str>,
}

impl<'a> EntityOut<'a> {
  /// `text` is the header for signatures depth, the whole declaration for
  /// full depth, and omitted otherwise.
  pub fn new(kind: &'a str, name: &'a str, line: usize, header: &'a str, full: &'a str, depth: &str) -> Self {
    let text = match depth {
      "full" => Some(full),
      "signatures" => Some(header),
      _ => None,
    };
    EntityOut { kind, name, line, text }
  }
}

#[derive(Serialize)]
pub struct DefinitionOut<'a> {
  pub symbol: &'a str,
  pub kind: &'a str,
  pub file: &'a str,
  pub line: usize,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub via: Option<&'a [String]>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub source: Option<&'a str>,
  /// The whole declaration, with `--verbose`.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub code: Option<&'a str>,
}

pub struct DefinitionArgs<'a> {
  pub symbol: &'a str,
  /// The file the symbol is used in; without it every definition in the
  /// project is reported.
  pub file: Option<&'a str>,
  /// `-v` / `--verbose`: include each definition's code.
  pub verbose: bool,
  /// `-p` / `--pretty`: print each definition as a header line and its code
  /// as written instead of JSON. Implies `verbose`.
  pub pretty: bool,
}

/// `definition <symbol> [<file>] [-v|--verbose] [-p|--pretty]`.
pub fn parse_definition<'a, L: Lang>(args: &'a [String]) -> Result<DefinitionArgs<'a>, String> {
  let usage = || format!("usage: {} definition <symbol> [<file>] [-v|--verbose] [-p|--pretty]", L::NAME);
  let mut verbose = VERBOSE.load(Ordering::Relaxed);
  let mut pretty = false;
  let mut positional = Vec::new();
  for arg in args {
    match arg.as_str() {
      "-p" | "--pretty" => pretty = true,
      other => positional.push(other),
    }
  }
  // Pretty output is the code, so it needs the code.
  verbose |= pretty;
  match positional[..] {
    [symbol] => Ok(DefinitionArgs { symbol, file: None, verbose, pretty }),
    [symbol, file] => Ok(DefinitionArgs { symbol, file: Some(file), verbose, pretty }),
    _ => Err(usage()),
  }
}

/// `--pretty` output for one definition: a `file:line kind symbol` header
/// (with the re-export chain, when there is one), then its code as written.
pub fn out_pretty_definition(def: &DefinitionOut) {
  let mut header = format!("{}:{} {} {}", def.file, def.line, def.kind, def.symbol);
  if let Some(via) = def.via.filter(|v| !v.is_empty()) {
    header.push_str(&format!(" (via {})", via.join(" -> ")));
  }
  out(&header);
  out(def.code.unwrap_or_default());
  out("");
}

/// One definition, as JSON or with `--pretty`.
pub fn out_definition(def: &DefinitionOut, pretty: bool) {
  if pretty {
    out_pretty_definition(def);
  } else {
    out_json(def);
  }
}

// ─────────────────────────────────────────────────────────
// is-live
// ─────────────────────────────────────────────────────────
fn cmd_is_live<L: Lang>(graph: &Graph<L>, args: &[String]) -> Result<u8, String> {
  let file = args.first().ok_or(format!("usage: {} is-live <file>", L::NAME))?;
  let (_, rel) = file_arg(graph.root(), file)?;
  if graph.live()?.contains(&rel) {
    out(&format!("LIVE: {rel}"));
    Ok(0)
  } else {
    out(&format!("DEAD: {rel}"));
    Ok(1)
  }
}

// ─────────────────────────────────────────────────────────
// importers
// ─────────────────────────────────────────────────────────
/// One importer per line. With several files, each line is `<target>:<importer>`, like grep with several files, so every importer stays attributed to its target.
fn cmd_importers<L: Lang>(graph: &Graph<L>, args: &[String]) -> Result<u8, String> {
  // Rejects a call with no file paths.
  if args.is_empty() {
    // Returns the usage message as the error.
    return Err(format!("usage: {} importers [--strict] <files ...>", L::NAME));
  }
  // Names the failure in the warning for a path that isn't a file.
  let msg = "does not exist";
  // Keeps the paths that are files, or errors on any that isn't when strict.
  let targets = if STRICT.load(Ordering::Relaxed) { collect_files_strict(true, msg, args)? } else { collect_files(true, msg, args) };
  // Loads the importers index once for all targets.
  let index = graph.importers()?;
  // Visits the targets in argument order.
  for file in &targets {
    // Gets this target's importer rows, or none when nothing imports it.
    let mut rows: Vec<&Row> = index.get(file).map(|rows| rows.iter().collect()).unwrap_or_default();
    // Sorts the rows by importer path.
    rows.sort_by(|a, b| a.file.cmp(&b.file));
    // Prints one line per importer.
    for row in rows {
      // Uses the argument count, so a skipped path can't change the output format.
      if args.len() > 1 {
        // Prefixes the target so each importer stays tied to it.
        out(&format!("{file}:{}", row.file));
      } else {
        // Prints the bare importer path for a single argument.
        out(&row.file);
      }
    }
  }
  // Exits successfully, including when paths were skipped.
  Ok(0)
}

// ─────────────────────────────────────────────────────────
// prune
// ─────────────────────────────────────────────────────────
fn cmd_prune<L: Lang>(graph: &mut Graph<L>, args: &[String]) -> Result<u8, String> {
  // Rejects a call with no file paths.
  if args.is_empty() {
    // Returns the usage message as the error.
    return Err(format!("usage: {} prune [--strict] <files ...>", L::NAME));
  }
  // Names the failure in the warning for a path that is still a file.
  let msg = "still exists";
  // Keeps the paths that are not files, or errors on any that is when strict.
  let targets = if STRICT.load(Ordering::Relaxed) { collect_files_strict(false, msg, args)? } else { collect_files(false, msg, args) };
  // Loads the set of paths the caches mention.
  let cached = graph.cached_files();
  // Visits the surviving paths in argument order.
  for file in &targets {
    // Prunes only a path the caches mention.
    if cached.contains(file) {
      // Removes the path from the caches.
      graph.prune(file)?;
    } else {
      // Warns about a path the caches don't mention, in strict mode too.
      eprintln!("warning: {file} is not in the caches");
    }
  }
  // Exits successfully, including when paths were skipped.
  Ok(0)
}

// ─────────────────────────────────────────────────────────
// trace — tags each importer of a file:
//   active — live importer that uses the target's entities
//   stale  — live importer that doesn't use any entities
//   zombie — dead importer (the dependency exists but the chain is dead)
// The file is dead when no importer is active, then the
// verdict is cross-checked against is-live.
// Several files produce one JSON document each, in argument
// order, which jq reads as a stream.
// ─────────────────────────────────────────────────────────
#[derive(Serialize)]
struct TracedRow {
  file: String,
  directive: String,
  uri: String,
  entities_used: Vec<EntityUse>,
  status: &'static str,
  /// Present (true) when the importer exports the target, passing its
  /// entities on to its own importers.
  #[serde(skip_serializing_if = "std::ops::Not::not")]
  transitive: bool,
}

#[derive(Serialize)]
// Borrows the file path for the moment the output is serialized.
struct TraceOut<'a> {
  // The target path, as given on the command line.
  file: &'a str,
  entities: Vec<String>,
  importers: Vec<TracedRow>,
  dead: bool,
  active_count: usize,
  #[serde(skip_serializing_if = "Option::is_none")]
  warning: Option<String>,
}

fn cmd_trace<L: Lang>(graph: &Graph<L>, args: &[String]) -> Result<u8, String> {
  // Rejects a call with no file paths.
  if args.is_empty() {
    // Returns the usage message as the error.
    return Err(format!("usage: {} trace [--strict] <files ...>", L::NAME));
  }
  // Names the failure in the warning for a path that isn't a file.
  let msg = "does not exist";
  // Keeps the paths that are files, or errors on any that isn't when strict.
  let targets = if STRICT.load(Ordering::Relaxed) { collect_files_strict(true, msg, args)? } else { collect_files(true, msg, args) };
  // Loaded once and shared: the reachability memo stays valid across targets.
  let index = graph.importers()?;
  let live = graph.live()?;
  let mut trace = Trace::new(&index, graph.entries());

  // Visits the targets in argument order.
  for file in &targets {
    // Views the argument as a path for the file-based lookups.
    let path = Path::new(file);
    // Skips a file that trace can't follow.
    if !graph.is_source(path) {
      // Warns about a non-source file, in strict mode too, and points to the command for assets.
      eprintln!("warning: {file} is not a source file (trace is for code; for assets use: {} usages --assets <path>)", L::NAME);
      // Moves on to the next target.
      continue;
    }
    // Reads the names of the entities the file declares.
    let entities = graph.entity_names(path);
    // Builds a tagged row for each importer stored under this file in the index.
    let mut importers: Vec<TracedRow> = index
      // Looks up this file's importer rows, using the argument as the key.
      .get(file)
      // Treats the rows as a slice.
      .map(Vec::as_slice)
      .unwrap_or_default()
      .iter()
      .map(|row| {
        let status = if !trace.reachable(&row.file) {
          "zombie"
        } else if row.entities_used.is_empty() {
          "stale"
        } else {
          "active"
        };
        TracedRow {
          file: row.file.clone(),
          directive: row.directive.clone(),
          uri: row.uri.clone(),
          entities_used: row.entities_used.clone(),
          status,
          transitive: row.directive.split(',').any(|d| d == "export"),
        }
      })
      .collect();
    importers.sort_by(|a, b| a.file.cmp(&b.file));

    let active_count = importers.iter().filter(|r| r.status == "active").count();
    // An entry point has no importers by definition, yet is live.
    let dead = active_count == 0 && !graph.entries().contains(file);
    // Reads the file's dead verdict from the live list, for the cross-check below.
    let bfs_dead = !live.contains(file);
    let warning = (dead != bfs_dead).then(|| {
      let w = format!("DISAGREEMENT: trace says dead={dead} but is-live says dead={bfs_dead}");
      eprintln!("WARNING: {w}");
      w
    });

    out_json(&TraceOut {
      // Passes the target path without copying it.
      file,
      entities,
      importers,
      dead,
      active_count,
      warning,
    });
  }
  // Exits successfully, including when paths were skipped.
  Ok(0)
}
