packsh_usage() {
  cat <<EOF
Usage: packsh -l <path/to/repo>   Install a package from a local directory
       packsh -t <path/to/repo>   Build and run that package's test suite
       packsh --single-bundle <path/to/repo>
                                   Build, and also emit a single runnable .sh
       packsh -u <name>          Uninstall a previously installed package
       packsh --list             List installed packages
       packsh -v, --version      Show version
       packsh -h, --help         Show this help

Configuration is read from a packsh.json file in the repo root:

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
with PACKSH_DIST set to the dist path. A suite that honours PACKSH_DIST
therefore tests the packed output instead of the source tree:

  : "\${MYTOOL_ROOT:=\${PACKSH_DIST:-\$BATS_TEST_DIRNAME/..}}"

Run bare (bats test) it still tests the source; run via packsh -t it tests
what would actually ship.

--single-bundle additionally inlines every lib and the first bin into a single
runnable <outFolder>/<name>.sh with no archive and no extraction step, so it
costs nothing at runtime. It can only carry bash — completions and vendored
test runners still ship as separate files in the dist.

Libs are not declared in packsh.json — if the repo has a package.sh
(basher's manifest format), its LIBS=(...) array is read automatically and
those files are included in the build too, so the list isn't duplicated in
two places.

That dist folder is then copied into \$PACKSH_HOME/cellar/<name> (default:
~/.packsh) and its bins/completions symlinked into \$PACKSH_HOME/bin.
Add that directory to your PATH to run installed commands.

Requires jq.

Remote installs (packsh user/repo) are not supported yet — local only.
EOF
}

packsh_die() {
  [[ -z "${PACKSH_QUIET:-}" ]] && echo "packsh: $*" >&2
  exit 1
}

packsh_warn() {
  [[ -z "${PACKSH_QUIET:-}" ]] && echo "packsh: $*" >&2
}

packsh_version() {
  local ver="dev"
  [[ -f "$PACKSH_ROOT/VERSION" ]] && ver="$(<"$PACKSH_ROOT/VERSION")"
  echo "packsh v${ver#v}"
}

packsh_require_jq() {
  command -v jq &>/dev/null || packsh_die "jq is required but not installed (see your package manager)"
}

packsh_home() {
  echo "${PACKSH_HOME:-$HOME/.packsh}"
}

packsh_read_package_sh_libs() {
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

packsh_read_package_sh_deps() {
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

# Resolves a dependency to a directory on disk, setting PS_DEP_DIR.
#
# A local path (/foo, ./foo, ../foo, ~/foo) is used in place, as-is — handy for
# developing against a checkout you're editing. A bare user/repo always uses the
# downloaded copy, fetched into a shared cache under $PACKSH_HOME/vendor and
# reused on later builds.
packsh_vendor_dep() {
  local dep="$1"
  local dir

  case "$dep" in
  /* | ./* | ../* | '~/'*)
    dir="${dep/#\~/$HOME}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || packsh_die "local dep not found: $dep"
    PS_DEP_DIR="$dir"
    return 0
    ;;
  esac

  local cache
  cache="$(packsh_home)/vendor"
  dir="$cache/${dep##*/}"

  if [[ ! -d "$dir" ]]; then
    command -v git &>/dev/null || packsh_die "git is required to fetch $dep"
    echo "fetching $dep"
    mkdir -p "$cache"
    rm -rf "$dir"
    git clone --depth 1 --quiet "https://github.com/$dep.git" "$dir" ||
      packsh_die "failed to fetch $dep from github.com/$dep"
  fi

  PS_DEP_DIR="$dir"
}

# Drops `source`/`.` lines, and any for-loop that exists only to source a glob
# of files, since everything they would have pulled in is inlined already.
packsh_strip_sources() {
  awk '
    /^[[:space:]]*(source|\.)[[:space:]]/ { next }
    /^[[:space:]]*#!/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*_ROOT=/ { next }
    /^[[:space:]]*for[[:space:]]/ && !infor { infor = 1; buf = $0; had = 0; next }
    infor {
      buf = buf "\n" $0
      if ($0 ~ /^[[:space:]]*(source|\.)[[:space:]]/) had = 1
      if ($0 ~ /^[[:space:]]*done[[:space:]]*$/) {
        infor = 0
        if (!had) print buf
      }
      next
    }
    { print }
  ' "$1"
}

# Concatenates every lib and the bin into one runnable file. No archive and no
# extraction, so it costs nothing at runtime — but it can only carry bash, not
# completions or vendored trees.
packsh_build_bundle() {
  local src="$1" dist="$2" name="$3" bin="$4"
  shift 4
  local libs=("$@")

  local out="$dist/$name.sh"
  local var
  var="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')_ROOT"

  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "$var=\"\$(cd \"\$(dirname \"\$(readlink -f \"\$0\")\")\" && pwd)\""

    local f
    for f in "${libs[@]}" "$bin"; do
      echo
      echo "# --- $f ---"
      packsh_strip_sources "$src/$f"
    done
  } >"$out"

  chmod +x "$out"
  echo "$out"
}

packsh_build_dist() {
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

  cp -a "$manifest" "$dist/packsh.json"

  # TODO: hardcoded for now — should come from the manifest, and the runner
  # (package.sh DEPS) should be fetched and vendored alongside it.
  [[ -d "$src/test" ]] && cp -a "$src/test" "$dist/test"

  echo "$dist"
}

# Validates the manifest and builds <repo>/<outFolder>. Results are left in the
# PS_* globals so both install and test can work off the same build.
packsh_pack() {
  local src="$1"

  src="$(cd "$src" 2>/dev/null && pwd)" || packsh_die "no such directory: $1"

  local manifest="$src/packsh.json"
  [[ -f "$manifest" ]] || packsh_die "no packsh.json found in $src"

  jq empty "$manifest" 2>/dev/null || packsh_die "invalid JSON in $manifest"

  local name
  name="$(jq -r '.name // empty' "$manifest")"
  [[ -n "$name" ]] || packsh_die "packsh.json missing required \"name\" field"

  local bins=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && bins+=("$line")
  done < <(jq -r '.bins // [] | .[]' "$manifest")

  [[ ${#bins[@]} -gt 0 ]] || packsh_die "packsh.json for \"$name\" declares no bins"

  local b
  for b in "${bins[@]}"; do
    [[ -f "$src/$b" ]] || packsh_die "declared bin not found: $b"
  done

  local libs=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && libs+=("$line")
  done < <(packsh_read_package_sh_libs "$src")

  for b in "${libs[@]}"; do
    [[ -f "$src/$b" ]] || packsh_die "lib declared in package.sh not found: $b"
  done

  local completion_bash completion_zsh
  completion_bash="$(jq -r '.completions.bash // empty' "$manifest")"
  completion_zsh="$(jq -r '.completions.zsh // empty' "$manifest")"

  if [[ -n "$completion_bash" && ! -f "$src/$completion_bash" ]]; then
    packsh_warn "declared bash completion not found: $completion_bash"
    completion_bash=""
  fi
  if [[ -n "$completion_zsh" && ! -f "$src/$completion_zsh" ]]; then
    packsh_warn "declared zsh completion not found: $completion_zsh"
    completion_zsh=""
  fi

  local out
  out="$(jq -r '.outFolder // "dist"' "$manifest")"

  case "$out" in
  "" | /* | *..*)
    packsh_die "invalid \"outFolder\" path in packsh.json: ${out:-<empty>}"
    ;;
  esac

  local dist_files=("${bins[@]}" "${libs[@]}")
  [[ -n "$completion_bash" ]] && dist_files+=("$completion_bash")
  [[ -n "$completion_zsh" ]] && dist_files+=("$completion_zsh")

  PS_SRC="$src"
  PS_MANIFEST="$manifest"
  PS_NAME="$name"
  PS_BINS=("${bins[@]}")
  PS_COMPLETION_BASH="$completion_bash"
  PS_COMPLETION_ZSH="$completion_zsh"
  PS_DIST="$(packsh_build_dist "$src" "$manifest" "$name" "$out" "${dist_files[@]}")"

  # If the tests shipped, the runner has to ship with them or the dist can't
  # actually test itself. Runners come from package.sh DEPS.
  if [[ -d "$PS_DIST/test" ]]; then
    local dep depname
    for dep in $(packsh_read_package_sh_deps "$src"); do
      packsh_vendor_dep "$dep"
      depname="${dep##*/}"
      mkdir -p "$PS_DIST/vendor"
      rm -rf "$PS_DIST/vendor/$depname"
      cp -a "$PS_DEP_DIR" "$PS_DIST/vendor/$depname"
      rm -rf "$PS_DIST/vendor/$depname/.git"
    done
  fi

  echo "built $name -> $PS_DIST"

  if [[ -n "${PS_BUNDLE:-}" ]]; then
    local bundle
    bundle="$(packsh_build_bundle "$src" "$PS_DIST" "$name" "${bins[0]}" "${libs[@]}")"
    [[ ${#bins[@]} -gt 1 ]] && packsh_warn "--single-bundle used ${bins[0]}; other bins were not bundled"
    echo "bundled $name -> $bundle"
  fi
}

packsh_install_local() {
  packsh_pack "$1"

  local name="$PS_NAME"
  local bins=("${PS_BINS[@]}")
  local completion_bash="$PS_COMPLETION_BASH"
  local completion_zsh="$PS_COMPLETION_ZSH"
  local dist="$PS_DIST"
  local b

  local home
  home="$(packsh_home)"
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
# where to look via PACKSH_DIST.
packsh_test() {
  packsh_pack "$1"

  local cmd
  cmd="$(jq -r '.test // empty' "$PS_MANIFEST")"
  [[ -n "$cmd" ]] || packsh_die "packsh.json for \"$PS_NAME\" declares no \"test\" command"

  local runner="${cmd%% *}"
  if ! command -v "$runner" &>/dev/null; then
    local deps
    deps="$(packsh_read_package_sh_deps "$PS_SRC")"
    packsh_die "test runner not found on PATH: $runner${deps:+ (package.sh declares DEPS: $deps)}"
  fi

  echo "testing $PS_NAME against $PS_DIST"
  (
    cd "$PS_SRC" || exit 1
    PACKSH_DIST="$PS_DIST" bash -c "$cmd"
  )
}

packsh_uninstall() {
  local name="$1"
  local home
  home="$(packsh_home)"

  [[ -e "$home/cellar/$name" ]] || packsh_die "not installed: $name"

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

packsh_list() {
  local home
  home="$(packsh_home)"
  [[ -d "$home/cellar" ]] || return 0

  local d
  for d in "$home"/cellar/*; do
    [[ -e "$d" ]] || continue
    echo "$(basename "$d") -> $(readlink -f "$d")"
  done
}

packsh_main() {
  local action="" arg=""
  PACKSH_QUIET=""
  PS_BUNDLE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      packsh_usage
      exit 0
      ;;
    -v | --version)
      packsh_version
      exit 0
      ;;
    -l | --local)
      action="install"
      shift
      # only take a value here if it isn't another flag, so the operand can
      # just as well come later on the line
      [[ $# -gt 0 && "$1" != -* ]] && { arg="$1"; shift; }
      ;;
    -test | -t | --test)
      action="test"
      shift
      [[ $# -gt 0 && "$1" != -* ]] && { arg="$1"; shift; }
      ;;
    -u | --uninstall)
      action="uninstall"
      shift
      [[ $# -gt 0 && "$1" != -* ]] && { arg="$1"; shift; }
      ;;
    --list)
      action="list"
      shift
      ;;
    --single-bundle)
      PS_BUNDLE=1
      shift
      ;;
    -q | --quiet)
      PACKSH_QUIET=1
      shift
      ;;
    *)
      if [[ -z "$arg" ]] && [[ -n "$action" || -n "$PS_BUNDLE" ]]; then
        arg="$1"
        shift
      else
        packsh_die "unsupported argument: $1 (only local installs via -l are supported right now)"
      fi
      ;;
    esac
  done

  # --single-bundle on its own just builds
  [[ -z "$action" && -n "$PS_BUNDLE" && -n "$arg" ]] && action="build"

  case "$action" in
  install | test | build)
    [[ -n "$arg" ]] || packsh_die "$action requires a path"
    ;;
  uninstall)
    [[ -n "$arg" ]] || packsh_die "-u requires a package name"
    ;;
  esac

  case "$action" in
  install)
    packsh_require_jq
    packsh_install_local "$arg"
    ;;
  build)
    packsh_require_jq
    packsh_pack "$arg"
    ;;
  test)
    packsh_require_jq
    packsh_test "$arg"
    ;;
  uninstall)
    packsh_uninstall "$arg"
    ;;
  list)
    packsh_list
    ;;
  *)
    packsh_usage >&2
    exit 1
    ;;
  esac
}
