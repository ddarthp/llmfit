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
- [Configuration](#configuration)
- [Living alongside your cloud providers](#living-alongside-your-cloud-providers)
- [Moving the package to another machine](#moving-the-package-to-another-machine)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)

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
| Disk | ~7 GB for the smallest model, ~23 GB for the full catalog |
| Network | Only on first run, to download the model and the backend |

Nothing else. Node.js and Pi are optional and only needed if you want the bundled portable copies.

---

## Quick start

```powershell
git clone https://github.com/<you>/llmfit.git
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
1) NVIDIA CUDA 13.3                                        [recommended]
     CUDA0    <discrete GPU>              15.9 GiB total,  15.6 GiB usable
2) Vulkan
     Vulkan0  <integrated GPU / APU>      47.6 GiB total,  47.3 GiB usable
     Vulkan1  <discrete GPU>              15.6 GiB total,  15.3 GiB usable
3) CPU x64
     no GPU: uses system RAM
```

**Usable** is total minus the driver reserve, assuming the GPU is otherwise idle.

> The `free` value reported by `llama-server --list-devices` is deliberately *not* used: it is static. It returns the same number with an empty GPU and with 15 GB in use. Only `total` is trustworthy.

### 2. Model

Two models × vision on/off:

```
1) Qwen 3.5 9B Q6_K                  with vision   weights 6.9 GiB + vision 876 MiB
2) Qwen 3.5 9B Q6_K                  no vision     weights 6.9 GiB
3) Qwen 3.8 27B UD-Q3_K_XL           with vision   weights 12.2 GiB + vision 885 MiB   MTP available
4) Qwen 3.8 27B UD-Q3_K_XL           no vision     weights 12.2 GiB                    MTP available
```

Turning vision off skips the `mmproj` file and saves roughly a gigabyte of weights plus another 448 MiB of encoder compute buffers.

### 3. Context

```
KV quantized to q4_1 (0.625 bytes per element).
Only 16 of 65 layers hold KV: this is a hybrid attention/SSM model.

1)   64K   KV  1.3 GiB   estimated total  15.0 GiB   TIGHT
2)  128K   KV  2.5 GiB   estimated total  16.3 GiB   TOO BIG
3)  256K   KV  5.0 GiB   estimated total  18.8 GiB   TOO BIG
```

**This is the part most tools get wrong.** Qwen 3.5 and 3.8 are **hybrid attention/SSM** models. Their GGUF header carries `full_attention_interval = 4`: only one layer in four keeps a KV cache. The other three are SSM layers whose state is a fixed size that does not grow with context.

So a 65-block 27B model only pays KV for **16** layers. Counting all blocks overestimates the KV cache by 4× and rules out configurations that fit comfortably.

```
KV = attention_layers × kv_heads × (key_length + value_length) × context × bytes_per_element
```

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

- Only if the model ships `nextn` layers. The 9B does not; the 27B does (`nextn_predict_layers = 1`).
- Only on CUDA. On Vulkan the cost of maintaining the draft context cancels the gain.
- Only if at least 1 GiB is left after everything else is loaded.

When it is off, `--spec-type none` is passed explicitly. A state shown on screen should be controlled by the launcher, not inherited from a default that can change between releases.

### 5. Harness

```
1) Pi          [installed]      OpenAI chat
2) OpenCode    [installed]      OpenAI chat
3) Codex       [not installed]  OpenAI responses
4) None, server only
```

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
powershell -ExecutionPolicy Bypass -File serve.ps1 -ModelKey stable9b -Backend cuda13 -Context 131072 -Vision

# Require the entire catalog before copying to a USB stick
powershell -ExecutionPolicy Bypass -File verify.ps1 -Full

# See the raw device list per backend when GPU detection misbehaves
$env:LLMFIT_DEBUG=1; .\START.cmd

# Stop the server
Get-Process llama-server | Stop-Process -Force
```

---

## What is in this repository

Everything here is plain text — about 85 KB in total.

```
llmfit.ps1              The launcher: detection, fit calculation, five-step flow
serve.ps1               Invokes llama-server with explicit flags
verify.ps1              SHA-256 and file-count integrity check
clean.ps1               Reclaims disk by deleting extracted archives
install-path.ps1        Adds the tool to the user PATH

lib/
  harness.ps1           Harness definitions and how to register the local
                        provider in Pi, OpenCode and Codex

config/
  models.json           Model catalog: alias, HuggingFace URL, SHA-256, and the
                        geometry read from the GGUF header
  backends.json         llama.cpp backends: release URL, SHA-256, file counts
  server.json           Host, port, KV type, driver reserve, calibrated
                        overheads, context options, harness provider names
  runtimes.json         Node and Pi: path, entrypoint, file counts

bin/llmfit.cmd          Shim that puts `llmfit` on your PATH
START.cmd               Launcher wrapper
INSTALL-PATH.cmd        PATH setup wrapper
VERIFY.cmd              Verification wrapper
CLEAN.cmd               Cleanup wrapper
```

## What is *not* in this repository

No weights, no binaries, no encoders. They are downloaded on first use and verified by SHA-256 before anything is extracted or loaded.

| What | Where it comes from | Size |
| --- | --- | --- |
| Model weights (`.gguf`) | Hugging Face — `unsloth/Qwen3.5-9B-GGUF`, `unsloth/Qwen3.8-27B-GGUF` | 7–13 GB each |
| Vision encoders (`mmproj`) | Same Hugging Face repositories | ~880 MB each |
| `llama.cpp` binaries | Official GitHub release artifacts (`ggml-org/llama.cpp`, build `b10566`) | 18–510 MB |

These paths are ignored by Git and never committed:

```
models/        downloads/        tools/        .gopath/
llama-server.*        .atl/        .pi/        *.llmfit-backup
```

Model weights belong to their respective publishers under their own licenses.

---

## Configuration

Everything tunable lives in `config/`. No values are hardcoded in the scripts.

| File | Defines |
| --- | --- |
| `config/models.json` | Catalog: alias, URL, SHA-256, and geometry read from the GGUF header |
| `config/backends.json` | Backends: URL, SHA-256, extracted file counts |
| `config/server.json` | Host, port, KV type, driver reserve, overheads, context options, provider names |
| `config/runtimes.json` | Node and Pi: path, entrypoint, file counts |

To add your own model, add an entry to `config/models.json` with its URL, SHA-256 and the geometry from its GGUF header (`block_count`, `attention.head_count_kv`, `attention.key_length`, `attention.value_length`, and `full_attention_interval` if the architecture is hybrid).

The `harness` section defines the name each tool uses for the local provider. Match it to what you already have — registering a second name creates a duplicate provider pointing at the same server.

---

## Living alongside your cloud providers

`llmfit` **registers** the local provider and nothing else. It never changes your default model, because that would leave every other project pointing at a local server that is usually switched off.

| Harness | Local | Your usual setup |
| --- | --- | --- |
| Pi | `pi --provider llama-cpp --model qwen3.5-9b-q6` | `pi` |
| OpenCode | `opencode -m llamacpp/qwen3.5-9b-q6` | `opencode` |
| Codex | `codex --profile llama-local` | `codex` |

To switch between cloud and local without leaving a session:

```
pi --models "<your-provider>/*,llama-cpp/*"    # Ctrl+P cycles models
```

In OpenCode, the TUI model picker switches live.

Every file `llmfit` touches is backed up next to the original as `.llmfit-backup` before the first write.

`piPackages` in `config/server.json` is **empty on purpose**. Pi *installs* every registered package at startup, and if one fails to build, Pi will not open. Install your extensions yourself, on the harness you choose.

---

## Reference measurements

A 16 GB NVIDIA card, measured with `nvidia-smi`:

| Configuration | VRAM used | Free | Generation |
| --- | --- | --- | --- |
| 27B + vision, 64K, `q4_0` | 15202 MiB | 794 MiB | 50.8 tok/s |
| 27B no vision, 128K, `q4_0` | 15076 MiB | 920 MiB | 50.3 tok/s |

A 27B at Q3 running entirely on the GPU, with the vision encoder loaded. The overhead model (256 MiB base, 448 MiB extra with vision) predicts both cases to within 15 MiB.

---

## Moving the package to another machine

Once models and backends are downloaded, the whole folder is self-contained and can be carried on a USB stick — useful for machines with no network access.

**Before copying**, on the source machine:

```powershell
powershell -ExecutionPolicy Bypass -File clean.ps1          # drop extracted archives
powershell -ExecutionPolicy Bypass -File verify.ps1 -Full   # require the whole catalog
```

**Then:**

1. Copy the whole folder to the stick. With both models it is around 23 GB, so the stick needs at least 32 GB formatted **exFAT or NTFS** — FAT32 cannot hold files over 4 GB and every GGUF here is larger.
2. On the target machine, copy it from the stick to a local SSD. Do not run models straight off a slow stick.
3. Run `VERIFY.cmd` and wait for confirmation. It checks SHA-256 of models and binaries, plus the file counts of the Node and Pi trees — thousands of small files, and the part a USB copy is most likely to truncate.
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
