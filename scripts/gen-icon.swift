// scripts/gen-icon.swift — draws the RemotePU app icon with CoreGraphics.
//
//   swift scripts/gen-icon.swift --preview <dir>                 all variants at 1024px + size montage
//   swift scripts/gen-icon.swift --variant <v> --iconset <dir>   AppIcon.iconset PNGs (for iconutil)
//
// Variants: pulse (chip + heartbeat + remote beacon), nodes (local and remote
// machine linked over ssh), gauge (utilization ring around a chip).
// The palette follows Sources/RemotePU/Theme.swift (blue accent 0x2A78D6 ramp,
// status green) so the icon matches the in-app look.
// Canvas is 1024×1024 design units, squircle 824×824 r=185 (macOS icon grid).

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let D: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func white(_ a: CGFloat) -> CGColor { rgb(0xFFFFFF, a) }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray, locations: locations)!
}

func makeCtx(_ w: Int, _ h: Int, flip: Bool = true) -> CGContext? {
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    if flip { c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1) } // y-down, origin top-left
    return c
}

func savePNG(_ image: CGImage, _ path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// Halving chain down from the 1024px master keeps small sizes clean.
func downscale(_ src: CGImage, to px: Int) -> CGImage? {
    var cur = src
    while cur.width / 2 >= px {
        guard let c = makeCtx(cur.width / 2, cur.height / 2, flip: false) else { return nil }
        c.interpolationQuality = .high
        c.draw(cur, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
        guard let next = c.makeImage() else { return nil }
        cur = next
    }
    return cur
}

// MARK: - Shared pieces

func drawBackground(_ c: CGContext) {
    let p = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                   cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.addPath(p); c.clip()
    c.drawLinearGradient(gradient([rgb(0x3778CC), rgb(0x1B4E9C), rgb(0x0A2C5E)], [0, 0.55, 1]),
                         start: CGPoint(x: 512, y: 90), end: CGPoint(x: 512, y: 934), options: [])
    c.drawRadialGradient(gradient([rgb(0x6FB7FF, 0.22), rgb(0x6FB7FF, 0)], [0, 1]),
                         startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 470), endRadius: 460, options: [])
    c.drawLinearGradient(gradient([white(0.10), white(0)], [0, 1]),
                         start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 560), options: [])
    c.restoreGState()
    c.addPath(p); c.setLineWidth(5); c.setStrokeColor(white(0.22)); c.strokePath()
}

struct ChipStyle {
    var bodyTop: UInt32 = 0xF5F7FB
    var bodyBottom: UInt32 = 0xC2CADB
    var pin: UInt32 = 0x8D99B3
    var dieTop: UInt32 = 0x223468
    var dieBottom: UInt32 = 0x0B1430
}

