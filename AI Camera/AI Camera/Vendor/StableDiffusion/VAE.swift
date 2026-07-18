// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXNN

// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/vae.py

nonisolated class Attention: Module, UnaryLayer {

    @ModuleInfo(key: "group_norm") public var groupNorm: GroupNorm

    @ModuleInfo(key: "query_proj") public var queryProjection: Linear
    @ModuleInfo(key: "key_proj") public var keyProjection: Linear
    @ModuleInfo(key: "value_proj") public var valueProjection: Linear
    @ModuleInfo(key: "out_proj") public var outProjection: Linear

    init(dimensions: Int, groupCount: Int = 32) {
        self._groupNorm.wrappedValue = GroupNorm(
            groupCount: groupCount, dimensions: dimensions, pytorchCompatible: true)

        self._queryProjection.wrappedValue = Linear(dimensions, dimensions)
        self._keyProjection.wrappedValue = Linear(dimensions, dimensions)
        self._valueProjection.wrappedValue = Linear(dimensions, dimensions)
        self._outProjection.wrappedValue = Linear(dimensions, dimensions)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (B, H, W, C) = x.shape4

        var y = groupNorm(x)

        let queries = queryProjection(y).reshaped(B, H * W, C)
        let keys = keyProjection(y).reshaped(B, H * W, C)
        let values = valueProjection(y).reshaped(B, H * W, C)

        let scale = 1 / sqrt(Float(queries.dim(-1)))
        let scores = (queries * scale).matmul(keys.transposed(0, 2, 1))
        let attention = softmax(scores, axis: -1)

        y = matmul(attention, values).reshaped(B, H, W, C)
        y = outProjection(y)

        return x + y
    }
}

nonisolated class EncoderDecoderBlock2D: Module, UnaryLayer {

    let resnets: [ResnetBlock2D]
    let downsample: Conv2d?
    let upsample: Conv2d?

    init(
        inputChannels: Int, outputChannels: Int, numLayers: Int = 1, resnetGroups: Int = 32,
        addDownSample: Bool = true, addUpSample: Bool = true
    ) {
        // Add the resnet blocks
        self.resnets = (0 ..< numLayers)
            .map { i in
                ResnetBlock2D(
                    inputChannels: i == 0 ? inputChannels : outputChannels,
                    outputChannels: outputChannels,
                    groupCount: resnetGroups)
            }

        // Add an optional downsampling layer
        if addDownSample {
            self.downsample = Conv2d(
                inputChannels: outputChannels, outputChannels: outputChannels, kernelSize: 3,
                stride: 2, padding: 0)
        } else {
            self.downsample = nil
        }

        // or upsampling layer
        if addUpSample {
            self.upsample = Conv2d(
                inputChannels: outputChannels, outputChannels: outputChannels, kernelSize: 3,
                stride: 1, padding: 1)
        } else {
            self.upsample = nil
        }
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x

        for resnet in resnets {
            x = resnet(x)
        }

        if let downsample {
            x = padded(x, widths: [[0, 0], [0, 1], [0, 1], [0, 0]])
            x = downsample(x)
        }

        if let upsample {
            x = upsample(upsampleNearest(x))
        }

        return x
    }
}

