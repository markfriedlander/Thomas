# Vendored: SmolVLM2 (Idefics3) model code from `mlx-swift-lm`

**Source:** https://github.com/ml-explore/mlx-swift-lm, `Libraries/MLXVLM/Models/Idefics3.swift`
(SmolVLM2 is `typealias SmolVLM2 = Idefics3` in the library's `SmolVLM2.swift`)
**Version:** 3.31.4 (revision `bd4b743`), the same version Thomas links as a package
**Licence:** MIT (`LICENSE-SmolVLM`, the library's `LICENSE` unmodified; Copyright (c) 2024 ml-explore). Named apart from
`LICENSE-QwenVLM` only because two bundle files cannot share a name.
**Vendored:** 2026-11-14, for the Developer Tray's eye stages (Mark: "let's build it and I'll play with it").

## Why

Like Qwen (`Vendor/QwenVLM`): the library keeps the model's attention inside a fused call, so nothing outside can see
where each word looked or the numbers the encoder made. This is the model's CODE only; the weights still come from the
shared store, unchanged, so Hal and every other tenant are unaffected. `registerInstrumentedSmolVLM()` (Qwen.swift)
points the library's `"smolvlm"` model type at `TIdefics3`. The library's own `SmolVLMProcessor` (tiling, prompt) is
untouched and still used.

## What a look is made of (measured on the Mac probe, 2026-11-14)

The processor cuts the photo into tiles of 512 px (4 x 3 for a 4:3 or 16:9 photo, longest edge capped at 2048) plus
one 512 px overview of the whole picture. Each becomes 64 squares (8 x 8 after the connector's pixel shuffle), in
reading order, tiles first, overview last. The recorder stitches the tiles into one grid (rows*8 x cols*8) and spreads
each overview square's attention evenly over the tile squares it covers, so one map on the photo holds both looks.
Probe sources and pictures: `screenshots-draft/eye-stages-probe/smol*` (private).

## Every change made to upstream source (re-apply on a re-sync)

1. **Renames:** `Idefics3*` types to `TIdefics3*` (perl `s/\bIdefics3\b/TIdefics3/g; s/\bIdefics3(?=[A-Z])/TIdefics3/g`).
2. **`import MLXVLM`** added after `import MLXLMCommon`.
3. **`nonisolated`** on every top-level declaration (the app target defaults to MainActor isolation).
4. **Recorder hooks, every line marked `THOMAS`:** the text attention does its cache update by hand on single-token
   passes while `EyeRecorder.shared.isRecording` and passes queries/keys to `noteGaze` (prefill chunks are not read:
   their keys don't yet cover every image square); `getInputEmbeddings` calls `noteTiledImage` with the connector's
   output; `prepare` calls `newPrompt` first and `flushStep(nil)` after the last residual pass; `callAsFunction`
   defers `flushStep(inputToken:)`. When not recording, the library path runs untouched.
