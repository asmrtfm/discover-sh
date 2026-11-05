use discover_jvm::project::{attribute, is_test_or_build_logic, strip_xml_comments, tags, tags_named};

#[test]
fn excludes_tests_and_build_logic() {
  assert!(is_test_or_build_logic("app/src/test/java/A.java"));
  assert!(is_test_or_build_logic("app/src/androidTest/java/A.kt"));
  assert!(is_test_or_build_logic("buildSrc/src/main/kotlin/A.kt"));
  assert!(!is_test_or_build_logic("app/src/main/java/com/x/testutil/A.java"));
  assert!(!is_test_or_build_logic("app/src/main/java/A.kt"));
}

#[test]
fn reads_manifest_tags() {
  let xml = strip_xml_comments(
    r#"<manifest package="com.x">
  <!-- <activity android:name=".Old" /> -->
  <application
    android:name=".App">
    <activity android:name="Main" />
    <activity-alias android:name="com.y.Alias" />
  </application>
</manifest>"#,
  );
  let names: Vec<String> = tags(&xml, &["application", "activity", "activity-alias"])
    .iter()
    .filter_map(|t| attribute(t, "android:name"))
    .collect();
  assert_eq!(names, [".App", "Main", "com.y.Alias"]);
  assert_eq!(attribute(&tags_named(&xml, "manifest")[0], "package").as_deref(), Some("com.x"));
}