/// A processor: silver body, pins on all four sides, dark die. `content` draws inside the die.
func drawChip(_ c: CGContext, center: CGPoint, side: CGFloat,
              style: ChipStyle = ChipStyle(), content: (CGRect) -> Void) {
    let half = side / 2
    let n = side > 350 ? 7 : 5
    let pinW = side * 0.081, out = side * 0.062, margin = side * 0.081
    let gap = (side - 2 * margin - CGFloat(n) * pinW) / CGFloat(n - 1)
    let pins = CGMutablePath()
    for i in 0..<n {
        let a = center.x - half + margin + CGFloat(i) * (pinW + gap)
        let b = center.y - half + margin + CGFloat(i) * (pinW + gap)
        let r: (CGRect) -> CGPath = {
            CGPath(roundedRect: $0, cornerWidth: pinW * 0.3, cornerHeight: pinW * 0.3, transform: nil)
        }
        pins.addPath(r(CGRect(x: a, y: center.y - half - out + 3, width: pinW, height: out)))
        pins.addPath(r(CGRect(x: a, y: center.y + half - 3, width: pinW, height: out)))
        pins.addPath(r(CGRect(x: center.x - half - out + 3, y: b, width: out, height: pinW)))
        pins.addPath(r(CGRect(x: center.x + half - 3, y: b, width: out, height: pinW)))
    }
    c.addPath(pins); c.setFillColor(rgb(style.pin)); c.fillPath()

    let body = CGPath(roundedRect: CGRect(x: center.x - half, y: center.y - half, width: side, height: side),
                      cornerWidth: side * 0.133, cornerHeight: side * 0.133, transform: nil)
    c.saveGState()
    c.addPath(body); c.clip()
    c.drawLinearGradient(gradient([rgb(style.bodyTop), rgb(style.bodyBottom)], [0, 1]),
                         start: CGPoint(x: 0, y: center.y - half), end: CGPoint(x: 0, y: center.y + half), options: [])
    c.drawLinearGradient(gradient([white(0.55), white(0)], [0, 1]),
                         start: CGPoint(x: 0, y: center.y - half),
                         end: CGPoint(x: 0, y: center.y - half + side * 0.35), options: [])
    c.restoreGState()
    c.addPath(body); c.setLineWidth(2.5); c.setStrokeColor(rgb(0x0A1B3F, 0.28)); c.strokePath()

    let inset = side * 0.148
    let drect = CGRect(x: center.x - half + inset, y: center.y - half + inset,
                       width: side - 2 * inset, height: side - 2 * inset)
    let die = CGPath(roundedRect: drect, cornerWidth: drect.width * 0.135, cornerHeight: drect.width * 0.135,
                     transform: nil)
    c.saveGState()
    c.addPath(die); c.clip()
    c.drawLinearGradient(gradient([rgb(style.dieTop), rgb(style.dieBottom)], [0, 1]),
                         start: CGPoint(x: 0, y: drect.minY), end: CGPoint(x: 0, y: drect.maxY), options: [])
    c.drawRadialGradient(gradient([rgb(0x4C7FD6, 0.35), rgb(0x4C7FD6, 0)], [0, 1]),
                         startCenter: CGPoint(x: drect.midX, y: drect.minY), startRadius: 0,
                         endCenter: CGPoint(x: drect.midX, y: drect.minY), endRadius: drect.width * 0.7, options: [])
    c.restoreGState()
    c.addPath(die); c.setLineWidth(3); c.setStrokeColor(white(0.16)); c.strokePath()
    content(drect)
}

/// EKG-style heartbeat, the "live monitoring" cue.
let ekg: [(CGFloat, CGFloat)] = [(0, 0), (0.14, 0), (0.22, 0.12), (0.30, 0.04), (0.36, -0.10),
                                 (0.46, 0.95), (0.56, -0.26), (0.62, 0.04), (0.74, 0.30), (0.82, 0.04), (1, 0)]

func drawPulse(_ c: CGContext, in rect: CGRect, width: CGFloat, hex: UInt32 = 0x30D158) {
    let r = rect.insetBy(dx: rect.width * 0.12, dy: rect.width * 0.12)
    let base = r.midY + r.height * 0.10
    let amp = r.height * 0.30
    let path = CGMutablePath()
    for (i, p) in ekg.enumerated() {
        let pt = CGPoint(x: r.minX + p.0 * r.width, y: base - p.1 * amp)
        i == 0 ? path.move(to: pt) : path.addLine(to: pt)
    }
    c.saveGState()
    c.setLineCap(.round); c.setLineJoin(.round)
    c.addPath(path); c.setLineWidth(width)
    c.setShadow(offset: .zero, blur: width * 1.6, color: rgb(hex, 0.85))
    c.setStrokeColor(rgb(hex, 0.9)); c.strokePath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(path); c.setLineWidth(width)
    c.setStrokeColor(rgb(hex)); c.strokePath()
    c.restoreGState()
}

