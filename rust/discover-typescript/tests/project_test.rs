use discover_typescript::project::{docker_command, is_docker_file, is_excluded, package_targets, runner_targets, strip_jsonc};
use serde_json::Value;

#[test]
fn strips_jsonc() {
  let src = r#"{
      // comment
      "a": "http://x", /* block */
      "b": [1, 2,],
    }"#;
  let v: Value = serde_json::from_str(&strip_jsonc(src)).unwrap();
  assert_eq!(v["a"], "http://x");
  assert_eq!(v["b"], serde_json::json!([1, 2]));
}

#[test]
fn excludes_tests_and_declarations() {
  assert!(is_excluded("src/a.d.ts"));
  assert!(is_excluded("src/a.test.tsx"));
  assert!(is_excluded("__tests__/App.test.tsx"));
  assert!(is_excluded("src/__mocks__/x.ts"));
  assert!(is_excluded("backend/tests/routes/userTest.js"));
  assert!(is_excluded("test/app.js"));
  assert!(!is_excluded("src/testing/util.ts"));
  assert!(!is_excluded("backend/server.js"));
}

#[test]
fn reads_runner_commands() {
  assert_eq!(runner_targets("node backend/server"), ["backend/server"]);
  assert_eq!(runner_targets("nodemon --watch src"), Vec::<&str>::new());
  assert_eq!(runner_targets("node backend/seeder -d"), ["backend/seeder"]);
  assert_eq!(runner_targets("mocha 'backend/tests/**/*Test.js' --exit"), Vec::<&str>::new());
  assert_eq!(runner_targets("concurrently \"npm run server\""), Vec::<&str>::new());
}

#[test]
fn reads_package_targets() {
  let pkg = serde_json::json!({"main": "a.js", "bin": {"x": "bin/x.js"}, "scripts": {"start": "node b.js"}});
  assert_eq!(package_targets(&pkg), ["a.js", "bin/x.js", "b.js"]);
  assert_eq!(package_targets(&serde_json::json!({"bin": "c.js"})), ["c.js"]);
}

#[test]
fn reads_docker_commands() {
  let run = |line: &str| docker_command(line).map(|c| runner_targets(&c).iter().map(|t| t.to_string()).collect::<Vec<_>>());
  assert_eq!(run("CMD [\"node\", \"dist/server.js\"]"), Some(vec!["dist/server.js".to_string()]));
  assert_eq!(run("ENTRYPOINT node app.js"), Some(vec!["app.js".to_string()]));
  assert_eq!(run("    command: sh -c \"npm install && node backend/worker.js\""), Some(vec!["backend/worker.js".to_string()]));
  assert_eq!(run("FROM node:20"), None);
  assert!(is_docker_file("docker-compose.yaml") && is_docker_file("Dockerfile.dev") && !is_docker_file("package.json"));
}
