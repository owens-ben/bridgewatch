#!/usr/bin/env swift
// Draws the Bridgewatch app icon ("B2": aircraft over a curved suspension bridge with a subway bullet on the deck,
// over a boat on the water) with Core Graphics, so the icon is reproducible and reviewable as code. No dependencies
// beyond macOS.
//
//   swift scripts/make-app-icon.swift                 # writes the three 1024 px variants into AppIcon.appiconset
//   swift scripts/make-app-icon.swift --preview DIR   # also renders 1024/180/120/60 px previews, masked like the
//                                                     # home screen, plus DIR/contact-sheet.png (for review, not committed)
//
// Variants (iOS 18+ appearances): default (off-white and periwinkle on brand indigo, opaque, no alpha channel), dark
// (periwinkle on deep indigo) and tinted (white and grey on black: iOS reads it as a grayscale mask and applies the
// user's tint). Corners are square: iOS rounds them. No text.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

struct Variant {
    let file: String
    let field: RGB // the background
    let main: RGB // aircraft, towers, cables, deck, boat
    let second: RGB // suspenders, the bullet, the waves
}

// Brand (docs/DESIGN.md, Brand): field #2B3F8C, paper #FBF8F1, periwinkle #A3B1FF (the dark-mode accent).
let variants = [
    Variant(file: "AppIcon.png", field: RGB(0x2B3F8C), main: RGB(0xFBF8F1), second: RGB(0xA3B1FF)),
    Variant(file: "AppIcon-Dark.png", field: RGB(0x10162E), main: RGB(0xFBF8F1), second: RGB(0x7F90E8)),
    Variant(file: "AppIcon-Tinted.png", field: RGB(0x000000), main: RGB(0xFFFFFF), second: RGB(0x9A9A9A)),
]

