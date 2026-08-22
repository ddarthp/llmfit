# llmfit

**Portable, hardware-aware local LLM server for coding agents.**

`llmfit` measures what your machine can actually hold, lets you pick a model, vision and context that fit, starts `llama.cpp`, and hands you the command line to point Pi, OpenCode or Codex at it — in whatever folder you want to work in.

No install step, no build, no Git needed on the target machine. Copy the folder, run one command.

> **Status:** Windows (CUDA / Vulkan / CPU). macOS Apple Silicon and Linux are on the roadmap.

---

## Contents

- [Why](#why)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [The five steps](#the-five-steps)
- [Command reference](#command-reference)
- [What is in this repository](#what-is-in-this-repository)
- [What is *not* in this repository](#what-is-not-in-this-repository)
- [Models](#models)
- [Configuration](#configuration)
- [Using it from your editor](#using-it-from-your-editor)
- [Reference measurements](#reference-measurements)
- [Moving the package to another machine](#moving-the-package-to-another-machine)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [License](#license)

---

## Why

Running a local model for coding usually means guessing. How much context fits? Does the vision encoder still leave room? Will speculative decoding help, or just run out of memory?

`llmfit` answers those from data instead of guesses:

- It asks `llama.cpp` itself which devices exist and how much memory they have.
- It reads the **GGUF header** to compute the exact KV cache size for each context length.
- Its overhead constants are **calibrated against `nvidia-smi`**, not estimated.
- It enables speculative decoding only when the model actually has the layers for it and the memory to spare.

The result is a fit table you can trust *before* you wait three minutes for a 13 GB model to load.

---

## Requirements

| | |
| --- | --- |
| OS | Windows 10 / 11 (x64) |
| PowerShell | 5.1, the one bundled with Windows |
| GPU | Optional. NVIDIA via CUDA, AMD/Intel via Vulkan, or CPU only |
| Disk | 4.2 GB for the smallest model without vision, ~51 GB for the whole catalog |
| Network | Only on first run, to download the model and the backend |

Nothing else. The harnesses (Pi, OpenCode, Codex) are optional: without one, `llmfit` still runs the server and you point anything OpenAI-compatible at it.

---

## Quick start

```powershell
git clone https://github.com/ddarthp/llmfit.git
cd llmfit
.\START.cmd
```

On first run it downloads the backend and the model you pick, verifying both by SHA-256.

To get a global `llmfit` command, run `INSTALL-PATH.cmd` once and open a new terminal.

---

## The five steps

Enter accepts the highlighted option in each step.

### 1. Architecture

```
1) NVIDIA CUDA 13.3                                     [recommended]
     CUDA0    NVIDIA GeForce RTX 5070 Ti   15.9 GiB total,  15.6 GiB usable
2) Vulkan
     Vulkan0  AMD Radeon 780M Graphics     47.6 GiB total,  47.3 GiB usable
     Vulkan1  NVIDIA GeForce RTX 5070 Ti   15.6 GiB total,  15.3 GiB usable
3) CPU x64
     no GPU: uses system RAM
```

**Usable** is total minus the driver reserve, assuming the GPU is otherwise idle.

> The `free` value reported by `llama-server --list-devices` is deliberately *not* used: it is static. It returns the same number with an empty GPU and with 15 GB in use. Only `total` is trustworthy.

### 2. Model

Every model in the catalog, each with vision on and off:

```
 1) Qwen 3.5 9B Q6_K             with vision  weights 6.9 GiB + vision 876 MiB
 2) Qwen 3.5 9B Q6_K             no vision    weights 6.9 GiB
 3) Qwen 3.8 27B UD-Q3_K_XL      with vision  weights 12.2 GiB + vision 885 MiB  MTP available
 4) Qwen 3.8 27B UD-Q3_K_XL      no vision    weights 12.2 GiB  MTP available
 5) Gemma 4 E4B QAT              with vision  will be downloaded  MTP available
 6) Gemma 4 E4B QAT              no vision    will be downloaded  MTP available
 7) Gemma 4 12B QAT              with vision  will be downloaded  MTP available
 8) Gemma 4 12B QAT              no vision    will be downloaded  MTP available
 9) Gemma 4 26B-A4B QAT (MoE)    with vision  will be downloaded  MTP available
10) Gemma 4 26B-A4B QAT (MoE)    no vision    will be downloaded  MTP available
```

Turning vision off skips the `mmproj` file. That saves its weight — between 175 MB and 1.2 GB depending on the model — plus the encoder's compute buffers, which are measured per model and listed under [reference measurements](#reference-measurements).

### 3. Context

The table is computed for the model and vision setting you just chose, against the budget of the device you picked. Here is the tightest case — the 27B with vision on a 16 GB card:

```
KV quantized to q4_1 (0.625 bytes per element).
hybrid attention/SSM: 16 of 65 layers hold a KV cache.

1)   64K   KV  1.3 GiB   estimated total  15.0 GiB   TIGHT
2)  128K   KV  2.5 GiB   estimated total  16.3 GiB   TOO BIG
3)  256K   KV  5.0 GiB   estimated total  18.8 GiB   TOO BIG
```

The same card running the 9B with vision reports `FITS` at all three lengths, topping out at 11.0 GiB for 256K.

**This is the part most tools get wrong.** Not every layer's cache grows with context, and modern architectures lean on that hard.

```
KV = elements_per_token × context + fixed_elements
```

Two coefficients, read from the GGUF header and stored in the catalog. What fills them depends on the architecture:

| Architecture | Scaling term | Fixed term |
| --- | --- | --- |
| **Hybrid attention/SSM** (Qwen 3.5, 3.8) | `full_attention_interval = 4`, so only 1 layer in 4 keeps a KV cache | The other 3 in 4 are SSM layers with fixed-size state |
| **Sliding-window attention** (Gemma 4) | 1 layer in 6 attends to the full context | The other 5 are capped at the window (512 or 1024 tokens) and never grow |

A 65-block Qwen 27B only pays KV for **16** layers. A 48-block Gemma 12B pays the scaling cost for **8** layers — and those use a single KV head each, which is why 256K stays under 1.4 GiB on it.

Assuming every layer scales overestimates the cache by 4× or more and rules out configurations that fit comfortably.

`FITS` leaves at least 8 % headroom, `TIGHT` fits with none, `TOO BIG` exceeds the budget. You can still pick a `TOO BIG` option — `llama.cpp` will offload layers to RAM and run much slower.

#### KV quantization

Set `cacheType` in `config/server.json`. Default is `q4_1`. Drop to `q4_0` to buy context at a small quality cost.

| Type | Bytes/element | 27B KV at 64K |
| --- | --- | --- |
| `f16` | 2 | 4.0 GiB |
| `q8_0` | 1.0625 | 2.1 GiB |
| `q5_1` | 0.75 | 1.5 GiB |
| `q4_1` *(default)* | 0.625 | 1.3 GiB |
| `q4_0` | 0.5625 | 1.1 GiB |

### 4. Speculative decoding (MTP)

Decided automatically, and it tells you why:

- Only if the model ships MTP at all. It comes in two shapes:
  - **Embedded** — Qwen 3.8 27B carries `nextn_predict_layers = 1` inside the model file.
  - **Separate draft model** — every Gemma 4 ships an `mtp-*.gguf` companion, downloaded on demand and passed with `--spec-draft-model`.
- Only on CUDA. On Vulkan the cost of maintaining the draft context cancels the gain.
- Only if at least 1 GiB is left after everything else is loaded, plus the draft model's own weight where one is used.

When it is off, `--spec-type none` is passed explicitly. A state shown on screen should be controlled by the launcher, not inherited from a default that can change between releases.

### 5. Harness

```
1) Pi          [installed]      OpenAI chat
2) OpenCode    [installed]      OpenAI chat
3) Codex       [installed]      OpenAI responses
4) None, server only
```

All three harnesses are supported. The bracket reports what was detected on *your* machine:

| Tag | Meaning |
| --- | --- |
| `[installed]` | The command is on your `PATH` and ready to use |
| `[not installed]` | Not found on `PATH`; install it and run `llmfit` again |
| `[incompatible]` | Installed, but this model's chat template rejects how that harness builds requests. The reason is printed next to it |

Pick one. `llmfit` registers the local provider in that tool's configuration and leaves the command on screen and in your clipboard:

```
pi --provider llama-cpp --model qwen3.5-9b-q6
```

Open whatever folder you want to work in, paste, done. The server stays in its own window, so you can open and close sessions without paying the load time again.

---

## Command reference

### Entry points

| Command | What it does |
| --- | --- |
| `llmfit` | The interactive launcher. Available globally after `INSTALL-PATH.cmd` |
| `START.cmd` | Same launcher, without touching `PATH`. Double-click friendly |
| `INSTALL-PATH.cmd` | Adds `bin\`, `tools\node` and Pi to the user `PATH`. Run once, no admin rights |
| `VERIFY.cmd` | Checks the integrity of everything installed |
| `CLEAN.cmd` | Deletes already-extracted archives to reclaim disk |

### PowerShell scripts

| Script | Flags | Purpose |
| --- | --- | --- |
| `llmfit.ps1` | `-Help` | The launcher itself |
| `serve.ps1` | `-ModelKey` `-Backend` `-Context` `-Vision` `-Mtp` | Starts `llama-server` directly, no menus |
| `verify.ps1` | `-Full` | Integrity check. `-Full` requires the whole catalog |
| `clean.ps1` | `-IncludeLogs` `-Force` | Reclaim disk. `-Force` skips the confirmation |
| `install-path.ps1` | — | `PATH` setup |

Useful invocations:

```powershell
# Start a specific configuration with no menus
powershell -ExecutionPolicy Bypass -File serve.ps1 -ModelKey qwen35-9b -Backend cuda13 -Context 131072 -Vision

# Require the entire catalog before copying to a USB stick
powershell -ExecutionPolicy Bypass -File verify.ps1 -Full

# See the raw device list per backend when GPU detection misbehaves
$env:LLMFIT_DEBUG=1; .\START.cmd

# Stop the server
Get-Process llama-server | Stop-Process -Force
```

---

## What is in this repository

Plain text, about 85 KB: five PowerShell scripts, the harness definitions in `lib/`, four JSON files in `config/`, and the `.cmd` wrappers that make them double-clickable. Nothing is generated and nothing is vendored.

## What is *not* in this repository

No weights, no binaries, no encoders. They are downloaded on first use and verified by SHA-256 before anything is extracted or loaded.

| What | Where it comes from | Size |
| --- | --- | --- |
| Model weights (`.gguf`) | Hugging Face — `unsloth/Qwen3.5-9B-GGUF`, `unsloth/Qwen3.8-27B-GGUF`, `unsloth/gemma-4-*-it-qat-GGUF` | 4.2–14.3 GB each |
| Vision encoders (`mmproj`) | The same repositories | 175 MB – 1.2 GB each |
| Speculative draft models (`mtp-*.gguf`) | The same repositories | 57–254 MB, only fetched when MTP is enabled |
| `llama.cpp` binaries | Official GitHub release artifacts (`ggml-org/llama.cpp`, build `b10566`) | 18–510 MB |

These paths are ignored by Git and never committed:

```
models/        downloads/        tools/        .gopath/
llama-server.*        .atl/        .pi/        *.llmfit-backup
```

Model weights belong to their respective publishers under their own licenses.

---

## Models

| Model | Model name to use | Weights | Vision | KV at 128K | Max context | MTP |
| --- | --- | --- | --- | --- | --- | --- |
| Gemma 4 E4B QAT | `gemma4-e4b-qat` | 4.22 GB | 990 MB | 0.64 GiB | 128K | draft model |
| Gemma 4 12B QAT | `gemma4-12b-qat` | 6.72 GB | 175 MB | 0.72 GiB | 256K | draft model |
| Qwen 3.5 9B Q6_K | `qwen3.5-9b-q6` | 7.46 GB | 876 MB | 1.25 GiB | 256K | — |
| Qwen 3.8 27B UD-Q3_K_XL | `qwen3.8-27b-q3` | 13.15 GB | 885 MB | 2.50 GiB | 256K | embedded |
| Gemma 4 26B-A4B QAT | `gemma4-26b-a4b-qat` | 14.25 GB | 1.19 GB | 0.84 GiB | 256K | draft model |

The middle column is the name your harness needs — see [using it from your editor](#using-it-from-your-editor). `config/models.json` keys them slightly differently (`gemma4-e4b` rather than `gemma4-e4b-qat`); the key is only for `serve.ps1 -ModelKey`.

All of them are Unsloth quantizations with an optional vision encoder. KV figures are at the default `q4_1`. The whole catalog, weights plus encoders plus draft models, is about 51 GB on disk — you only ever download what you pick.

Two things worth reading off that table:

- **The 26B-A4B has the heaviest weights and the lightest KV cache.** It is a mixture of experts: 8 of 128 experts run per token but all 128 must be resident, so you pay the full 14.25 GB for weights while its 5 context-scaling layers keep the cache tiny. On a 16 GB card it fits with vision at 64K, with about 350 MiB to spare.
- **The E4B's KV figure is measured, not derived.** Its header implies 1.10 GiB at 128K; the card says 0.64 GiB. `shared_kv_layers = 18` is the reason, and the header never says which layers share, so the catalog carries the measured coefficient.

To add your own model, put an entry in `config/models.json` with its URL, SHA-256 and the two KV coefficients derived from its GGUF header. Every existing entry records its derivation — and, where measurement disagreed with the header, what was measured and why — in a `detail` block.

## Configuration

Everything tunable lives in `config/`. No values are hardcoded in the scripts.

| File | Defines |
| --- | --- |
| `config/models.json` | Catalog: alias, URL, SHA-256, and geometry read from the GGUF header |
| `config/backends.json` | Backends: URL, SHA-256, extracted file counts |
| `config/server.json` | Host, port, KV type, driver reserve, overheads, context options, provider names |
| `config/runtimes.json` | Node and Pi: path, entrypoint, file counts |

The `harness` section defines the name each tool uses for the local provider. Match it to what you already have — registering a second name creates a duplicate provider pointing at the same server.

Each model may carry its own `overhead` block with measured `baseMiB` and `visionMiB` values. When it does, those win over the defaults in `config/server.json`. A new model works without one; it just inherits constants measured on something else, so measure it if the numbers matter to you.

---

## Using it from your editor

When `llmfit` finishes it prints the command and copies it to your clipboard, so normally you just paste. This is the reference for writing it yourself.

| Harness | Point it at the local server | Keep using your cloud provider |
| --- | --- | --- |
| **Pi** | `pi --provider llama-cpp --model MODEL` | `pi` |
| **OpenCode** | `opencode -m llamacpp/MODEL` | `opencode` |
| **Codex** | `codex --profile llama-local` | `codex` |

`MODEL` is the *model name to use* column of the [models table](#models). Worked examples, for the Gemma 4 12B:

```powershell
pi --provider llama-cpp --model gemma4-12b-qat
opencode -m llamacpp/gemma4-12b-qat
codex --profile llama-local
```

Codex takes no model name: `llmfit` writes the model into the `llama-local` profile every time you pick one, so the profile always matches whatever is loaded.

Three things worth knowing:

- **The name has to match what the server loaded.** One model is served at a time; asking for a different one will not switch it. Re-run `llmfit` to load another.
- **Run it in any folder.** The harness talks to `http://127.0.0.1:8080`, so start it wherever your code lives.
- **The server outlives your session.** Close the harness and open it again without paying the load time twice.

### It leaves your defaults alone

`llmfit` **registers** the local provider in that tool's configuration and nothing more. It never changes your default model, because that would leave every other project pointing at a local server that is usually switched off. Run `pi` or `opencode` with no flags and you are on your usual provider.

To switch between cloud and local without leaving a session, load both catalogs at once and cycle with **Ctrl+P**:

```powershell
pi --models "anthropic/*,llama-cpp/*"
```

Replace `anthropic` with whichever provider you already use in Pi. In OpenCode the TUI model picker switches live, no flag needed.

Every file `llmfit` touches is backed up next to the original as `.llmfit-backup` before the first write.

`piPackages` in `config/server.json` is **empty on purpose**. Pi *installs* every registered package at startup, and if one fails to build, Pi will not open. Install your extensions yourself, on the harness you choose.

---

## Reference measurements

Every model in the catalog has been measured against `nvidia-smi` on a 16 GB NVIDIA card (an RTX 5070 Ti). A sample:

| Configuration | Estimated | VRAM used | Generation |
| --- | --- | --- | --- |
| Qwen 27B + vision, 64K | 15203 MiB | 15202 MiB | 50.8 tok/s |
| Qwen 27B no vision, 128K | 15063 MiB | 15076 MiB | 50.3 tok/s |
| Gemma 4 E4B + vision, 128K | 4611 MiB | 4610 MiB | 89.1 tok/s |
| Gemma 4 12B no vision, 256K | 8132 MiB | 8132 MiB | — |
| Gemma 4 12B + vision, 64K | 7516 MiB | 7516 MiB | — |
| Gemma 4 26B-A4B + vision, 64K | 15644 MiB | 15644 MiB | — |

Across 12 Gemma configurations spanning three models, two vision settings and context lengths from 64K to 256K, the **worst error is 1 MiB**.

Getting there took two corrections that no amount of reading the header would have produced:

- **Gemma 4 E4B holds fewer KV caches than its header implies.** The arithmetic says 7 full-attention layers; the measured delta between 64K and 128K says 4. `shared_kv_layers = 18` is why — three of the seven reuse another layer's cache. The header states how many layers share, never which, so only measurement resolves it.
- **E4B keeps about 1.2 GB of its weights in system RAM.** It is a MatFormer: its per-layer embeddings never become resident on the GPU. Its calibrated base overhead is therefore *negative*, which is the honest way to encode "part of this file is not in VRAM".

Overhead constants per model, all measured:

| Model | Base | With vision |
| --- | --- | --- |
| Qwen (both) | 256 MiB | +448 MiB |
| Gemma 4 E4B | −1207 MiB | +202 MiB |
| Gemma 4 12B | 347 MiB | +177 MiB |
| Gemma 4 26B-A4B | 313 MiB | +142 MiB |

Gemma's vision encoder costs roughly a third of what Qwen's does in compute buffers. A model with no measured values falls back to the defaults in `config/server.json`.

---

## Moving the package to another machine

Once models and backends are downloaded, the whole folder is self-contained and can be carried on a USB stick — useful for machines with no network access.

**Before copying**, on the source machine:

```powershell
powershell -ExecutionPolicy Bypass -File clean.ps1          # drop extracted archives
powershell -ExecutionPolicy Bypass -File verify.ps1 -Full   # require the whole catalog
```

**Then:**

1. Copy the whole folder to the stick. A full catalog runs to about 52 GB with the backends, so size the stick for what you actually keep, and format it **exFAT or NTFS** — FAT32 cannot hold files over 4 GB and every GGUF here is larger.
2. On the target machine, copy it from the stick to a local SSD. Do not run models straight off a slow stick.
3. Run `VERIFY.cmd` and wait for confirmation. It re-checks the SHA-256 of every model and binary, which is what catches a copy that was silently truncated.
4. Run `INSTALL-PATH.cmd` once.
5. Open a new terminal and run `llmfit`.

---

## Troubleshooting

**A large download was interrupted.** Run `llmfit` again. It validates by SHA-256, not by file existence: a partial file is resumed, and if it still does not match it is re-downloaded clean. Nothing to delete by hand.

**My GPU is not detected.** Set `LLMFIT_DEBUG=1` to see the raw `llama-server --list-devices` output per backend.

**It says TIGHT and I want headroom.** Lower `cacheType` to `q4_0` in `config/server.json`, or pick the no-vision variant.

**"A local llama-server is already running."** Answer `Y` to replace it, or `n` to keep using the one already up.

**Restore my previous configuration.** Every file the launcher touched has a `.llmfit-backup` copy next to it.

**Stop the server.**

```powershell
Get-Process llama-server | Stop-Process -Force
```

---

## Roadmap

- macOS on Apple Silicon (Metal backend, unified memory budgeting)
- Linux (CUDA / ROCm / Vulkan)
- More models in the catalog

---

## License

The launcher is released under the MIT License. `llama.cpp` is downloaded, not vendored, and remains under its own license; model weights belong to their respective publishers.
