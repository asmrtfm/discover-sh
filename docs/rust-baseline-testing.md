# Baseline testing for the Rust navigators

The four binaries in `rust/` (`discover-dart`, `discover-typescript`, `discover-java`, `discover-kotlin`) are tested by running a fixed list of subcommands against a real project, writing everything they print to a log, and diffing that log against the log from the previous build. A behaviour-preserving change (refactor) must produce an identical log. An intended behaviour change must produce a diff containing only that change.

`cargo test --release` (from `rust/`) runs the unit tests, which cover parsing only. The baseline logs are what cover the subcommands.

## Procedure

1. Before editing, build the current code: `cargo build --release` in `rust/`. Binaries land in `rust/target/release/`.
2. Run each language's command list below with those binaries and write the logs somewhere outside the projects. These are the baseline logs.
3. Make the change, rebuild, and run the same command lists into new logs.
4. `diff baseline.log after.log`. Identical means no output changed. Any difference is either the intended change or a regression; read every hunk.
5. When a change is intended, the new log becomes the baseline for the next change.

If the code was already edited before a baseline was taken, build the commit being compared against in a separate `git worktree` and take the baseline from that build.

## Rules

- Run every command from the project root. The binaries treat the current directory as the project and exit with `error: no <manifest> in <dir>: run this from the project root` otherwise. For Kotlin and Java the project root is the Gradle root (`android/`, `jadx/`), not the repository root.
- The first command in every list is `--rebuild-cache`, so each run starts from freshly built caches. Caches are written to `<project>/tmp/` (or `$CACHE_DIR` if set).
- Each log entry is `### <binary> <args>`, then stdout and stderr merged, then `### exit <status>`. Exit status is part of what is compared.
- Run one language at a time.

## Caches left behind by a run

Most lists end with `prune <file>`. `prune` removes that file from the live-files cache and the importers index and re-stamps both, so after a run the caches on disk report the pruned file as dead even though the source has not changed. Any command run afterwards without `--rebuild-cache` reads those pruned caches. A `trace` of the pruned file then prints `DISAGREEMENT: trace says dead=false but is-live says dead=true` when only some of the caches were rebuilt (for example after a cache format change). Run `--rebuild-cache` before checking anything by hand after a baseline run.

## Projects

| Binary | Project root |
|---|---|
| discover-dart | `/home/me/Workspaces/malsi-app/malsi` |
| discover-typescript | `/home/me/Workspaces/night-district/night-district-vending` |
| discover-kotlin | `/home/me/Workspaces/night-district/night-district-vending/android` |
| discover-java | `/home/me/Workspaces/night-district/night-district-vending/jadx` |

`night-district-vending/android` has no Java sources, which is why Java uses `jadx` (a full Gradle Java project vendored inside night-district-vending).

## Command lists

Each block is run in bash from the project root. Set `LOG` to the output file first. The `r` function appends one log entry per command.

### Dart (malsi)

The targets come from the comment API: `comment_api.dart` is imported by `comment_api_provider.dart`. `definition` takes the symbol first and the file second; the second `definition` call, with no file, lists every definition of the symbol in the project.

```bash
B=/home/me/Workspaces/asmrtfm/discover/rust/target/release/discover-dart
F=lib/shared/api/comment/comment_api.dart
: > $LOG
r() { echo "### discover-dart $*" >> $LOG; $B "$@" >> $LOG 2>&1; echo "### exit $?" >> $LOG; }
r --rebuild-cache
r live-files
r dead-files
r is-live $F
r importers $F
r trace $F
r inspect $F
r definition CommentApi $F
r definition CommentApi
r resolve comment_api.dart --from lib/shared/api/comment/comment_api_provider.dart
r usages '$X.getComments($$$)'
r usages '$X.getComments($$$)' --live-only
```

### TypeScript (night-district-vending)

What the targets exercise: `kioskData.ts` is live (imported by `VendingDashboard.tsx`); `src/api/client.ts` is dead and reached only through the `@/api/...` tsconfig alias and the `src/api/index.ts` barrel, so its importers are all zombies; the three `definition` calls go through a named import, a default import and an alias import; the asset is loaded with `require()` in `kioskData.ts`.

