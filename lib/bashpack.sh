bashpack_usage() {
  cat <<EOF
Usage: bashpack -l <path/to/repo>   Install a package from a local directory
       bashpack -t <path/to/repo>   Build and run that package's test suite
       bashpack -u <name>          Uninstall a previously installed package
       bashpack --list             List installed packages
       bashpack -v, --version      Show version
       bashpack -h, --help         Show this help

Configuration is read from a bashpack.json file in the repo root:

  {
    "name": "mytool",
    "bins": ["bin/mytool"],
    "outFolder": "dist",
    "test": "bats test",
    "completions": {
      "bash": "completions/mytool",
      "zsh": "completions/_mytool"
    }
  }

"name" and "bins" are required. "completions" and "test" are optional.
"outFolder" defaults to "dist" — the declared bins/completions are built into
<repo>/<outFolder>, preserving their relative paths, so you can inspect
exactly what gets packaged.

-t builds that same dist and then runs the "test" command from the repo root
with BASHPACK_DIST set to the dist path. A suite that honours BASHPACK_DIST
therefore tests the packed output instead of the source tree:

  : "\${MYTOOL_ROOT:=\${BASHPACK_DIST:-\$BATS_TEST_DIRNAME/..}}"

Run bare (bats test) it still tests the source; run via bashpack -t it tests
what would actually ship. Tests themselves are never copied into the dist.

Libs are not declared in bashpack.json — if the repo has a package.sh
(basher's manifest format), its LIBS=(...) array is read automatically and
those files are included in the build too, so the list isn't duplicated in
two places.

That dist folder is then copied into \$BASHPACK_HOME/cellar/<name> (default:
~/.bashpack) and its bins/completions symlinked into \$BASHPACK_HOME/bin.
Add that directory to your PATH to run installed commands.

Requires jq.

Remote installs (bashpack user/repo) are not supported yet — local only.
EOF
}

bashpack_die() {
  [[ -z "${BASHPACK_QUIET:-}" ]] && echo "bashpack: $*" >&2
  exit 1
}

bashpack_warn() {
  [[ -z "${BASHPACK_QUIET:-}" ]] && echo "bashpack: $*" >&2
}

bashpack_version() {
  local ver="dev"
  [[ -f "$BASHPACK_ROOT/VERSION" ]] && ver="$(<"$BASHPACK_ROOT/VERSION")"
  echo "bashpack v${ver#v}"
}

bashpack_require_jq() {
  command -v jq &>/dev/null || bashpack_die "jq is required but not installed (see your package manager)"
}

bashpack_home() {
  echo "${BASHPACK_HOME:-$HOME/.bashpack}"
}

bashpack_read_package_sh_libs() {
  local src="$1"
  local pkgsh="$src/package.sh"
  [[ -f "$pkgsh" ]] || return 0

  (
    LIBS=()
    # shellcheck disable=SC1090
    source "$pkgsh"
    printf '%s\n' "${LIBS[@]}"
  )
}

bashpack_read_package_sh_deps() {
  local src="$1"
  local pkgsh="$src/package.sh"
  [[ -f "$pkgsh" ]] || return 0

  (
    DEPS=""
    # shellcheck disable=SC1090
    source "$pkgsh"
    echo "$DEPS"
  )
}

# Resolves a dependency to a directory on disk, setting BP_DEP_DIR.
#
# A local path (/foo, ./foo, ../foo, ~/foo) is used in place, as-is — handy for
# developing against a checkout you're editing. A bare user/repo always uses the
# downloaded copy, fetched into a shared cache under $BASHPACK_HOME/vendor and
# reused on later builds.
bashpack_vendor_dep() {
  local dep="$1"
  local dir

  case "$dep" in
  /* | ./* | ../* | '~/'*)
    dir="${dep/#\~/$HOME}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || bashpack_die "local dep not found: $dep"
    BP_DEP_DIR="$dir"
    return 0
    ;;
  esac

  local cache
  cache="$(bashpack_home)/vendor"
  dir="$cache/${dep##*/}"

  if [[ ! -d "$dir" ]]; then
    command -v git &>/dev/null || bashpack_die "git is required to fetch $dep"
    echo "fetching $dep"
    mkdir -p "$cache"
    rm -rf "$dir"
    git clone --depth 1 --quiet "https://github.com/$dep.git" "$dir" ||
      bashpack_die "failed to fetch $dep from github.com/$dep"
  fi

  BP_DEP_DIR="$dir"
}

