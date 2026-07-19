# Thomas

**A camera whose film is language.**

Point Thomas at the world and press the shutter. Instead of only saving a photograph, an on-device
vision model **describes what it sees** — and those words are the recording. Then a second model
**re-imagines the scene from the words alone**, drawing what it "understood." One press, three frames:

1. **The photograph** — what the lens actually saw.
2. **The description** — what the machine *perceived*, in its own words.
3. **The drawing** — the machine *re-imagining* the scene from that description.

**Reality → machine perception → machine re-imagining.** The distance between the three is the point —
a legible, pointable look at how a machine sees, and how far that is from what's really there.

## Local-first, and private

Everything runs **on the device**. The photograph, the words, and the drawing are all produced on
your iPhone. The words work on a fresh install with no download at all (via Apple Intelligence); the
drawing is an optional model you download when you want it.

## How it works

- **The eye** — a vision-language model looks at the photo and writes what it sees. Choose Apple
  Intelligence (built in, zero download) or a downloadable model that sees more.
- **The hand** — a Stable Diffusion model draws a new image from the eye's words. It never sees your
  photo; it only reads the description. You pick how it develops the drawing (a full, detailed decoder
  or a fast, lighter one — and Thomas quietly falls back to the light one rather than ever failing).
- **The shot is atomic.** You configure once, then just shoot. Finished frames land in Photos like a
  print surfacing in a chemical bath — the latency is the film developing.

## Requirements

- iOS 27 or later, on an Apple-Intelligence-capable iPhone.

## Third-party components

Thomas stands on open-source work, including Apple's [MLX](https://github.com/ml-explore/mlx) and
[mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples), `stabilityai/sd-turbo`, and
[TAESD](https://github.com/madebyollin/taesd) by Ollin Boer Bohan. Their licenses ship with the code.

---

*One of a small family of apps by [Mark Friedlander](https://markfriedlander.github.io/).*
