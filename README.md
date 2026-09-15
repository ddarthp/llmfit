# llmfit

**Portable, hardware-aware local LLM server for coding agents.**

`llmfit` measures what your machine can actually hold, lets you pick a model, vision and context that fit, and starts `llama.cpp`. Then it either opens a chat window or hands you the command line to point Pi, OpenCode or Codex at the server — in whatever folder you want to work in.

Ask for it in a terminal, or from [a web panel](#the-panel) built for a controller and a touchscreen — the same decisions and the same arithmetic, on a page you can also open from your phone.

No install step, no build, no Git needed on the target machine. Copy the folder, run one command.

> **Status:** Windows (CUDA / Vulkan / CPU), macOS on Apple Silicon (Metal) and Linux on x64 and arm64 (Vulkan / CPU), including SteamOS on a 24 GB handheld, where the largest model in the catalog fits with vision and the panel goes in the Steam library as a non-Steam game. Overhead constants are calibrated on CUDA; on Metal and Linux they are borrowed for every model but one, and the launcher says so on screen.

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
- [What is different on Linux](#what-is-different-on-linux)
- [Just chatting](#just-chatting)
- [The panel](#the-panel)
- [On your network](#on-your-network)
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
- It enables speculative decoding only when the model can actually draft — with its own layers, or with a model-free method that needs none — and the memory is there to spare.

The result is a fit table you can trust *before* you wait three minutes for a 13 GB model to load.

---

## Requirements

| | Windows | macOS | Linux |
| --- | --- | --- | --- |
| OS | Windows 10 / 11 (x64) | macOS on Apple Silicon (M1–M4) | any distro, x64 or arm64 |
| Runtime | PowerShell 5.1, the one bundled with Windows | zsh, and PowerShell 7 downloaded on first run | bash, `curl`, `tar`, `jq`, and PowerShell 7 downloaded on first run |
| GPU | Optional. NVIDIA via CUDA, AMD/Intel via Vulkan, or CPU only | Metal, always present | Optional. AMD/Intel/NVIDIA via Vulkan, or CPU only |
| Disk | 4.2 GB for the smallest model without vision, ~87 GB for the whole catalog | the same, plus 183 MB for PowerShell | the same, plus 170 MB for PowerShell |
| Network | Only on first run, to download the model and the backend | the same | the same |
| Panel | Any browser | Any browser | Any browser; on SteamOS it uses Steam's own, or Firefox in kiosk mode |

Nothing else, and nothing installed. The harnesses (Pi, OpenCode, Codex) are optional: without one, `llmfit` still runs the server and you point anything OpenAI-compatible at it.

**On macOS and Linux the launcher needs PowerShell, and it fetches its own.** There is no runtime all three systems ship — Windows has no shell, macOS and a stock Linux have no PowerShell — so the alternative was maintaining the fit arithmetic three times and letting the implementations drift apart. Instead `llmfit` stays one codebase and treats PowerShell as one more dependency: downloaded, checked against its SHA-256, extracted into `tools/pwsh`, never installed. Nothing is written outside the folder, no Homebrew, no `apt`, no admin rights. A `pwsh` already on your `PATH` is used as is and nothing is downloaded.

Intel Macs are not supported: the catalog carries the `macos-arm64` build of `llama.cpp` only.

**What Linux does not have yet.** There is no CUDA or ROCm backend in the catalog: an NVIDIA card runs through Vulkan here like any other, and ROCm is blocked by the runtime rather than by the catalog — see [what is different on Linux](#what-is-different-on-linux) for the measurements behind that. The overhead constants behind the estimated totals were measured on CUDA under Windows, so on Linux the KV column is exact while the estimated total is borrowed for every model except `qwen36-35b-a3b-mtp`, which was measured there. `config/server.json` carries a smaller safety margin on Linux than on Windows, because Linux fails an allocation that does not fit instead of quietly paging it into system RAM.

### What your machine has to be

The name of the GPU is the wrong question. The catalog's ceiling is **Qwen 3.6 35B-A3B at UD-Q3_K_XL** — a 16 GB file that holds around **17.3 GiB** resident with its vision encoder and a 32K `q8_0` cache, and **18.0 GiB** with the MTP draft context on top. Everything below follows from that number and from the measurements in [reference measurements](#reference-measurements):

| What you have | Examples | The 35B-A3B Q3 |
| --- | --- | --- |
| 8–12 GB discrete | RTX 3060 12 GB, 4060 Ti, 5060 Ti, Arc A770 | No. Qwen 3.5 9B and Gemma 4 E4B / 12B are the range |
| 16 GB discrete | RTX 4080, 5070 Ti, 5080 | No. The 27B Q3 with vision at 64K is the ceiling here, measured at 14564 MiB |
| 24 GB+ discrete | RTX 3090, 4090, 5090 | Yes, with room left for vision, a draft context and a longer window |
| 24 GB+ unified, **on Linux** | ROG Ally X, ROG Xbox Ally X (24 GB), Legion Go S (32 GB), any Ryzen APU desktop or mini-PC with 24 GB or more | Yes, and measured — see [what is different on Linux](#what-is-different-on-linux) |
| 24 GB+ Apple Silicon | M1–M4 with 24 GB or more | Yes, against a budget of roughly 74 % of RAM — see [what is different on macOS](#what-is-different-on-macos) |

A smaller machine is not shut out of anything: every model in the catalog is offered at whatever context actually fits it, and the fit table says so before you download a byte.

**On a handheld, that row says *on Linux* on purpose.** A handheld has no dedicated VRAM — the GPU and the CPU share one pool — so how much of 24 GB a Vulkan process may actually hold is a driver and OS decision rather than a hardware one, and the two systems decide it differently:

- **Linux and SteamOS** reach the amdgpu GTT pool. On the 24 GB Z1 Extreme this launcher was built on, Vulkan reports **19.6 GiB** and the 35B-A3B with its encoder takes 16.9 of it. It fits, it stays on the iGPU, and speculative decoding pays: **28.2 → 37.5–38.3 tok/s**.
- **Windows** hands out the carve-out the BIOS or Armoury Crate sets, plus whatever WDDM will lend on top — and WDDM will not let one process keep the last of what it lent. It pages the excess into system RAM instead, with no error and no way for the launcher to see it, or the allocation fails outright. A configuration that runs on SteamOS can therefore crawl or die on the same handheld under Windows.

So: a 24 GB handheld running SteamOS or any Linux distribution runs the largest model in this catalog with vision and 32K of context. The same handheld on Windows is a smaller machine, and the fit table will tell you how much smaller once the backend reports its budget.

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

**Linux**

```bash
git clone https://github.com/ddarthp/llmfit.git
cd llmfit
./START.sh
```

On first run it downloads the backend and the model you pick, verifying both by SHA-256. On macOS and Linux it fetches PowerShell first, the same way.

To get a global `llmfit` command, run `INSTALL-PATH.cmd` (Windows), `INSTALL-PATH.command` (macOS) or `INSTALL-PATH.sh` (Linux) once and open a new terminal.

**Or skip the terminal entirely.** `PANEL.sh` (`PANEL.command`, `PANEL.cmd`) serves the same decisions as a page that a controller or a thumb can drive, and on SteamOS one more command puts it in your Steam library:

```bash
./PANEL.sh                                      # open the panel here
./tools/pwsh/pwsh -File add-to-steam.ps1        # and put it in Steam, artwork included
```

See [the panel](#the-panel).

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
 1) Qwen 3.5 9B Q6_K             with vision  7.8 GiB to download  ngram-map-k available
 2) Qwen 3.5 9B Q6_K             no vision    6.9 GiB to download  ngram-map-k available
 3) Qwen 3.8 27B UD-Q3_K_XL      with vision  13.1 GiB to download  ngram-map-k available
 4) Qwen 3.8 27B UD-Q3_K_XL      no vision    12.2 GiB to download  ngram-map-k available
 5) Qwen 3.6 35B-A3B UD-Q3_K_XL  with vision  16.5 GiB to download
 6) Qwen 3.6 35B-A3B UD-Q3_K_XL  no vision    15.7 GiB to download
 7) Qwen 3.6 35B-A3B UD-Q3_K_XL (MTP build) with vision  weights 16.0 GiB + vision 858 MiB  MTP available
 8) Qwen 3.6 35B-A3B UD-Q3_K_XL (MTP build) no vision    weights 16.0 GiB  MTP available
 9) Gemma 4 E4B QAT              with vision  weights 3.9 GiB + vision 944 MiB  MTP available
