# yap

Push-to-talk dictation for macOS. Hold **F11**, speak, release — cleaned-up text is
inserted into whatever window has focus. Dictation is entirely on-device: audio and
transcripts never leave the Mac. The one network request Yap makes is a daily update
check against GitHub, and the menu turns it off.

Two models run warm in a single process:

- **Parakeet TDT 0.6B v3** transcribes the audio (cased and punctuated natively).
- **S1-mini by Superwhisper** normalizes the transcript — removes fillers, resolves
  false starts to what you actually landed on, and writes out spoken numbers, dates,
  and email addresses.

## Measured latency (M1 Max)

Post-release, warm, steady state:

| utterance | total |
|---|---|
| ~2 s | ~150 ms |
| ~5 s | ~195 ms |
| ~11 s | ~285 ms |
| ~30 s | ~740 ms |

Generation cost tracks *output* length, so short commands are the fast case.

## Build

```sh
./scripts/setup-deps.sh      # clone llama.cpp + whisper.cpp at pinned SHAs
./scripts/fetch-models.sh    # ~1.1 GB of model weights
cmake -B build -G Ninja
ninja -C build
```

Requires macOS 15+, an Apple Silicon Mac, and CommandLineTools (full Xcode is *not*
needed — we deliberately avoid the Core ML path, which requires `xcrun coremlc`).

### Smoke test

Proves both engines coexist on one shared ggml and prints a stage-by-stage breakdown:

```sh
ninja -C build yap-smoke
./build/yap-smoke models/s1-mini-q4_k_m.gguf \
                 models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
                 bench/jfk_11s.wav
```

### Run the app

`./scripts/dev-run.sh` builds, bundles, signs, and relaunches. It signs with a real
certificate identity on purpose: TCC keys permissions to the code-signing designated
requirement, so ad-hoc signing would make macOS forget the Microphone and
Accessibility grants on **every rebuild**.

Override the identity with `YAP_SIGN_IDENTITY`, and the install path with `YAP_APP_PATH`.

### Build a DMG to distribute

```sh
./scripts/make-dmg.sh                  # -> dist/Yap-<version>.dmg
./scripts/make-dmg.sh --skip-notarize  # local testing, will warn downloaders
```

Notarization needs a one-time keychain profile. Create it in your own terminal and
leave `--password` off, so notarytool gives you a secure prompt instead of putting
the secret in shell history and in `argv`, which any process can read via `ps`:

```sh
xcrun notarytool store-credentials yap-notary \
  --apple-id <your-apple-id> --team-id 266VNLKVKQ
```

That needs an app-specific password from appleid.apple.com, or an App Store Connect
API key (`--key <path.p8> --key-id <id> --issuer <uuid>`), which is the better
choice for CI since it is revocable independently of your Apple ID. Afterwards the
secret lives only in the login keychain and the build passes notarytool the profile
*name* — nothing in this repo ever reads it. Pass `--staple-app`
to notarize the `.app` as well as the DMG, which costs a second ~1 GB upload but
lets the app launch offline on a Mac that has never seen it.

Unlike `dev-run.sh`, this signs with the **hardened runtime**, which notarization
requires and which silently revokes microphone access unless the bundle carries
`com.apple.security.device.audio-input` (see `bundle/yap.entitlements`). The script
verifies both after signing, because a mic that returns digital silence looks
exactly like a mic that works.

The DMG is ~1.1 GB: the models are bundled into `Contents/Resources`, so there is
nothing to download on first launch.

Publishing the release is what makes an update reach existing installs. They read
`/releases/latest`, so drafts and pre-releases are invisible to them by design, and
they take the first `.dmg` asset on it. The comparison is against the release **tag**,
not the asset name, so the tag has to be `v<version>`:

```sh
gh release create "v$VER" "dist/Yap-$VER.dmg" --title "Yap $VER" --notes-file <notes>
```

### Icon

`bundle/Yap.icns` is committed, so nothing normally needs to regenerate it. The
artwork is drawn in code (`scripts/make-icon.mm`); after editing it, run:

```sh
./scripts/make-icon.sh
```

Each size is drawn natively rather than downsampled, and the speech arcs thin out
and then drop away as the canvas shrinks — at 16 px the tile holds a clean
silhouette instead of a smudge. The mark is original artwork on purpose: the
menu-bar glyph is an SF Symbol, and Apple's SF Symbols license does not allow those
in an app icon.

## Permissions

Two grants, both one-time:

- **Microphone** — to record while you hold the key.
- **Accessibility** — to observe the hotkey and insert text. This is the superset that
  also covers Input Monitoring; there is no separate step.

## Updates

Yap updates itself from this repo's [releases](https://github.com/samw3/yap/releases).
Once a day it asks `api.github.com` for the latest release and compares its tag against
the running version. Nothing is downloaded and nothing is installed without a click, and
an automatic check never raises an alert — it only changes what the menu says.
**Check for Updates Automatically** turns it off, and with it the app's only network
access.

Choosing the update row downloads the DMG — shown as a percentage, and stoppable — and
then:

1. `hdiutil attach` verifies the image's own checksum, so a truncated download fails
   there rather than becoming a broken install.
2. The app inside is checked against a pinned code requirement: bundle identifier
   `com.samw3.yap`, Developer ID leaf on team `266VNLKVKQ`, chained to Apple's root.
   The URL is not what makes a downloaded gigabyte safe to run — this is.
3. It is copied next to the installed app and re-checked in full, resource seal
   included, before anything is replaced.
4. The two bundles are exchanged in one atomic `renamex_np(RENAME_SWAP)`, and Yap
   relaunches into the new one.

Microphone and Accessibility are not asked for again: the designated requirement does
not change across a release, which is the same reason `dev-run.sh` signs with a real
identity rather than ad-hoc.

In-place installation needs the app bundle to be writable by you — true of
`/Applications` and `~/Applications` for whoever installed it. If it is not, the menu
says so instead of failing halfway, and the release page is one click away.

## Attribution

See [NOTICE](NOTICE). The s1-mini license carries a naming clause; the model is credited
as **S1-mini by Superwhisper**.
