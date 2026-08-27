# CLAUDE.md

## Versioning

Bump the version **in the same commit as the work it describes**, not in a separate
"bump version" commit. The version is part of the change, not bookkeeping that
follows it.

Two keys, both in `bundle/Info.plist`:

- `CFBundleShortVersionString` — the semver string users see (currently `0.3.0`)
- `CFBundleVersion` — an opaque build counter; increment by 1 on every bump

Judge the element from what changes **for someone using the app**, not from how much
code moved:

| Element | Bump when the commit… | Examples from this repo |
|---|---|---|
| **patch** `0.2.0` → `0.2.1` | fixes a bug, improves performance, or changes only internals | the transcript-concatenation fix; the engine rebuild loop; comment rewrites that ship a rebuilt binary |
| **minor** `0.2.0` → `0.3.0` | adds a capability, or deliberately changes what the app shows or does | the app icon; the menu-bar glyph change; a new setting or a second hotkey |
| **major** `0.2.0` → `1.0.0` | takes something away or breaks a habit or a stored setting | moving off F11; a settings format existing installs cannot read |

While the major version is `0`, a breaking change bumps the **minor** and the major
stays at `0` — that is standard pre-1.0 semver, and `1.0.0` is a deliberate "this is
stable" decision, never an accident of accumulation.

**Do not bump** for changes that cannot reach a user: README and comment edits,
`scripts/` and tooling work, tests, or anything under `third_party/`. `make-dmg.sh`
gaining a flag is not a release of Yap.

When one commit spans categories, take the highest element that applies — a commit
that adds a feature and fixes two bugs is a minor bump, not three commits' worth.

A bump renames the release artifact (`dist/Yap-<version>.dmg`), so any already-built
DMG has to be rebuilt and re-notarized before publishing. Notarization is a ~1 GB
upload; batch related work into one bump rather than bumping per commit in a series
that ships together.

## Finishing a change

Building is not testing. When the work is done, relaunch the real app:

```sh
scripts/dev-run.sh
```

It builds, bundles, signs with the Developer ID identity, kills the running copy,
and reopens `~/Applications/Yap.app`, printing the pid it comes back on. Yap is an
`LSUIElement` app with no window, so "it launched" is not what `open` returns — it
is the process still being alive a few seconds later, after the ASR and normalizer
models have loaded off disk:

```sh
sleep 5 && pgrep -x yap
```

A crash on load looks exactly like a successful launch until that check comes back
empty. If it does, or the menu-bar glyph never appears, read the log before touching
anything else:

```sh
log stream --predicate 'process == "yap"' --style compact
```

**If the app comes back up and stays up, commit the work** — no need to ask first.
The version bump belongs in that same commit (see above). If it crashed, fix the
crash and relaunch until it holds; a commit that does not launch is worse than an
uncommitted one, because the next session inherits it as the working baseline.