10) Gemma 4 E4B QAT              no vision    weights 3.9 GiB  MTP available
11) Gemma 4 12B QAT              with vision  6.4 GiB to download  MTP available
12) Gemma 4 12B QAT              no vision    6.3 GiB to download  MTP available
13) Gemma 4 26B-A4B QAT (MoE)    with vision  14.4 GiB to download  MTP available
14) Gemma 4 26B-A4B QAT (MoE)    no vision    13.3 GiB to download  MTP available
```

Two sizes, two meanings. **weights** is what is on this disk right now; **to download** is what the catalog declares the file to be, so a choice states its cost before you commit to it rather than after. Those declared figures come from the host — `curl -sIL` and the `x-linked-size` header — and they are the SHA-256's companion, never its replacement: the hash still decides when a file is complete.

Turning vision off skips the `mmproj` file. That saves its weight — between 175 MB and 1.2 GB depending on the model — plus the encoder's compute buffers, which are measured per model and listed under [reference measurements](#reference-measurements).

### 3. KV cache and context

Two questions, in that order, because the answer to the first sizes the table for the second.

```
KV cache type. The fit table below is sized with what you pick here.
 1) f16   2       bytes/element   full precision, attention stays on the GPU   (default, from config/server.json)
 2) q8_0  1.0625  bytes/element   QUANTIZED: attention falls back to the CPU on CUDA
KV cache [1]:
```

The warning next to `q8_0` is written per platform, because what it costs is not a property of the option. On CUDA it is the 84× collapse below. On Linux the line reads `collapses prompt on CUDA; 7% on Vulkan/gfx1103`, which is a measurement rather than a caution — see [what is different on Linux](#what-is-different-on-linux). On Metal it says the cost is unmeasured, because it is.

Pressing Enter takes the default, which is whatever the catalog resolves for this model on this platform — so the launcher behaves exactly as it did before this menu existed. The list itself is `cacheTypeOptions` in `config/server.json`. Read the next section before picking option 2: on CUDA it was measured, and it is a bad trade.

Then the table, computed for the model and vision setting you just chose, against the budget of the device you picked. Here is the tightest case — the 27B without vision on a 16 GB card:

```
KV cache in f16, 2 bytes per element (full precision, attention stays on the GPU).
hybrid attention/SSM: 16 of 65 layers hold a KV cache.

 1)   32K   KV  2.0 GiB   estimated total  13.9 GiB   TIGHT
 2)   48K   KV  3.0 GiB   estimated total  14.9 GiB   TOO BIG
 3)   56K   KV  3.5 GiB   estimated total  15.4 GiB   TOO BIG
 4)   64K   KV  4.0 GiB   estimated total  15.9 GiB   TOO BIG
 5)   72K   KV  4.5 GiB   estimated total  16.4 GiB   TOO BIG
 6)   80K   KV  5.0 GiB   estimated total  16.9 GiB   TOO BIG
 7)   96K   KV  6.0 GiB   estimated total  17.9 GiB   TOO BIG
 8)  112K   KV  7.0 GiB   estimated total  18.9 GiB   TOO BIG
 9)  128K   KV  8.0 GiB   estimated total  19.9 GiB   TOO BIG