/// Small broadcast beacon: the "remote" cue.
func drawBeacon(_ c: CGContext, at p: CGPoint) {
    c.saveGState()
    c.addEllipse(in: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30))
    c.setShadow(offset: .zero, blur: 26, color: rgb(0x7EBBFF, 0.9))
    c.setFillColor(rgb(0x8FC6FF)); c.fillPath()
    c.setShadow(offset: .zero, blur: 18, color: rgb(0x6FB7FF, 0.7))
    c.setLineCap(.round)
    for (r, a) in [(CGFloat(64), CGFloat(1)), (104, 0.85)] {
        c.addArc(center: p, radius: r, startAngle: -78 * .pi / 180, endAngle: -12 * .pi / 180, clockwise: false)
        c.setLineWidth(17); c.setStrokeColor(rgb(0x6FB7FF, a)); c.strokePath()
    }
    c.restoreGState()
}

/// Utilization bars (CPU + GPUs) for the remote machine in the "nodes" variant.
func drawBars(_ c: CGContext, in die: CGRect) {
    let r = die.insetBy(dx: die.width * 0.20, dy: die.width * 0.20)
    let w = r.width * 0.24, gap = r.width * 0.14
    let heights: [CGFloat] = [0.38, 0.62, 0.90]
    let colors: [UInt32] = [0x30D158, 0x2FB8A0, 0x4FC3F7]
    for i in 0..<3 {
        let h = r.height * heights[i]
        let rect = CGRect(x: r.minX + CGFloat(i) * (w + gap), y: r.maxY - h, width: w, height: h)
        c.addPath(CGPath(roundedRect: rect, cornerWidth: w * 0.3, cornerHeight: w * 0.3, transform: nil))
        c.setFillColor(rgb(colors[i])); c.fillPath()
    }
}

// MARK: - Variants

func drawPulseVariant(_ c: CGContext) {
    drawBackground(c)
    drawChip(c, center: CGPoint(x: 512, y: 512), side: 420) { drawPulse(c, in: $0, width: 17) }
    drawBeacon(c, at: CGPoint(x: 512 + 210 + 20, y: 512 - 210 - 20))
}

func drawNodesVariant(_ c: CGContext) {
    drawBackground(c)
    let local = CGPoint(x: 392, y: 648), remote = CGPoint(x: 712, y: 372)
    // ssh link: dotted line under the chips, with a live sample traveling along it.
    c.saveGState()
    c.setStrokeColor(white(0.85)); c.setLineWidth(9); c.setLineCap(.round)
    c.setLineDash(phase: 0, lengths: [0.1, 26])
    let link = CGMutablePath()
    link.move(to: local); link.addLine(to: remote)
    c.addPath(link); c.strokePath()
    c.restoreGState()
    drawChip(c, center: local, side: 300) { drawPulse(c, in: $0, width: 12) }
    var style = ChipStyle()
    style.bodyTop = 0xE3EAF6; style.bodyBottom = 0xA9BAD6
    style.dieTop = 0x1C3E66; style.dieBottom = 0x0A2238
    drawChip(c, center: remote, side: 236, style: style) { drawBars(c, in: $0) }
    let t = CGPoint(x: local.x + (remote.x - local.x) * 0.58, y: local.y + (remote.y - local.y) * 0.58)
    c.saveGState()
    c.setShadow(offset: .zero, blur: 24, color: rgb(0x30D158, 0.9))
    c.addEllipse(in: CGRect(x: t.x - 13, y: t.y - 13, width: 26, height: 26))
    c.setFillColor(rgb(0x30D158)); c.fillPath()
    c.restoreGState()
}

