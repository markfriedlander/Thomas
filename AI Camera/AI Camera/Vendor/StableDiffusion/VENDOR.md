# Vendored: `StableDiffusion` from `mlx-swift-examples`

**Source:** https://github.com/ml-explore/mlx-swift-examples — `Libraries/StableDiffusion/`
**Commit:** `357c97f` ("mlx-swift-examples prep for mlx-swift-lm 3.x release (#468)")
**Licence:** MIT (`LICENSE`, in this folder, unmodified — Copyright (c) 2024 ml-explore)
**Vendored:** 2026-07-15
**Size:** 2,552 lines across 9 files

---

## Why vendored rather than added as a package

Three reasons, in order of weight.

**1. The preset we need points at a dead repo, and we can't override it from outside.**
`StableDiffusionConfiguration.presetStableDiffusion21Base` names
`stabilityai/stable-diffusion-2-1-base`, which **HuggingFace no longer serves** (401 —
verified 2026-07-15 from two machines and from the phone; the `stabilityai` org listing has
no `stable-diffusion-2-*` repos left, and a known-*gated* repo answers 200 with
`"private": false`, so this is withdrawal, not gating). We need to point the same code at a
live model. `StableDiffusionConfiguration`'s `files` and `factory` are **`internal`**
(`Load.swift:112,114`), and a struct with internal members gets an internal memberwise init
— so from outside the module you cannot construct one. NEXT.md called this correctly.

**2. The file list is wrong for a phone and also not overridable.** The presets hardcode the
**fp32** filenames and convert to fp16 after loading — paying the heavy download to use the
light weights, while the fp16 twins sit unused in the same repo. Measured: the SDXL-Turbo
preset as shipped is **12.93 GB**; its fp16 twins are **6.46 GB**. Same lock, same reason.

**3. Adding the package would re-resolve the MLX graph.** `mlx-swift-examples` brings its own
`mlx-swift` dependency and SPM would re-resolve everything. Hal's HISTORY records exactly this
class of bug — a resolver re-run silently downgraded `swift-transformers` and broke the build.
The library only needs `mlx-swift` (have 0.31.6) and `swift-transformers` (have 1.3.3), both
already linked here. **Verified after vendoring: `Package.resolved` is untouched.**

---

## Every change made to upstream source

Keep this list exact. It is the entire diff from `357c97f`, and it is what a re-sync has to
re-apply.

### 1. `nonisolated` on 13 `Module` subclasses

| file | classes |
|---|---|
| `Clip.swift` | `CLIPEncoderLayer`, `CLIPTextModel` |
| `UNet.swift` | `TimestepEmbedding`, `TransformerBlock`, `Transformer2D`, `ResnetBlock2D`, `UNetBlock2D`, `UNetModel` |
| `VAE.swift` | `Attention`, `EncoderDecoderBlock2D`, `VAEncoder`, `VADecoder`, `Autoencoder` |

**Not a fix to the library — a consequence of AI Camera's build settings.** This target sets
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a bare `class X: Module` gets a
MainActor-isolated `init()`, which cannot override MLXNN's nonisolated one. Upstream compiles
as its own module under default (nonisolated) isolation and never sees this. These are compute
graphs and belong off the main actor regardless, so `nonisolated` is also simply correct.

### 2. Two renames, to stop the library shadowing the app

A separate module has its own namespace. Vendored into the app target, these two `public`
types landed in AI Camera's global namespace and **broke working code**:

| upstream | here | why it had to move |
|---|---|---|
| `Image` (`Image.swift:25`) | **`SDImage`** | Shadowed **SwiftUI's `Image`** app-wide. Every `Image(systemName:)` in the app stopped compiling. |
| `ImageError` | **`SDImageError`** | Carried along with its type. |
| `ModelContainer<M>` (`StableDiffusion.swift:125`) | **`SDModelContainer<M>`** | Shadowed **MLXLMCommon's `ModelContainer`**, which `Qwen.swift` uses — i.e. vendoring the drawing model broke the seeing model. |

Both were self-contained: `Image` was referenced outside its own file only in three doc
comments, `ModelContainer` only within `StableDiffusion.swift`. Renames are word-boundary
scoped to this folder; no framework name (`CGImage`, `CIImage`, `CoreImage`, `ImageIO`, …) was
touched.

**If this is ever made a real local SPM package, revert both renames** — the module boundary
makes them unnecessary, and they are pure cost.

### 3. `CLIPTokenizer.tokenize` truncates to 77 tokens (2026-07-16)

