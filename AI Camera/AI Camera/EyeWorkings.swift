//
//  EyeWorkings.swift
//  Thomas
//
//  The eye's workings, for the Developer Tray: the numbers the eye made of the photograph
//  before it said a word, and where it looked as it chose each word. Real data only.
//

import Accelerate
import Foundation
import MLX
import MLXLMCommon

// ==== LEGO START: 39 The Eye's Workings (The Numbers, And Where Each Word Looked) ====

/// What the eye did on its way to the words, as the Developer Tray shows it.
///
/// Two things, both read straight out of the running model (Thomas's vendored copy of Qwen
/// 3.5, `Vendor/QwenVLM`; the library's own copy cannot be watched):
///
/// - **The numbers.** The vision encoder turns the photograph into a grid of squares, and each
///   square into a list of 2,048 numbers. That grid is the machine's whole understanding of the
///   picture, and it exists before any word (CLAUDE.md, "the encoder output IS the seam").
/// - **The gaze.** As the language half chooses each word, it attends over everything it has
///   in front of it, the image squares included. `gaze` is how much of that attention landed on
///   each square, measured in Qwen's 6 full-attention layers (the other 18 are a different kind
///   of layer that has no attention to read) and averaged over 8 heads. `imageShare` is the
///   fraction of the attention that went to the picture at all; the rest went to the words.
///
/// Nothing here is smoothed, rescaled or guessed. The tray compares squares over all of their
/// numbers (`EyeLikeness`), and the raw numbers stay one tap away.
nonisolated struct EyeWorkings: Sendable {
    struct Piece: Sendable {
        let text: String       // the word piece exactly as the tokenizer spells it
        let gaze: [Float]      // one value per square, rows then columns; sums to imageShare
        let imageShare: Float
        /// The whole attention row this word was chosen with: one value per position before it, in
        /// order (the prompt, whose image squares sit at `promptImagePositions`, then every earlier
        /// word piece). Sums to 1. The part that is not `gaze` is the attention that went to words:
        /// its instructions and what it had already said. Empty when not recorded (shots kept
        /// before 2026-11-12 recorded only the picture's part).
        var context: [Float] = []
    }

    let model: String
    var features: [Float] = []   // [squares, width] row-major, squares in reading order
    var width = 0                // numbers per square (2,048 for Qwen3.5-2B)
    var rows = 0                 // the grid after the encoder's 2x2 merge
    var cols = 0
    var pieces: [Piece] = []
    /// The prompt the eye was given, one entry per token as the tokenizer spells it (image
    /// squares are ""), and where in it the squares sit. Lets `Piece.context` be read as words.
    var promptPieces: [String] = []
    var promptImagePositions: [Int] = []
    var done = false
    /// Wall time spent inside the recorder on the model's thread, for the whole look. Mostly time
    /// spent waiting for GPU work the look does anyway; the real added cost is measured by comparing
    /// looks with and without recording (about a quarter second on a 3-4 s look, iPhone 16 Plus,
    /// 2026-11-05).
    var recorderMS: Double = 0
    /// How the gaze was measured, as counted while recording: attention layers read per word, and
    /// attention heads averaged in each.
    var layers = 0
    var heads = 0

    var squares: Int { rows * cols }

    /// The raw numbers of one square.
    func numbers(ofSquare i: Int) -> ArraySlice<Float> {
        guard i >= 0, i < squares, width > 0, features.count >= (i + 1) * width else { return [] }
        return features[(i * width)..<((i + 1) * width)]
    }
}

