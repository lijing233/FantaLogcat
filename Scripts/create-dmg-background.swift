#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: create-dmg-background.swift OUTPUT_PNG\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSize = NSSize(width: 760, height: 440)
let image = NSImage(size: canvasSize)

image.lockFocus()

let canvas = NSRect(origin: .zero, size: canvasSize)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.00, alpha: 1),
    ending: NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.98, alpha: 1)
)
gradient?.draw(in: canvas, angle: -90)

func drawCard(_ rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.10, alpha: 0.12)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.set()

    NSColor.white.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor(calibratedRed: 0.75, green: 0.81, blue: 0.89, alpha: 0.48).setStroke()
    let border = NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24)
    border.lineWidth = 1
    border.stroke()
}

drawCard(NSRect(x: 96, y: 102, width: 198, height: 202))
drawCard(NSRect(x: 466, y: 102, width: 198, height: 202))

NSColor(calibratedRed: 0.24, green: 0.55, blue: 0.96, alpha: 0.10).setFill()
NSBezierPath(roundedRect: NSRect(x: 330, y: 176, width: 100, height: 58), xRadius: 29, yRadius: 29).fill()

let arrowColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 0.95, alpha: 1)
arrowColor.setStroke()

let arrow = NSBezierPath()
arrow.lineWidth = 3.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 352, y: 205))
arrow.line(to: NSPoint(x: 406, y: 205))
arrow.move(to: NSPoint(x: 396, y: 215))
arrow.line(to: NSPoint(x: 406, y: 205))
arrow.line(to: NSPoint(x: 396, y: 195))
arrow.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.21, alpha: 1),
    .paragraphStyle: paragraph,
]

let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.34, green: 0.40, blue: 0.49, alpha: 1),
    .paragraphStyle: paragraph,
]

NSString(string: "安装 FantaLogcat").draw(
    in: NSRect(x: 80, y: 366, width: 600, height: 34),
    withAttributes: titleAttributes
)
NSString(string: "将左侧应用拖到右侧 Applications 文件夹").draw(
    in: NSRect(x: 80, y: 338, width: 600, height: 24),
    withAttributes: subtitleAttributes
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("failed to render DMG background\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