```bash
B=/home/me/Workspaces/asmrtfm/discover/rust/target/release/discover-typescript
: > $LOG
r() { echo "### discover-typescript $*" >> $LOG; $B "$@" >> $LOG 2>&1; echo "### exit $?" >> $LOG; }
r --rebuild-cache
r live-files
r dead-files
r is-live src/features/vending/kioskData.ts
r is-live src/api/client.ts
r importers src/features/vending/kioskData.ts
r importers src/api/client.ts
r trace src/features/vending/kioskData.ts
r trace src/api/client.ts
r trace src/api/errors.ts
r inspect src/features/vending/kioskData.ts
r inspect src/api/index.ts
r inspect src/api/client.ts --entities signatures
r definition src/features/vending/VendingDashboard.tsx PRODUCTS
r definition src/features/vending/VendingDashboard.tsx BrowseScreen
r definition src/api/orders.ts VendingClient
r resolve @/api/client --from src/api/orders.ts
r resolve ./kioskData --from src/features/vending/VendingDashboard.tsx
r usages 'require($P)'
r usages 'require($P)' --live-only
r usages --assets assets/images/products/zyn-orangespritz-11mg-np.png
r prune src/api/client.ts
r importers src/api/errors.ts
```

### Kotlin (night-district-vending/android)

What the targets exercise: `MotorBoardClient.kt` uses `WoovendProtocol` through same-package visibility (no import); `MotorModule.kt` uses `MotorBoardClient` through an import; `resolve` covers a fully-qualified name, a wildcard, and a simple name seen from a file; the asset is an Android drawable, looked up as `R.drawable.<name>` and `@drawable/<name>`.

```bash
B=/home/me/Workspaces/asmrtfm/discover/rust/target/release/discover-kotlin
K=app/src/main/java/com/nightdistrict/vending
: > $LOG
r() { echo "### discover-kotlin $*" >> $LOG; $B "$@" >> $LOG 2>&1; echo "### exit $?" >> $LOG; }
r --rebuild-cache
r live-files
r dead-files
r is-live $K/hardware/drivers/WoovendProtocol.kt
r importers $K/hardware/drivers/WoovendProtocol.kt
r trace $K/hardware/drivers/WoovendProtocol.kt
r trace $K/hardware/drivers/SerialPortManager.kt
r trace $K/hardware/discovery/ByteAnalyzer.kt
r inspect $K/hardware/drivers/WoovendProtocol.kt
r inspect $K/hardware/MotorModule.kt --entities signatures
r definition $K/hardware/drivers/MotorBoardClient.kt WoovendProtocol
r definition $K/hardware/MotorModule.kt MotorBoardClient
r resolve com.nightdistrict.vending.hardware.drivers.WoovendProtocol
r resolve 'com.nightdistrict.vending.hardware.drivers.*'
r resolve WoovendProtocol --from $K/hardware/drivers/MotorBoardClient.kt
r usages 'WoovendProtocol.$M($$$)'
r usages 'WoovendProtocol.$M($$$)' --live-only
r usages --assets app/src/main/res/drawable/rn_edit_text_material.xml
r prune $K/hardware/drivers/SerialPortManager.kt
r live-files
r dead-files
```

### Java (night-district-vending/jadx)

What the targets exercise: `JadxCLI.java` holds `main` (an entry point); it uses `JadxDecompiler` through an import and `JadxCLIArgs` through same-package visibility; `resolve` covers a fully-qualified name, a `jadx.api.*` wildcard, and a simple name seen from a file; the asset `jadx-build-info.properties` is loaded by `JadxBuildInfo.java` through `getResourceAsStream("/jadx-build-info.properties")`.

```bash
B=/home/me/Workspaces/asmrtfm/discover/rust/target/release/discover-java
C=jadx-cli/src/main/java/jadx/cli
A=jadx-core/src/main/java/jadx/api
: > $LOG
r() { echo "### discover-java $*" >> $LOG; $B "$@" >> $LOG 2>&1; echo "### exit $?" >> $LOG; }
r --rebuild-cache
r live-files
r dead-files
r is-live $C/JadxCLI.java
r is-live $A/JadxDecompiler.java
r importers $A/JadxDecompiler.java
r importers $A/JadxArgs.java
r trace $C/JadxCLI.java
r trace $A/JadxDecompiler.java
r trace $C/SingleClassMode.java
r inspect $C/JadxCLI.java
r inspect $A/JadxDecompiler.java --entities signatures
r definition $C/JadxCLI.java JadxDecompiler
r definition $C/JadxCLI.java JadxCLIArgs
r resolve jadx.api.JadxDecompiler
r resolve 'jadx.api.*'
r resolve JadxCLIArgs --from $C/JadxCLI.java
r usages '$X.getClasses()'
r usages '$X.getClasses()' --live-only
r usages --assets jadx-core/src/main/resources/jadx-build-info.properties
r prune $C/SingleClassMode.java
r live-files
r dead-files
```

## Expected non-zero exits

- TypeScript `is-live src/api/client.ts` exits 1 (the file is dead; `is-live` exits 1 for dead files).

Every other command in the four lists exits 0.
