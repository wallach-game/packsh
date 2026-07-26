setup() {
  export BUNDLESH_ROOT="$BATS_TEST_DIRNAME/.."
  BUNDLESH="$BUNDLESH_ROOT/bin/bundlesh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export BUNDLESH_HOME="$BATS_TEST_TMPDIR/bundlesh-home"
}

# --- help / version / usage ---

@test "--help prints usage" {
  run "$BUNDLESH" --help
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "Usage" ]]
}

@test "-v prints version" {
  run "$BUNDLESH" -v
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "bundlesh v" ]]
}

@test "no args prints usage and exits nonzero" {
  run "$BUNDLESH"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "Usage" ]]
}

@test "bare user/repo argument is rejected (remote installs unsupported)" {
  run "$BUNDLESH" some/repo
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "local installs" ]]
}

# --- validation ---

@test "-l on missing directory fails" {
  run "$BUNDLESH" -l "$BATS_TEST_TMPDIR/does-not-exist"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no such directory" ]]
}

@test "-l on directory without bundlesh.json fails" {
  run "$BUNDLESH" -l "$BATS_TEST_TMPDIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no bundlesh.json" ]]
}

@test "-l on invalid JSON fails" {
  run "$BUNDLESH" -l "$FIXTURES/badjson"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "invalid JSON" ]]
}

@test "-l on manifest missing name fails" {
  run "$BUNDLESH" -l "$FIXTURES/noname"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "missing required" ]]
}

@test "-l on manifest with empty bins fails" {
  run "$BUNDLESH" -l "$FIXTURES/nobins"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no bins" ]]
}

@test "-l on manifest declaring a nonexistent bin fails" {
  run "$BUNDLESH" -l "$FIXTURES/missingbin"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "bin not found" ]]
}

# --- install ---

@test "-l installs bins into BUNDLESH_HOME/bin" {
  run "$BUNDLESH" -l "$FIXTURES/samplepkg"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "installed samplepkg" ]]
  [[ -L "$BUNDLESH_HOME/bin/hello" ]]
  [[ "$("$BUNDLESH_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "-l copies the source repo into cellar (not a symlink)" {
  "$BUNDLESH" -l "$FIXTURES/samplepkg"
  [[ -d "$BUNDLESH_HOME/cellar/samplepkg" ]]
  [[ ! -L "$BUNDLESH_HOME/cellar/samplepkg" ]]
  [[ -f "$BUNDLESH_HOME/cellar/samplepkg/bundlesh.json" ]]
}

@test "installed package is self-sufficient: survives source being deleted" {
  local src_copy="$BATS_TEST_TMPDIR/samplepkg-copy"
  cp -a "$FIXTURES/samplepkg" "$src_copy"
  "$BUNDLESH" -l "$src_copy"
  rm -rf "$src_copy"
  [[ "$("$BUNDLESH_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "installed package is self-sufficient: unaffected by later source edits" {
  local src_copy="$BATS_TEST_TMPDIR/samplepkg-edit"
  cp -a "$FIXTURES/samplepkg" "$src_copy"
  "$BUNDLESH" -l "$src_copy"
  echo 'echo "changed"' > "$src_copy/bin/hello"
  [[ "$("$BUNDLESH_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "-l installs declared completions" {
  "$BUNDLESH" -l "$FIXTURES/samplepkg"
  [[ -L "$BUNDLESH_HOME/completions/bash/samplepkg" ]]
  [[ -L "$BUNDLESH_HOME/completions/zsh/samplepkg" ]]
}

@test "-l is idempotent (installing twice does not fail)" {
  "$BUNDLESH" -l "$FIXTURES/samplepkg"
  run "$BUNDLESH" -l "$FIXTURES/samplepkg"
  [[ "$status" -eq 0 ]]
  [[ -L "$BUNDLESH_HOME/bin/hello" ]]
}

@test "-l accepts a relative path" {
  run bash -c "cd '$FIXTURES' && BUNDLESH_HOME='$BUNDLESH_HOME' '$BUNDLESH' -l samplepkg"
  [[ "$status" -eq 0 ]]
  [[ -L "$BUNDLESH_HOME/bin/hello" ]]
}

# --- list ---

@test "--list is empty before any install" {
  run "$BUNDLESH" --list
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "--list shows installed package after install" {
  "$BUNDLESH" -l "$FIXTURES/samplepkg"
  run "$BUNDLESH" --list
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "samplepkg ->" ]]
}

# --- uninstall ---

@test "-u removes bin symlink, cellar entry and completions" {
  "$BUNDLESH" -l "$FIXTURES/samplepkg"
  run "$BUNDLESH" -u samplepkg
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "uninstalled samplepkg" ]]
  [[ ! -e "$BUNDLESH_HOME/bin/hello" ]]
  [[ ! -e "$BUNDLESH_HOME/cellar/samplepkg" ]]
  [[ ! -e "$BUNDLESH_HOME/completions/bash/samplepkg" ]]
  [[ ! -e "$BUNDLESH_HOME/completions/zsh/samplepkg" ]]
}

@test "-u on a package that isn't installed fails" {
  run "$BUNDLESH" -u never-installed
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "not installed" ]]
}

@test "package no longer appears in --list after uninstall" {
  "$BUNDLESH" -l "$FIXTURES/samplepkg"
  "$BUNDLESH" -u samplepkg
  run "$BUNDLESH" --list
  [[ ! "$output" =~ "samplepkg" ]]
}