/// The whole drawing in a 1024-unit square; `size` only scales it. Core Graphics' y axis points up.
func draw(_ v: Variant, size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // noneSkipLast: no alpha channel at all, as the App Store requires for the icon.
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    ctx.setFillColor(v.field.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Layer 1 (top): an aircraft seen from above, climbing to the right.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 878)
    ctx.rotate(by: -32 * .pi / 180)
    ctx.scaleBy(x: 0.9, y: 0.9)
    ctx.setFillColor(v.main.cg)
    let fuselage = CGPath(roundedRect: CGRect(x: -22, y: -118, width: 44, height: 236), cornerWidth: 22, cornerHeight: 22,
                          transform: nil)
    ctx.addPath(fuselage)
    for side in [-1.0, 1.0] as [CGFloat] {
        ctx.move(to: CGPoint(x: side * 10, y: 34))
        ctx.addLine(to: CGPoint(x: side * 150, y: -42))
        ctx.addLine(to: CGPoint(x: side * 150, y: -74))
        ctx.addLine(to: CGPoint(x: side * 10, y: -18))
        ctx.closePath()
        ctx.move(to: CGPoint(x: side * 8, y: -84))
        ctx.addLine(to: CGPoint(x: side * 62, y: -120))
        ctx.addLine(to: CGPoint(x: side * 62, y: -142))
        ctx.addLine(to: CGPoint(x: side * 8, y: -112))
        ctx.closePath()
    }
    ctx.fillPath()
    ctx.restoreGState()

    // Layer 2 (middle): a suspension bridge. Two steel towers with cross bracing, gently curved main cable, side
    // spans sweeping down to the anchorages, vertical suspenders, a deck, and a bullet on the deck.
    let deckY: CGFloat = 440, deckH: CGFloat = 40
    let towerX: CGFloat = 232 // distance of each tower from the centre
    let towerTop: CGFloat = 766
    let legW: CGFloat = 40
    let sagY: CGFloat = 664 // lowest point of the main cable
    func cableY(_ x: CGFloat) -> CGFloat {
        let t = (x - 512) / towerX
        return sagY + (towerTop - 20 - sagY) * t * t
    }
    // Suspenders first, so cables and deck cover their ends.
    ctx.setStrokeColor(v.second.cg)
    ctx.setLineWidth(18)
    ctx.setLineCap(.butt)
    for px in [512 - 168, 512 - 112, 512 + 112, 512 + 168] as [CGFloat] { // clear of the bullet
        ctx.move(to: CGPoint(x: px, y: deckY))
        ctx.addLine(to: CGPoint(x: px, y: cableY(px)))
    }
    ctx.strokePath()

    ctx.setFillColor(v.main.cg)
    ctx.setStrokeColor(v.main.cg)
    // Towers: two legs, braced by a crossbar and a portal beam, with pointed caps, standing in the water.
    for side in [-1.0, 1.0] as [CGFloat] {
        let x = 512 + side * towerX
        for leg in [-1.0, 1.0] as [CGFloat] {
            let lx = x + leg * 28
            let p = CGMutablePath()
            p.move(to: CGPoint(x: lx - legW / 2, y: 330))
            p.addLine(to: CGPoint(x: lx - legW / 2, y: towerTop))
            p.addLine(to: CGPoint(x: lx, y: towerTop + 26))
            p.addLine(to: CGPoint(x: lx + legW / 2, y: towerTop))
            p.addLine(to: CGPoint(x: lx + legW / 2, y: 330))
            p.closeSubpath()
            ctx.addPath(p)
        }
        ctx.addRect(CGRect(x: x - 40, y: 640, width: 80, height: 30))
    }
    ctx.fillPath()

    // Cables.
    ctx.setLineWidth(26)
    ctx.setLineCap(.round)
    let cable = CGMutablePath()
    let leftTop = CGPoint(x: 512 - towerX, y: towerTop - 20)
    let rightTop = CGPoint(x: 512 + towerX, y: towerTop - 20)
    cable.move(to: CGPoint(x: -40, y: deckY + 6))
    cable.addQuadCurve(to: leftTop, control: CGPoint(x: 120, y: 470))
    var x = leftTop.x
    while x <= rightTop.x {
        cable.addLine(to: CGPoint(x: x, y: cableY(x)))
        x += 2
    }
    cable.addLine(to: rightTop)
    cable.addQuadCurve(to: CGPoint(x: 1064, y: deckY + 6), control: CGPoint(x: 904, y: 470))
    ctx.addPath(cable)
    ctx.strokePath()

    // Deck, edge to edge.
    ctx.fill(CGRect(x: 0, y: deckY, width: 1024, height: deckH))

    // The bullet: a round subway marker on the deck (no letter: a bright core instead).
    let bulletR: CGFloat = 74
    let bulletC = CGPoint(x: 512, y: deckY + deckH + bulletR - 4)
    ctx.setFillColor(v.second.cg)
    ctx.fillEllipse(in: CGRect(x: bulletC.x - bulletR, y: bulletC.y - bulletR, width: bulletR * 2, height: bulletR * 2))
    ctx.setFillColor(v.main.cg)
    ctx.fillEllipse(in: CGRect(x: bulletC.x - 34, y: bulletC.y - 34, width: 68, height: 68))

    // Layer 3 (bottom): a small boat on the water, two wave lines under it.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 190)
    ctx.scaleBy(x: 1.22, y: 1.22)
    ctx.translateBy(x: -512, y: -190)
    ctx.setFillColor(v.main.cg)
    let hull = CGMutablePath()
    hull.move(to: CGPoint(x: 372, y: 262))
    hull.addLine(to: CGPoint(x: 668, y: 262))
    hull.addLine(to: CGPoint(x: 618, y: 190))
    hull.addLine(to: CGPoint(x: 424, y: 190))
    hull.closeSubpath()
    ctx.addPath(hull)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 440, y: 262, width: 104, height: 70), cornerWidth: 10, cornerHeight: 10,
                       transform: nil))
    ctx.addRect(CGRect(x: 572, y: 262, width: 34, height: 92))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setStrokeColor(v.second.cg)
    ctx.setLineWidth(26)
    ctx.setLineCap(.round)
    for (row, y) in [(0, 140.0), (0, 70.0)] as [(Int, CGFloat)] {
        let wave = CGMutablePath()
        let length: CGFloat = 200
        let amplitude: CGFloat = 16
        let phase: CGFloat = row == 0 ? 0 : length / 2
        var wx: CGFloat = -40
        wave.move(to: CGPoint(x: wx, y: y + amplitude * sin((wx + phase) / length * 2 * .pi)))
        while wx <= 1064 {
            wx += 2
            wave.addLine(to: CGPoint(x: wx, y: y + amplitude * sin((wx + phase) / length * 2 * .pi)))
        }
        ctx.addPath(wave)
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

/// A home-screen-style preview: the icon with iOS's rounded corners on a neutral wallpaper.
func preview(_ icon: CGImage, size: Int, wallpaper: RGB) -> CGImage {
    let pad = max(8, size / 6)
    let full = size + pad * 2
    let ctx = CGContext(data: nil, width: full, height: full, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(wallpaper.cg)
    ctx.fill(CGRect(x: 0, y: 0, width: full, height: full))
    let rect = CGRect(x: pad, y: pad, width: size, height: size)
    let radius = CGFloat(size) * 0.2237
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(icon, in: rect)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconSet = scriptDir.appendingPathComponent("../App/Assets.xcassets/AppIcon.appiconset").standardizedFileURL
let args = CommandLine.arguments
let previewDir = args.firstIndex(of: "--preview").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

for v in variants {
    let master = draw(v, size: 1024)
    write(master, to: iconSet.appendingPathComponent(v.file))
    print("wrote \(iconSet.lastPathComponent)/\(v.file)")
    guard let previewDir else { continue }
    let dir = URL(fileURLWithPath: previewDir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = (v.file as NSString).deletingPathExtension
    // Small sizes are downsampled from the 1024 master, as iOS does.
    for size in [1024, 180, 120, 60] {
        let wallpaper = v.file == "AppIcon.png" ? RGB(0x6E7F99) : RGB(0x1C1C1E)
        write(preview(master, size: size, wallpaper: wallpaper),
              to: dir.appendingPathComponent("\(name)-\(size).png"))
    }
}

if let previewDir {
    // Contact sheet: rows light / dark / tinted, columns 1024 (shown at 420), 180, 120, 60 (native pixels).
    let dir = URL(fileURLWithPath: previewDir)
    let width = 1400, rowH = 520
    let ctx = CGContext(data: nil, width: width, height: rowH * 3, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(RGB(0x888888).cg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: rowH * 3))
    for (i, v) in variants.enumerated() {
        let name = (v.file as NSString).deletingPathExtension
        var x = 20
        let rowY = (2 - i) * rowH
        for size in [1024, 180, 120, 60] {
            let url = dir.appendingPathComponent("\(name)-\(size).png")
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let shown = size == 1024 ? 480 : img.width
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: x, y: rowY + (rowH - shown) / 2, width: shown, height: shown))
            x += shown + 20
        }
    }
    write(ctx.makeImage()!, to: dir.appendingPathComponent("contact-sheet.png"))
}
