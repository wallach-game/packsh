# bashpack

A small package installer for bash tools. Point it at a local repo containing
a `bashpack.json` manifest and it symlinks the declared bins (and completions)
into place.

## Usage

```bash
bashpack -l <path/to/repo>   # install a package from a local directory
bashpack -u <name>           # uninstall a previously installed package
bashpack --list              # list installed packages
bashpack -v, --version       # show version
bashpack -h, --help          # show help
```

Remote installs (`bashpack user/repo`, cloning from GitHub) are not supported
yet — local installs only, for now.

## Manifest

A package repo declares itself with a `bashpack.json` file in its root:

```json
{
  "name": "mytool",
  "bins": ["bin/mytool"],
  "completions": {
    "bash": "completions/mytool",
    "zsh": "completions/_mytool"
  }
}
```

- `name` and `bins` are required.
- `completions` is optional (`bash` and/or `zsh` keys).

## Install layout

Installed bins are symlinked into `$BASHPACK_HOME/bin` (default:
`~/.bashpack/bin`). Add that directory to your `PATH` to run installed
commands. The source repo itself is symlinked into
`$BASHPACK_HOME/cellar/<name>` rather than copied, so local installs stay in
sync with the source directory.

Note that the *entire* source repo gets symlinked into the cellar entry, not
just the files listed in `bashpack.json` — only `bins` and `completions` get
a second symlink out into `bin/`/`completions/`. Anything else in the repo
(tests, fixtures, docs, `.git`, etc.) rides along inertly in the cellar entry
but is never linked anywhere a user of the installed command would see it.
There's no manifest-driven pruning of what gets included in the cellar entry
— that would be a separate feature if it's ever needed.

Uninstalling (`-u <name>`) removes the bin symlinks, completion symlinks, and
the cellar symlink itself — it never touches the original source directory.

## Dependencies

bashpack currently requires [`jq`](https://jqlang.org/) to parse
`bashpack.json`. This is a system prerequisite (like basher requiring `git`),
not something bashpack manages itself.

**Note:** a pure-bash JSON parser (avoiding the jq dependency entirely) is a
possible future improvement — evaluated
[bash-jsonvar](https://github.com/bahamas10/bash-jsonvar) for this, but it
only serializes bash → JSON, not the JSON → bash direction bashpack needs, so
it doesn't help here. Revisit this later if dropping the jq dependency
becomes worthwhile.

## Test

```bash
basher install bats-core/bats-core
bats test/
```

## License

MIT
