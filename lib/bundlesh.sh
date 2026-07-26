bundlesh_usage() {
  cat <<EOF
Usage: bundlesh -l <path/to/repo>   Install a package from a local directory
       bundlesh -t <path/to/repo>   Build and run that package's test suite
       bundlesh --single-bundle <path/to/repo>
                                    Build, and also emit a single runnable .sh
       bundlesh -u <name>          Uninstall a previously installed package
       bundlesh --list             List installed packages
       bundlesh -v, --version      Show version
       bundlesh -h, --help         Show this help

Configuration is read from a bundlesh.json file in the repo root:

  {
    "name": "mytool",
    "bins": ["bin/mytool"],
    "outFolder": "dist",
    "test": "bats test",
    "completions": {
      "bash": "completions/mytool",
      "zsh": "completions/_mytool"
    },
    "binaries": ["/usr/bin/jq"],
    "devdeps": ["lib/helpers.sh"]
  }

"name" and "bins" are required. "completions", "test", "binaries", and "devdeps" are optional.
"outFolder" defaults to "dist" — the declared bins/completions are built into
<repo>/<outFolder>, preserving their relative paths, so you can inspect
exactly what gets packaged.

-t builds that same dist and then runs the "test" command from the repo root
with BUNDLESH_DIST set to the dist path. A suite that honours BUNDLESH_DIST
therefore tests the packed output instead of the source tree:

  : "\${MYTOOL_ROOT:=\${BUNDLESH_DIST:-\$BATS_TEST_DIRNAME/..}}"

Run bare (bats test) it still tests the source; run via bundlesh -t it tests
what would actually ship.

--single-bundle additionally inlines every lib and the first bin into a single
runnable <outFolder>/<name>.sh with no archive and no extraction step, so it
costs nothing at runtime. It can only carry bash — completions and vendored
test runners still ship as separate files in the dist.

If "binaries" are declared, they are base64-encoded and embedded into the
single bundle. At startup they are decoded into a temp directory and added to
PATH, so the bundled tool can invoke them as normal commands.

If "devdeps" are declared, any lib from package.sh matching one of those paths
is excluded from the dist and from the single-bundle — useful for test helpers
and other files that should not ship.

Libs are not declared in bundlesh.json — if the repo has a package.sh
(basher's manifest format), its LIBS=(...) array is read automatically and
those files are included in the build too, so the list isn't duplicated in
two places.

That dist folder is then copied into \$BUNDLESH_HOME/cellar/<name> (default:
~/.bundlesh) and its bins/completions symlinked into \$BUNDLESH_HOME/bin.
Add that directory to your PATH to run installed commands.

Requires jq and base64.

Remote installs (bundlesh user/repo) are not supported yet — local only.
EOF
}

bundlesh_die() {
  [[ -z "${BUNDLESH_QUIET:-}" ]] && echo "bundlesh: $*" >&2
  exit 1
}

bundlesh_warn() {
  [[ -z "${BUNDLESH_QUIET:-}" ]] && echo "bundlesh: $*" >&2
}

bundlesh_version() {
  local ver="dev"
  [[ -f "$BUNDLESH_ROOT/VERSION" ]] && ver="$(<"$BUNDLESH_ROOT/VERSION")"
  echo "bundlesh v${ver#v}"
}

bundlesh_require_jq() {
  command -v jq &>/dev/null || bundlesh_die "jq is required but not installed (see your package manager)"
}

bundlesh_home() {
  echo "${BUNDLESH_HOME:-$HOME/.bundlesh}"
}

bundlesh_read_package_sh_libs() {
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

bundlesh_read_package_sh_deps() {
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

# Resolves a dependency to a directory on disk, setting BS_DEP_DIR.
#
# A local path (/foo, ./foo, ../foo, ~/foo) is used in place, as-is — handy for
# developing against a checkout you're editing. A bare user/repo always uses the
# downloaded copy, fetched into a shared cache under $BUNDLESH_HOME/vendor and
# reused on later builds.
bundlesh_vendor_dep() {
  local dep="$1"
  local dir

  case "$dep" in
  /* | ./* | ../* | '~/'*)
    dir="${dep/#\~/$HOME}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || bundlesh_die "local dep not found: $dep"
    BS_DEP_DIR="$dir"
    return 0
    ;;
  esac

  local cache
  cache="$(bundlesh_home)/vendor"
  dir="$cache/${dep##*/}"

  if [[ ! -d "$dir" ]]; then
    command -v git &>/dev/null || bundlesh_die "git is required to fetch $dep"
    echo "fetching $dep"
    mkdir -p "$cache"
    rm -rf "$dir"
    git clone --depth 1 --quiet "https://github.com/$dep.git" "$dir" ||
      bundlesh_die "failed to fetch $dep from github.com/$dep"
  fi

  BS_DEP_DIR="$dir"
}

# Drops `source`/`.` lines, and any for-loop that exists only to source a glob
# of files, since everything they would have pulled in is inlined already.
bundlesh_strip_sources() {
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

# Concatenates every lib and the bin into one runnable file. If BS_BINARIES is
# set, each binary is base64-encoded and embedded with a preamble that decodes
# them into a temp directory and adds them to PATH at startup.
bundlesh_build_bundle() {
  local src="$1" dist="$2" name="$3" bin="$4"
  shift 4
  local libs=("$@")

  local out="$dist/$name.sh"
  local var
  var="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')_ROOT"

  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'

    if [[ ${#BS_BINARIES[@]} -gt 0 ]]; then
      echo
      echo '# --- embedded binaries ---'
      echo '__bs_bin_dir=""'
      echo '__bs_cleanup() { [[ -n "$__bs_bin_dir" ]] && rm -rf "$__bs_bin_dir"; }'
      echo '__bs_decode() {'
      echo '  local n="$1" d="$2"'
      echo '  __bs_bin_dir="${__bs_bin_dir:-$(mktemp -d)}"'
      echo '  echo "$d" | base64 -d > "$__bs_bin_dir/$n"'
      echo '  chmod +x "$__bs_bin_dir/$n"'
      echo '}'
      local bpath bname encoded
      for bpath in "${BS_BINARIES[@]}"; do
        bname="$(basename "$bpath")"
        encoded="$(base64 "$bpath" | tr -d '\n')"
        echo "__bs_decode '$bname' '$encoded'"
      done
      echo 'trap __bs_cleanup EXIT TERM INT'
      echo 'PATH="$__bs_bin_dir:$PATH"'
      echo '# --- end embedded binaries ---'
    fi

    echo "$var=\"\$(cd \"\$(dirname \"\$(readlink -f \"\$0\")\")\" && pwd)\""

    local f
    for f in "${libs[@]}" "$bin"; do
      echo
      echo "# --- $f ---"
      bundlesh_strip_sources "$src/$f"
    done
  } >"$out"

  chmod +x "$out"
  echo "$out"
}

bundlesh_build_dist() {
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

  cp -a "$manifest" "$dist/bundlesh.json"

  # TODO: hardcoded for now — should come from the manifest, and the runner
  # (package.sh DEPS) should be fetched and vendored alongside it.
  [[ -d "$src/test" ]] && cp -a "$src/test" "$dist/test"

  echo "$dist"
}

# Validates the manifest and builds <repo>/<outFolder>. Results are left in the
# PS_* globals so both install and test can work off the same build.
bundlesh_pack() {
  local src="$1"

  src="$(cd "$src" 2>/dev/null && pwd)" || bundlesh_die "no such directory: $1"

  local manifest="$src/bundlesh.json"
  [[ -f "$manifest" ]] || bundlesh_die "no bundlesh.json found in $src"

  jq empty "$manifest" 2>/dev/null || bundlesh_die "invalid JSON in $manifest"

  local name
  name="$(jq -r '.name // empty' "$manifest")"
  [[ -n "$name" ]] || bundlesh_die "bundlesh.json missing required \"name\" field"

  local bins=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && bins+=("$line")
  done < <(jq -r '.bins // [] | .[]' "$manifest")

  [[ ${#bins[@]} -gt 0 ]] || bundlesh_die "bundlesh.json for \"$name\" declares no bins"

  local b
  for b in "${bins[@]}"; do
    [[ -f "$src/$b" ]] || bundlesh_die "declared bin not found: $b"
  done

  local libs=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && libs+=("$line")
  done < <(bundlesh_read_package_sh_libs "$src")

  for b in "${libs[@]}"; do
    [[ -f "$src/$b" ]] || bundlesh_die "lib declared in package.sh not found: $b"
  done

  local devdeps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && devdeps+=("$line")
  done < <(jq -r '.devdeps // [] | .[]' "$manifest")

  if [[ ${#devdeps[@]} -gt 0 ]]; then
    local filtered_libs=()
    local lib dep
    for lib in "${libs[@]}"; do
      local skip=0
      for dep in "${devdeps[@]}"; do
        [[ "$lib" == "$dep" ]] && { skip=1; break; }
      done
      [[ $skip -eq 0 ]] && filtered_libs+=("$lib")
    done
    libs=("${filtered_libs[@]}")
  fi

  local completion_bash completion_zsh
  completion_bash="$(jq -r '.completions.bash // empty' "$manifest")"
  completion_zsh="$(jq -r '.completions.zsh // empty' "$manifest")"

  if [[ -n "$completion_bash" && ! -f "$src/$completion_bash" ]]; then
    bundlesh_warn "declared bash completion not found: $completion_bash"
    completion_bash=""
  fi
  if [[ -n "$completion_zsh" && ! -f "$src/$completion_zsh" ]]; then
    bundlesh_warn "declared zsh completion not found: $completion_zsh"
    completion_zsh=""
  fi

  local binaries_raw=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && binaries_raw+=("$line")
  done < <(jq -r '.binaries // [] | .[]' "$manifest")

  local binaries=()
  local bp
  for bp in "${binaries_raw[@]}"; do
    case "$bp" in
    /*)
      [[ -f "$bp" ]] || bundlesh_die "declared binary not found: $bp"
      binaries+=("$bp")
      ;;
    *)
      [[ -f "$src/$bp" ]] || bundlesh_die "declared binary not found: $src/$bp"
      binaries+=("$src/$bp")
      ;;
    esac
  done

  local out
  out="$(jq -r '.outFolder // "dist"' "$manifest")"

  case "$out" in
  "" | /* | *..*)
    bundlesh_die "invalid \"outFolder\" path in bundlesh.json: ${out:-<empty>}"
    ;;
  esac

  local dist_files=("${bins[@]}" "${libs[@]}")
  [[ -n "$completion_bash" ]] && dist_files+=("$completion_bash")
  [[ -n "$completion_zsh" ]] && dist_files+=("$completion_zsh")

  BS_SRC="$src"
  BS_MANIFEST="$manifest"
  BS_NAME="$name"
  BS_BINS=("${bins[@]}")
  BS_BINARIES=("${binaries[@]}")
  BS_COMPLETION_BASH="$completion_bash"
  BS_COMPLETION_ZSH="$completion_zsh"
  BS_DIST="$(bundlesh_build_dist "$src" "$manifest" "$name" "$out" "${dist_files[@]}")"

  # If the tests shipped, the runner has to ship with them or the dist can't
  # actually test itself. Runners come from package.sh DEPS.
  if [[ -d "$BS_DIST/test" ]]; then
    local dep depname
    for dep in $(bundlesh_read_package_sh_deps "$src"); do
      bundlesh_vendor_dep "$dep"
      depname="${dep##*/}"
      mkdir -p "$BS_DIST/vendor"
      rm -rf "$BS_DIST/vendor/$depname"
      cp -a "$BS_DEP_DIR" "$BS_DIST/vendor/$depname"
      rm -rf "$BS_DIST/vendor/$depname/.git"
    done
  fi

  echo "built $name -> $BS_DIST"

  if [[ -n "${BS_BUNDLE:-}" ]]; then
    local bundle
    bundle="$(bundlesh_build_bundle "$src" "$BS_DIST" "$name" "${bins[0]}" "${libs[@]}")"
    [[ ${#bins[@]} -gt 1 ]] && bundlesh_warn "--single-bundle used ${bins[0]}; other bins were not bundled"
    echo "bundled $name -> $bundle"
  fi

  if [[ ${#binaries[@]} -gt 0 ]]; then
    local b
    for b in "${binaries[@]}"; do
      echo "  binary: $(basename "$b")"
    done
  fi
}

bundlesh_install_local() {
  bundlesh_pack "$1"

  local name="$BS_NAME"
  local bins=("${BS_BINS[@]}")
  local completion_bash="$BS_COMPLETION_BASH"
  local completion_zsh="$BS_COMPLETION_ZSH"
  local dist="$BS_DIST"
  local b

  local home
  home="$(bundlesh_home)"
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
# where to look via BUNDLESH_DIST.
bundlesh_test() {
  bundlesh_pack "$1"

  local cmd
  cmd="$(jq -r '.test // empty' "$BS_MANIFEST")"
  [[ -n "$cmd" ]] || bundlesh_die "bundlesh.json for \"$BS_NAME\" declares no \"test\" command"

  local runner="${cmd%% *}"
  if ! command -v "$runner" &>/dev/null; then
    local deps
    deps="$(bundlesh_read_package_sh_deps "$BS_SRC")"
    bundlesh_die "test runner not found on PATH: $runner${deps:+ (package.sh declares DEPS: $deps)}"
  fi

  echo "testing $BS_NAME against $BS_DIST"
  (
    cd "$BS_SRC" || exit 1
    BUNDLESH_DIST="$BS_DIST" bash -c "$cmd"
  )
}

bundlesh_uninstall() {
  local name="$1"
  local home
  home="$(bundlesh_home)"

  [[ -e "$home/cellar/$name" ]] || bundlesh_die "not installed: $name"

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

bundlesh_list() {
  local home
  home="$(bundlesh_home)"
  [[ -d "$home/cellar" ]] || return 0

  local d
  for d in "$home"/cellar/*; do
    [[ -e "$d" ]] || continue
    echo "$(basename "$d") -> $(readlink -f "$d")"
  done
}

bundlesh_main() {
  local action="" arg=""
  BUNDLESH_QUIET=""
  BS_BUNDLE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      bundlesh_usage
      exit 0
      ;;
    -v | --version)
      bundlesh_version
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
      BS_BUNDLE=1
      shift
      ;;
    -q | --quiet)
      BUNDLESH_QUIET=1
      shift
      ;;
    *)
      if [[ -z "$arg" ]] && [[ -n "$action" || -n "$BS_BUNDLE" ]]; then
        arg="$1"
        shift
      else
        bundlesh_die "unsupported argument: $1 (only local installs via -l are supported right now)"
      fi
      ;;
    esac
  done

  # --single-bundle on its own just builds
  [[ -z "$action" && -n "$BS_BUNDLE" && -n "$arg" ]] && action="build"

  case "$action" in
  install | test | build)
    [[ -n "$arg" ]] || bundlesh_die "$action requires a path"
    ;;
  uninstall)
    [[ -n "$arg" ]] || bundlesh_die "-u requires a package name"
    ;;
  esac

  case "$action" in
  install)
    bundlesh_require_jq
    bundlesh_install_local "$arg"
    ;;
  build)
    bundlesh_require_jq
    bundlesh_pack "$arg"
    ;;
  test)
    bundlesh_require_jq
    bundlesh_test "$arg"
    ;;
  uninstall)
    bundlesh_uninstall "$arg"
    ;;
  list)
    bundlesh_list
    ;;
  *)
    bundlesh_usage >&2
    exit 1
    ;;
  esac
}
