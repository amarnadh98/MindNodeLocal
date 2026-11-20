#!/usr/bin/env swift
// generate_app_icon.swift — Arbor's app icon, drawn programmatically.
//
//   swift scripts/generate_app_icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
//
// Produces every macOS AppIcon size as PNGs plus the Contents.json.
// The design is original to Arbor (SPEC §7.7): a soft teal-gradient
// squircle (the brand accent #12A594) carrying a stylized arbor — one
// trunk forking into branches whose tips are map nodes, one node lit
// amber. Full-bleed squares; macOS applies its own corner mask.
//
// No third-party tooling: CoreGraphics + ImageIO only, so the icon is
// reproducible from the repo with a plain `swift` invocation.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: palette

enum Palette {
    static let tealLight = hex(0x4ED8BE)
    static let tealDeep = hex(0x0B6E60)
    static let ink = hex(0x10312B)  // deep green-ink trunk shadow
    static let branchWhite = hex(0xF6FDFB)
    static let nodeWhite = hex(0xFFFFFF)
    static let amber = hex(0xFFC53D)
    static let amberDeep = hex(0xE5A63C)
}

func hex(_ value: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
        green: CGFloat((value >> 8) & 0xFF) / 255.0,
        blue: CGFloat(value & 0xFF) / 255.0,
        alpha: 1.0)
}

// MARK: geometry (normalized 0…1, scaled per size)

/// One stroke of the tree: a cubic curve with its own width.
struct Limb {
    let start: CGPoint
    let c1: CGPoint
    let c2: CGPoint
    let end: CGPoint
    let width: CGFloat
    let color: CGColor
}

let limbs: [Limb] = [
    // Trunk, rising from the base.
    Limb(
        start: CGPoint(x: 0.50, y: 0.86),
        c1: CGPoint(x: 0.50, y: 0.68),
        c2: CGPoint(x: 0.46, y: 0.58),
        end: CGPoint(x: 0.44, y: 0.46),
        width: 0.075, color: Palette.branchWhite),
    // Left branch.
    Limb(
        start: CGPoint(x: 0.44, y: 0.46),
        c1: CGPoint(x: 0.36, y: 0.40),
        c2: CGPoint(x: 0.28, y: 0.36),
        end: CGPoint(x: 0.22, y: 0.27),
        width: 0.052, color: Palette.branchWhite),
    // Center branch, the tallest.
    Limb(
        start: CGPoint(x: 0.44, y: 0.46),
        c1: CGPoint(x: 0.46, y: 0.36),
        c2: CGPoint(x: 0.52, y: 0.30),
        end: CGPoint(x: 0.55, y: 0.20),
        width: 0.052, color: Palette.branchWhite),
    // Right branch.
    Limb(
        start: CGPoint(x: 0.44, y: 0.46),
        c1: CGPoint(x: 0.58, y: 0.42),
        c2: CGPoint(x: 0.68, y: 0.40),
        end: CGPoint(x: 0.78, y: 0.34),
        width: 0.052, color: Palette.branchWhite),
]

let nodes: [(center: CGPoint, radius: CGFloat, fill: CGColor, stroke: CGColor?)] = [
    (CGPoint(x: 0.22, y: 0.27), 0.052, Palette.nodeWhite, nil),
    (CGPoint(x: 0.55, y: 0.20), 0.052, Palette.amber, Palette.amberDeep),
    (CGPoint(x: 0.78, y: 0.34), 0.052, Palette.nodeWhite, nil),
]

// MARK: drawing

func drawIcon(size: CGFloat) -> CGImage? {
    let pixels = Int(size.rounded())
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let s = CGFloat(pixels)

    // Full-bleed gradient: light teal top-left, deep teal
    // bottom-right, with a soft diagonal sheen.
    let colors = [Palette.tealLight, Palette.tealDeep] as CFArray
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else {
        return nil
    }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: [])

    // A faint deep-ink halo behind the glyph grounds it against the
    // gradient's brightness at the bottom.
    context.setFillColor(Palette.ink)
    context.setAlpha(0.10)
    context.fillEllipse(in: CGRect(x: s * 0.10, y: s * 0.08, width: s * 0.80, height: s * 0.84))
    context.setAlpha(1)

    func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * s, y: s - p.y * s) }

    // Branch strokes (round caps, tapered per-limb widths).
    for limb in limbs {
        let path = CGMutablePath()
        path.move(to: scaled(limb.start))
        path.addCurve(to: scaled(limb.end), control1: scaled(limb.c1), control2: scaled(limb.c2))
        context.addPath(path)
        context.setLineCap(.round)
        context.setLineWidth(limb.width * s)
        context.setStrokeColor(limb.color)
        context.strokePath()
    }

    // Node tips: filled circles; the amber one carries a hairline rim.
    for node in nodes {
        let center = scaled(node.center)
        let radius = node.radius * s
        if let stroke = node.stroke {
            context.setFillColor(stroke)
            context.fillEllipse(in: CGRect(
                x: center.x - radius - s * 0.006, y: center.y - radius - s * 0.006,
                width: (radius + s * 0.006) * 2, height: (radius + s * 0.006) * 2))
        }
        context.setFillColor(node.fill)
        context.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    return context.makeImage()
}

// MARK: output

let outputURL = URL(
    fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "App/Resources/Assets.xcassets/AppIcon.appiconset")

let sizes: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for (name, size) in sizes {
    guard let image = drawIcon(size: size) else {
        FileHandle.standardError.write("failed to draw \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outputURL.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("failed to open \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write("failed to write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(name)")
}

// Contents.json — the classic macOS size grid.
let contents = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try contents.write(
    to: outputURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
