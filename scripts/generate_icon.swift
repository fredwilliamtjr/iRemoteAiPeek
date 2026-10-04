#!/usr/bin/env swift
import AppKit

// Gerador do ícone do iRemoteAiPeek — segue o mesmo padrão dos apps irmãos
// (iMackPeek, iCloudPeek, iNetPeek): squircle full-bleed, gradiente AZUL da família e um
// único SF Symbol branco centralizado. Glyph: "dot.radiowaves.left.and.right"
// (o Remote Control transmitindo).
//
// Uso: swift scripts/generate_icon.swift [pastaDeSaída] [azul|laranja|roxo]

let topColor: CGColor
let bottomColor: CGColor
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "azul"
switch variant {
case "laranja":
    topColor    = CGColor(red: 1.00, green: 0.62, blue: 0.26, alpha: 1)
    bottomColor = CGColor(red: 0.93, green: 0.35, blue: 0.14, alpha: 1)
case "roxo":
    topColor    = CGColor(red: 0.65, green: 0.43, blue: 1.00, alpha: 1)
    bottomColor = CGColor(red: 0.42, green: 0.19, blue: 0.84, alpha: 1)
default: // azul — base da família (iCloudPeek / iNetPeek)
    topColor    = CGColor(red: 0.16, green: 0.56, blue: 0.98, alpha: 1)
    bottomColor = CGColor(red: 0.06, green: 0.36, blue: 0.86, alpha: 1)
}

func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2237 // squircle-ish macOS, igual ao iNetPeek

    // Fundo: gradiente diagonal da cor da marca
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [topColor, bottomColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    cg.restoreGState()

    // Glyph branco centralizado
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.58, weight: .semibold)
        .applying(.preferringMonochrome())
    guard let base = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    let tinted = NSImage(size: base.size, flipped: false) { r in
        base.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let target = NSRect(x: (size - tinted.size.width) / 2,
                        y: (size - tinted.size.height) / 2,
                        width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: target)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try! data.write(to: URL(fileURLWithPath: path))
    print("  wrote \(path) (\(Int(rep.size.width))x\(Int(rep.size.height)))")
}

let defaultTarget = "Resources/Assets.xcassets/AppIcon.appiconset"
let targetDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultTarget

let outputs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

print("Rendering \(outputs.count) PNGs into \(targetDir) [\(variant)]")
for o in outputs { savePNG(renderIcon(size: o.1), to: "\(targetDir)/\(o.0)") }
print("Done.")
