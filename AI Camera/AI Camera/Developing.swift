//
//  Developing.swift
//  AI Camera
//
//  The darkroom. Takes a photograph, the machine's words, and the world's receipt, and
//  composes the finished frame.
//
//  The grammar is Mark's book (*Making Change*), and it is not decoration:
//    - letterbox bars, top and bottom
//    - heavy sans superimposed on the image, upper left
//    - a metadata footer: PLACE bottom-left (GPS), DATE bottom-right (the clock)
//
//  Why the footer is load-bearing: the machine asserts, and the photograph and the
//  metadata testify. Panel 1 is what was actually there; the stamp says where and when,
//  and both are free — no model, no latency, no tokens. Cameras have printed the date on
//  the frame since long before any of this.
//
//  ⚠️ Principle 3 lives here too. The words go on the image with NO disclaimer, NO
//  confidence score, and no "AI-generated" chrome. The juxtaposition IS the disclaimer:
//  the photograph is right there, and the viewer judges. That's what earns the right to
//  state the claim flatly.
//

import CoreGraphics
import CoreImage
import ImageIO
import UIKit

// ==== LEGO START: 16 The Darkroom (Compositor) ====

/// How the words meet the photograph.
///
/// Deliberately a **small, tested set** — not a freeform editor (CLAUDE.md, "The visual
/// language"). Every option here is a property of the loaded film, chosen before the
/// shutter, never per-shot.
/// The five families a layout can belong to. Drives the grouped, content-aware layout picker
/// (2026-07-27): the menu shows these as sections, offering only the variants the current eye/hand
/// state can actually produce.
nonisolated enum LayoutCategory: String, CaseIterable, Sendable {
    case superimposed, single, diptych, triptych, separate
    var title: String {
        switch self {
        case .superimposed: return "Superimposed"
        case .single:       return "Single"
        case .diptych:      return "Diptych"
        case .triptych:     return "Triptych"
        case .separate:     return "Separate files"
        }
    }
}