bashpack_build_dist() {
  local src="$1" manifest="$2" name="$3" out="$4"
  shift 4
  local files=("$@")

  local dist="$src/$out"
  rm -rf "$dist"
  mkdir -p "$dist"

  local f
  for f in "${files[@]}"; do
    mkdir -p "$dist/$(dirname "$f")"
    cp -a "$src/$f" "$dist/$f"
  done

  cp -a "$manifest" "$dist/bashpack.json"

  # TODO: hardcoded for now — should come from the manifest, and the runner
  # (package.sh DEPS) should be fetched and vendored alongside it.
  [[ -d "$src/test" ]] && cp -a "$src/test" "$dist/test"

  echo "$dist"
}

# Validates the manifest and builds <repo>/<outFolder>. Results are left in the
# BP_* globals so both install and test can work off the same build.
bashpack_pack() {
  local src="$1"

  src="$(cd "$src" 2>/dev/null && pwd)" || bashpack_die "no such directory: $1"

  local manifest="$src/bashpack.json"
  [[ -f "$manifest" ]] || bashpack_die "no bashpack.json found in $src"

  jq empty "$manifest" 2>/dev/null || bashpack_die "invalid JSON in $manifest"

  local name
  name="$(jq -r '.name // empty' "$manifest")"
  [[ -n "$name" ]] || bashpack_die "bashpack.json missing required \"name\" field"

  local bins=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && bins+=("$line")
  done < <(jq -r '.bins // [] | .[]' "$manifest")

  [[ ${#bins[@]} -gt 0 ]] || bashpack_die "bashpack.json for \"$name\" declares no bins"

  local b
  for b in "${bins[@]}"; do
    [[ -f "$src/$b" ]] || bashpack_die "declared bin not found: $b"
  done

  local libs=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && libs+=("$line")
  done < <(bashpack_read_package_sh_libs "$src")

  for b in "${libs[@]}"; do
    [[ -f "$src/$b" ]] || bashpack_die "lib declared in package.sh not found: $b"
  done

  local completion_bash completion_zsh
  completion_bash="$(jq -r '.completions.bash // empty' "$manifest")"
  completion_zsh="$(jq -r '.completions.zsh // empty' "$manifest")"

  if [[ -n "$completion_bash" && ! -f "$src/$completion_bash" ]]; then
    bashpack_warn "declared bash completion not found: $completion_bash"
    completion_bash=""
  fi
  if [[ -n "$completion_zsh" && ! -f "$src/$completion_zsh" ]]; then
    bashpack_warn "declared zsh completion not found: $completion_zsh"
    completion_zsh=""
  fi

  local out
  out="$(jq -r '.outFolder // "dist"' "$manifest")"

  case "$out" in
  "" | /* | *..*)
    bashpack_die "invalid \"outFolder\" path in bashpack.json: ${out:-<empty>}"
    ;;
  esac

  local dist_files=("${bins[@]}" "${libs[@]}")
  [[ -n "$completion_bash" ]] && dist_files+=("$completion_bash")
  [[ -n "$completion_zsh" ]] && dist_files+=("$completion_zsh")

  BP_SRC="$src"
  BP_MANIFEST="$manifest"
  BP_NAME="$name"
  BP_BINS=("${bins[@]}")
  BP_COMPLETION_BASH="$completion_bash"
  BP_COMPLETION_ZSH="$completion_zsh"
  BP_DIST="$(bashpack_build_dist "$src" "$manifest" "$name" "$out" "${dist_files[@]}")"

  # If the tests shipped, the runner has to ship with them or the dist can't
  # actually test itself. Runners come from package.sh DEPS.
  if [[ -d "$BP_DIST/test" ]]; then
    local dep depname
    for dep in $(bashpack_read_package_sh_deps "$src"); do
      bashpack_vendor_dep "$dep"
      depname="${dep##*/}"
      mkdir -p "$BP_DIST/vendor"
      rm -rf "$BP_DIST/vendor/$depname"
      cp -a "$BP_DEP_DIR" "$BP_DIST/vendor/$depname"
      rm -rf "$BP_DIST/vendor/$depname/.git"
    done
  fi

  echo "built $name -> $BP_DIST"
}

bashpack_install_local() {
  bashpack_pack "$1"

  local name="$BP_NAME"
  local bins=("${BP_BINS[@]}")
  local completion_bash="$BP_COMPLETION_BASH"
  local completion_zsh="$BP_COMPLETION_ZSH"
  local dist="$BP_DIST"
  local b

  local home
  home="$(bashpack_home)"
  mkdir -p "$home/cellar" "$home/bin" "$home/completions/bash" "$home/completions/zsh"

  rm -rf "$home/cellar/$name"
  mkdir -p "$home/cellar/$name"
  cp -a "$dist/." "$home/cellar/$name/"

  for b in "${bins[@]}"; do
    chmod +x "$home/cellar/$name/$b" 2>/dev/null || true
    ln -sfn "$home/cellar/$name/$b" "$home/bin/$(basename "$b")"
  done

  [[ -n "$completion_bash" ]] && ln -sfn "$home/cellar/$name/$completion_bash" "$home/completions/bash/$name"
  [[ -n "$completion_zsh" ]] && ln -sfn "$home/cellar/$name/$completion_zsh" "$home/completions/zsh/$name"

  echo "installed $name"
  for b in "${bins[@]}"; do
    echo "  bin: $(basename "$b") -> $home/bin/$(basename "$b")"
  done
  [[ -n "$completion_bash" ]] && echo "  bash completion -> $home/completions/bash/$name"
  [[ -n "$completion_zsh" ]] && echo "  zsh completion -> $home/completions/zsh/$name"
}

# Runs the package's own test suite against the built dist rather than against
# the source tree, so what gets tested is what gets shipped. The suite is told
# where to look via BASHPACK_DIST.
bashpack_test() {
  bashpack_pack "$1"

  local cmd
  cmd="$(jq -r '.test // empty' "$BP_MANIFEST")"
  [[ -n "$cmd" ]] || bashpack_die "bashpack.json for \"$BP_NAME\" declares no \"test\" command"

  local runner="${cmd%% *}"
  if ! command -v "$runner" &>/dev/null; then
    local deps
    deps="$(bashpack_read_package_sh_deps "$BP_SRC")"
    bashpack_die "test runner not found on PATH: $runner${deps:+ (package.sh declares DEPS: $deps)}"
  fi

  echo "testing $BP_NAME against $BP_DIST"
  (
    cd "$BP_SRC" || exit 1
    BASHPACK_DIST="$BP_DIST" bash -c "$cmd"
  )
}

bashpack_uninstall() {
  local name="$1"
  local home
  home="$(bashpack_home)"

  [[ -e "$home/cellar/$name" ]] || bashpack_die "not installed: $name"

  local f target
  for f in "$home"/bin/*; do
    [[ -L "$f" ]] || continue
    target="$(readlink -f "$f" 2>/dev/null)" || continue
    [[ "$target" == "$home/cellar/$name/"* ]] && rm -f "$f"
  done

  rm -f "$home/completions/bash/$name" "$home/completions/zsh/$name"
  rm -rf "$home/cellar/$name"

  echo "uninstalled $name"
}

bashpack_list() {
  local home
  home="$(bashpack_home)"
  [[ -d "$home/cellar" ]] || return 0

  local d
  for d in "$home"/cellar/*; do
    [[ -e "$d" ]] || continue
    echo "$(basename "$d") -> $(readlink -f "$d")"
  done
}

bashpack_main() {
  local action="" arg=""
  BASHPACK_QUIET=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      bashpack_usage
      exit 0
      ;;
    -v | --version)
      bashpack_version
      exit 0
      ;;
    -l | --local)
      shift
      [[ $# -gt 0 ]] || bashpack_die "-l requires a path"
      action="install"
      arg="$1"
      shift
      ;;
    -test | -t | --test)
      shift
      [[ $# -gt 0 ]] || bashpack_die "-t requires a path"
      action="test"
      arg="$1"
      shift
      ;;
    -u | --uninstall)
      shift
      [[ $# -gt 0 ]] || bashpack_die "-u requires a package name"
      action="uninstall"
      arg="$1"
      shift
      ;;
    --list)
      action="list"
      shift
      ;;
    -q | --quiet)
      BASHPACK_QUIET=1
      shift
      ;;
    *)
      bashpack_die "unsupported argument: $1 (only local installs via -l are supported right now)"
      ;;
    esac
  done

  case "$action" in
  install)
    bashpack_require_jq
    bashpack_install_local "$arg"
    ;;
  test)
    bashpack_require_jq
    bashpack_test "$arg"
    ;;
  uninstall)
    bashpack_uninstall "$arg"
    ;;
  list)
    bashpack_list
    ;;
  *)
    bashpack_usage >&2
    exit 1
    ;;
  esac
}