10)  160K   KV 10.0 GiB   estimated total  21.9 GiB   TOO BIG
11)  192K   KV 12.0 GiB   estimated total  23.9 GiB   TOO BIG
12)  224K   KV 14.0 GiB   estimated total  25.9 GiB   TOO BIG
13)  256K   KV 16.0 GiB   estimated total  27.9 GiB   TOO BIG
```

That is what a 27B costs on 16 GB: 32K and nothing more. The Gemma 4 12B on the same card reports `FITS` at every length, 256K included, at 10.9 GiB.

The rungs are close together at the bottom and widen at the top, and that column is the reason. KV cost is linear in context, so the gap between two rungs *is* what stepping up costs you: on this model, 8K of context is 512 MiB of VRAM. A ladder that went 64K then straight to 128K was asking for 4 GiB in one step, so a card with room for 96K got offered 64K and nothing in between. Below 128K the steps are 8K and 16K, where consumer cards actually run out; above it they widen to 32K, because a machine that reached 128K has headroom and a coarse rung costs it nothing.

Pick `q8_0` at the prompt above and the KV column halves — 1.1 GiB at 32K, 2.1 at 64K — which is exactly what makes the option tempting and exactly why the warning is next to it.

The shorter options exist because context is the cheapest thing to give up. Halving it frees real memory and keeps the model on the GPU, which quantizing the cache does not. The list is `contextOptions` in `config/server.json`, and every rung above a model's `maxContext` is dropped before the table is drawn — the Gemma 4 E4B stops at 128K, so it never sees the last four.

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

Prefer a shorter context over a quantized cache. The fit table offers 32K, 48K, 56K and 72K through 112K precisely so you can trade context for memory without leaving the GPU.

### 4. Speculative decoding

Decided automatically, and it tells you why:

- Only if the model can draft at all. **With draft weights** — an `mtp` block — in three shapes:
  - **Embedded** — the nextn layers live inside the model file. Qwen 3.8 27B carries `nextn_predict_layers = 1`; so does the MTP build of the 35B-A3B.
  - **Separate draft model** — every Gemma 4 ships an `mtp-*.gguf` companion, downloaded on demand and passed with `--spec-draft-model`.
  - **Separate full build** — Qwen 3.6 35B-A3B publishes MTP as a different 16 GB model file (41 blocks against 40, 753 tensors against 733). A 16 GB download is a decision at step 2 and not a toggle at step 4, so it is its own catalog entry, `qwen36-35b-a3b-mtp`, and the plain entry carries a comment saying where it went.

  Or **without any weights at all** — a `speculative` block, where `llama-server` drafts from the tokens already inside the context window and no file is downloaded. Two models use `ngram-map-k`. On the Qwen 3.5 9B, measured on Metal at temp 0, it reaches **1.26× on a prompt with text to copy** and **1.00× on one without**, with byte-identical output either way. On the Qwen 3.8 27B it replaced embedded MTP outright — 13.59 tok/s against 10.78 at 8K, 10.57 against 8.92 at 32K with vision — after MTP measured *slower* than no speculation at all on the same model. `ngram-cache` was the one variant measured below baseline on the 9B (0.93×), so it is deliberately not the default. No prompt-processing gain is claimed: an apparent one turned out to be page-cache warm-up on the first run.
- Only on a backend that declares `speculativeDecoding: true` in `config/backends.json`. CUDA, Metal and the Linux Vulkan build do. **Windows Vulkan does not**, and that is measured rather than assumed: there the cost of maintaining the draft context cancels the gain, and a Gemma 4 companion draft aborts outright during KV allocation.
- Only up to a `maxContext` when the catalog records one. That ceiling is the longest context somebody actually ran, not a derived limit — see [what is different on macOS](#what-is-different-on-macos).
- Only if its measured cost fits in what is left, with a margin. See the [overhead table](#reference-measurements) for what each model charges. A method that loads no weights costs nothing, so it reserves nothing and is never turned down for memory.
- Only if the catalog lets it. `autoEnable: false` turns it off for a model regardless, and it can be set per platform. The Gemma entries turn it off on Linux, where the companion draft runs but buys nothing; the 27B's `mtp` block is off everywhere now that its `speculative` block supersedes it.

When it is off, `--spec-type none` is passed explicitly, and when it is on the status line names the method that was resolved rather than calling everything MTP. A state shown on screen should be controlled by the launcher, not inherited from a default that can change between releases.

**One configuration in this catalog is measured to pay, and it is worth knowing which.** The MTP build of the 35B-A3B, on Vulkan and an RDNA3 iGPU, at 32K with vision and a `q8_0` cache: **28.2–28.6 tok/s without speculation against 37.5–38.3 with**, at draft acceptance 0.71–0.73. Everything else here either loses, lands inside noise, or has not been measured on the hardware you are about to run it on.

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

| Windows | macOS | Linux | What it does |
| --- | --- | --- | --- |
| `llmfit` | `llmfit` | `llmfit` | The interactive launcher. Available globally after the PATH installer |
| `START.cmd` | `START.command` | `START.sh` | Same launcher, without touching `PATH`. Double-click friendly |
| `INSTALL-PATH.cmd` | `INSTALL-PATH.command` | `INSTALL-PATH.sh` | Puts the launcher on your `PATH`. Run once, no admin rights |
| `VERIFY.cmd` | `VERIFY.command` | `VERIFY.sh` | Checks the integrity of everything installed |
| `CLEAN.cmd` | `CLEAN.command` | `CLEAN.sh` | Deletes already-extracted archives to reclaim disk |
| `PANEL.cmd` | `PANEL.command` | `PANEL.sh` | The same decisions as a web page, for a controller or a phone. See [the panel](#the-panel) |
| — | — | `add-to-steam.ps1` | Puts `PANEL.sh` in the Steam library as a non-Steam game, artwork included |

On Windows the PATH installer adds `bin\`, `tools\node` and Pi to the user `PATH` through the registry. On macOS and Linux it writes a marked block adding `bin/` only, into `~/.zshrc` under zsh and into `~/.bash_profile` (macOS) or `~/.bashrc` (Linux) under bash — which file bash reads is not the same on the two, since a macOS terminal opens a login shell and a Linux one does not. `tools/node` and `tools/pi` are runtimes a Windows package vendors so an offline machine can still run Pi; everywhere else Pi is an npm install like any other. The file is backed up as `.llmfit-backup` before the first write and re-running only rewrites the block.

### PowerShell scripts

| Script | Flags | Purpose |
| --- | --- | --- |
| `llmfit.ps1` | `-Help` | The launcher itself |
| `serve.ps1` | `-ModelKey` `-Backend` `-Context` `-CacheType` `-Device` `-Vision` `-Spec` | Starts `llama-server` directly, no menus. `-Spec` was called `-Mtp` while draft weights were the only method here, and that name still works as an alias |
| `verify.ps1` | `-Full` | Integrity check. `-Full` requires the whole catalog |
| `ui.ps1` | `-Port` `-WhereIsIt` | Serves the panel. `-WhereIsIt` prints the addresses and exits, which is how the launchers know where to point a browser |
| `fetch.ps1` | `-ModelKey` `-Vision` `-Spec` `-Backend` `-ProgressPath` | Downloads and verifies a configuration without loading it. Useful on its own before a trip |
| `clean.ps1` | `-IncludeLogs` `-Force` | Reclaim disk. `-Force` skips the confirmation |
| `install-path.ps1` | — | `PATH` setup |
| `add-to-steam.ps1` | `-Name` `-Target` `-Remove` `-Force` | Writes the non-Steam shortcut. Refuses while Steam is running, because Steam would discard the edit |

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

And Linux, where the backend key carries the platform and the panel is usually how you start:

```bash
# Start a specific configuration with no menus
./tools/pwsh/pwsh -NoProfile -File serve.ps1 -ModelKey qwen36-35b-a3b-mtp -Backend vulkan-linux \
  -Context 32768 -CacheType q8_0 -Vision -Spec

# Download and verify a configuration without loading it - before a trip, or overnight
./tools/pwsh/pwsh -NoProfile -File fetch.ps1 -ModelKey qwen36-35b-a3b-mtp -Vision -Backend vulkan-linux

# The panel, and where it is listening
./PANEL.sh
./tools/pwsh/pwsh -NoProfile -File ui.ps1 -WhereIsIt

# Put the panel in the Steam library (close Steam first)
./tools/pwsh/pwsh -NoProfile -File add-to-steam.ps1

# See the raw device list when GPU detection misbehaves
LLMFIT_DEBUG=1 ./START.sh

# Stop the server, and the panel
pkill -x llama-server
pkill -f ui.ps1
```

---

## What is in this repository

Plain text: eight PowerShell scripts, five shared libraries in `lib/` plus the two bootstraps, five JSON files in `config/`, the panel in `ui/`, and the `.cmd`, `.command` and `.sh` wrappers that make them double-clickable on each system. Nothing is generated, nothing is vendored, and there is no build step: the panel ships the JavaScript the browser runs, and even the Steam artwork in `ui/steam/` was written byte by byte rather than exported from a tool this project would then depend on.

| Front end | What it is |
| --- | --- |
| `llmfit.ps1` | The terminal launcher, five steps |
| `ui.ps1` + `ui/` | The panel: an `HttpListener`, one HTML page, one stylesheet, one script |
| `serve.ps1` | The server, with every flag set explicitly and no menus |
| `fetch.ps1` | Downloads and verifies without loading |
| `verify.ps1`, `clean.ps1`, `install-path.ps1`, `add-to-steam.ps1` | Integrity, disk, `PATH`, Steam |

`lib/` is what more than one front end needs, and the reason it exists at all: `fit.ps1` holds the arithmetic and returns data without printing any of it, so the terminal and the panel cannot disagree about what fits. `config.ps1` reads the catalog the same way everywhere, `artifacts.ps1` downloads and verifies, `net.ps1` answers "which address", and `harness.ps1` knows about Pi, OpenCode and Codex.

The launcher itself is one codebase. `lib/bootstrap.zsh` and `lib/bootstrap.sh` are the only part written more than once, and they duplicate no logic: they exist solely to put a PowerShell on the machine and hand over. They are separate files because zsh is the shell macOS ships and bash is the one every distro ships, which is the whole of the difference between them.

## What is *not* in this repository

No weights, no binaries, no encoders. They are downloaded on first use and verified by SHA-256 before anything is extracted or loaded.

| What | Where it comes from | Size |
| --- | --- | --- |
| Model weights (`.gguf`) | Hugging Face — `unsloth/Qwen3.5-9B-GGUF`, `unsloth/Qwen3.8-27B-GGUF`, `unsloth/Qwen3.6-35B-A3B-GGUF`, `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`, `unsloth/gemma-4-*-it-qat-GGUF` | 4.2–17.2 GB each |
| Vision encoders (`mmproj`) | The same repositories | 175 MB – 1.2 GB each |
| Speculative draft models (`mtp-*.gguf`) | The same repositories | 57–254 MB, only fetched when speculation needs one |
| `llama.cpp` binaries | Official GitHub release artifacts (`ggml-org/llama.cpp`, build `b10566`) | 13–510 MB depending on platform |
| PowerShell 7 (macOS and Linux) | Official GitHub release artifact (`PowerShell/PowerShell`, `v7.6.5`) | 68–73 MB, 170–183 MB extracted |

Every one of those is declared in `config/` with its URL and SHA-256, and the model entries now also declare the size the host reports. Nothing is fetched that the catalog did not name.

These paths are ignored by Git and never committed:

```
models/        downloads/        tools/        .gopath/
llama-server.*        llmfit-panel.log        llmfit-fetch.log
.llmfit-ui-state.json        .llmfit-ui-progress.json
.atl/        .pi/        *.llmfit-backup
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
| Qwen 3.6 35B-A3B UD-Q3_K_XL (MTP) | `qwen3.6-35b-a3b-q3-mtp` | 17.23 GB | 899 MB | 2.5 GiB | 256K | embedded |