nonisolated enum Layout: String, CaseIterable, Sendable {
    // ── Superimposed: the machine's words laid ON one image (no scrim, no box). ──
    /// Words over the PHOTOGRAPH — the claim on the reality it describes.
    case superimposed
    /// Words over the DRAWING — the claim on the machine's own re-imagining (2026-07-27). A new
    /// artifact: the same words, over reality vs over the reinvention, is the gap in one frame.
    case superimposedOnDrawing

    // ── Single: one panel. ──
    /// **Just the words.** Mark's original idea — *"initially, I just wanted the words."* The
    /// photograph was taken; you keep only what the machine said about a moment nobody can check.
    case textOnly
    /// Just the drawing — the machine's re-imagining, standing alone (2026-07-27).
    case singleDrawing
    /// Just the photograph — reality, framed, no words (2026-07-27).
    case singlePhoto

    // ── Diptych: two panels, side by side. ──
    /// Photo + words, words LEFT.  /  words RIGHT. The claim beside the evidence, arguing.
    case diptychTextLeft
    case diptychTextRight
    /// Photo + drawing, drawing LEFT.  /  drawing RIGHT (2026-07-27). Reality beside its
    /// re-imagining, both squared to the hand's shape.
    case diptychDrawingLeft
    case diptychDrawingRight

    // ── Triptych: all three frames in one plate. ──
    case triptychVertical
    case triptychHorizontal

    // ── Separate files: each artifact its own image. ──
    /// Distinct files at their **own natural ratios**. (`rawValue "separate"` preserved so old
    /// saved settings still load.)
    case separateNative = "separate"
    /// Distinct files all **matched to the drawer's square** so they pair. Photo centre-cropped.
    case separateSquare

    /// Which family this layout belongs to (drives the grouped picker).
    var category: LayoutCategory {
        switch self {
        case .superimposed, .superimposedOnDrawing:                       return .superimposed
        case .textOnly, .singleDrawing, .singlePhoto:                     return .single
        case .diptychTextLeft, .diptychTextRight,
             .diptychDrawingLeft, .diptychDrawingRight:                   return .diptych
        case .triptychVertical, .triptychHorizontal:                      return .triptych
        case .separateNative, .separateSquare:                            return .separate
        }
    }

    /// Short label shown INSIDE a category section in the picker (the category header carries the
    /// rest of the context, so these stay terse — Mark's readability ask, 2026-07-27).
    var shortName: String {
        switch self {
        case .superimposed:          return "On the photo"
        case .superimposedOnDrawing: return "On the drawing"
        case .textOnly:              return "Words only"
        case .singleDrawing:         return "Drawing only"
        case .singlePhoto:           return "Photo only"
        case .diptychTextLeft:       return "Words · photo"
        case .diptychTextRight:      return "Photo · words"
        case .diptychDrawingLeft:    return "Drawing · photo"
        case .diptychDrawingRight:   return "Photo · drawing"
        case .triptychVertical:      return "Vertical"
        case .triptychHorizontal:    return "Horizontal"
        case .separateNative:        return "Native ratios"
        case .separateSquare:        return "Square"
        }
    }

    /// Full name — for the picker's current-selection label and accessibility.
    var name: String {
        "\(category.title) · \(shortName)"
    }

    /// Whether this layout needs the eye's WORDS to exist. If the eye is off (silent loop), every
    /// word-bearing layout is unavailable.
    var needsEye: Bool {
        switch self {
        case .singleDrawing, .singlePhoto, .diptychDrawingLeft, .diptychDrawingRight: return false
        default:                                                                       return true
        }
    }

    /// Whether this layout needs the DRAWING to exist. If the hand is off, every drawing-bearing
    /// layout is unavailable — which is what retires the "triptych stuck on when the hand's off" bug.
    var needsHand: Bool {
        switch self {
        case .superimposedOnDrawing, .singleDrawing,
             .diptychDrawingLeft, .diptychDrawingRight,
             .triptychVertical, .triptychHorizontal: return true
        default:                                     return false
        }
    }

    /// Can this layout actually be PRODUCED given what's switched on? The one rule the picker filters
    /// by, so no selectable layout ever conflicts with the eye/hand toggles (Mark, 2026-07-27).
    func isAvailable(hasEye: Bool, hasHand: Bool) -> Bool {
        (!needsEye || hasEye) && (!needsHand || hasHand)
    }

    /// A sensible layout to fall back to when the selected one becomes unavailable (a toggle flipped).
    /// Prefers the richest thing the current state can make; `singlePhoto` always qualifies.
    static func fallback(hasEye: Bool, hasHand: Bool) -> Layout {
        let order: [Layout] = [.superimposed, .triptychVertical, .diptychTextLeft,
                               .superimposedOnDrawing, .diptychDrawingLeft, .singleDrawing,
                               .textOnly, .singlePhoto]
        return order.first { $0.isAvailable(hasEye: hasEye, hasHand: hasHand) } ?? .singlePhoto
    }

    var isDiptych: Bool { self == .diptychTextLeft || self == .diptychTextRight }
    var isTriptych: Bool { self == .triptychVertical || self == .triptychHorizontal }

    /// The layouts that shoot **square** — where the hand (the square drawer) trumps the camera
    /// because its output must match the others in one composition (Triptych, photo+drawing Diptych)
    /// or as equal separate files (Separate — square). Triggers the square viewfinder guide AND the
    /// photo centre-crop. Mark's rule (2026-07-16): things that must match take the hand's ratio.
    var isSquareFormat: Bool {
        isTriptych || self == .separateSquare
            || self == .diptychDrawingLeft || self == .diptychDrawingRight
    }
}

enum Darkroom {

