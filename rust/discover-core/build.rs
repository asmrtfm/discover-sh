//! Bakes the build's version into discover-core for `--version`: the
//! workspace version and the UTC time of the build.

use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
  // Rerun whenever any navigator's sources change, so every build that
  // changes a binary also changes its version.
  if let Ok(dirs) = fs::read_dir("..") {
    for dir in dirs.flatten() {
      let name = dir.file_name().to_string_lossy().to_string();
      if name.starts_with("discover-") {
        println!("cargo:rerun-if-changed=../{name}/src");
        println!("cargo:rerun-if-changed=../{name}/Cargo.toml");
      }
    }
  }
  println!(
    "cargo:rustc-env=DISCOVER_VERSION={} (built {})",
    env!("CARGO_PKG_VERSION"),
    utc_now()
  );
}

/// The current time as `YYYY-MM-DDTHH:MM:SSZ`.
fn utc_now() -> String {
  let secs = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .map_or(0, |d| d.as_secs());
  let (days, rem) = (secs / 86_400, secs % 86_400);
  let (year, month, day) = civil_from_days(days as i64);
  format!(
    "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
    rem / 3600,
    rem % 3600 / 60,
    rem % 60
  )
}

/// Days since 1970-01-01 → (year, month, day) in the proleptic Gregorian
/// calendar (Howard Hinnant's `civil_from_days`).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
  let z = days + 719_468;
  let era = z.div_euclid(146_097);
  let doe = z.rem_euclid(146_097);
  let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  let mp = (5 * doy + 2) / 153;
  let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
  let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
  let year = yoe + era * 400 + i64::from(month <= 2);
  (year, month, day)
}