/// Watches the instrumented Qwen while a shot's eye is looking, and files what it sees into
/// `DevelopTrace`.
///
/// The model calls in from its own thread (`noteImage`, `noteGaze`, `flushStep`); `MLXVLMEye`
/// opens and closes the look. **It records only when a developing shot is waiting for its eye**
/// (`DevelopTrace.openEyeRecording`), so the condense call that follows, an antenna `/look`, or
/// any other use of the eye costs nothing extra: the model takes the library's own path.
///
/// Built to stay off the words' critical path. Each layer's gaze is computed lazily on the GPU
/// and never waited on there; the step's gaze is sent with `asyncEval` and only read one step
/// later, by which time it is long finished. The single synchronous read is the encoder's
/// numbers, once per look.
///
/// Alignment, which is easy to get wrong: the attention measured during a forward pass is the
/// look that CHOOSES the next token, and that token only becomes visible as the input of the
/// following pass. So each step's gaze waits as `pending` and is paired with the next step's
/// input. The last pass's gaze chooses the end-of-text marker and is dropped.
nonisolated final class EyeRecorder: @unchecked Sendable {
    static let shared = EyeRecorder()
    private let lock = NSLock()

    private var recording = false
    private var tokenizer: (any Tokenizer)?
    private var imagePositions: MLXArray?
    private var layerGaze: [MLXArray] = []
    private var layerShare: [MLXArray] = []
    private var layerRow: [MLXArray] = []
    private var pending: (gaze: MLXArray, share: MLXArray, row: MLXArray)?
    private var unread: [(token: MLXArray, gaze: MLXArray, share: MLXArray, row: MLXArray)] = []
    private var spent: Double = 0
    private var pieceCount = 0
    private var layersSeen = 0
    private var headsSeen = 0

    /// Cheap enough to ask once per attention layer.
    var isRecording: Bool { lock.withLock { recording && imagePositions != nil } }

    /// Start watching, if a developing shot is waiting for this look. Returns whether it is.
    @discardableResult
    func beginLook(model: String, tokenizer: any Tokenizer) -> Bool {
        guard DevelopTrace.shared.openEyeRecording(model: model) else { return false }
        lock.withLock {
            recording = true
            self.tokenizer = tokenizer
            imagePositions = nil
            layerGaze = []; layerShare = []; layerRow = []
            pending = nil; unread = []
            spent = 0; pieceCount = 0; layersSeen = 0; headsSeen = 0
        }
        return true
    }

    /// The look is over (spoken, or failed). Read what is left, drop the end-of-text gaze, and
    /// close the record. Safe to call when nothing was recorded.
    func endLook(lookSeconds: Double) {
        let wasRecording = lock.withLock { recording }
        guard wasRecording else { return }
        let started = CFAbsoluteTimeGetCurrent()
        drain()
        let (ms, layers, heads) = lock.withLock { () -> (Double, Int, Int) in
            recording = false
            tokenizer = nil
            imagePositions = nil
            layerGaze = []; layerShare = []; layerRow = []
            pending = nil; unread = []
            spent += CFAbsoluteTimeGetCurrent() - started
            return (spent * 1000, layersSeen, headsSeen)
        }
        DevelopTrace.shared.finishEyeRecording(recorderMS: ms, layers: layers, heads: heads)
        cameraLog("EYE TRACE: \(pieceCount) word pieces recorded; recorder \(String(format: "%.0f", ms)) ms of a \(String(format: "%.1f", lookSeconds)) s look")
    }

    // MARK: Called by the model (Vendor/QwenVLM/Qwen35.swift, the lines marked THOMAS)

    /// A new prompt is being prepared: its image positions are not the last prompt's.
    func newPrompt() {
        lock.withLock { imagePositions = nil; layerGaze = []; layerShare = []; layerRow = []; pending = nil }
    }

    /// The vision encoder has turned the photograph into numbers. `grid` is (t, h, w) in
    /// patches before the encoder's 2x2 merge.
    func noteImage(features: MLXArray, grid: [Int], inputIds: MLXArray, imageTokenIndex: Int) {
        guard lock.withLock({ recording }) else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let ids = inputIds.flattened().asArray(Int32.self)
        let positions = ids.enumerated().compactMap { Int($0.element) == imageTokenIndex ? Int32($0.offset) : nil }
        let f32 = features.asType(.float32)
        eval(f32)
        let shape = f32.shape
        let rows = grid.count == 3 ? grid[1] / 2 : 0
        let cols = grid.count == 3 ? grid[2] / 2 : 0
        let usable = shape.count == 2 && rows * cols == shape[0] && positions.count == shape[0]
        if usable {
            DevelopTrace.shared.noteEyeNumbers(f32.asArray(Float.self), width: shape[1], rows: rows, cols: cols)
            let tok = lock.withLock { tokenizer }
            let image = Set(positions.map(Int.init))
            let spelled = ids.enumerated().map { i, id in
                image.contains(i) ? "" : (tok?.decode(tokenIds: [Int(id)], skipSpecialTokens: false) ?? "")
            }
            DevelopTrace.shared.noteEyePrompt(spelled, imagePositions: positions.map(Int.init))
        } else {
            cameraLog("EYE TRACE: shapes disagree (features \(shape), grid \(grid), image tokens \(positions.count)); not recording this look")
        }
        lock.withLock {
            imagePositions = usable ? MLXArray(positions) : nil
            spent += CFAbsoluteTimeGetCurrent() - started
        }
    }

    /// One full-attention layer's look. `queries` is [1, H, L, D], `keys` the whole cache so far
    /// [1, KV, T, D]. Only the last query row matters: it is the one choosing the next token.
    func noteGaze(queries: MLXArray, keys: MLXArray, scale: Float) {
        let started = CFAbsoluteTimeGetCurrent()
        guard let positions = lock.withLock({ recording ? imagePositions : nil }) else { return }
        let heads = queries.dim(1), kvHeads = keys.dim(1), length = queries.dim(2), depth = queries.dim(3)
        guard kvHeads > 0, heads % kvHeads == 0 else { return }
        // Grouped heads: query head h reads key head h / (heads / kvHeads). Grouping the queries
        // instead of repeating the keys gives the same scores without copying the cache.
        let last = queries[0..., 0..., (length - 1)..., 0...].asType(.float32)
            .reshaped(1, kvHeads, heads / kvHeads, depth)
        let scores = softmax(matmul(last * scale, keys.asType(.float32).transposed(0, 1, 3, 2)), axis: -1)
            .reshaped(heads, -1)                                    // [H, T]
        let onImage = take(scores, positions, axis: 1)              // [H, squares]
        let gaze = onImage.mean(axis: 0)                            // [squares]
        let share = onImage.sum(axis: 1).mean()                     // scalar
        let row = scores.mean(axis: 0)                              // [T]: everything, words included
        lock.withLock {
            layerGaze.append(gaze); layerShare.append(share); layerRow.append(row)
            headsSeen = heads
            spent += CFAbsoluteTimeGetCurrent() - started
        }
    }

    /// One forward pass is done. `inputToken` is the token this pass took in (nil for the
    /// prompt), which is the word the PREVIOUS pass's gaze chose.
    func flushStep(inputToken: MLXArray?) {
        guard lock.withLock({ recording }) else { return }
        let started = CFAbsoluteTimeGetCurrent()
        drain()   // last step's pieces: finished on the GPU long ago, so this never waits
        lock.withLock {
            var current: (gaze: MLXArray, share: MLXArray, row: MLXArray)?
            if !layerGaze.isEmpty {
                layersSeen = layerGaze.count
                let g = stacked(layerGaze).mean(axis: 0)
                let s = stacked(layerShare).mean()
                let r = stacked(layerRow).mean(axis: 0)
                asyncEval(g, s, r)
                current = (g, s, r)
            }
            if let inputToken, let pending { unread.append((inputToken, pending.gaze, pending.share, pending.row)) }
            pending = current
            layerGaze = []; layerShare = []; layerRow = []
            spent += CFAbsoluteTimeGetCurrent() - started
        }
    }

    /// Turn finished pieces into values and file them.
    private func drain() {
        let (batch, tok) = lock.withLock { () -> ([(token: MLXArray, gaze: MLXArray, share: MLXArray, row: MLXArray)], (any Tokenizer)?) in
            let b = unread; unread = []; return (b, tokenizer)
        }
        guard !batch.isEmpty, let tok else { return }
        for entry in batch {
            let id = Int(entry.token.flattened()[0].item(Int32.self))
            let text = tok.decode(tokenIds: [id], skipSpecialTokens: true)
            DevelopTrace.shared.appendEyePiece(.init(text: text, gaze: entry.gaze.asArray(Float.self),
                                                     imageShare: entry.share.item(Float.self),
                                                     context: entry.row.asArray(Float.self)))
            lock.withLock { pieceCount += 1 }
        }
    }
}

