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

// ==== LEGO START: 18 The Darkroom (Compositor) ====

/// How the words meet the photograph.
///
/// Deliberately a **small, tested set** — not a freeform editor (CLAUDE.md, "The visual
/// language"). Every option here is a property of the loaded film, chosen before the
/// shutter, never per-shot.
enum Layout: String, CaseIterable, Sendable {
    /// The machine's words laid ON the world it's describing. Heavy sans over the image,
    /// no scrim, no box — the claim and the evidence in the same rectangle.
    case superimposed
    /// The book's other move: a black panel beside the photograph, white text, text LEFT.
    /// The claim and the evidence side by side, arguing.
    case diptychTextLeft
    /// Same, text RIGHT.
    case diptychTextRight
    /// **Just the words.** No photograph at all.
    ///
    /// This is Mark's original idea, and it is not a degraded triptych — it's a quieter
    /// camera. *"Me initially, I just wanted the words. I kind of saw it as AI writing
    /// poetry inspired by what it sees."* The photograph was taken; you simply don't keep
    /// it. What survives is what the machine said about a moment nobody else can check.
    case textOnly
    /// Two assets, not one: the photograph, and the words, saved separately.
    ///
    /// Same dimensions so they pair. Reality and perception as distinct artifacts rather
    /// than a composition arguing with itself — the viewer does the juxtaposition.
    case separate

    var name: String {
        switch self {
        case .superimposed:     return "Superimposed"
        case .diptychTextLeft:  return "Diptych — text left"
        case .diptychTextRight: return "Diptych — text right"
        case .textOnly:         return "Words only"
        case .separate:         return "Separate images"
        }
    }

    var isDiptych: Bool { self == .diptychTextLeft || self == .diptychTextRight }
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
                        place: String?,
                        layout: Layout = .superimposed,
                        date: Date = Date()) -> [UIImage] {
        switch layout {
        case .textOnly:
            return [card(words: words, size: CGSize(width: photograph.width,
                                                    height: photograph.height),
                         place: place, date: date)]
        case .separate:
            return [
                compose(photograph: photograph, words: nil, place: place,
                        layout: .superimposed, date: date),
                card(words: words, size: CGSize(width: photograph.width,
                                                height: photograph.height),
                     place: place, date: date)
            ]
        default:
            return [compose(photograph: photograph, words: words, place: place,
                            layout: layout, date: date)]
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
            case .superimposed, .textOnly, .separate:
                image.draw(in: CGRect(x: 0, y: bar, width: w, height: h))
                if let words {
                    drawWords(words, in: CGRect(x: margin, y: bar + margin,
                                                width: w - margin * 2,
                                                height: h * 0.62),
                              size: w * 0.115, shadowed: true)
                }

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

        // Shrink to fit rather than truncate. The machine said what it said; we don't get
        // to cut it off mid-sentence because our box was too small.
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
        } while bounds.height > maxHeight && pointSize > size * 0.3

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

// ==== LEGO END: 18 The Darkroom (Compositor) ====