    /// Compose a finished frame.
    ///
    /// - Parameters:
    ///   - photograph: what the lens saw — reality, untouched.
    ///   - words: what the machine said. Set on the image, unhedged and unattributed.
    ///   - place: e.g. "Tulsa, Oklahoma". Omitted silently if there's no fix — a shot
    ///     without a place stamp is still a shot, and we never invent a location.
    ///   - date: when the shutter fired.
    /// Returns every asset this shot produces — one frame for most layouts, **two** for
    /// `.separate`. The shot is still atomic: one press, one set of artifacts.
    static func develop(photograph: CGImage,
                        words: String,
                        drawing: CGImage? = nil,
                        place: String?,
                        layout: Layout = .superimposed,
                        date: Date = Date()) -> [UIImage] {
        // In the content-driven taxonomy (2026-07-27) each layout produces EXACTLY its named panels.
        // The old "the drawing always rides along as an extra file" behavior is gone — except for the
        // Separate layouts, whose whole point is one file per artifact. A layout is only ever chosen
        // when its content exists (the picker filters by the eye/hand toggles), so the `drawing`
        // guards below are defensive fallbacks, not the normal path.
        let photoSize = CGSize(width: photograph.width, height: photograph.height)

        switch layout {
        case .triptychVertical, .triptychHorizontal:
            return [triptych(photograph: photograph, words: words, drawing: drawing,
                             axis: layout == .triptychVertical ? .vertical : .horizontal,
                             place: place, date: date)]

        // ── Single: one panel. ──
        case .textOnly:
            return [card(words: words, size: photoSize, place: place, date: date)]
        case .singlePhoto:
            return [compose(photograph: photograph, words: nil, place: place,
                            layout: .superimposed, date: date)]
        case .singleDrawing:
            guard let drawing else { return [] }
            return [frameDrawing(drawing, place: place, date: date)]

        // ── Superimposed: words on one image. ──
        case .superimposed:
            return [compose(photograph: photograph, words: words, place: place,
                            layout: .superimposed, date: date)]
        case .superimposedOnDrawing:
            guard let drawing else {
                return [compose(photograph: photograph, words: words, place: place,
                                layout: .superimposed, date: date)]
            }
            return [compose(photograph: drawing, words: words, place: place,
                            layout: .superimposed, date: date)]

        // ── Diptych: two panels. ──
        case .diptychTextLeft, .diptychTextRight:
            return [compose(photograph: photograph, words: words, place: place,
                            layout: layout, date: date)]
        case .diptychDrawingLeft, .diptychDrawingRight:
            guard let drawing else {
                return [compose(photograph: photograph, words: words, place: place,
                                layout: .superimposed, date: date)]
            }
            return [photoDrawingDiptych(photograph: photograph, drawing: drawing,
                                        drawingFirst: layout == .diptychDrawingLeft,
                                        place: place, date: date)]

        // ── Separate files: each artifact its own file (the ride-along survives ONLY here). ──
        case .separateNative:
            var out = [compose(photograph: photograph, words: nil, place: place,
                               layout: .superimposed, date: date),
                       card(words: words, size: photoSize, place: place, date: date)]
            if let drawing { out.append(frameDrawing(drawing, place: place, date: date)) }
            return out
        case .separateSquare:
            // Every asset square (the hand's ratio). Photo centre-cropped to the square you framed;
            // the words card is square; the drawing is already square. Same shape, so they pair —
            // kept at their own resolutions (separate files need only share a ratio, not a size).
            let square = centerCropSquare(photograph)
            let side = square.width
            var out = [compose(photograph: square, words: nil, place: place,
                               layout: .superimposed, date: date),
                       card(words: words, size: CGSize(width: side, height: side), place: place, date: date)]
            if let drawing { out.append(frameDrawing(drawing, place: place, date: date)) }
            return out
        }
    }

    /// Give the re-imagining (frame 3) the same grammar as the other frames — letterbox bars
    /// and the place/date footer — so the whole shot reads as one object. Mark, 2026-07-16: the
    /// drawing lacked "the footer and the black borders that frame one and frame two have."
    ///
    /// The drawing carries **no words**: it *is* the machine's visual, and the words are frame
    /// 2's — putting them here would conflate the two frames. The footer still testifies, and
    /// honestly so: the re-imagining came from a look at a real place at a real time — the same
    /// claim the words-only card makes once the photograph is gone. It attests to the *look*,
    /// not to the drawing's accuracy, and the triptych makes plain this panel is a re-imagining.
    ///
    /// Internally this is `compose` with no words. The drawing is square (512/1080/2048); its
    /// bars are 8.5% of its height, the same proportion a photograph's are, so the frames share
    /// a grammar even though their pixel sizes differ.
    static func frameDrawing(_ drawing: CGImage, place: String?, date: Date = Date()) -> UIImage {
        compose(photograph: drawing, words: nil, place: place, layout: .superimposed, date: date)
    }

