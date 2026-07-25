# bashpack

A packer for bash tools. Point it at a local repo with a `bashpack.json` and it
builds an inspectable **dist folder** containing exactly what would ship — then
installs that, bundles it into a single `.sh`, or runs the package's tests
against it.

The dist is the point. Like webpack, you set an `outFolder` and can look at the
build output before anything gets installed anywhere.

```bash
bashpack --single-bundle -l .
built bashumerate -> /home/jirka/bashumerate/dist
bundled bashumerate -> /home/jirka/bashumerate/dist/bashumerate.sh
installed bashumerate
  bin: enumerate -> /home/jirka/.bashpack/bin/enumerate
```

## Usage

```bash
bashpack -l <path/to/repo>              # build, then install
bashpack -test <path/to/repo>           # build, then run the package's tests against it
bashpack --single-bundle <path/to/repo> # build, and emit one runnable .sh
bashpack -u <name>                      # uninstall
bashpack --list                         # list installed packages
bashpack -v | -h                        # version / help
```

Flags can appear in any order, and `--single-bundle` combines with the others:
`bashpack -l --single-bundle .` and `bashpack --single-bundle -l .` are the same
thing.

Remote installs (`bashpack user/repo`) are **not supported** — local only.

## Manifest

```json
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
```

| field | required | meaning |
|---|---|---|
| `name` | yes | package name; names the cellar entry and the bundle |
| `bins` | yes | executables to build and link onto `PATH` |
| `outFolder` | no | where the build lands, relative to the repo (default `dist`) |
| `test` | no | command run by `-test` |
| `completions` | no | `bash` and/or `zsh` completion files |

### Libs and test deps come from `package.sh`

They are **not** declared in `bashpack.json`, so the same list never lives in two
places. If the repo has a `package.sh` (basher's manifest format), bashpack reads
it:

```bash
LIBS=(lib/mytool.sh lib/helpers.sh)   # -> included in the build
DEPS='bats-core/bats-core'            # -> test runner, fetched and vendored
```

## What the build contains

Only what's declared — bins, `LIBS`, completions, plus a copy of the manifest —
with relative paths preserved:

```
dist/
├── bashpack.json
├── bin/enumerate
├── lib/enumerate.sh
├── lib/enumerators/{files,lines,range,list}.sh
├── completions/{enumerate,_enumerate}
├── test/                    # if the repo has tests
└── vendor/bats-core/        # the test runner, so the dist can test itself
```

## Install layout

The dist is **copied** into `$BASHPACK_HOME/cellar/<name>` (default
`~/.bashpack`), and bins and completions are symlinked out into
`$BASHPACK_HOME/bin` and `$BASHPACK_HOME/completions/`. Add `~/.bashpack/bin` to
your `PATH`.

Copied, not symlinked, deliberately: an installed package keeps working after
the source repo is edited, moved or deleted. It's a snapshot, not a live view.

`-u <name>` removes the bin and completion symlinks and the cellar copy. It
never touches the original source.

## Testing what actually ships

`-test` builds the dist and runs the manifest's `test` command from the repo
root with `BASHPACK_DIST` pointing at the build. A suite that honours it tests
the packed output rather than the source tree:

```bash
setup() {
  : "${MYTOOL_ROOT:=${BASHPACK_DIST:-$BATS_TEST_DIRNAME/..}}"
  MYTOOL="$MYTOOL_ROOT/bin/mytool"
}
```

Run bare (`bats test`) it still tests the source; run through bashpack it tests
what would ship. That difference finds real bugs — a test reading a build-time
file like `package.sh` passes against a checkout and fails against the dist,
because that file was never meant to ship.

Test runners named `user/repo` in `DEPS` are cloned from GitHub into a shared
cache at `$BASHPACK_HOME/vendor` (once, then reused) and shipped inside the
dist, so the built package can test itself with no runner installed on the
system. A `DEPS` entry that is a local path (`/x`, `./x`, `../x`, `~/x`) is used
in place instead of being downloaded.

## Single-file bundles

`--single-bundle` inlines every lib and the first declared bin into one runnable
`<outFolder>/<name>.sh`. There is no archive and no extraction step, so it costs
nothing at runtime — measured on bashumerate:

| output | size | per run |
|---|---|---|
| single bundle `.sh` | 12K | **5.0 ms** |
| dist folder | 2.0M | 5.0 ms |
| self-extracting archive (lean) | 4.4K | 12.8 ms |
| self-extracting archive (with tests + runner) | 185K | 19.0 ms |

It can only carry bash. Completions and vendored test runners still ship as
separate files in the dist alongside it.

To build it, bashpack strips what inlining makes redundant: shebangs, `*_ROOT`
assignments (the bundle defines its own, pointing at itself), `source` lines,
and any `for` loop that exists only to source a glob of files.

## Dependencies

bashpack requires [`jq`](https://jqlang.org/) to parse `bashpack.json`, and
`git` to fetch `DEPS`. Both are system prerequisites, like basher requiring
`git` — bashpack does not manage them.

**Note:** a pure-bash JSON parser (dropping the jq dependency) is a possible
future improvement. [bash-jsonvar](https://github.com/bahamas10/bash-jsonvar)
was evaluated for this and doesn't help — it only serializes bash → JSON, not
the JSON → bash direction needed here.

## Test

```bash
basher install bats-core/bats-core
bats test/
```

## License

MIT
