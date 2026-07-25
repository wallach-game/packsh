setup() {
  export PACKSH_ROOT="$BATS_TEST_DIRNAME/.."
  PACKSH="$PACKSH_ROOT/bin/packsh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export PACKSH_HOME="$BATS_TEST_TMPDIR/packsh-home"
}

# --- help / version / usage ---

@test "--help prints usage" {
  run "$PACKSH" --help
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "Usage" ]]
}

@test "-v prints version" {
  run "$PACKSH" -v
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "packsh v" ]]
}

@test "no args prints usage and exits nonzero" {
  run "$PACKSH"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "Usage" ]]
}

@test "bare user/repo argument is rejected (remote installs unsupported)" {
  run "$PACKSH" some/repo
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "local installs" ]]
}

# --- validation ---

@test "-l on missing directory fails" {
  run "$PACKSH" -l "$BATS_TEST_TMPDIR/does-not-exist"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no such directory" ]]
}

@test "-l on directory without packsh.json fails" {
  run "$PACKSH" -l "$BATS_TEST_TMPDIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no packsh.json" ]]
}

@test "-l on invalid JSON fails" {
  run "$PACKSH" -l "$FIXTURES/badjson"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "invalid JSON" ]]
}

@test "-l on manifest missing name fails" {
  run "$PACKSH" -l "$FIXTURES/noname"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "missing required" ]]
}

@test "-l on manifest with empty bins fails" {
  run "$PACKSH" -l "$FIXTURES/nobins"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no bins" ]]
}

@test "-l on manifest declaring a nonexistent bin fails" {
  run "$PACKSH" -l "$FIXTURES/missingbin"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "bin not found" ]]
}

# --- install ---

@test "-l installs bins into PACKSH_HOME/bin" {
  run "$PACKSH" -l "$FIXTURES/samplepkg"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "installed samplepkg" ]]
  [[ -L "$PACKSH_HOME/bin/hello" ]]
  [[ "$("$PACKSH_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "-l copies the source repo into cellar (not a symlink)" {
  "$PACKSH" -l "$FIXTURES/samplepkg"
  [[ -d "$PACKSH_HOME/cellar/samplepkg" ]]
  [[ ! -L "$PACKSH_HOME/cellar/samplepkg" ]]
  [[ -f "$PACKSH_HOME/cellar/samplepkg/packsh.json" ]]
}

@test "installed package is self-sufficient: survives source being deleted" {
  local src_copy="$BATS_TEST_TMPDIR/samplepkg-copy"
  cp -a "$FIXTURES/samplepkg" "$src_copy"
  "$PACKSH" -l "$src_copy"
  rm -rf "$src_copy"
  [[ "$("$PACKSH_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "installed package is self-sufficient: unaffected by later source edits" {
  local src_copy="$BATS_TEST_TMPDIR/samplepkg-edit"
  cp -a "$FIXTURES/samplepkg" "$src_copy"
  "$PACKSH" -l "$src_copy"
  echo 'echo "changed"' > "$src_copy/bin/hello"
  [[ "$("$PACKSH_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "-l installs declared completions" {
  "$PACKSH" -l "$FIXTURES/samplepkg"
  [[ -L "$PACKSH_HOME/completions/bash/samplepkg" ]]
  [[ -L "$PACKSH_HOME/completions/zsh/samplepkg" ]]
}

@test "-l is idempotent (installing twice does not fail)" {
  "$PACKSH" -l "$FIXTURES/samplepkg"
  run "$PACKSH" -l "$FIXTURES/samplepkg"
  [[ "$status" -eq 0 ]]
  [[ -L "$PACKSH_HOME/bin/hello" ]]
}

@test "-l accepts a relative path" {
  run bash -c "cd '$FIXTURES' && PACKSH_HOME='$PACKSH_HOME' '$PACKSH' -l samplepkg"
  [[ "$status" -eq 0 ]]
  [[ -L "$PACKSH_HOME/bin/hello" ]]
}

# --- list ---

@test "--list is empty before any install" {
  run "$PACKSH" --list
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "--list shows installed package after install" {
  "$PACKSH" -l "$FIXTURES/samplepkg"
  run "$PACKSH" --list
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "samplepkg ->" ]]
}

# --- uninstall ---

@test "-u removes bin symlink, cellar entry and completions" {
  "$PACKSH" -l "$FIXTURES/samplepkg"
  run "$PACKSH" -u samplepkg
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "uninstalled samplepkg" ]]
  [[ ! -e "$PACKSH_HOME/bin/hello" ]]
  [[ ! -e "$PACKSH_HOME/cellar/samplepkg" ]]
  [[ ! -e "$PACKSH_HOME/completions/bash/samplepkg" ]]
  [[ ! -e "$PACKSH_HOME/completions/zsh/samplepkg" ]]
}

@test "-u on a package that isn't installed fails" {
  run "$PACKSH" -u never-installed
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "not installed" ]]
}

@test "package no longer appears in --list after uninstall" {
  "$PACKSH" -l "$FIXTURES/samplepkg"
  "$PACKSH" -u samplepkg
  run "$PACKSH" --list
  [[ ! "$output" =~ "samplepkg" ]]
}
