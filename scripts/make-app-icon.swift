// Draws docs/assets/app-icon.png, the 1024 px source for Parrot.app's icon: the
// bird from docs/assets/icon.png on a white rounded square in the macOS icon grid
// (an 824 px body with a 100 px margin). A full-bleed or transparent icon
// gets a gray tile from macOS 26; this shape does not.
//
//     swift scripts/make-app-icon.swift
import AppKit

let canvas: CGFloat = 1024
let body: CGFloat = 824
let corner: CGFloat = 185
/// The bird's width as a share of the body.
let birdScale: CGFloat = 0.7

guard let bird = NSImage(contentsOfFile: "docs/assets/icon.png") else {
    fatalError("run from the repository root: docs/assets/icon.png not found")
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let margin = (canvas - body) / 2
let tile = NSRect(x: margin, y: margin, width: body, height: body)
// The soft drop shadow macOS icons carry.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 20
shadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner).fill()
NSShadow().set()

let side = body * birdScale
let birdRect = NSRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
bird.draw(in: birdRect)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/assets/app-icon.png"))
print("wrote docs/assets/app-icon.png")