    /// Centre-crop a photograph to a square — the largest centred square that fits. Used by the
    /// square-format layouts (Triptych, Separate — square) so the photo matches the drawer's
    /// shape. It takes the *centre* of the frame, which is exactly what the square viewfinder
    /// guide shows the user, so what they framed is what they get.
    static func centerCropSquare(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        let x = (image.width - side) / 2
        let y = (image.height - side) / 2
        return image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) ?? image
    }

    // MARK: - The triptych

    private enum TriptychAxis { case vertical, horizontal }
    private enum TriptychPanel { case image(UIImage); case words(String) }

    /// All three frames stitched into one plate: reality → perception → re-imagining.
    ///
    /// **Normalized to the drawing's resolution** — the lowest of the three — so the whole file
    /// scales with the user's drawing-size control (Native/1080/2048). Mark's call, 2026-07-16:
    /// "three times the lowest resolution one." The photograph is scaled *down* to match; keeping
    /// it crisp (and the file very large) is a parked future option, the reverse of this.
    ///
    /// One footer for the whole object — place bottom-left, date bottom-right — which lands under
    /// the first panel and the last exactly as Mark asked, in both axes. Black gutters between the
    /// panels give the letterbox grammar without double bars. The words panel is square, balanced
    /// against the square drawing; `drawWords` shrinks to fit whatever the machine said.
    ///
    /// Degrades gracefully with no drawing (third frame off): two panels, photo + words.
    private static func triptych(photograph: CGImage,
                                 words: String,
                                 drawing: CGImage?,
                                 axis: TriptychAxis,
                                 place: String?,
                                 date: Date) -> UIImage {
        // The photo is centre-cropped to a square so all three panels are EQUAL squares — the
        // hand's ratio wins in the triptych (Mark's rule). What's inside the square viewfinder
        // guide is what lands here.
        let photo = UIImage(cgImage: centerCropSquare(photograph))
        let draw = drawing.map { UIImage(cgImage: $0) }

        // The common dimension: the drawing's width (it's square). Without a drawing, fall back
        // to a sane unit off the photo so the two-panel degrade isn't a giant file.
        let unit: CGFloat = draw?.size.width ?? min(photo.size.width, 1200)
        let gutter = (unit * 0.03).rounded()
        let footerBar = (unit * 0.11).rounded()
        let margin = unit * 0.045
        let footerSize = unit * 0.03

        // Order is the thesis: reality, perception (words), re-imagining.
        var panels: [TriptychPanel] = [.image(photo), .words(words)]
        if let draw { panels.append(.image(draw)) }

        // Size each panel at the common dimension. Words panels are square; image panels keep
        // their aspect, fitted to the common width (vertical) or height (horizontal).
        func size(of panel: TriptychPanel) -> CGSize {
            switch panel {
            case .words:
                return CGSize(width: unit, height: unit)
            case .image(let img):
                switch axis {
                case .vertical:   return CGSize(width: unit, height: (unit * img.size.height / img.size.width).rounded())
                case .horizontal: return CGSize(width: (unit * img.size.width / img.size.height).rounded(), height: unit)
                }
            }
        }
        let sizes = panels.map(size)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let canvas: CGSize
        switch axis {
        case .vertical:
            let contentH = sizes.reduce(0) { $0 + $1.height }
            canvas = CGSize(width: unit,
                            height: gutter + contentH + gutter * CGFloat(panels.count - 1) + footerBar)
        case .horizontal:
            let contentW = sizes.reduce(0) { $0 + $1.width }
            canvas = CGSize(width: margin + contentW + gutter * CGFloat(panels.count - 1) + margin,
                            height: gutter + unit + footerBar)
        }

        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: canvas))

            var x = (axis == .horizontal) ? margin : 0
            var y = gutter
            for (panel, s) in zip(panels, sizes) {
                let originX = (axis == .vertical) ? 0 : x
                let rect = CGRect(x: originX, y: y, width: s.width, height: s.height)
                switch panel {
                case .image(let img):
                    img.draw(in: rect)
                case .words(let w):
                    // Inside its square, with the same margin the single card uses. No shadow —
                    // the panel is already black.
                    drawWords(w, in: rect.insetBy(dx: margin, dy: margin),
                              size: unit * 0.075, shadowed: false)
                }
                if axis == .vertical { y += s.height + gutter }
                else { x += s.width + gutter }
            }

            drawFooter(place: place, date: date, in: ctx.cgContext, canvas: canvas,
                       bar: footerBar, margin: margin, size: footerSize)
        }
    }

    /// Photo + drawing side by side — two EQUAL squares (the hand's ratio), one letterbox footer
    /// underneath (2026-07-27). Reality beside its re-imagining, no words. `drawingFirst` puts the
    /// drawing on the left. Mirrors the triptych's horizontal grammar, for two panels.
    private static func photoDrawingDiptych(photograph: CGImage, drawing: CGImage,
                                            drawingFirst: Bool, place: String?, date: Date) -> UIImage {
        let photo = UIImage(cgImage: centerCropSquare(photograph))
        let draw = UIImage(cgImage: drawing)
        let unit = draw.size.width            // the drawing is square; both panels are this square
        let gutter = (unit * 0.03).rounded()
        let footerBar = (unit * 0.11).rounded()
        let margin = unit * 0.045
        let footerSize = unit * 0.03

        let left = drawingFirst ? draw : photo
        let right = drawingFirst ? photo : draw

        let canvas = CGSize(width: margin + unit * 2 + gutter + margin,
                            height: gutter + unit + footerBar)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: canvas))
            left.draw(in: CGRect(x: margin, y: gutter, width: unit, height: unit))
            right.draw(in: CGRect(x: margin + unit + gutter, y: gutter, width: unit, height: unit))
            drawFooter(place: place, date: date, in: ctx.cgContext, canvas: canvas,
                       bar: footerBar, margin: margin, size: footerSize)
        }
    }

    /// A frame containing a photograph. `words == nil` leaves it bare (the `.separate`
    /// case, where the words get their own card).
    private static func compose(photograph: CGImage,
                                words: String?,
                                place: String?,
                                layout: Layout,
                                date: Date) -> UIImage {

        let image = UIImage(cgImage: photograph)
        let w = image.size.width
        let h = image.size.height

        // Letterbox. The bars are part of the form, not padding — they're what makes a
        // photograph read as a *plate*.
        let bar = (h * 0.085).rounded()
        // A diptych puts a text panel the same size as the photograph beside it, so the
        // claim gets exactly as much room as the evidence. Neither is a caption.
        let canvas = CGSize(width: layout.isDiptych ? w * 2 : w, height: h + bar * 2)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            let cg = ctx.cgContext

            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: canvas))

            // Scale everything off the PHOTOGRAPH's width so the book's proportions
            // survive any sensor and both layouts — not fixed point sizes.
            let margin = w * 0.045
            let footerSize = w * 0.026

            switch layout {
            case .diptychTextLeft, .diptychTextRight:
                let textFirst = (layout == .diptychTextLeft)
                let imageX = textFirst ? w : 0
                let textX  = textFirst ? 0 : w
                image.draw(in: CGRect(x: imageX, y: bar, width: w, height: h))
                // No shadow on the diptych: the panel is already black, so the text has
                // nothing to fight. Shadowing it would just be grime.
                drawWords(words ?? "", in: CGRect(x: textX + margin, y: bar + margin,
                                                  width: w - margin * 2,
                                                  height: h - margin * 2),
                          size: w * 0.095, shadowed: false)

            default:
                // Full-frame image + optional words over it. `develop` only ever hands `compose` a
                // superimposed or single-image layout (words-over-photo, words-over-drawing,
                // photo-only, drawing-only, the separate-file panels); everything lands here.
                image.draw(in: CGRect(x: 0, y: bar, width: w, height: h))
                if let words {
                    drawWords(words, in: CGRect(x: margin, y: bar + margin,
                                                width: w - margin * 2,
                                                height: h * 0.62),
                              size: w * 0.115, shadowed: true)
                }
            }

            drawFooter(place: place, date: date, in: cg, canvas: canvas,
                       bar: bar, margin: margin, size: footerSize)
        }
    }

    /// Words alone, white on black, in the same grammar and the same dimensions as a
    /// photograph — so it hangs beside one, or stands on its own.
    private static func card(words: String,
                             size: CGSize,
                             place: String?,
                             date: Date) -> UIImage {
        let w = size.width, h = size.height
        let bar = (h * 0.085).rounded()
        let canvas = CGSize(width: w, height: h + bar * 2)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: canvas))

            let margin = w * 0.06
            drawWords(words, in: CGRect(x: margin, y: bar + margin,
                                        width: w - margin * 2,
                                        height: h - margin * 2),
                      size: w * 0.105, shadowed: false)
            // The footer stays. The photograph is gone, but the machine still looked at a
            // real place at a real time, and that remains checkable.
            drawFooter(place: place, date: date, in: ctx.cgContext, canvas: canvas,
                       bar: bar, margin: w * 0.045, size: w * 0.026)
        }
    }

    // MARK: - The claim

    /// The machine's words, set over the photograph.
    ///
    /// Heavy, white, upper-left, with a shadow so it survives a bright sky. No box, no
    /// scrim, no quotation marks — nothing that would frame it as a caption *about* the
    /// picture. It's laid ON the world it's describing, which is the whole argument.
    private static func drawWords(_ words: String,
                                  in box: CGRect,
                                  size: CGFloat,
                                  shadowed: Bool) {
        guard !words.isEmpty else { return }

        let shadow = NSShadow()
        if shadowed {
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = size * 0.22
            shadow.shadowOffset = CGSize(width: 0, height: size * 0.03)
        }

        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineHeightMultiple = 0.92

        // Shrink to fit rather than truncate, with NO readability floor. The machine said what
        // it said; we don't get to cut it off because our box was too small, and we don't let it
        // overrun the box into the footer either (the 2026-07-26 Smol essay shrank to the old
        // ⅓-size floor, gave up, and plowed straight through reality's receipt). A very wordy eye
        // yields micro-text — honest, every word present, just small. The `> 1` guard below only
        // guarantees the loop terminates; it is not a floor.
        var pointSize = size
        var attributes: [NSAttributedString.Key: Any] = [:]
        var bounds = CGRect.zero
        let maxWidth = box.width
        let maxHeight = box.height

        repeat {
            attributes = [
                .font: UIFont.systemFont(ofSize: pointSize, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            if shadowed { attributes[.shadow] = shadow }
            bounds = (words as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil)
            pointSize *= 0.92
        } while bounds.height > maxHeight && pointSize > 1

        (words as NSString).draw(
            with: CGRect(x: box.minX, y: box.minY, width: maxWidth, height: bounds.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
    }

    // MARK: - Reality's receipt

    /// Place bottom-left, date bottom-right, in the lower bar. Quiet, small, and in the
    /// margin — the way a date-back camera stamped a negative. It is not competing with
    /// the claim; it's the evidence sitting underneath it.
    private static func drawFooter(place: String?,
                                   date: Date,
                                   in cg: CGContext,
                                   canvas: CGSize,
                                   bar: CGFloat,
                                   margin: CGFloat,
                                   size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: UIColor.white
        ]
        let y = canvas.height - bar / 2 - size * 0.62

        if let place, !place.isEmpty {
            (place as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        }

        let stamp = Place.stamp(date) as NSString
        let width = stamp.size(withAttributes: attributes).width
        stamp.draw(at: CGPoint(x: canvas.width - margin - width, y: y),
                   withAttributes: attributes)
    }
}

// ==== LEGO END: 16 The Darkroom (Compositor) ====
