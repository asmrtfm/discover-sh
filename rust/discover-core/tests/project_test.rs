use discover_core::project::relative;
use std::path::Path;

#[test]
fn relative_paths() {
  let base = Path::new("/a/b");
  assert_eq!(relative(base, Path::new("/a/b/lib/x.dart")), "lib/x.dart");
  assert_eq!(relative(base, Path::new("/a/c/x.dart")), "../c/x.dart");
  assert_eq!(relative(base, Path::new("/a/b")), ".");
}