/// How alike the squares are, measured over ALL of their numbers at once (Mark, 2026-11-12: of
/// the ways tried in the design pass, this one shows the numbers without summarizing them).
///
/// Tap a square and every square lights by the cosine similarity of its 2,048 numbers to the tapped
/// square's: 1 means the same direction, 0 unrelated, below 0 opposite. Each of the 2,048 numbers
/// is first centered across the squares (the photograph's average square is taken away), so what
/// every square shares does not make them all look alike; what remains is how each square differs.
/// Nothing is dropped: every number of every square enters every comparison.
///
/// Cheap: one centering pass when the numbers arrive, then each tap is 144 dot products of 2,048.
nonisolated struct EyeLikeness: Sendable {
    let squares: Int
    let width: Int
    private let centered: [Float]   // [squares, width]
    private let norms: [Float]

    init?(_ w: EyeWorkings) {
        let n = w.squares, d = w.width
        guard n > 1, d > 0, w.features.count == n * d else { return nil }
        var x = w.features
        var mean = [Float](repeating: 0, count: d)
        for i in 0..<n { x.withUnsafeBufferPointer { vDSP_vadd($0.baseAddress! + i * d, 1, mean, 1, &mean, 1, vDSP_Length(d)) } }
        var inverse = 1 / Float(n)
        vDSP_vsmul(mean, 1, &inverse, &mean, 1, vDSP_Length(d))
        var norms = [Float](repeating: 0, count: n)
        x.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                let row = buf.baseAddress! + i * d
                vDSP_vsub(mean, 1, row, 1, row, 1, vDSP_Length(d))   // row - mean
                var sq: Float = 0
                vDSP_svesq(row, 1, &sq, vDSP_Length(d))
                norms[i] = sq.squareRoot()
            }
        }
        squares = n; width = d; centered = x; self.norms = norms
    }

    /// Every square's likeness to square `i`, from -1 to 1 (square `i` itself is 1).
    func alike(to i: Int) -> [Float] {
        guard i >= 0, i < squares, norms[i] > 0 else { return [Float](repeating: 0, count: squares) }
        var dots = [Float](repeating: 0, count: squares)
        centered.withUnsafeBufferPointer { buf in
            vDSP_mmul(buf.baseAddress!, 1, buf.baseAddress! + i * width, 1, &dots, 1,
                      vDSP_Length(squares), 1, vDSP_Length(width))
        }
        return dots.indices.map { j in norms[j] > 0 ? dots[j] / (norms[j] * norms[i]) : 0 }
    }
}

// ==== LEGO END: 39 The Eye's Workings (The Numbers, And Where Each Word Looked) ====