`Tokenizer.swift`. Upstream returns `[bos] + allContent + [eos]` with no cap. CLIP's text
encoder has a fixed `[77, 1024]` positional embedding, so any prompt over 77 tokens aborts MLX
mid-draw with a **`Fatal error: [broadcast_shapes] Shapes (1,92,1024) and (77,1024) cannot be
broadcast`** — the app dies (signal 5). Mark hit it on the first verbose description (a laptop
→ 92 tokens). This caps content at 75 (BOS + 75 + EOS = 77), which is what every real CLIP
tokenizer does. **This is a genuine upstream bug, not an AI-Camera-ism — worth reporting to
mlx-swift-examples.** A re-sync must re-apply it.

**NB — this truncation is now the FLOOR, not the primary defense.** As of 2026-07-16 the app
condenses over-budget descriptions *before* they reach the drawer (the eye restates itself
shorter — `Eye.condense` / `Qwen.condense`, driven from `Shot.seeThenDraw`), and a locked
Layer-1 brevity line (`PromptLayers`) keeps the eye short at the source. So this cap should
normally never engage. Keep it anyway: it is the belt that guarantees the drawer can never be
handed a crashing prompt again, whatever happens upstream of it.

---

### 4. Tiled VAE decode, to survive the decode on iPhone (2026-07-17)

`VAE.swift` and `StableDiffusion.swift`. **Additions, not edits — nothing upstream changed
behaviour.** The monolithic decode of a 64×64 latent to 512×512 peaks ~4.5 GB in intermediate
activations (measured 2026-07-15, the VAE decode is where MLX diffusion jetsams on an 8 GB
iPhone whose process ceiling is already maxed via the Increased Memory Limit entitlement). Added:

| file | addition |
|---|---|
| `VAE.swift` | `Autoencoder.decodeTiled(_:tileLatent:overlapLatent:)` + two statics `tilePositions`, `taperWindow` |
| `StableDiffusion.swift` | `StableDiffusion.detachedTiledDecoder(tileLatent:overlapLatent:)` — the tiled twin of `detachedDecoder()` |

The tiled decoder splits the latent into overlapping tiles, decodes each (a fraction of the
area, so a fraction of the peak), and feathers the pixel overlaps back together — `diffusers`'
`enable_vae_tiling` in miniature. It tiles the *latent*, so it is model-agnostic across the
KL-f8 SD family. `Drawing.draw` calls `detachedTiledDecoder` in place of `detachedDecoder`; the
original `detachedDecoder`/`decode` are untouched and still callable. A re-sync must re-apply
these two additions. **✅ Verified on device 2026-07-17 (iPhone 16 Plus): the tiled decode peaks
~3,480 MB vs the monolithic ~4,559 MB, and produces a seamless image.**

### 5. Cleared five pre-existing upstream warnings (2026-07-17)

All five were in the vendored code from `357c97f`, not introduced by us. Cleared so the build has a
**zero-warning baseline** — the point of "warnings are errors" (CLAUDE.md §6) is that a *new*
warning stays visible, and five standing ones defeat that. Trivial and behaviour-neutral; a re-sync
must re-apply them (small cost, accepted for the clean baseline while we develop against this code).

| file | was | now |
|---|---|---|
| `Image.swift:135` | `let (H, W, C) = raster.shape3` (C unused) | `let (H, W, _) = …` |
| `Load.swift:452` | `String(contentsOf: mergesURL)` (deprecated iOS 18) | `String(contentsOf: mergesURL, encoding: .utf8)` |
| `UNet.swift:134` | `let dtype = x.dtype` (dead) | removed |
| `UNet.swift:196` | `let dtype = x.dtype` (dead) | removed |
| `UNet.swift:503` | `let dtype = x.dtype` (dead) | removed |

## Known upstream issues, NOT fixed here

Recorded so nobody rediscovers them as bugs of ours.

- **`presetStableDiffusion21Base` is dead** — see above. Left as-is rather than deleted; a
  re-sync should not have to reconcile a deletion. AI Camera does not use it.
- **Presets hardcode fp32 filenames.** AI Camera does not use the presets. `ModelCatalog`
  names the fp16 files and `MLXModelDownloader` fetches them; the library is handed weights
  that are already on disk.
- **The stock demo app drops to a single diffusion step when `Memory.memoryLimit < 8 GB`** —
  and on iOS that is the *task* limit, so every iPhone trips it. That is in the demo app, not
  in this library, and is not vendored. Noted because NEXT.md warns that missing it would make
  you conclude MLX can't draw. sd-turbo genuinely wants 1–4 steps, so the trap is moot here —
  but do not inherit the reasoning.