The middle column is the name your harness needs — see [using it from your editor](#using-it-from-your-editor). `config/models.json` keys them slightly differently (`gemma4-e4b` rather than `gemma4-e4b-qat`); the key is only for `serve.ps1 -ModelKey`.

All of them are Unsloth quantizations with an optional vision encoder. **KV figures are at `f16`**, so they are 3.2× the `q4_1` numbers an earlier revision of this table carried — the default changed and the table did not follow it. The two 35B-A3B entries are the ones that ship with a quantized cache — on macOS for both, and on Linux for the MTP build, where it is measured; see below.

The whole catalog is **86 GB**: 80 GB of weights, 6 GB of encoders and 0.6 GB of draft models, plus a backend between 30 MB and 850 MB depending on the platform. You only ever download what you pick, and the sizes above are what the launcher prints next to a model you have not downloaded yet.

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

The two 35B-A3B entries are the only ones that do this, and each platform has its own reason. Their weights are 15.7 and 16.0 GiB before the encoder's 858 MiB, so on a 24 GiB Mac — where Metal recommends 17.8 GiB — `f16` leaves no room for a cache at any length, while `q8_0` halves it and brings 32K and 48K within reach. On Windows it stays `f16` deliberately: quantizing the cache on CUDA was measured on this build at 40 tok/s prompt processing against 3355, because CUDA flash attention has no quantized-KV kernel and attention silently moves to the CPU. **A card big enough for this model is a card big enough for an `f16` cache.**

The MTP build carries a third block, and it is the only one of the three that was measured where it applies:

```json
"cache": {
  "linux":   { "type": "q8_0" },
  "macos":   { "type": "q8_0" },
  "windows": { "type": "f16" }
}
```

On Vulkan, `f16` → `q8_0` costs **7% of prompt processing and 3% of generation** — 353.3 and 31.9 tok/s against 329.3 and 31.0, `llama-bench` on Gemma 4 E4B. The CUDA hole is not there. That 7% is what makes a 16 GB model fit next to its vision encoder on a 24 GB machine, and it is why that entry reaches 32K with both.

`q8_0` on Metal is still **not measured**. Run it once each way and compare tokens per second before trusting it — the KV cache prompt exists so that takes two runs rather than an edit to a config file.

Two things worth reading off that table:

- **The 35B-A3B is the largest model here and has a cheaper cache than the 27B.** It is both a mixture of experts (8 of 256 active, all 256 resident) and a hybrid attention/SSM, and it holds two KV heads per attention layer where the 9B and 27B hold four. Ten of its forty layers keep a cache, at 10240 elements per token against the 27B's 32768. Weights are what costs you here, not context.
- **The 26B-A4B has the heaviest Gemma weights and the lightest KV cache.** It is a mixture of experts: 8 of 128 experts run per token but all 128 must be resident, so you pay the full 14.25 GB for weights while its 5 context-scaling layers keep the cache tiny. On a 16 GB card it fits with vision at 64K, with about 350 MiB to spare.
- **The MTP build is the same model with its nextn layer, and it is the only entry whose speculative decoding was measured to be worth turning on.** Qwen publishes MTP for this model as a separate 17.23 GB file rather than as layers inside the standard one, which is why it is a second entry rather than a step-4 toggle. Its extra 41st block costs nothing in the target cache — llama.cpp still reports 10 cache-holding layers and 340 MiB at 32K with `q8_0` — and the draft context it builds costs a measured 801 MiB at that length. What it buys was measured on Vulkan/gfx1103 at 32K with vision: 28.2–28.6 tok/s without, 37.5–38.3 with, acceptance 0.71–0.73. See [what is different on Linux](#what-is-different-on-linux).
- **The E4B's KV figure is measured, not derived.** Its header implies 1.10 GiB at 128K; the card says 0.64 GiB. `shared_kv_layers = 18` is the reason, and the header never says which layers share, so the catalog carries the measured coefficient.

To add your own model, put an entry in `config/models.json` with its URL, SHA-256 and the two KV coefficients derived from its GGUF header. Every existing entry records its derivation — and, where measurement disagreed with the header, what was measured and why — in a `detail` block.

## Configuration

Everything tunable lives in `config/`. No values are hardcoded in the scripts.

| File | Defines |
| --- | --- |
| `config/models.json` | Catalog: alias, URL, SHA-256, geometry read from the GGUF header, and the publisher's sampling profiles |
| `config/backends.json` | Backends: platform, URL, SHA-256, extracted file counts, whether MTP pays off |
| `config/server.json` | Host, the model's port and the panel's, default KV type and the types the launcher offers, per-platform budget constants, overheads, context options, provider names |
| `config/runtimes.json` | Node and Pi, vendored into a Windows package: path, entrypoint, file counts |
| `config/bootstrap.json` | The PowerShell the macOS and Linux entry points fetch, one block per platform and architecture. Read by `zsh` or `bash` with `jq`, before any PowerShell exists |

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
| Qwen 3.6 35B-A3B, both entries | `coding` | 0.6 | 0.95 | 20 | 0.0 | 0.0 | 1.0 |
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

- **Not every `coding` profile is published.** Qwen 3.5 and Qwen 3.6 document theirs; the Qwen 3.8 one is extrapolated, and it is labelled as such in the file: Qwen 3.5 documents its coding profile as its thinking profile with the temperature dropped to 0.6 and the presence penalty zeroed, and the same adjustment is applied here. Switch that model to `thinking` for numbers its publisher actually states.
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

Everything above works the same way on every system, with three exceptions worth knowing before you rely on the numbers. The first of them applies to Linux too.

### The server has no window of its own

On Windows the server opens its own console and stays there. Neither macOS nor Linux has an equivalent that works without assuming a particular desktop or raising a permission prompt you can refuse, so the server is detached instead and writes to a log next to the launcher:

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

### Speculative decoding is available, and what pays is not what everyone assumes

Metal declares `speculativeDecoding: true`, so the option exists. What each model does with it is decided in its own block, which may carry a sub-block named after the platform — nothing about speculation travelled between CUDA and Metal, not what it costs, not how far up the context range it survives, not whether it is worth having at all.

**On the Qwen 3.8 27B, embedded MTP lost.** Measured on a 24 GiB M4 Pro against a no-speculation baseline, every run byte-identical in output:

| | Copy-heavy prompt, 8K | Nothing to copy, 8K | 32K with vision |
| --- | --- | --- | --- |
| Embedded MTP | 0.86× | 0.65× | 0.90× |
| `ngram-map-k` | **1.26×** | — | **1.18×** |

MTP costs about 805 MiB every time it is on, and the damage shrinks as context grows but never crosses into gain. The model-free method, which loads no weights and drafts from the context window, does what MTP could not on the same model and the same build: 13.59 tok/s against 10.78 at 8K, and 10.57 against 8.92 at a 32K context with the encoder loaded. So that model now declares a `speculative` block and its `mtp` block is off everywhere.

The earlier reading of this was that the architecture was to blame — a hybrid attention/SSM model walks its recurrent state forward one position at a time, so verifying a 3.79-token draft still costs 3.79 sequential state updates. That explanation is doubtful now. `ngram` is a different code path over the same layers and it works.

**`maxContext` is a measured ceiling, and it is doing real work** wherever an embedded draft is still in play. `costMiB` is modelled as a flat number, but an embedded draft context carries its own KV cache and therefore grows with context. At 48K with vision the memory check would have waved MTP through; the configuration then loads, answers `/health` with `ok`, and dies on its first decode:

```
error: Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)
llama_decode: failed to decode, ret = -3
```

Loading successfully is not proof that a configuration fits on Metal. Until the cost is modelled per token the way the main KV cache already is, the honest bound is the longest context somebody actually ran, and raising it means running the thing you are raising it for.

The one place speculation is measured to pay is the MTP build of the 35B-A3B on Linux, with real nextn layers and a 28 tok/s baseline to beat. See [what is different on Linux](#what-is-different-on-linux).

---

## What is different on Linux

Three things, and the second is the one to read before trusting a number. Everything here was measured on a Ryzen Z1 Extreme running SteamOS — an RDNA3 integrated GPU, `gfx1103`, 24 GB of shared LPDDR5 — because that is the machine the Linux support was built on.

That is a class rather than a single unit. The **ROG Ally X** is the same Z1 Extreme with the same 24 GB; the **ROG Xbox Ally X** pairs a newer RDNA3.5 iGPU with the same 24 GB and the same budget; a **Legion Go S with 32 GB** has more room again, and ships with SteamOS on some configurations. Any Ryzen APU desktop or mini-PC with 24 GB or more of system RAM lands in the same place. What they have in common is the thing that matters here: one pool of memory, and a Linux kernel willing to let a Vulkan process reach most of it.

### The catalog carries Vulkan and CPU only

No CUDA build, no ROCm build. An NVIDIA card works, through Vulkan like every other GPU, which costs speed that a CUDA build would not. Adding one is a `backends.json` entry with a URL, a SHA-256 and the file and byte counts of the extracted tree — the same five fields every other backend has — and nothing in the launcher needs to change for it.

Speculative decoding **is** on for the Linux Vulkan backend, and unlike everywhere else in this catalog it was measured to pay. Qwen 3.6 35B-A3B from its MTP build, 32K with vision and a q8_0 cache on a gfx1103 iGPU: **28.2–28.6 tok/s without, 37.5–38.3 with**, at draft acceptance 0.71–0.73 and mean draft length 3.1. That is 1.33x, above the 1.15–1.25x the vendor claims for MoE models.

A **companion draft file** is a different story, and it has now been measured here too. It does *not* abort the way it does on Windows, where on `b10566` Gemma 4 E4B dies during KV allocation with `pre-allocated tensor (cache_k_l22) in a buffer (Vulkan0) that cannot run the operation (NONE)`. On Linux with the same build it loads, generates and stops cleanly. What it does not do is pay: acceptance 0.33–0.34, and 27.15 and 25.58 tok/s against 25.82 and 28.59 without it — two ranges that overlap. So the three Gemma entries turn it off for Linux in their own blocks rather than the backend refusing it for everyone.

### ROCm does not work here, and it is the runtime's fault rather than the catalog's

Worth writing down, because "add a ROCm backend" looks like a five-minute catalog edit and is not:

- The **official** `ubuntu-rocm-10.0` build of `llama.cpp` carries no `gfx1103` device code at all. Its `libggml-hip.so` has `gfx1010`–`gfx1036`, `gfx1100`/`1101`/`1102`, `gfx1150`/`1151`/`1152`, `gfx1200`/`1201` and CDNA — the RDNA3 iGPUs are missing. It also expects ROCm installed on the system: `libhipblas.so.3`, `librocblas.so.5`, `libamdhip64.so.7`.
- The **multiarch nightly** from `AMD-Ecosystem/llama.cpp` does carry `gfx1103`, and bundles the whole ROCm userspace so nothing needs installing. It detects the device correctly — `Device 0: AMD Radeon Graphics, gfx1103 (0x1103), Wave Size: 32, VRAM: 11906 MiB` — and then every allocation fails. With `AMD_LOG_LEVEL=3` the cause is one line: `hipMalloc` returns success, `Device::acquireQueue: hsa_amd_queue_create failed!`, and the next `hipMemset` comes back `hipErrorOutOfMemory`. Same result at `-ngl 3` and at `-ngl 999`, and with `HSA_ENABLE_SDMA=0`, `HSA_XNACK=1`, `GGML_CUDA_NO_PINNED=1` and `HSA_OVERRIDE_GFX_VERSION=11.0.2`. The kernel exposes the device — `/dev/kfd` is there and reports `gfx_target_version 110003` — but the SteamOS kernel and the ROCm 10.1 runtime do not agree about queues.
- Even if that were fixed, HIP exposes only **11906 MiB** on this machine against the 19.6 GiB Vulkan reports, because Vulkan reaches the GTT pool and HIP does not. The 35B-A3B with its encoder needs 16.9 GiB of that. For the model this catalog cares most about, ROCm would not be an option here regardless.

### The fit table is calibrated for exactly one model so far

The KV column comes from the GGUF header and is exact everywhere. The per-model overhead constants behind the *estimated total* were measured against `nvidia-smi` on CUDA under Windows, so on Linux they are borrowed — and the launcher says so on screen — for every entry except one.

`qwen36-35b-a3b-mtp` carries a measured `overhead.linux` block: `baseMiB -205`, `visionMiB 251`, taken on Vulkan/gfx1103 at 32K with a q8_0 cache by sampling `mem_info_vram_used + mem_info_gtt_used` against an idle baseline. Without vision the process holds 16564 MiB against 16429 of weights and 340 of cache; with vision, 17673. The base term is negative because llama.cpp keeps 515 MiB of that file in a `Vulkan_Host` buffer and only 15499 reaches the device. Do the same for another model and its warning goes away too.

**A quantized KV cache is cheap here.** The 84x prompt collapse that CUDA suffers — flash attention has no quantized-KV kernel there and attention falls off the GPU — does not happen on Vulkan. Measured with Gemma 4 E4B, `llama-bench`: f16 gives pp512 353.3 and tg128 31.9 tok/s, q8_0 gives 329.3 and 31.0. Seven percent of prompt processing and three of generation, which is what makes a 16 GB model fit next to its vision encoder on a 24 GB machine.

The safety margin is smaller here than on Windows — 5% against 10%, in `config/server.json`. Windows holds back that slice because WDDM will not let one process keep all of the dedicated VRAM and quietly pages the excess into system RAM, where nothing reports an error and generation just crawls. Linux fails an allocation that does not fit instead, loudly. What is left to guard against is the memory the desktop compositor holds and the launcher cannot see, which is real and much smaller; on a headless machine you can set it to 0.

The device reserve, on the other hand, is still the Windows figure carried over, and the comment beside it in `config/server.json` says so. Measuring it against `nvidia-smi` on a Linux card is the way to replace it.

### SteamOS

The read-only root changes nothing, because nothing here installs: PowerShell and `llama.cpp` are fetched into `tools/` and verified, exactly as on any other distro. Three things are specific to it:

- **The panel goes in the Steam library**, so a model is picked with a controller rather than a keyboard. `add-to-steam.ps1` writes the shortcut; see [the panel](#the-panel).
- **Port 8080 is taken.** Steam's own `steamwebhelper` holds `127.0.0.1:8080`, and a wildcard bind over it fails with `couldn't bind HTTP server socket`. That is why the default moved to 8088.
- **There is no compiler.** `gcc`, `cmake` and `make` are absent and the root filesystem is immutable, so building `llama.cpp` from source means a container. The prebuilt Vulkan binary runs as it is, with `coopmat` active.

---

## Just chatting

If you only want to talk to the model, pick **Browser** and `llmfit` opens it for you. `llama.cpp` compiles a chat UI into the server itself, so it is already running at:

```
http://127.0.0.1:8088
```

No install, no Docker, no extra process. It handles conversations, system prompts, sampling settings, and file attachments — with a vision model loaded the server advertises image, video and audio input, and the UI exposes them. It ships a web manifest too, so your browser can install it as a standalone app.

That URL is printed at the end of every run whatever harness you chose, because the UI is up regardless.

Want chat history synced across devices, document search or multiple users? Point **Open WebUI** or any other OpenAI-compatible front end at `http://127.0.0.1:8088/v1` with any value as the API key. `llmfit` does not bundle one: they need Docker or a Python environment, which is exactly the install step this project exists to avoid.

---

## The panel

The launcher is a terminal wizard, which is the wrong shape for a machine you drive from the sofa with a controller. `PANEL.sh` (`PANEL.command` on macOS, `PANEL.cmd` on Windows) puts the same decisions on a page instead:

```bash
./PANEL.sh
```

It starts the panel, works out which session it is in, and opens it — Steam's built-in browser under Gaming Mode, Firefox in kiosk mode on the desktop. The page is plain HTML, CSS and JavaScript with no framework and no CDN, because the machine it runs on may have no network left once the weights are down.

Three screens rather than the terminal's five steps, because a page can show at once what a console has to ask in sequence:

| Screen | What is on it |
| --- | --- |
| **Model** | Backend and its budget, then every model as a tile: what it weighs, whether it is here, whether it can draft |
| **Fit** | Vision on or off, KV cache type, and the fit table as tiles — one per context length, `FITS` / `TIGHT` / `TOO BIG` — with speculative decoding underneath and the sentence explaining it. A meter along the bottom follows the running total against the budget |
| **Run** | A progress bar per file while anything downloads, then the addresses: the chat UI, the API, and both again as the LAN sees them |

**Put it in your Steam library**, with one command rather than six clicks:

```bash
./tools/pwsh/pwsh -File add-to-steam.ps1
```

It writes a non-Steam shortcut pointing at `PANEL.sh`, with library artwork. Run it again and it replaces its own entry rather than adding a second; `-Remove` takes it out again.

Two things it insists on. It **refuses while Steam is running**, because Steam keeps its own copy of `shortcuts.vdf` in memory and writes it back on exit — an edit made underneath a live Steam is discarded with no error at all. And it **backs the file up once** before the first write, the same `.llmfit-backup` convention the harness configuration uses. `shortcuts.vdf` is Valve's binary key-value format, so the script parses and re-emits the whole file; the round trip was checked byte for byte against a real 47-entry library before it was allowed to write anything.

The manual route still works if you prefer it: Desktop Mode → Steam → Games → *Add a Non-Steam Game* → Browse → pick `PANEL.sh`.

Either way it then launches from Gaming Mode like any other entry, and the thumbstick drives the cursor across the tiles. Touch works directly, and arrow keys with Enter and Escape work wherever a keyboard or a Steam Input layout provides them. A gamepad that reaches the page through the Gamepad API drives it too: D-pad to move, **A** to select, **B** to go back.

**It shows the same numbers as the terminal.** Backend and budget, every model with what it weighs, the KV cache type, the fit table with `FITS` / `TIGHT` / `TOO BIG` per context length, and whether speculative decoding is on with the sentence that says why. That is not a reimplementation: `lib/fit.ps1` computes it once and both front ends print what it returns. A fit table nobody can trust is the thing this project exists to replace, and two of them would be worse than none.

Downloads happen in the panel too, with a progress bar per file — the catalog now carries each file's size, so the bar is real rather than a spinner, and the SHA-256 still decides when a file is done. You can watch a 16 GB download from your phone while the Deck sits on the dock.

The panel listens on its own port (`uiPort` in `config/server.json`, 8089 by default) because it has to answer while `llama-server` is loading, restarting or stopped. It binds the same host as the API, so it is reachable from the same devices — read [On your network](#on-your-network) before opening either to a network you do not control.

Stop it with `pkill -f ui.ps1`. Stopping the panel does not stop a model: the server is detached and outlives it.

---

## On your network

The server listens on every interface, so the model you just loaded is available to every device in the house — phone, laptop, the machine you actually work on. The launcher prints the address at the end of a run:

```
  API       : http://127.0.0.1:8088/v1
  Chat UI   : http://127.0.0.1:8088  (built into llama.cpp, always available)
  LAN       : http://192.168.1.3:8088  - same paths, from any device on this network
              API http://192.168.1.3:8088/v1
              or http://steamdeck.local:8088 wherever mDNS resolves
```

Open that chat UI address on a phone and you are talking to the model on your desktop, with no app and no account.

**Bind address and connect address are not the same string.** `config/server.json` sets `host`, which is what `llama-server` binds to, and `0.0.0.0` there means *every interface*. It is not an address anything can connect to: Windows refuses it outright, and on macOS and Linux it only works by falling through to the loopback. So the launcher binds with what the config says, talks to `127.0.0.1` itself, writes that into your harness configuration, and works out the LAN address separately.

**Which address, on a machine that has several.** A laptop with Docker, a VPN and wifi has three equally plausible addresses and no way to tell them apart by name. `lib/net.ps1` asks the routing table instead: a UDP socket *connected* to `192.0.2.1` sends no packets — the address is reserved for documentation and routed nowhere — it only makes the OS pick a route, and the socket's local endpoint is then the address the LAN would see. That one is printed first; the rest are listed as also listening, named by interface, because a wildcard bind really did open them.

The `.local` name appears only where something answers for it: always on macOS, on Linux when Avahi is running, never on Windows, which ships no mDNS responder.

**To keep it to this machine**, set `"host": "127.0.0.1"` in `config/server.json`. The summary then says so rather than printing an address that does not work:

```
  LAN       : not reachable - bound to 127.0.0.1 only.
              Set "host": "0.0.0.0" in config/server.json to open it to this network.
```

**There is no authentication.** `llama-server` takes any string as an API key and checks none of it, so on `0.0.0.0` anyone who can reach the port can use your model, read the prompts in flight and load the machine. That is fine on a home network you control and wrong on a café's wifi. This is a local inference server, not a service: do not port-forward it, and use the loopback bind when you are somewhere you do not trust.

**The port is 8088 and not 8080 on purpose.** 8080 is the `llama.cpp` default and it is not free everywhere: on SteamOS the Steam client's `steamwebhelper` already holds `127.0.0.1:8080`, and a wildcard bind over it fails with `couldn't bind HTTP server socket, hostname: 0.0.0.0, port: 8080`. Any free port works; change `port` in `config/server.json` and the harness configuration follows on the next run.

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
- **Run it in any folder.** The harness talks to `http://127.0.0.1:8088`, so start it wherever your code lives.
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

Five of the seven catalog entries have been measured against `nvidia-smi` on a 16 GB NVIDIA card — the class a 4080, a 5070 Ti or a 5080 belongs to. A 24 GB card (3090, 4090) or a 32 GB one (5090) runs the same arithmetic with more room; what changes is the budget in step 1, not the constants below. **Every figure in this first part is CUDA**; the integrated-GPU sections below are separate measurements on their own hardware, and [what is different on macOS](#what-is-different-on-macos) covers Metal. A sample:

| Configuration | Estimated | VRAM used | Generation |
| --- | --- | --- | --- |
| Qwen 27B + vision, 64K | 14564 MiB | 14564 MiB | 50.8 tok/s |
| Qwen 27B no vision, 128K | 14708 MiB | 14708 MiB | — |
| Qwen 9B + vision, 64K | 8424 MiB | 8424 MiB | — |
| Gemma 4 E4B + vision, 128K | 4611 MiB | 4610 MiB | 89.1 tok/s |
| Gemma 4 12B no vision, 256K | 8132 MiB | 8132 MiB | — |
| Gemma 4 26B-A4B + vision, 64K | 15644 MiB | 15644 MiB | — |

Across 18 configurations spanning those five models, two vision settings and context lengths from 64K to 256K, the **worst error is 1 MiB**.

The 27B at 32K with an `f16` cache measures 14254 MiB against an estimate of 14196, and runs at 1542 tok/s prompt and 42.7 tok/s generation — on the GPU, where it belongs.

Every figure comes from running `serve.ps1` itself and reading `nvidia-smi`, never from an ad-hoc `llama-server` invocation. That matters: an earlier round of Qwen constants was fitted to hand-written commands that omitted `--parallel 1` and `--image-min-tokens`, and it overestimated by 800 MiB.

Getting there took two corrections that no amount of reading the header would have produced:

- **Gemma 4 E4B holds fewer KV caches than its header implies.** The arithmetic says 7 full-attention layers; the measured delta between 64K and 128K says 4. `shared_kv_layers = 18` is why — three of the seven reuse another layer's cache. The header states how many layers share, never which, so only measurement resolves it.
- **E4B keeps about 1.2 GB of its weights in system RAM.** It is a MatFormer: its per-layer embeddings never become resident on the GPU. Its calibrated base overhead is therefore *negative*, which is the honest way to encode "part of this file is not in VRAM".

Overhead constants per model, all measured:

| Model | Base | With vision | Speculation | Measured on |
| --- | --- | --- | --- | --- |
| Qwen 3.5 9B | −455 MiB | +251 MiB | 0 MiB, model-free | CUDA |
| Qwen 3.8 27B | −389 MiB | +251 MiB | 0 MiB model-free; the embedded MTP it no longer uses cost +1200 | CUDA |
| Qwen 3.6 35B-A3B | — | — | none declared | nothing, anywhere |
| Qwen 3.6 35B-A3B (MTP) | −205 MiB | +251 MiB | +801 MiB, embedded | Vulkan, `gfx1103` |
| Gemma 4 E4B | −1207 MiB | +202 MiB | +66 MiB, draft model | CUDA |
| Gemma 4 12B | +347 MiB | +177 MiB | +294 MiB, draft model | CUDA |
| Gemma 4 26B-A4B | +313 MiB | +142 MiB | +292 MiB, estimated | CUDA |

A negative base means part of the file never reaches VRAM: metadata and tokenizer tables are counted in the file size, for the 27B so are the `blk.64` tensors llama.cpp skips when MTP is off, and for the 35B-A3B MTP build it is the 515 MiB llama.cpp keeps in a host buffer. A model with no measured values — the plain 35B-A3B is the one left — falls back to the defaults in `config/server.json`, which stay deliberately pessimistic, and the launcher says on screen that it is doing so.

### The same models on an integrated GPU, on Windows

Everything above is CUDA. The figures below are an AMD Radeon 780M — the integrated GPU of a Ryzen APU, sharing 64 GB of DDR5 with the CPU — reached through the Windows Vulkan backend with the device pinned. They are `llama-bench` with `-r 1` and `-fa on`, so treat them as one measurement each rather than as the calibration the CUDA numbers above received.

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

> **On Windows Vulkan, speculative decoding is not merely pointless, it aborts.** Gemma 4 E4B with its companion draft model dies during KV allocation: `pre-allocated tensor (cache_k_l22) in a buffer (Vulkan0) that cannot run the operation (NONE)`. That is Gemma 4's shared-KV layers meeting a Vulkan buffer with no kernel for them. The launcher never offers it there, because the `vulkan` backend sets `speculativeDecoding: false`; `serve.ps1` refuses it too, rather than letting a hand-written command reach the abort. The **Linux** Vulkan build behaves differently on both counts — see the next section.

**Speculation is charged what it actually costs**, and the shapes are an order of magnitude apart. An embedded draft context is built against the whole model — 1200 MiB on the 27B, 801 on the 35B-A3B MTP build — while a companion draft file costs little more than its own weight, and a model-free method costs nothing at all and is therefore never refused for memory. Counting a real cost as free is how a configuration reports `FITS` and then spills into system RAM, where prompt processing collapses from hundreds of tokens per second to tens.

### The same models on an RDNA3 handheld, on Linux

A Ryzen Z1 Extreme running SteamOS: `gfx1103`, 24 GB of LPDDR5 shared with the CPU, through the Vulkan backend — a ROG Ally X, a ROG Xbox Ally X or a 32 GB Legion Go S is the same shape of machine. This is where the Linux support was built and measured, and unlike the CUDA table above these are single runs rather than a calibration.

**The model this catalog cares most about fits, and speculation pays.** Qwen 3.6 35B-A3B from its MTP build, 32K with vision and a `q8_0` cache, everything on the iGPU:

| | Prompt | Generation |
| --- | --- | --- |
| No speculation | 42.5 tok/s | 28.2 – 28.6 tok/s |
| Embedded MTP | 40.5 – 69.6 tok/s | **37.5 – 38.3 tok/s** |

1.33×, at draft acceptance 0.71–0.73 and a mean draft length of 3.1. Prompt processing on a real batch rather than a 30-token question is **238.6 tok/s** (`llama-bench`, pp512).

**Memory, measured rather than estimated.** Sampled from `mem_info_vram_used + mem_info_gtt_used` against an idle baseline of 1340 MiB, same configuration at 32K:

| | Held |
| --- | --- |
| No vision, no speculation | 16564 MiB |
| With vision | 17673 MiB |
| With vision and MTP | 18474 MiB |

Against 16429 MiB of weights and 340 of cache, that is where `overhead.linux` comes from: **−205 MiB base, +251 with vision**, and **801 MiB** for the draft context. The negative base is the 515 MiB llama.cpp keeps in a `Vulkan_Host` buffer, out of a file only 15499 MiB of which reaches the device.

The MTP draft cache is **64 MiB at 32K, one layer, and `f16` whatever `--cache-type-k` says** — 2048 bytes per token, so it grows with context while `costMiB` is modelled flat. That is the same weakness the Metal ceiling exists for.

**A quantized cache is nearly free on this backend**, which is what makes the 16 GB model fit beside its encoder. Gemma 4 E4B, `llama-bench`:

| KV | pp512 | tg128 |
| --- | --- | --- |
| `f16` / `f16` | 353.3 tok/s | 31.9 tok/s |
| `f16` / `q8_0` | 327.3 tok/s | 31.6 tok/s |
| `q8_0` / `q8_0` | 329.3 tok/s | 31.0 tok/s |

Seven percent of prompt processing and three of generation, against the 84× collapse the same change causes on CUDA.

**The companion draft runs here and buys nothing.** Gemma 4 E4B at 32K, temp 0, 200 predicted tokens, two runs per arm: 27.15 and 25.58 tok/s with its draft model, 25.82 and 28.59 without, at acceptance 0.33–0.34. Overlapping ranges, so the Gemma entries turn it off on Linux.

---

## Moving the package to another machine

Once models and backends are downloaded, the whole folder is self-contained and can be carried on a USB stick — useful for machines with no network access.

**Before copying**, on the source machine:

```powershell
powershell -ExecutionPolicy Bypass -File clean.ps1          # drop extracted archives
powershell -ExecutionPolicy Bypass -File verify.ps1 -Full   # require the whole catalog
```

**Then:**

1. Copy the whole folder to the stick. The full catalog is about **87 GB** with a backend, so size the stick for what you actually keep, and format it **exFAT or NTFS** — FAT32 cannot hold files over 4 GB and every GGUF here is larger.
2. On the target machine, copy it from the stick to a local SSD. Do not run models straight off a slow stick.
3. Run `VERIFY.cmd` (or `VERIFY.command`, or `VERIFY.sh`) and wait for confirmation. It re-checks the SHA-256 of every model and binary, which is what catches a copy that was silently truncated.
4. Run `INSTALL-PATH.cmd` (or `INSTALL-PATH.command`, or `INSTALL-PATH.sh`) once.
5. Open a new terminal and run `llmfit`.

The catalog is portable but the binaries are not: a folder carried from Windows has the CUDA, Vulkan and CPU backends, and a Mac needs the Metal one, a Linux box the `ubuntu` ones. The models are the expensive part and they are shared, so the target machine downloads between 13 and 33 MB of backend — plus PowerShell, on macOS and Linux — and gets going. Copying between two machines of the same kind needs no download at all.

`fetch.ps1` is the other way to fill a folder before a trip: it downloads and verifies a configuration without loading anything, so a catalog can be pulled overnight rather than in front of somebody waiting to use it.

`VERIFY` only checks what belongs to the system it runs on, so a Windows package verified on a Mac reports the models as fine and the Metal backend as not installed, rather than calling the CUDA one missing.

---

## Troubleshooting

**A large download was interrupted.** Run `llmfit` again. It validates by SHA-256, not by file existence: a partial file is resumed, and if it still does not match it is re-downloaded clean. Nothing to delete by hand.

**My GPU is not detected.** Set `LLMFIT_DEBUG=1` to see the raw `llama-server --list-devices` output per backend.

**A 24 GB handheld fits far less than 24 GB, or a model that loaded on SteamOS fails to allocate on Windows.** Shared memory is not a single number the hardware decides. Under Linux a Vulkan process reaches the amdgpu GTT pool and sees most of the machine — 19.6 GiB of 24 on the Z1 Extreme measured here. Under Windows it sees the carve-out the BIOS or Armoury Crate sets plus what WDDM lends, and WDDM pages the last of that into system RAM rather than refusing it, so the symptom is either an allocation failure or a load that "succeeds" and then generates at a few tokens per second. Raise the graphics-memory setting in the BIOS or Armoury Crate if the vendor exposes one, drop vision or shorten the context to fit what the backend actually reports — or run SteamOS or another Linux distribution, which is what [what is different on Linux](#what-is-different-on-linux) was measured on.

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

**Restore my previous configuration.** Every file the launcher touched has a `.llmfit-backup` copy next to it — `~/.zshrc` or `~/.bashrc`, your harness configuration, and Steam's `shortcuts.vdf` if you used `add-to-steam.ps1`.

**The panel will not open, or the page says it cannot reach its own server.** `PANEL.sh` leaves its log at `llmfit-panel.log`. The usual cause is the port: something else already holds `uiPort`. Check with `./tools/pwsh/pwsh -File ui.ps1 -WhereIsIt`, and change `uiPort` in `config/server.json` if it is taken.

**`couldn't bind HTTP server socket, hostname: 0.0.0.0, port: 8080`.** Something else owns 8080 — on SteamOS that is Steam's own `steamwebhelper`. Change `port` in `config/server.json`; the default here is already 8088 for that reason.

**The Steam shortcut did not appear.** `add-to-steam.ps1` refuses while Steam is running and says so, because Steam keeps `shortcuts.vdf` in memory and writes it back on exit, discarding anything written underneath it. Close Steam, run it again, start Steam. If an entry went in and you want it gone, `-Remove` takes it out and renumbers the rest.

**The panel shows a model as `TIGHT` before it is downloaded.** That table is drawn from the size the catalog declares, which is what the host reports for the file. It is recomputed from the real file once the download finishes — and the SHA-256, not the size, is what decides the file is complete.

**macOS: `zsh: permission denied: ./START.command`.** The executable bit did not survive however the folder reached you. `chmod +x START.command VERIFY.command CLEAN.command INSTALL-PATH.command bin/llmfit`.

**Linux: `permission denied: ./START.sh`.** The same thing. `chmod +x START.sh VERIFY.sh CLEAN.sh INSTALL-PATH.sh bin/llmfit`.

**Linux: `Missing required tool: jq`.** The bootstrap reads `config/bootstrap.json` before any PowerShell exists, so it needs `jq`, `curl` and `tar` from your package manager. Everything after that point is PowerShell and needs nothing installed.

**Linux: PowerShell extracts but will not start.** Almost always a missing `libicu` on a minimal image; on Debian and Ubuntu `sudo apt install libicu-dev` resolves it.

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

- Overhead constants measured on Apple Silicon and on Linux for the rest of the catalog, so every fit table is calibrated rather than borrowed from CUDA. One entry of seven is measured on Linux today, none on Metal
- The plain Qwen 3.6 35B-A3B has no measured overhead on any platform, which makes it the one entry whose estimated total is a guess everywhere
- Whether a quantized KV cache costs anything on Metal, measured rather than left as an open question
- CUDA and ROCm backends for Linux, so an NVIDIA or AMD card is not limited to Vulkan there. ROCm is blocked today on RDNA3 iGPUs by the runtime rather than by the catalog; [what is different on Linux](#what-is-different-on-linux) records exactly where it stops
- Intel Macs (the `macos-x64` build)
- More models in the catalog

---

## License

The launcher is released under the MIT License. `llama.cpp` is downloaded, not vendored, and remains under its own license; model weights belong to their respective publishers.
