setup() {
  export BASHPACK_ROOT="$BATS_TEST_DIRNAME/.."
  BASHPACK="$BASHPACK_ROOT/bin/bashpack"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export BASHPACK_HOME="$BATS_TEST_TMPDIR/bashpack-home"
}

# --- help / version / usage ---

@test "--help prints usage" {
  run "$BASHPACK" --help
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "Usage" ]]
}

@test "-v prints version" {
  run "$BASHPACK" -v
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "bashpack v" ]]
}

@test "no args prints usage and exits nonzero" {
  run "$BASHPACK"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "Usage" ]]
}

@test "bare user/repo argument is rejected (remote installs unsupported)" {
  run "$BASHPACK" some/repo
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "local installs" ]]
}

# --- validation ---

@test "-l on missing directory fails" {
  run "$BASHPACK" -l "$BATS_TEST_TMPDIR/does-not-exist"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no such directory" ]]
}

@test "-l on directory without bashpack.json fails" {
  run "$BASHPACK" -l "$BATS_TEST_TMPDIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no bashpack.json" ]]
}

@test "-l on invalid JSON fails" {
  run "$BASHPACK" -l "$FIXTURES/badjson"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "invalid JSON" ]]
}

@test "-l on manifest missing name fails" {
  run "$BASHPACK" -l "$FIXTURES/noname"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "missing required" ]]
}

@test "-l on manifest with empty bins fails" {
  run "$BASHPACK" -l "$FIXTURES/nobins"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "no bins" ]]
}

@test "-l on manifest declaring a nonexistent bin fails" {
  run "$BASHPACK" -l "$FIXTURES/missingbin"
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "bin not found" ]]
}

# --- install ---

@test "-l installs bins into BASHPACK_HOME/bin" {
  run "$BASHPACK" -l "$FIXTURES/samplepkg"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "installed samplepkg" ]]
  [[ -L "$BASHPACK_HOME/bin/hello" ]]
  [[ "$("$BASHPACK_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "-l copies the source repo into cellar (not a symlink)" {
  "$BASHPACK" -l "$FIXTURES/samplepkg"
  [[ -d "$BASHPACK_HOME/cellar/samplepkg" ]]
  [[ ! -L "$BASHPACK_HOME/cellar/samplepkg" ]]
  [[ -f "$BASHPACK_HOME/cellar/samplepkg/bashpack.json" ]]
}

@test "installed package is self-sufficient: survives source being deleted" {
  local src_copy="$BATS_TEST_TMPDIR/samplepkg-copy"
  cp -a "$FIXTURES/samplepkg" "$src_copy"
  "$BASHPACK" -l "$src_copy"
  rm -rf "$src_copy"
  [[ "$("$BASHPACK_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "installed package is self-sufficient: unaffected by later source edits" {
  local src_copy="$BATS_TEST_TMPDIR/samplepkg-edit"
  cp -a "$FIXTURES/samplepkg" "$src_copy"
  "$BASHPACK" -l "$src_copy"
  echo 'echo "changed"' > "$src_copy/bin/hello"
  [[ "$("$BASHPACK_HOME/bin/hello")" == "hello from samplepkg" ]]
}

@test "-l installs declared completions" {
  "$BASHPACK" -l "$FIXTURES/samplepkg"
  [[ -L "$BASHPACK_HOME/completions/bash/samplepkg" ]]
  [[ -L "$BASHPACK_HOME/completions/zsh/samplepkg" ]]
}

@test "-l is idempotent (installing twice does not fail)" {
  "$BASHPACK" -l "$FIXTURES/samplepkg"
  run "$BASHPACK" -l "$FIXTURES/samplepkg"
  [[ "$status" -eq 0 ]]
  [[ -L "$BASHPACK_HOME/bin/hello" ]]
}

@test "-l accepts a relative path" {
  run bash -c "cd '$FIXTURES' && BASHPACK_HOME='$BASHPACK_HOME' '$BASHPACK' -l samplepkg"
  [[ "$status" -eq 0 ]]
  [[ -L "$BASHPACK_HOME/bin/hello" ]]
}

# --- list ---

@test "--list is empty before any install" {
  run "$BASHPACK" --list
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "--list shows installed package after install" {
  "$BASHPACK" -l "$FIXTURES/samplepkg"
  run "$BASHPACK" --list
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "samplepkg ->" ]]
}

# --- uninstall ---

@test "-u removes bin symlink, cellar entry and completions" {
  "$BASHPACK" -l "$FIXTURES/samplepkg"
  run "$BASHPACK" -u samplepkg
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ "uninstalled samplepkg" ]]
  [[ ! -e "$BASHPACK_HOME/bin/hello" ]]
  [[ ! -e "$BASHPACK_HOME/cellar/samplepkg" ]]
  [[ ! -e "$BASHPACK_HOME/completions/bash/samplepkg" ]]
  [[ ! -e "$BASHPACK_HOME/completions/zsh/samplepkg" ]]
}

@test "-u on a package that isn't installed fails" {
  run "$BASHPACK" -u never-installed
  [[ "$status" -ne 0 ]]
  [[ "$output" =~ "not installed" ]]
}

@test "package no longer appears in --list after uninstall" {
  "$BASHPACK" -l "$FIXTURES/samplepkg"
  "$BASHPACK" -u samplepkg
  run "$BASHPACK" --list
  [[ ! "$output" =~ "samplepkg" ]]
}