func drawGaugeVariant(_ c: CGContext) {
    drawBackground(c)
    let center = CGPoint(x: 512, y: 530), radius: CGFloat = 300
    c.setLineCap(.round); c.setLineWidth(44)
    c.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    c.setStrokeColor(white(0.12)); c.strokePath()
    // Utilization arc (270°, gap at the bottom) with the accent ramp along it.
    c.saveGState()
    c.addArc(center: center, radius: radius, startAngle: 3 * .pi / 4, endAngle: 3 * .pi / 4 + 1.5 * .pi,
             clockwise: false)
    c.replacePathWithStrokedPath(); c.clip()
    c.drawLinearGradient(gradient([rgb(0x6FB7FF), rgb(0x3987E5), rgb(0x2A78D6)], [0, 0.5, 1]),
                         start: CGPoint(x: 200, y: 240), end: CGPoint(x: 824, y: 824), options: [])
    c.restoreGState()
    drawChip(c, center: center, side: 300) { drawPulse(c, in: $0, width: 13) }
}

func render(_ variant: String, _ size: CGFloat) -> CGImage? {
    guard let c = makeCtx(Int(size), Int(size)) else { return nil }
    c.scaleBy(x: size / D, y: size / D)
    switch variant {
    case "pulse": drawPulseVariant(c)
    case "nodes": drawNodesVariant(c)
    case "gauge": drawGaugeVariant(c)
    default: return nil
    }
    return c.makeImage()
}

// MARK: - Outputs

func montage(_ shots: [(String, CGImage)], _ dir: String) {
    let sizes: [CGFloat] = [256, 128, 64, 32, 16]
    let pad: CGFloat = 64, gx: CGFloat = 56, rowH: CGFloat = 300, gy: CGFloat = 20
    let W = Int(pad * 2 + sizes.reduce(0, +) + gx * CGFloat(sizes.count - 1))
    let H = Int(pad * 2 + rowH * CGFloat(shots.count) + gy * CGFloat(shots.count - 1))
    guard let c = makeCtx(W, H, flip: false) else { return }
    c.setFillColor(rgb(0xE9EBF1)); c.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
    for (i, (_, master)) in shots.enumerated() {
        let rowTop = pad + CGFloat(i) * (rowH + gy)
        var x = pad
        for s in sizes {
            guard let im = downscale(master, to: Int(s)) else { continue }
            c.draw(im, in: CGRect(x: x, y: CGFloat(H) - rowTop - rowH + (rowH - s),
                                  width: s, height: s))
            x += s + gx
        }
        if i > 0 {
            c.setFillColor(rgb(0xC9CCD6, 0.6))
            c.fill(CGRect(x: pad, y: CGFloat(H) - rowTop + gy / 2, width: CGFloat(W) - 2 * pad, height: 1))
        }
    }
    guard let image = c.makeImage() else { return }
    savePNG(image, dir + "/preview.png")
}

let argv = CommandLine.arguments
var preview: String?
var variant = "pulse"
var iconset: String?
var i = 1
while i < argv.count {
    let v = argv[i]
    if v == "--preview", i + 1 < argv.count { preview = argv[i + 1]; i += 2 }
    else if v == "--variant", i + 1 < argv.count { variant = argv[i + 1]; i += 2 }
    else if v == "--iconset", i + 1 < argv.count { iconset = argv[i + 1]; i += 2 }
    else { i += 1 }
}

if let dir = preview {
    var shots: [(String, CGImage)] = []
    for v in ["pulse", "nodes", "gauge"] {
        if let im = render(v, D) { savePNG(im, "\(dir)/\(v).png"); shots.append((v, im)) }
    }
    montage(shots, dir)
    print("preview: \(dir)/preview.png (+ pulse.png, nodes.png, gauge.png)")
} else if let dir = iconset {
    guard let master = render(variant, D) else {
        print("unknown variant: \(variant)"); exit(2)
    }
    let files: [(String, Int)] = [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
                                  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                                  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                                  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                                  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)]
    for (name, px) in files {
        if let im = downscale(master, to: px) { savePNG(im, dir + "/" + name) }
    }
    print("iconset: \(dir) (\(variant))")
} else {
    print("usage: gen-icon.swift --preview DIR | --variant V --iconset DIR")
    exit(2)
}
