# Vendored: Qwen 3.5 VLM model code from `mlx-swift-lm`

**Source:** https://github.com/ml-explore/mlx-swift-lm, `Libraries/MLXVLM/Models/` (`Qwen35.swift`, `Qwen3VL.swift`, `QwenVL.swift`)
**Version:** 3.31.4 (revision `bd4b743`), the same version Thomas links as a package
**Licence:** MIT (`LICENSE-QwenVLM`, unmodified; Copyright (c) 2024 ml-explore). Renamed from `LICENSE` only because
the StableDiffusion vendor folder's `LICENSE` is copied into the same app bundle and two files cannot share a name.
**Vendored:** 2026-11-05, for the Developer Tray's eye stages.

## Why

The library's Qwen 3.5 keeps its vision model private and runs attention through a fused kernel, so nothing outside it
can see the encoder's numbers or where each word looked. This is the model's CODE only (the recipe); the weights still
come from the shared store, unchanged, so Hal and every other tenant are unaffected. `registerInstrumentedQwen()`
(Qwen.swift) points the library's `"qwen3_5"` model type at `TQwen35` before each load. Other models (SmolVLM) keep
the library's code.

## Every change made to upstream source (re-apply on a re-sync)

1. **Renames:** `Qwen35*`, `Qwen3VL*`, `QwenVL*` types to `TQwen35*`, `TQwen3VL*`, `TQwenVL*` (perl
   `s/\bQwen(35|3VL|VL)\b/TQwen$1/g; s/\bQwen(35|3VL|VL)(?=[A-Z])/TQwen$1/g`), so they never collide with MLXVLM's.
2. **`import MLXVLM`** added after `import MLXLMCommon` in all three files.
3. **`nonisolated`** on every top-level declaration: the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
   (same reason as Vendor/StableDiffusion VENDOR.md #1).
4. **Recorder hooks in `Qwen35.swift`, every line marked `THOMAS`:** the full-attention layer does its cache update by
   hand while `EyeRecorder.shared.isRecording` (identical maths to `attentionWithCacheUpdate` for a plain cache) and
   passes queries/keys to `noteGaze`; `prepare` calls `newPrompt`, `noteImage` (vision features, grid, ids) and
   `flushStep(nil)`; `callAsFunction` defers `flushStep(inputToken:)`. When not recording, the library path runs untouched.
