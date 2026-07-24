//
//  TAESD.swift
//  AI Camera
//
//  A tiny, low-memory decoder for the drawing — an alternative "developer" for frame 3.
//
//  The hand (sd-turbo) draws in a 64×64 *latent* space; something has to turn that latent into a
//  512×512 image. The full VAE decoder does it beautifully but peaks ~4.5 GB doing so, because it
//  carries 512-channel feature maps at full resolution through GroupNorm and a self-attention
//  block (see Drawing.swift / VENDOR.md — this is the step that jetsammed the process on iPhone).
//  Tiling the full VAE (Autoencoder.decodeTiled) is our fidelity-preserving fix for that.
//
//  TAESD is the *other* lever: a distilled decoder that replaces the full VAE entirely. 1.2 M
//  parameters vs 49.5 M, a 4.9 MB weights file, and — crucially — **no GroupNorm and no
//  attention**. Its feature maps are a constant 64 channels wide. Those three absences are exactly
//  why it is light. The trade is honest: TAESD is measurably softer, dropping fine high-frequency
//  detail. For an app whose thesis is the honest gap in panel 3, that is a *product* choice to A/B,
//  not a free win — so this is built as an OPTION, never a silent replacement of the real VAE.
//
//  Our port. Architecture transliterated verbatim from madebyollin/taesd `taesd.py` (MIT,
//  © 2023 Ollin Boer Bohan — license in Resources/taesd_decoder.LICENSE.txt, covering both this
//  derivative port and the bundled weights); there is no mlx-swift TAESD anywhere, so this is also
//  a small gift back to that ecosystem. Two scaling
//  facts are load-bearing and were read from the reference source, not remembered — get either
//  wrong and the image is washed-out garbage:
//
//    1. INPUT: feed the RAW sampler latent straight in. TAESD does NOT apply the 0.18215 VAE
//       scaling (its diffusers `config.scaling_factor` is 1.0, and `decode` scales nothing). The
//       first layer's `tanh(x/3)*3` clamp absorbs the range. So we hand it `final` directly — NOT
//       `final / scalingFactor`, which is what the full-VAE `decode` does internally.
//    2. OUTPUT: the decoder emits pixels already in [0, 1]. The reference demo is literally
//       `taesd.decoder(x).clamp(0, 1)`. So we clamp [0,1] and stop — we must NOT apply the
//       `x/2 + 0.5` that the full-VAE path uses (its decoder emits [-1, 1]).
//
//  ✅ Weight-key remap (taesdRemap) VERIFIED 2026-07-17 against the actual `taesd_decoder.safetensors`
//  (madebyollin/taesd, 4,895,612 bytes). Its 67 tensors map key-for-key onto this module's 67
//  parameters — none dropped, none missing; `1.weight` is [64,4,3,3] (convIn), `7/12/17.weight`
//  carry no bias (the post-upsample convs), `19.weight` is [3,64,3,3] (convOut).
//  ✅ Run on device 2026-07-17 (iPhone 16 Plus): draws a clean, correctly-exposed image (the raw-in
//  / [0,1]-out scaling is right), decode ~0.79s, and adds essentially nothing to the memory peak.
//

import Foundation
import MLX
import MLXNN

// ==== LEGO START: 29 TAESD (A Tiny, Low-Memory Decoder For The Drawing) ====

