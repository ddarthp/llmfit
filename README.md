# llmfit

**Portable, hardware-aware local LLM server for coding agents.**

`llmfit` measures what your machine can actually hold, lets you pick a model, vision and context that fit, and starts `llama.cpp`. Then it either opens a chat window or hands you the command line to point Pi, OpenCode or Codex at the server — in whatever folder you want to work in.

No install step, no build, no Git needed on the target machine. Copy the folder, run one command.

> **Status:** Windows (CUDA / Vulkan / CPU) and macOS on Apple Silicon (Metal). Linux is on the roadmap.

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
- [What is different on macOS](#what-is-different-on-macos)
- [Just chatting](#just-chatting)
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

| | Windows | macOS |
| --- | --- | --- |
| OS | Windows 10 / 11 (x64) | macOS on Apple Silicon (M1–M4) |
| Runtime | PowerShell 5.1, the one bundled with Windows | zsh, and PowerShell 7 downloaded on first run |
| GPU | Optional. NVIDIA via CUDA, AMD/Intel via Vulkan, or CPU only | Metal, always present |
| Disk | 4.2 GB for the smallest model without vision, ~69 GB for the whole catalog | the same, plus 183 MB for PowerShell |
| Network | Only on first run, to download the model and the backend | the same |

Nothing else, and nothing installed. The harnesses (Pi, OpenCode, Codex) are optional: without one, `llmfit` still runs the server and you point anything OpenAI-compatible at it.

**On macOS the launcher needs PowerShell, and it fetches its own.** There is no runtime both systems ship — Windows has no shell, macOS has no PowerShell — so the alternative was maintaining the fit arithmetic twice and letting two implementations drift apart. Instead `llmfit` stays one codebase and treats PowerShell as one more dependency: downloaded, checked against its SHA-256, extracted into `tools/pwsh`, never installed. Nothing is written outside the folder, no Homebrew, no admin rights. A `pwsh` already on your `PATH` is used as is and nothing is downloaded.

Intel Macs are not supported: the catalog carries the `macos-arm64` build of `llama.cpp` only.

---

## Quick start

**Windows**

```powershell
git clone https://github.com/ddarthp/llmfit.git
cd llmfit
.\START.cmd
```

**macOS**

```zsh
git clone https://github.com/ddarthp/llmfit.git
cd llmfit
./START.command
```

`START.command` is also double-clickable from Finder.

On first run it downloads the backend and the model you pick, verifying both by SHA-256. On macOS it fetches PowerShell first, the same way.

To get a global `llmfit` command, run `INSTALL-PATH.cmd` (Windows) or `INSTALL-PATH.command` (macOS) once and open a new terminal.

---

## The five steps

Enter accepts the highlighted option in each step.

### 1. Architecture

```
1) NVIDIA CUDA 13.3                                     [recommended]
     CUDA0    NVIDIA GeForce RTX 5070 Ti   15.9 GiB total,  15.6 GiB usable, 798 MiB free now
2) Vulkan
     Vulkan0  AMD Radeon 780M Graphics     47.6 GiB total,  47.3 GiB usable
     Vulkan1  NVIDIA GeForce RTX 5070 Ti   15.6 GiB total,  15.3 GiB usable, 798 MiB free now
3) CPU x64
     no GPU: uses system RAM
```

**free now** appears only where a live reading exists, which today means `nvidia-smi`. It is printed in yellow when it has fallen below half the card, because that is the case the rest of the menu cannot see: the machine above has a training job holding the 5070 Ti, and every other number on its line was measured on an idle card that no longer exists.

On macOS there is one entry, because there is one answer:

```
  System RAM: 24.0 GiB
  Apple Silicon shares that RAM with the GPU. The budget below is the slice
  macOS recommends a single process keep resident, not a separate pool.

1) Apple Metal (M1-M4, unified memory)                  [recommended]
     MTL0     Apple M4 Pro                  17.8 GiB recommended,  17.8 GiB usable
```

**Usable** is what the machine will actually give you, and how it is reached differs by platform because the number `llama.cpp` reports means different things.

On **Windows**, `total` is the card's raw dedicated VRAM with nothing held back, so `llmfit` subtracts a driver reserve and then a safety margin (`safetyMarginPercent`, 10 % by default). Windows does not hand a single process the last of the dedicated VRAM: WDDM keeps headroom for the desktop and quietly pages the excess into system RAM. There is no error, only a slowdown. On NVIDIA the budget is instead `nvidia-smi`'s live free memory whenever that is lower, so a browser or a model someone else left running is accounted for rather than silently overcommitted.

On **macOS**, `total` is already `recommendedMaxWorkingSetSize` — what macOS itself recommends one process keep resident. Measured on a 24 GiB M4 Pro it reads 18186 MiB, 74 % of the machine: the OS has already held back 6.4 GB before `llmfit` sees the number. So both constants are **zero** on macOS, and that is not the same as having no margin. Subtracting a reserve calibrated against an NVIDIA driver, or a second margin for a WDDM paging behaviour that does not exist on unified memory, would count the same headroom twice and rule out configurations that fit.

There is no separate pool of video memory on Apple Silicon. The weights, the KV cache and everything the OS is doing come out of the same RAM, which is why the menu prints the machine's total above the budget.

> The `free` value reported by `llama-server --list-devices` is deliberately *not* used as a budget: it is static. It returns the same number with an empty GPU and with 15 GB in use. Measured on the machine above, the Vulkan build reported **15227 MiB free** on the 5070 Ti while `nvidia-smi` reported **798**, because a training job held the rest. Only `total` is trustworthy.

> Metal also reports `BLAS: Accelerate (0 MiB, 0 MiB free)`, which matches the device pattern exactly but is a compute library, not memory you can spend. Anything reporting no memory is dropped rather than listed as a GPU with none.

#### Which device runs it

A backend enumerates every device its API can reach, and `llama.cpp`'s default split mode is `layer` **across all of them**. On the machine above, choosing Vulkan without saying more puts part of the model on the 780M and part on the 5070 Ti — and sizes that split with the static `free` above, which says the busy card has 15 GB going spare.

So when a backend that declares `pinDevice` sees more than one device, there is a step:

```
  This backend can see more than one device, and llama.cpp would spread the
  model over all of them. Pick the one that should carry it.

1) Vulkan0  AMD Radeon 780M Graphics     47.6 GiB total [recommended]
2) Vulkan1  NVIDIA GeForce RTX 5070 Ti   15.6 GiB total
     798 MiB free right now against the 15.3 GiB this backend reports

  Device [1]:
```

The choice is sent on as `--device <id> --split-mode none`, and the fit table in step 3 is computed against **that** device's memory rather than against the largest one on the machine. Those two have to agree: a table sized for one card describing a run spread over two is a table that measured nothing.

`cuda13` and `vulkan` declare `pinDevice`. `cpu` has no devices, and `metal` has exactly one, so neither does — nothing changes on macOS.

> An integrated GPU is not a small discrete one. The 780M reads 47.6 GiB because on an APU that memory *is* system RAM, and there is no PCIe crossing and no dedicated pool to overflow. What it does not have is bandwidth of its own: it shares the machine's DDR5 with the CPU. Prompt processing, which is compute-bound, gets the full benefit. Token generation, which is bandwidth-bound, gets much less. See [Reference measurements](#reference-measurements).

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

### 3. KV cache and context

Two questions, in that order, because the answer to the first sizes the table for the second.

```
KV cache type. The fit table below is sized with what you pick here.
 1) f16   2       bytes/element   full precision, attention stays on the GPU   (default, from config/server.json)
 2) q8_0  1.0625  bytes/element   QUANTIZED: attention falls back to the CPU on CUDA
KV cache [1]:
```

Pressing Enter takes the default, which is whatever the catalog resolves for this model on this platform — so the launcher behaves exactly as it did before this menu existed. The list itself is `cacheTypeOptions` in `config/server.json`. Read the next section before picking option 2: on CUDA it was measured, and it is a bad trade.

Then the table, computed for the model and vision setting you just chose, against the budget of the device you picked. Here is the tightest case — the 27B without vision on a 16 GB card:

```
KV cache in f16, 2 bytes per element (full precision, attention stays on the GPU).
hybrid attention/SSM: 16 of 65 layers hold a KV cache.

1)   32K   KV  2.0 GiB   estimated total  13.9 GiB   TIGHT
2)   48K   KV  3.0 GiB   estimated total  14.9 GiB   TOO BIG
3)   56K   KV  3.5 GiB   estimated total  15.4 GiB   TOO BIG
4)   64K   KV  4.0 GiB   estimated total  15.9 GiB   TOO BIG
5)  128K   KV  8.0 GiB   estimated total  19.9 GiB   TOO BIG
6)  256K   KV 16.0 GiB   estimated total  27.9 GiB   TOO BIG
```

That is what a 27B costs on 16 GB: 32K and nothing more. The Gemma 4 12B on the same card reports `FITS` at every length, 256K included, at 10.9 GiB.

Pick `q8_0` at the prompt above and the KV column halves — 1.1 GiB at 32K, 2.1 at 64K — which is exactly what makes the option tempting and exactly why the warning is next to it.

The shorter options exist because context is the cheapest thing to give up. Halving it frees real memory and keeps the model on the GPU, which quantizing the cache does not.

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

#### KV quantization costs you the GPU

The launcher lets you pick the type, and the default is `f16`. Quantizing the KV cache is **not** the free context win it looks like. Measured on this build, same model, same prompt, same card:

| `cacheType` | VRAM | Prompt processing | Generation |
| --- | --- | --- | --- |
| `f16` *(default)* | 8310 MiB | **3355 tok/s** | **65.1 tok/s** |
| `q4_1` | 7172 MiB | 40 tok/s | 10.9 tok/s |

A gigabyte saved for **84× slower prompt processing**. CUDA flash-attention has no kernel for a quantized KV cache, so attention falls off the GPU and runs on the CPU. The weights stay resident on the card, `nvidia-smi` reports normal memory use, and nothing anywhere reports an error — the GPU simply sits at a few percent utilisation while the CPU does the work.

If you need the context badly enough to pay that, the types are there:

| Type | Bytes/element | 27B KV at 32K |
| --- | --- | --- |
| `f16` *(default)* | 2 | 2.0 GiB |
| `q8_0` | 1.0625 | 1.1 GiB |
| `q5_1` | 0.75 | 768 MiB |
| `q4_1` | 0.625 | 640 MiB |
| `q4_0` | 0.5625 | 576 MiB |

The launcher's menu offers only `f16` and `q8_0`, because those are the two worth putting in front of somebody: full precision, and the mildest quantization at roughly half the cache. The rest are reachable by adding them to `cacheTypeOptions` in `config/server.json` — every type listed there must also appear in `cacheTypeBytes`, or the launcher stops before anything loads.

**If you do quantize, measure it.** The 84× figure above is a CUDA measurement and it is the only one anybody here has taken; Metal has never been checked. Run your workload once with each type and compare the `prompt eval time` and `eval time` lines `llama-server` prints — that is the whole point of the type being a prompt instead of a constant. If prompt processing collapses, you found the same hole on your platform.

Prefer a shorter context over a quantized cache. The fit table offers 32K, 48K and 56K precisely so you can trade context for memory without leaving the GPU.

### 4. Speculative decoding (MTP)

Decided automatically, and it tells you why:

- Only if the model ships MTP at all. It comes in two shapes:
  - **Embedded** — Qwen 3.8 27B carries `nextn_predict_layers = 1` inside the model file.
  - **Separate draft model** — every Gemma 4 ships an `mtp-*.gguf` companion, downloaded on demand and passed with `--spec-draft-model`.
  - **Separate full build** — Qwen 3.6 35B-A3B publishes MTP as a different 16 GB model file (41 blocks against 40, 753 tensors against 733). That makes it a choice at download time, not a toggle at step 4, so the catalog entry declares no `mtp` block and explains why. Register the MTP build as its own entry if you want it.
- Only on a backend that declares `speculativeDecoding: true` in `config/backends.json`. CUDA and Metal do. Vulkan does not: the cost of maintaining the draft context was measured there and cancels the gain.
- Only up to a `maxContext` when the catalog records one. That ceiling is the longest context somebody actually ran, not a derived limit — see [what is different on macOS](#what-is-different-on-macos).
- Only if its measured cost fits in what is left, with a margin. See the [table above](#reference-measurements) for what each model charges.
- Only if the catalog lets it. `mtp.autoEnable: false` turns it off for a model regardless. **The Qwen 27B ships with it off**: on a 16 GB card that model already sits near the ceiling, and 1200 MiB more leaves nothing for anything else touching the GPU. Set it to `true` if your card has room.

When it is off, `--spec-type none` is passed explicitly. A state shown on screen should be controlled by the launcher, not inherited from a default that can change between releases.

### 5. Harness

```
1) Pi          [installed]      OpenAI chat
2) OpenCode    [installed]      OpenAI chat
3) Browser     [installed]      built-in chat UI
4) Codex       [installed]      OpenAI responses
5) None, server only
```

**Browser** needs nothing installed and is always available — see [just chatting](#just-chatting). For the rest, the bracket reports what was detected on *your* machine:

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

| Windows | macOS | What it does |
| --- | --- | --- |
| `llmfit` | `llmfit` | The interactive launcher. Available globally after the PATH installer |
| `START.cmd` | `START.command` | Same launcher, without touching `PATH`. Double-click friendly |
| `INSTALL-PATH.cmd` | `INSTALL-PATH.command` | Puts the launcher on your `PATH`. Run once, no admin rights |
| `VERIFY.cmd` | `VERIFY.command` | Checks the integrity of everything installed |
| `CLEAN.cmd` | `CLEAN.command` | Deletes already-extracted archives to reclaim disk |

On Windows the PATH installer adds `bin\`, `tools\node` and Pi to the user `PATH` through the registry. On macOS it writes a marked block into `~/.zshrc` (or `~/.bash_profile`) adding `bin/` only — `tools/node` and `tools/pi` are runtimes a Windows package vendors so an offline machine can still run Pi, and on macOS Pi is an npm install like any other. The file is backed up as `.llmfit-backup` before the first write and re-running only rewrites the block.

### PowerShell scripts

| Script | Flags | Purpose |
| --- | --- | --- |
| `llmfit.ps1` | `-Help` | The launcher itself |
| `serve.ps1` | `-ModelKey` `-Backend` `-Context` `-CacheType` `-Device` `-Vision` `-Mtp` | Starts `llama-server` directly, no menus |
| `verify.ps1` | `-Full` | Integrity check. `-Full` requires the whole catalog |
| `clean.ps1` | `-IncludeLogs` `-Force` | Reclaim disk. `-Force` skips the confirmation |
| `install-path.ps1` | — | `PATH` setup |

Useful invocations, Windows:

```powershell
# Start a specific configuration with no menus
powershell -ExecutionPolicy Bypass -File serve.ps1 -ModelKey qwen35-9b -Backend cuda13 -Context 131072 -Vision

# Keep the whole model on the integrated GPU and leave the discrete card alone
powershell -ExecutionPolicy Bypass -File serve.ps1 -ModelKey gemma4-e4b -Backend vulkan -Context 49152 -Device Vulkan0

# Require the entire catalog before copying to a USB stick
powershell -ExecutionPolicy Bypass -File verify.ps1 -Full

# See the raw device list per backend when GPU detection misbehaves
$env:LLMFIT_DEBUG=1; .\START.cmd

# Stop the server
Get-Process llama-server | Stop-Process -Force
```

And macOS:

```zsh
# Start a specific configuration with no menus
./tools/pwsh/pwsh -NoProfile -File serve.ps1 -ModelKey qwen35-9b -Backend metal -Context 131072 -Vision

# Require the entire catalog before copying to an external disk
./tools/pwsh/pwsh -NoProfile -File verify.ps1 -Full

# See the raw device list when GPU detection misbehaves
LLMFIT_DEBUG=1 ./START.command

# Follow the server, which has no window of its own here
tail -f llama-server.log

# Stop the server
pkill -x llama-server
```

---

## What is in this repository

Plain text: five PowerShell scripts, the harness definitions and the macOS bootstrap in `lib/`, five JSON files in `config/`, and the `.cmd` and `.command` wrappers that make them double-clickable on each system. Nothing is generated and nothing is vendored.

The launcher itself is one codebase. `lib/bootstrap.zsh` is the only part written twice over, and it does not duplicate any logic: it exists solely to put a PowerShell on the machine and hand over.

## What is *not* in this repository

No weights, no binaries, no encoders. They are downloaded on first use and verified by SHA-256 before anything is extracted or loaded.

| What | Where it comes from | Size |
| --- | --- | --- |
| Model weights (`.gguf`) | Hugging Face — `unsloth/Qwen3.5-9B-GGUF`, `unsloth/Qwen3.8-27B-GGUF`, `unsloth/gemma-4-*-it-qat-GGUF` | 4.2–14.3 GB each |
| Vision encoders (`mmproj`) | The same repositories | 175 MB – 1.2 GB each |
| Speculative draft models (`mtp-*.gguf`) | The same repositories | 57–254 MB, only fetched when MTP is enabled |
| `llama.cpp` binaries | Official GitHub release artifacts (`ggml-org/llama.cpp`, build `b10566`) | 11–510 MB |
| PowerShell 7 (macOS only) | Official GitHub release artifact (`PowerShell/PowerShell`, `v7.6.5`) | 68 MB, 183 MB extracted |

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
| Gemma 4 E4B QAT | `gemma4-e4b-qat` | 4.22 GB | 990 MB | 2.0 GiB | 128K | draft model |
| Gemma 4 12B QAT | `gemma4-12b-qat` | 6.72 GB | 175 MB | 2.3 GiB | 256K | draft model |
| Qwen 3.5 9B Q6_K | `qwen3.5-9b-q6` | 7.46 GB | 876 MB | 4.0 GiB | 256K | — |
| Qwen 3.8 27B UD-Q3_K_XL | `qwen3.8-27b-q3` | 13.15 GB | 885 MB | 8.0 GiB | 256K | embedded |
| Gemma 4 26B-A4B QAT | `gemma4-26b-a4b-qat` | 14.25 GB | 1.19 GB | 2.7 GiB | 256K | draft model |
| Qwen 3.6 35B-A3B UD-Q3_K_XL | `qwen3.6-35b-a3b-q3` | 16.85 GB | 899 MB | 2.5 GiB | 256K | separate build |

The middle column is the name your harness needs — see [using it from your editor](#using-it-from-your-editor). `config/models.json` keys them slightly differently (`gemma4-e4b` rather than `gemma4-e4b-qat`); the key is only for `serve.ps1 -ModelKey`.

All of them are Unsloth quantizations with an optional vision encoder. **KV figures are at `f16`**, so they are 3.2× the `q4_1` numbers an earlier revision of this table carried — the default changed and the table did not follow it. The 35B-A3B is the one model that ships with a quantized cache, and only on macOS; see below. The whole catalog, weights plus encoders plus draft models, is about 69 GB on disk — you only ever download what you pick.

### A model can pick its own KV cache type

Three layers, and the last one wins:

| Layer | Where | What it decides |
| --- | --- | --- |
| Global | `cacheType` in `config/server.json` | The default for every model |
| Per model | a `cache` block in `config/models.json`, optionally per platform | The default for that model |
| Per run | the launcher's KV cache prompt | What actually loads |

The first two only ever set what is **pre-selected** in the menu. Pressing Enter accepts it, so a catalog that never mentions the launcher still gets exactly the type it asked for.

A model overrides the global default when the type is what decides whether a context is reachable at all:

```json
"cache": {
  "macos":   { "type": "q8_0" },
  "windows": { "type": "f16" }
}
```

The 35B-A3B is the only entry that does this, and the two halves have different reasons. Its weights are 15.7 GiB before the encoder's 858 MiB, so on a 24 GiB Mac — where Metal recommends 17.8 GiB — `f16` leaves no room for a cache at any length, while `q8_0` halves it and brings 32K and 48K within reach. On Windows it stays `f16` deliberately: quantizing the cache on CUDA was measured on this build at 40 tok/s prompt processing against 3355, because CUDA flash attention has no quantized-KV kernel and attention silently moves to the CPU. **A card big enough for this model is a card big enough for an `f16` cache.**

`q8_0` on Metal is **not measured**. The collapse above is a CUDA finding; whether Metal has the same hole nobody here has checked. Run it once each way and compare tokens per second before trusting it — the KV cache prompt exists so that takes two runs rather than an edit to a config file.

Two things worth reading off that table:

- **The 35B-A3B is the largest model here and has a cheaper cache than the 27B.** It is both a mixture of experts (8 of 256 active, all 256 resident) and a hybrid attention/SSM, and it holds two KV heads per attention layer where the 9B and 27B hold four. Ten of its forty layers keep a cache, at 10240 elements per token against the 27B's 32768. Weights are what costs you here, not context.
- **The 26B-A4B has the heaviest Gemma weights and the lightest KV cache.** It is a mixture of experts: 8 of 128 experts run per token but all 128 must be resident, so you pay the full 14.25 GB for weights while its 5 context-scaling layers keep the cache tiny. On a 16 GB card it fits with vision at 64K, with about 350 MiB to spare.
- **The E4B's KV figure is measured, not derived.** Its header implies 1.10 GiB at 128K; the card says 0.64 GiB. `shared_kv_layers = 18` is the reason, and the header never says which layers share, so the catalog carries the measured coefficient.

To add your own model, put an entry in `config/models.json` with its URL, SHA-256 and the two KV coefficients derived from its GGUF header. Every existing entry records its derivation — and, where measurement disagreed with the header, what was measured and why — in a `detail` block.

## Configuration

Everything tunable lives in `config/`. No values are hardcoded in the scripts.

| File | Defines |
| --- | --- |
| `config/models.json` | Catalog: alias, URL, SHA-256, geometry read from the GGUF header, and the publisher's sampling profiles |
| `config/backends.json` | Backends: platform, URL, SHA-256, extracted file counts, whether MTP pays off |
| `config/server.json` | Host, port, default KV type and the types the launcher offers, per-platform budget constants, overheads, context options, provider names |
| `config/runtimes.json` | Node and Pi, vendored into a Windows package: path, entrypoint, file counts |
| `config/bootstrap.json` | The PowerShell the macOS entry points fetch. Read by `zsh` with `jq` before any PowerShell exists |

Each backend declares the `platform` it runs on and the launcher only offers the ones that match, so a Mac is never shown a CUDA package it cannot execute and Windows is never shown Metal.

The `platforms` block in `config/server.json` holds the two constants that turn a reported device total into a budget, and they are per platform because the reported total does not mean the same thing on both. See [step 1](#1-architecture).

The `harness` section defines the name each tool uses for the local provider. Match it to what you already have — registering a second name creates a duplicate provider pointing at the same server.

Each model may carry its own `overhead` block with measured `baseMiB` and `visionMiB` values. When it does, those win over the defaults in `config/server.json`. A new model works without one; it just inherits constants measured on something else, so measure it if the numbers matter to you.

### Sampling belongs to the model

Every model carries the sampling profiles its publisher recommends, and the launcher sends all six values to `llama-server` explicitly. Nothing is inherited from a llama.cpp default, because those defaults match no model here and can change between releases:

| Model | Active profile | temp | top-p | top-k | min-p | presence | repeat |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen 3.5 9B | `coding` | 0.6 | 0.95 | 20 | 0.0 | 0.0 | 1.0 |
| Qwen 3.8 27B | `coding` | 0.6 | 0.95 | 20 | 0.0 | 0.0 | 1.0 |
| Gemma 4 (all three) | `default` | 1.0 | 0.95 | **64** | 0.0 | 0.0 | 1.0 |
| *anything with no block* | `llamacpp-defaults` | 0.8 | 0.95 | 40 | 0.05 | 0.0 | 1.0 |

**`top-k` is 20 for Qwen and 64 for Gemma.** One number cannot serve both families, which is the whole reason this moved out of `serve.ps1`.

Each model also carries the alternatives, so switching is one word rather than six numbers. Qwen ships `coding`, `thinking` and `instruct`:

```json
"sampling": {
  "profile": "coding",
  "profiles": { "coding": { ... }, "thinking": { ... }, "instruct": { ... } }
}
```

Two things are worth knowing before you trust the table:

- **Only Qwen 3.5 publishes a profile for coding.** The Qwen 3.8 `coding` profile is the one extrapolated set of numbers in the catalog, and it is labelled as such in the file: Qwen 3.5 documents its coding profile as its thinking profile with the temperature dropped to 0.6 and the presence penalty zeroed, and the same adjustment is applied here. Switch that model to `thinking` for numbers its publisher actually states.
- **Google publishes only `temperature`, `top_p` and `top_k` for Gemma 4.** The other three are pinned here to the values that disable them, rather than left out, because `llama-server` defaults `min-p` to 0.05 and inheriting a filter nobody asked for is worse than switching it off deliberately.

Thinking mode is a separate control from sampling and the launcher does not set it: Gemma 4 and Qwen 3.5 use `--chat-template-kwargs '{"enable_thinking":false}'`, Qwen 3.8 uses `--chat-template-kwargs '{"reasoning_effort":"medium"}'` with `xhigh`, `medium`, `low` and `none` available.

### How long a reply the harness is allowed

A reply and the prompt that provoked it come out of the same window, so the limit handed to a harness is a **share of the context you actually loaded**, not a number frozen in the catalog. `harness.maxOutputPercent` in `config/server.json` sets the share and each model's `maxTokens` caps it:

| Context loaded | 32K | 48K | 64K | 128K | 256K |
| --- | --- | --- | --- | --- | --- |
| Output limit written to the harness | 8192 | 12288 | 16384 | 32768 | 32768 |

At 25 % a coding agent keeps three quarters of the window for the files and history it has to send, and 32K lands on the 8192 this project shipped before. From 128K up the model's ceiling binds instead.

**A longer reply costs no memory.** The KV cache is allocated for the whole `--ctx-size` when the model loads; generating fills it rather than growing it. Measured on Metal with the 27B at 32K:

| | Resident |
| --- | --- |
| After load, nothing generated | 15438 MiB |
| After 100 tokens | 15603 MiB |
| After 2000 tokens | 15318 MiB |

Twenty times the output, no more memory — the variation is ordinary page-cache noise. What a long reply spends is context.

Only Qwen 3.5 publishes a figure to cap against, *"Adequate Output Length: 32,768 tokens for most queries"*. Qwen 3.8 borrows it as the same family and generation; Google publishes nothing of the kind for Gemma 4, so those ceilings are chosen rather than stated. Each `maxTokens` says which it is.

---

## What is different on macOS

Everything above works the same way on both systems, with three exceptions worth knowing before you rely on the numbers.

### The server has no window of its own

On Windows the server opens its own console and stays there. macOS has no equivalent short of driving Terminal through AppleScript, which raises a permission prompt you can refuse, so the server is detached instead and writes to a log next to the launcher:

```zsh
tail -f llama-server.log        # what the server is printing
tail -f llama-server.err.log    # where llama.cpp puts its progress
pkill -x llama-server           # stop it
```

It is started under `nohup`, so it survives the terminal that launched it closing — the same "start a session, close it, the model is still loaded" behaviour the Windows window gives you.

### The fit table is not calibrated on Metal yet

This is the honest limitation. The KV column is **exact on both platforms**: it comes from the two coefficients read out of the GGUF header, and that arithmetic has nothing platform-specific in it. The *estimated total* adds a per-model overhead constant, and every one of those was measured against `nvidia-smi` on CUDA.

Until someone measures them on Apple Silicon, `llmfit` falls back to the CUDA constants and says so on screen rather than implying an accuracy nobody verified:

```
  NOTE: no overhead measured on this platform yet, so the CUDA constants are
  standing in. The KV column is exact; the estimated total is a guess until
  someone measures it here and adds an overhead.macos block to models.json.
```

The gap is not cosmetic. Those constants are negative for three models, which encodes "part of this file never reaches VRAM" — and on unified memory there is no transfer for that statement to be about. To fix it for a model, run it, read the real usage, and add the measured values to its `overhead` block:

```json
"overhead": {
  "baseMiB": -389,
  "visionMiB": 251,
  "macos": { "baseMiB": 0, "visionMiB": 0 }
}
```

The platform block wins when present; without one the top-level numbers are used and the warning appears.

### Speculative decoding is available, and on one model it was measured to be pointless

Metal declares `speculativeDecoding: true`, so the option exists. What each model does with it is decided in its own `mtp` block, which may carry a sub-block named after the platform. Nothing about MTP travelled between CUDA and Metal — not what it costs, not how far up the context range it survives, not whether it is worth having:

```json
"mtp": {
  "mode": "embedded",
  "costMiB": 1200,
  "autoEnable": false,
  "macos": {
    "autoEnable": true,
    "costMiB": 817,
    "maxContext": 32768
  }
}
```

The one model measured so far is the **Qwen 3.8 27B**, on a 24 GiB M4 Pro with vision:

| | 32K, no MTP | 32K, MTP |
| --- | --- | --- |
| Resident | 15717 MiB | 16534 MiB |
| Generation | **10.7 tok/s** | **10.6 tok/s** |

Draft acceptance was 0.93 with a mean draft length of 3.79 — so the drafting works, and the speedup still does not arrive. The likely reason is architectural rather than a tuning failure: this is a hybrid attention/SSM model where 3 layers in 4 hold recurrent state, and an SSM layer walks its state forward one position at a time. Verifying 3.79 drafted tokens in one pass therefore still costs 3.79 sequential state updates, which is exactly the work speculative decoding exists to avoid. That is the standing explanation, not something measured directly, and it does not carry over to the Gemma 4 models — they are pure sliding-window attention with a small companion draft file, an entirely different bet, still untested here.

**`maxContext` is a measured ceiling, and it is doing real work.** `costMiB` is modelled as a flat number, but an embedded draft context carries its own KV cache and therefore grows with context. At 48K with vision the memory check would have waved MTP through; the configuration then loads, answers `/health` with `ok`, and dies on its first decode:

```
error: Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)
llama_decode: failed to decode, ret = -3
```

Loading successfully is not proof that a configuration fits on Metal. Until the cost is modelled per token the way the main KV cache already is, the honest bound is the longest context somebody actually ran, and raising it means running the thing you are raising it for.

---

## Just chatting

If you only want to talk to the model, pick **Browser** and `llmfit` opens it for you. `llama.cpp` compiles a chat UI into the server itself, so it is already running at:

```
http://127.0.0.1:8080
```

No install, no Docker, no extra process. It handles conversations, system prompts, sampling settings, and file attachments — with a vision model loaded the server advertises image, video and audio input, and the UI exposes them. It ships a web manifest too, so your browser can install it as a standalone app.

That URL is printed at the end of every run whatever harness you chose, because the UI is up regardless.

Want chat history synced across devices, document search or multiple users? Point **Open WebUI** or any other OpenAI-compatible front end at `http://127.0.0.1:8080/v1` with any value as the API key. `llmfit` does not bundle one: they need Docker or a Python environment, which is exactly the install step this project exists to avoid.

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

Every model in the catalog has been measured against `nvidia-smi` on a 16 GB NVIDIA card (an RTX 5070 Ti). **Every figure in this section is CUDA**; see [what is different on macOS](#what-is-different-on-macos) for what that means when you run on Metal. A sample:

| Configuration | Estimated | VRAM used | Generation |
| --- | --- | --- | --- |
| Qwen 27B + vision, 64K | 14564 MiB | 14564 MiB | 50.8 tok/s |
| Qwen 27B no vision, 128K | 14708 MiB | 14708 MiB | — |
| Qwen 9B + vision, 64K | 8424 MiB | 8424 MiB | — |
| Gemma 4 E4B + vision, 128K | 4611 MiB | 4610 MiB | 89.1 tok/s |
| Gemma 4 12B no vision, 256K | 8132 MiB | 8132 MiB | — |
| Gemma 4 26B-A4B + vision, 64K | 15644 MiB | 15644 MiB | — |

Across 18 configurations spanning all five models, two vision settings and context lengths from 64K to 256K, the **worst error is 1 MiB**.

The 27B at 32K with an `f16` cache measures 14254 MiB against an estimate of 14196, and runs at 1542 tok/s prompt and 42.7 tok/s generation — on the GPU, where it belongs.

Every figure comes from running `serve.ps1` itself and reading `nvidia-smi`, never from an ad-hoc `llama-server` invocation. That matters: an earlier round of Qwen constants was fitted to hand-written commands that omitted `--parallel 1` and `--image-min-tokens`, and it overestimated by 800 MiB.

Getting there took two corrections that no amount of reading the header would have produced:

- **Gemma 4 E4B holds fewer KV caches than its header implies.** The arithmetic says 7 full-attention layers; the measured delta between 64K and 128K says 4. `shared_kv_layers = 18` is why — three of the seven reuse another layer's cache. The header states how many layers share, never which, so only measurement resolves it.
- **E4B keeps about 1.2 GB of its weights in system RAM.** It is a MatFormer: its per-layer embeddings never become resident on the GPU. Its calibrated base overhead is therefore *negative*, which is the honest way to encode "part of this file is not in VRAM".

Overhead constants per model, all measured:

| Model | Base | With vision | MTP |
| --- | --- | --- | --- |
| Qwen 3.5 9B | −455 MiB | +251 MiB | — |
| Qwen 3.8 27B | −389 MiB | +251 MiB | +1200 MiB, embedded |
| Gemma 4 E4B | −1207 MiB | +202 MiB | +66 MiB, draft model |
| Gemma 4 12B | +347 MiB | +177 MiB | +294 MiB, draft model |
| Gemma 4 26B-A4B | +313 MiB | +142 MiB | +292 MiB, estimated |

A negative base means part of the file never reaches VRAM: metadata and tokenizer tables are counted in the file size, and for the 27B so are the `blk.64` tensors llama.cpp skips when MTP is off. A model with no measured values falls back to the defaults in `config/server.json`, which stay deliberately pessimistic.

### The same models on an integrated GPU

Everything above is CUDA. The figures below are an AMD Radeon 780M — the integrated GPU of a Ryzen APU, sharing 64 GB of DDR5 with the CPU — reached through the Vulkan backend with the device pinned. They are `llama-bench` with `-r 1` and `-fa on`, so treat them as one measurement each rather than as the calibration the CUDA numbers above received.

| Model | File | Params | pp512 | tg128 |
| --- | --- | --- | --- | --- |
| Gemma 4 E4B | 3.91 GiB | 7.46 B | **449.70 tok/s** | 13.96 tok/s |
| Gemma 4 12B | 6.24 GiB | 11.91 B | 166.27 tok/s | 6.77 tok/s |
| Gemma 4 26B-A4B | 13.26 GiB | 25.23 B | 297.05 tok/s | **17.01 tok/s** |

**The smallest model is not the fastest one to generate with.** The 26B-A4B is a mixture of experts: 25 B parameters in the file, roughly 4 B of them touched per token. Generation is bandwidth-bound, so what it costs is the bytes read per token, not the size of the file — and on an APU the GPU has no bandwidth of its own to hide that with. The 12 B is the slowest of the three because it is dense: every one of its 11.91 B parameters is read for every token.

Prompt processing is the other way round, because it is compute-bound and batched. There the E4B wins by a wide margin, and the same E4B run on the CPU-only build of the identical release measures **98.06 tok/s pp512 and 10.74 tok/s tg64** — which is what "Vulkan is working" looks like from the outside: 4.6x the prompt throughput and 1.3x the generation.

Context depth hits the two halves very differently. E4B again, same device:

| Depth | pp512 | tg128 |
| --- | --- | --- |
| 0 | 449.70 tok/s | 13.96 tok/s |
| 8192 | 136.98 tok/s | 13.79 tok/s |
| 32768 | 59.92 tok/s | 11.05 tok/s |

Generation barely moves across 32K, which is sliding-window attention doing exactly what the catalog says it does: 35 of the 42 layers are capped at a 512-token window and never see the context grow. Prompt processing falls to a seventh, because the 7 full-attention layers are quadratic and there is no window to save them.

Loaded through `serve.ps1` at 48K with the device pinned, both models keep the discrete card at **0 MiB**:

| Configuration | On the iGPU | Prompt, 5125 tokens | Generation |
| --- | --- | --- | --- |
| E4B no vision, 48K | 5463 MiB | 233.11 tok/s | 15.97 tok/s |
| 26B-A4B no vision, 48K | 15519 MiB | 206.19 tok/s | 17.14 tok/s |

> **Speculative decoding is not merely pointless on Vulkan, it aborts.** Gemma 4 E4B with its companion draft model dies during KV allocation: `pre-allocated tensor (cache_k_l22) in a buffer (Vulkan0) that cannot run the operation (NONE)`. That is Gemma 4's shared-KV layers meeting a Vulkan buffer with no kernel for them. The launcher never offers it, because `vulkan` sets `speculativeDecoding: false`; `serve.ps1` now refuses it too, rather than letting a hand-written command reach the abort.

**MTP is charged what it actually costs**, and the two shapes are an order of magnitude apart. An embedded draft context is built against the whole model — 1200 MiB on the 27B — while a companion draft file costs little more than its own weight. Counting it as free is how a configuration reports `FITS` and then spills into system RAM, where prompt processing collapses from hundreds of tokens per second to tens.

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
3. Run `VERIFY.cmd` (or `VERIFY.command`) and wait for confirmation. It re-checks the SHA-256 of every model and binary, which is what catches a copy that was silently truncated.
4. Run `INSTALL-PATH.cmd` (or `INSTALL-PATH.command`) once.
5. Open a new terminal and run `llmfit`.

The catalog is portable but the binaries are not: a folder carried from Windows has the CUDA, Vulkan and CPU backends, and a Mac needs the Metal one. The models are the expensive part and they are shared, so the target machine downloads 11 MB of backend and gets going. Copying between two machines of the same kind needs no download at all.

`VERIFY` only checks what belongs to the system it runs on, so a Windows package verified on a Mac reports the models as fine and the Metal backend as not installed, rather than calling the CUDA one missing.

---

## Troubleshooting

**A large download was interrupted.** Run `llmfit` again. It validates by SHA-256, not by file existence: a partial file is resumed, and if it still does not match it is re-downloaded clean. Nothing to delete by hand.

**My GPU is not detected.** Set `LLMFIT_DEBUG=1` to see the raw `llama-server --list-devices` output per backend.

**It says TIGHT and I want headroom.** Lower `cacheType` to `q4_0` in `config/server.json`, or pick the no-vision variant.

**It loaded, but prompt processing is in the tens of tokens per second and the GPU sits near idle.** Check `cacheType` in `config/server.json`. A quantized KV cache has no CUDA flash-attention kernel, so attention runs on the CPU while the weights stay parked in VRAM — memory looks healthy, utilisation does not. Set it back to `f16` and shorten the context instead.

If the cache is already `f16`, then it overflowed and llama.cpp is running layers from system RAM. Free the card — a browser with hardware acceleration costs hundreds of megabytes — and pick a smaller context or drop vision.

**"A local llama-server is already running."** Answer `Y` to replace it, or `n` to keep using the one already up.

**Pi will not start: `npm error ... install failed`.** Pi *installs* every package listed under `packages` in `~/.pi/agent/settings.json` each time it launches, and one that fails to build stops it from opening at all. `llmfit` never adds packages — `piPackages` is empty on purpose — but it will not silently delete ones you put there either. To make it drop a specific package the next time you pick Pi, name it under `piPackagesRetired` in `config/server.json`:

```json
"piPackagesRetired": ["npm:the-broken-package"]
```

Or edit `settings.json` yourself. To check whether Pi is healthy without opening the TUI:

```powershell
pi --provider llama-cpp --model qwen3.5-9b-q6 -p "say OK"
```

**Restore my previous configuration.** Every file the launcher touched has a `.llmfit-backup` copy next to it, including `~/.zshrc` on macOS.

**macOS: `zsh: permission denied: ./START.command`.** The executable bit did not survive however the folder reached you. `chmod +x START.command VERIFY.command CLEAN.command INSTALL-PATH.command bin/llmfit`.

**macOS: the launcher refuses to start on an Intel Mac.** Only the `macos-arm64` build of `llama.cpp` is in the catalog. Add the `macos-x64` archive to `config/backends.json` with its SHA-256 if you need it.

**macOS: I already have PowerShell and do not want another copy.** You will not get one. A `pwsh` on your `PATH` reporting version 7 or newer is used as is and nothing is downloaded.

**macOS: the estimated total looks wrong.** It probably is, by some amount nobody has measured. Read [what is different on macOS](#what-is-different-on-macos): the KV column is exact, the overhead constants behind the total are borrowed from CUDA.

**Stop the server.**

```powershell
Get-Process llama-server | Stop-Process -Force   # Windows
```

```zsh
pkill -x llama-server                            # macOS
```

---

## Roadmap

- Overhead constants measured on Apple Silicon, so the macOS fit table is calibrated rather than borrowed
- Whether speculative decoding pays off on Metal, measured rather than assumed
- Linux (CUDA / ROCm / Vulkan)
- Intel Macs (the `macos-x64` build)
- More models in the catalog

---

## License

The launcher is released under the MIT License. `llama.cpp` is downloaded, not vendored, and remains under its own license; model weights belong to their respective publishers.