/// Implements the encoder side of the Autoencoder
nonisolated class VAEncoder: Module, UnaryLayer {

    @ModuleInfo(key: "conv_in") var convIn: Conv2d
    @ModuleInfo(key: "down_blocks") var downBlocks: [EncoderDecoderBlock2D]
    @ModuleInfo(key: "mid_blocks") var midBlocks: (ResnetBlock2D, Attention, ResnetBlock2D)
    @ModuleInfo(key: "conv_norm_out") var convNormOut: GroupNorm
    @ModuleInfo(key: "conv_out") var convOut: Conv2d

    init(
        inputChannels: Int, outputChannels: Int, blockOutChannels: [Int] = [64],
        layersPerBlock: Int = 2, resnetGroups: Int = 32
    ) {
        let channels0 = blockOutChannels[0]

        self._convIn.wrappedValue = Conv2d(
            inputChannels: inputChannels, outputChannels: channels0, kernelSize: 3, stride: 1,
            padding: 1)

        let downblockChannels = [channels0] + blockOutChannels
        self._downBlocks.wrappedValue = zip(downblockChannels, downblockChannels.dropFirst())
            .enumerated()
            .map { (i, pair) in
                let (inChannels, outChannels) = pair
                return EncoderDecoderBlock2D(
                    inputChannels: inChannels, outputChannels: outChannels,
                    numLayers: layersPerBlock, resnetGroups: resnetGroups,
                    addDownSample: i < blockOutChannels.count - 1,
                    addUpSample: false
                )
            }

        let channelsLast = blockOutChannels.last!
        self._midBlocks.wrappedValue = (
            ResnetBlock2D(
                inputChannels: channelsLast,
                outputChannels: channelsLast,
                groupCount: resnetGroups
            ),
            Attention(dimensions: channelsLast, groupCount: resnetGroups),
            ResnetBlock2D(
                inputChannels: channelsLast,
                outputChannels: channelsLast,
                groupCount: resnetGroups
            )
        )

        self._convNormOut.wrappedValue = GroupNorm(
            groupCount: resnetGroups, dimensions: channelsLast, pytorchCompatible: true)
        self._convOut.wrappedValue = Conv2d(
            inputChannels: channelsLast, outputChannels: outputChannels,
            kernelSize: 3,
            padding: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = convIn(x)

        for l in downBlocks {
            x = l(x)
        }

        x = midBlocks.0(x)
        x = midBlocks.1(x)
        x = midBlocks.2(x)

        x = convNormOut(x)
        x = silu(x)
        x = convOut(x)

        return x
    }
}

/// Implements the decoder side of the Autoencoder
nonisolated class VADecoder: Module, UnaryLayer {

    @ModuleInfo(key: "conv_in") var convIn: Conv2d
    @ModuleInfo(key: "mid_blocks") var midBlocks: (ResnetBlock2D, Attention, ResnetBlock2D)
    @ModuleInfo(key: "up_blocks") var upBlocks: [EncoderDecoderBlock2D]
    @ModuleInfo(key: "conv_norm_out") var convNormOut: GroupNorm
    @ModuleInfo(key: "conv_out") var convOut: Conv2d

    init(
        inputChannels: Int, outputChannels: Int, blockOutChannels: [Int] = [64],
        layersPerBlock: Int = 2, resnetGroups: Int = 32
    ) {
        let channels0 = blockOutChannels[0]
        let channelsLast = blockOutChannels.last!

        self._convIn.wrappedValue = Conv2d(
            inputChannels: inputChannels, outputChannels: channelsLast, kernelSize: 3, stride: 1,
            padding: 1)

        self._midBlocks.wrappedValue = (
            ResnetBlock2D(
                inputChannels: channelsLast,
                outputChannels: channelsLast,
                groupCount: resnetGroups
            ),
            Attention(dimensions: channelsLast, groupCount: resnetGroups),
            ResnetBlock2D(
                inputChannels: channelsLast,
                outputChannels: channelsLast,
                groupCount: resnetGroups
            )
        )

        let channels = [channelsLast] + blockOutChannels.reversed()
        self._upBlocks.wrappedValue = zip(channels, channels.dropFirst())
            .enumerated()
            .map { (i, pair) in
                let (inChannels, outChannels) = pair
                return EncoderDecoderBlock2D(
                    inputChannels: inChannels,
                    outputChannels: outChannels,
                    numLayers: layersPerBlock,
                    resnetGroups: resnetGroups,
                    addDownSample: false,
                    addUpSample: i < blockOutChannels.count - 1
                )
            }

        self._convNormOut.wrappedValue = GroupNorm(
            groupCount: resnetGroups, dimensions: channels0, pytorchCompatible: true)
        self._convOut.wrappedValue = Conv2d(
            inputChannels: channels0, outputChannels: outputChannels,
            kernelSize: 3,
            padding: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = convIn(x)

        x = midBlocks.0(x)
        x = midBlocks.1(x)
        x = midBlocks.2(x)

        for l in upBlocks {
            x = l(x)
        }

        x = convNormOut(x)
        x = silu(x)
        x = convOut(x)

        return x
    }
}

/// The autoencoder that allows us to perform diffusion in the latent space
nonisolated class Autoencoder: Module {

    let latentChannels: Int
    let scalingFactor: Float
    let encoder: VAEncoder
    let decoder: VADecoder

    @ModuleInfo(key: "quant_proj") public var quantProjection: Linear
    @ModuleInfo(key: "post_quant_proj") public var postQuantProjection: Linear

    init(configuration: AutoencoderConfiguration) {
        self.latentChannels = configuration.latentChannelsIn
        self.scalingFactor = configuration.scalingFactor
        self.encoder = VAEncoder(
            inputChannels: configuration.inputChannels,
            outputChannels: configuration.latentChannelsOut,
            blockOutChannels: configuration.blockOutChannels,
            layersPerBlock: configuration.layersPerBlock,
            resnetGroups: configuration.normNumGroups)
        self.decoder = VADecoder(
            inputChannels: configuration.latentChannelsIn,
            outputChannels: configuration.outputChannels,
            blockOutChannels: configuration.blockOutChannels,
            layersPerBlock: configuration.layersPerBlock + 1,
            resnetGroups: configuration.normNumGroups)

        self._quantProjection.wrappedValue = Linear(
            configuration.latentChannelsIn, configuration.latentChannelsOut)
        self._postQuantProjection.wrappedValue = Linear(
            configuration.latentChannelsIn, configuration.latentChannelsIn)
    }

    func decode(_ z: MLXArray) -> MLXArray {
        let z = z / scalingFactor
        return decoder(postQuantProjection(z))
    }

    /// Tiled VAE decode — the same result as ``decode(_:)``, but with peak memory bounded to a
    /// fraction of the whole image. **AI Camera addition (not upstream); recorded in VENDOR.md.**
    ///
    /// Why it exists: the monolithic decode inflates a 64×64×4 latent to 512×512×3 through the
    /// upsampling conv stack, and its intermediate activations peaked **~4.5 GB** on an iPhone —
    /// over the ~6 GB process ceiling once the app is resident, so the process was jetsammed at
    /// the decode *every time* (measured 2026-07-15). The denoise, by contrast, runs entirely at
    /// 64×64 and is cheap. So the fix is here and only here: decode the latent in overlapping
    /// spatial tiles, each a fraction of the area, and feather the pixel overlaps back together.
    /// Peak scales with the tile, not the whole image.
    ///
    /// This is `diffusers`' `enable_vae_tiling` in miniature. Two honest costs. **(1)** The
    /// decoder's GroupNorm and its bottleneck self-attention normalize/attend *within* whatever
    /// they are handed, so a tile's statistics differ slightly from the whole — the
    /// overlap-and-feather is what hides the resulting seam, and why the overlap must be generous
    /// (wider than the conv receptive field, so a tile's zero-padded borders are down-weighted to
    /// nothing and its neighbour's interior carries that region). **(2)** It runs the decoder once
    /// per tile, so it is slower. Both are the right trade: *the latency is the film developing*,
    /// and a shot that finishes softly beats a process that dies.
    ///
    /// Model-agnostic: it tiles the *latent*, so it works for any KL-f8 SD-family autoencoder
    /// (sd-turbo, SD 1.5, SDXL) without change — the safety net for every drawer we add.
    ///
    /// - Parameters:
    ///   - z: the final latent, `[B, H, W, C]` (this app draws one image, so `B == 1`).
    ///   - tileLatent: tile edge in *latent* units. The pixel tile is this × the VAE's 8× upsample.
    ///   - overlapLatent: overlap between neighbouring tiles, in latent units. Wider = smoother seam.
    func decodeTiled(_ z: MLXArray, tileLatent: Int, overlapLatent: Int) -> MLXArray {
        let (B, H, W, C) = z.shape4

        // Already a single tile? Then there is nothing to tile — one plain decode, no overhead.
        if H <= tileLatent && W <= tileLatent {
            return decode(z)
        }

        let ys = Autoencoder.tilePositions(total: H, tile: tileLatent, overlap: overlapLatent)
        let xs = Autoencoder.tilePositions(total: W, tile: tileLatent, overlap: overlapLatent)

        var acc: MLXArray? = nil   // Σ (tile pixels · weight)
        var wacc: MLXArray? = nil  // Σ weight — the per-pixel normaliser

        for y0 in ys {
            let th = min(tileLatent, H - y0)
            for x0 in xs {
                let tw = min(tileLatent, W - x0)

                // Decode just this latent tile. `decode` is `z/scale → postQuant → decoder`; the
                // first two are pointwise (per-pixel, per-channel), so a decoded tile equals the
                // matching crop of a full decode up to the conv receptive field and the
                // norm/attention locality above — exactly what the feather absorbs.
                let zt = z[0 ..< B, y0 ..< (y0 + th), x0 ..< (x0 + tw), 0 ..< C]
                let px = decode(zt).squeezed()          // [th*scale, tw*scale, 3]

                let (ph, pw, _) = px.shape3
                let scale = ph / th                     // the VAE's spatial upsample (8 for KL-f8)

                // Feather window: tapers to a small positive floor at every edge, so overlapping
                // tiles blend AND the normaliser is never exactly zero anywhere (no 0/0 at a
                // corner covered by a single tile).
                let taper = overlapLatent * scale
                let wy = Autoencoder.taperWindow(length: ph, taper: taper)
                let wx = Autoencoder.taperWindow(length: pw, taper: taper)
                let w = wy.reshaped(ph, 1, 1) * wx.reshaped(1, pw, 1)   // [ph, pw, 1]

                // Place the weighted tile into the full canvas by zero-padding it out to its
                // offset, then accumulate. Only one padded canvas is alive per iteration and the
                // accumulator is a single 512×512 float image (~3 MB), so the stitching's own
                // footprint is negligible next to a decode.
                let top = y0 * scale
                let left = x0 * scale
                let bottom = (H * scale) - top - ph
                let right = (W * scale) - left - pw

                let contribPx = padded(px * w, widths: [[top, bottom], [left, right], [0, 0]])
                let contribW = padded(w, widths: [[top, bottom], [left, right], [0, 0]])

                acc = acc == nil ? contribPx : acc! + contribPx
                wacc = wacc == nil ? contribW : wacc! + contribW

                // Evaluate the running sums each tile so the lazy graph — and the tile's own
                // activations — do not pile up across the loop. This is what keeps the peak
                // bounded to one tile at a time rather than all of them at once.
                eval(acc!, wacc!)
            }
        }

        // Restore the leading batch dim that `decode` returns, so callers see an identical shape.
        return (acc! / wacc!)[.newAxis]
    }

    /// Start offsets that cover `total` with tiles of edge `tile`, each overlapping its
    /// predecessor by at least `overlap`, with the final tile flush to the end. Ascending, deduped.
    static func tilePositions(total: Int, tile: Int, overlap: Int) -> [Int] {
        if total <= tile { return [0] }
        let step = max(1, tile - overlap)
        var positions: [Int] = []
        var start = 0
        while true {
            if start + tile >= total {
                positions.append(total - tile)   // last tile flush to the end
                break
            }
            positions.append(start)
            start += step
        }
        // The flush-to-end tile can land on a stride point; drop the exact duplicate if so.
        var unique: [Int] = []
        for p in positions where unique.last != p { unique.append(p) }
        return unique
    }

    /// A 1-D blend window: ramps from a small positive floor up to 1 across `taper` samples at each
    /// end, flat 1 in the middle. It never reaches 0, so summed across overlapping tiles it forms a
    /// valid partition of unity everywhere — no division-by-zero in the normaliser, even at an
    /// image corner covered by only one tile.
    static func taperWindow(length: Int, taper: Int) -> MLXArray {
        let floor: Float = 0.01
        let t = max(1, min(taper, length / 2))
        var w = [Float](repeating: 1, count: length)
        for i in 0 ..< t {
            let v = floor + (1 - floor) * Float(i + 1) / Float(t + 1)
            w[i] = v                       // leading ramp
            w[length - 1 - i] = v          // trailing ramp (symmetric)
        }
        return MLXArray(w)
    }

    func encode(_ x: MLXArray) -> (MLXArray, MLXArray) {
        var x = encoder(x)
        x = quantProjection(x)
        var (mean, logvar) = x.split(axis: -1)
        mean = mean * scalingFactor
        logvar = logvar + 2 * log(scalingFactor)

        return (mean, logvar)
    }

    struct Result {
        let xHat: MLXArray
        let z: MLXArray
        let mean: MLXArray
        let logvar: MLXArray
    }

    func callAsFunction(_ x: MLXArray, key: MLXArray? = nil) -> Result {
        let (mean, logvar) = encode(x)
        let z = MLXRandom.normal(mean.shape, key: key) * exp(0.5 * logvar) + mean
        let xHat = decode(z)

        return Result(xHat: xHat, z: z, mean: mean, logvar: logvar)
    }
}