/// One TAESD residual block: `conv → relu → conv → relu → conv`, added to a skip, fused by a relu.
///
/// In the SD decoder every block is 64→64, so the reference's skip (`Conv2d(n_in,n_out,1)` only
/// when `n_in != n_out`) is always `Identity` here — no skip parameters exist in the weights.
/// `nonisolated` for the same reason as the vendored modules: this target defaults to MainActor
/// isolation, and a MainActor `init()` cannot override MLXNN's nonisolated one (VENDOR.md #1).
nonisolated class TAESDBlock: Module, UnaryLayer {

    @ModuleInfo(key: "conv0") var conv0: Conv2d
    @ModuleInfo(key: "conv1") var conv1: Conv2d
    @ModuleInfo(key: "conv2") var conv2: Conv2d

    init(_ channels: Int = 64) {
        self._conv0.wrappedValue = Conv2d(
            inputChannels: channels, outputChannels: channels, kernelSize: 3, padding: 1)
        self._conv1.wrappedValue = Conv2d(
            inputChannels: channels, outputChannels: channels, kernelSize: 3, padding: 1)
        self._conv2.wrappedValue = Conv2d(
            inputChannels: channels, outputChannels: channels, kernelSize: 3, padding: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = relu(conv0(x))
        h = relu(conv1(h))
        h = conv2(h)
        return relu(h + x)   // skip is Identity (n_in == n_out), so `+ x` is the whole skip
    }
}

/// The TAESD decoder: latent `[B, H, W, 4]` → image `[B, H*8, W*8, 3]` in [0, 1].
///
/// Layer-for-layer the reference `Decoder(latent_channels=4, use_midblock_gn=False)`:
///   Clamp · conv(4,64)·relu · Block×3 · up·conv(64,64,nobias) · Block×3 · up·conv · Block×3 ·
///   up·conv · Block · conv(64,3).
/// The three post-upsample convs carry no bias (reference `conv(64,64,bias=False)`); every other
/// conv does. Upsampling is nearest ×2 (reference `nn.Upsample(scale_factor=2)`).
nonisolated class TAESDDecoder: Module, UnaryLayer {

    @ModuleInfo(key: "convIn") var convIn: Conv2d
    @ModuleInfo(key: "stage0") var stage0: [TAESDBlock]
    @ModuleInfo(key: "up0") var up0: Conv2d
    @ModuleInfo(key: "stage1") var stage1: [TAESDBlock]
    @ModuleInfo(key: "up1") var up1: Conv2d
    @ModuleInfo(key: "stage2") var stage2: [TAESDBlock]
    @ModuleInfo(key: "up2") var up2: Conv2d
    @ModuleInfo(key: "tail") var tail: TAESDBlock
    @ModuleInfo(key: "convOut") var convOut: Conv2d

    override init() {
        self._convIn.wrappedValue = Conv2d(
            inputChannels: 4, outputChannels: 64, kernelSize: 3, padding: 1)
        self._stage0.wrappedValue = [TAESDBlock(), TAESDBlock(), TAESDBlock()]
        self._up0.wrappedValue = Conv2d(
            inputChannels: 64, outputChannels: 64, kernelSize: 3, padding: 1, bias: false)
        self._stage1.wrappedValue = [TAESDBlock(), TAESDBlock(), TAESDBlock()]
        self._up1.wrappedValue = Conv2d(
            inputChannels: 64, outputChannels: 64, kernelSize: 3, padding: 1, bias: false)
        self._stage2.wrappedValue = [TAESDBlock(), TAESDBlock(), TAESDBlock()]
        self._up2.wrappedValue = Conv2d(
            inputChannels: 64, outputChannels: 64, kernelSize: 3, padding: 1, bias: false)
        self._tail.wrappedValue = TAESDBlock()
        self._convOut.wrappedValue = Conv2d(
            inputChannels: 64, outputChannels: 3, kernelSize: 3, padding: 1)
    }

    func callAsFunction(_ z: MLXArray) -> MLXArray {
        var x = tanh(z / 3) * 3          // Clamp() — the input-range guard; also the reason no
                                         // 0.18215 pre-scaling is needed.
        x = relu(convIn(x))

        for b in stage0 { x = b(x) }
        x = up0(upsampleNearest(x))      // 64 → 128 px

        for b in stage1 { x = b(x) }
        x = up1(upsampleNearest(x))      // 128 → 256 px

        for b in stage2 { x = b(x) }
        x = up2(upsampleNearest(x))      // 256 → 512 px

        x = tail(x)
        x = convOut(x)
        return x                         // already ~[0, 1]; caller clamps
    }

    /// Decode a final latent to pixels, matching the shape/range the draw path expects from the
    /// full-VAE decoder closure: `[B, H*8, W*8, 3]` clamped to [0, 1]. **Feed the RAW latent** —
    /// no `/ scalingFactor`, unlike `Autoencoder.decode`.
    func decodePixels(_ z: MLXArray) -> MLXArray {
        clip(callAsFunction(z), min: 0, max: 1)
    }
}

/// Rewrite a `taesd_decoder.safetensors` key onto this module's key paths, and transpose conv
/// weights from PyTorch layout `[O, I, kH, kW]` to MLX's channels-last `[O, kH, kW, I]` — the same
/// treatment `vaeRemap` gives the full VAE (Load.swift). Returns `nil` for keys we don't own (e.g.
/// stray encoder tensors), which the loader drops.
///
/// The reference decoder is an `nn.Sequential`, so its keys are position-numbered: `1.weight` is
/// `conv(4,64)`, `3.conv.0.weight` is the first block's first conv, `7.weight` is the first
/// post-upsample bias-less conv, and so on. This table maps those leading indices onto the named
/// stages above. ✅ Verified 2026-07-17: the real file's 67 keys map exactly onto this module's 67
/// parameters (see the file header).
nonisolated let taesdIndexMap: [String: String] = [
    "1": "convIn",
    "3": "stage0.0", "4": "stage0.1", "5": "stage0.2",
    "7": "up0",
    "8": "stage1.0", "9": "stage1.1", "10": "stage1.2",
    "12": "up1",
    "13": "stage2.0", "14": "stage2.1", "15": "stage2.2",
    "17": "up2",
    "18": "tail",
    "19": "convOut",
]

nonisolated func taesdRemap(key: String, value: MLXArray) -> [(String, MLXArray)]? {
    // Keys look like "3.conv.0.weight", "1.weight", or "7.weight". Split off the leading index.
    guard let dot = key.firstIndex(of: ".") else { return nil }
    let head = String(key[key.startIndex ..< dot])
    guard let mapped = taesdIndexMap[head] else { return nil }   // not ours — drop it

    // Inside a block, `self.conv` is Sequential(conv, relu, conv, relu, conv) → indices 0/2/4.
    let rest = String(key[key.index(after: dot)...])
        .replacingOccurrences(of: "conv.0.", with: "conv0.")
        .replacingOccurrences(of: "conv.2.", with: "conv1.")
        .replacingOccurrences(of: "conv.4.", with: "conv2.")

    var v = value
    if v.ndim == 4 {
        v = v.transposed(0, 2, 3, 1)
        v = v.reshaped(-1).reshaped(v.shape)   // force contiguity, as vaeRemap does
    }
    return [(mapped + "." + rest, v)]
}

/// Build a TAESD decoder and load its weights from a `taesd_decoder.safetensors` on disk.
/// Weights are float32 (the file is tiny; no reason to quantize the one cheap part of the pipeline).
nonisolated func loadTAESDDecoder(url: URL, dType: DType = .float32) throws -> TAESDDecoder {
    let model = TAESDDecoder()
    let weights = try loadArrays(url: url)
        .compactMap { taesdRemap(key: $0.key, value: $0.value.asType(dType)) }
        .flatMap { $0 }
    try model.update(parameters: ModuleParameters.unflattened(weights), verify: .none)
    eval(model)
    return model
}

nonisolated enum TAESDError: LocalizedError {
    case weightsMissing
    var errorDescription: String? {
        switch self {
        case .weightsMissing:
            return String(
                localized:
                    "The bundled TAESD decoder weights (taesd_decoder.safetensors) were not found in the app bundle."
            )
        }
    }
}

extension TAESDDecoder {
    /// The bundled weights' resource name. The 4.9 MB file rides inside the app (Resources/), MIT
    /// licensed, so the fast/fallback decoder is always available — no download, even offline, even
    /// when a device is too tight to afford the full-VAE decode.
    nonisolated static let bundledResourceName = "taesd_decoder"

    /// Load a fresh TAESD decoder from the app-bundled weights. Cheap enough (4.9 MB) to load
    /// per-draw and drop after, honoring Mark's *"no overhead from one frame into the next."*
    nonisolated static func bundled() throws -> TAESDDecoder {
        guard
            let url = Bundle.main.url(
                forResource: bundledResourceName, withExtension: "safetensors")
        else {
            throw TAESDError.weightsMissing
        }
        return try loadTAESDDecoder(url: url)
    }
}

// ==== LEGO END: 29 TAESD (A Tiny, Low-Memory Decoder For The Drawing) ====
