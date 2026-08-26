# yap

Push-to-talk dictation for macOS. Hold **F11**, speak, release — cleaned-up text is
inserted into whatever window has focus. Fully on-device; no network.

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

## Permissions

Two grants, both one-time:

- **Microphone** — to record while you hold the key.
- **Accessibility** — to observe the hotkey and insert text. This is the superset that
  also covers Input Monitoring; there is no separate step.

## Attribution

See [NOTICE](NOTICE). The s1-mini license carries a naming clause; the model is credited
as **S1-mini by Superwhisper**.
