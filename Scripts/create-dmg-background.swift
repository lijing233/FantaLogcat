#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: create-dmg-background.swift OUTPUT_PNG\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSize = NSSize(width: 720, height: 420)
let image = NSImage(size: canvasSize)

image.lockFocus()

let canvas = NSRect(origin: .zero, size: canvasSize)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.16, alpha: 1),
    ending: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.24, alpha: 1)
)
gradient?.draw(in: canvas, angle: -90)

let arrowColor = NSColor(calibratedRed: 0.30, green: 0.62, blue: 1.00, alpha: 1)
arrowColor.setStroke()

let arrow = NSBezierPath()
arrow.lineWidth = 7
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 292, y: 218))
arrow.line(to: NSPoint(x: 428, y: 218))
arrow.move(to: NSPoint(x: 395, y: 247))
arrow.line(to: NSPoint(x: 428, y: 218))
arrow.line(to: NSPoint(x: 395, y: 189))
arrow.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
]

let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1),
    .paragraphStyle: paragraph,
]

NSString(string: "拖到 Applications 完成安装").draw(
    in: NSRect(x: 80, y: 88, width: 560, height: 30),
    withAttributes: titleAttributes
)
NSString(string: "Drag FantaLogcat to Applications to install").draw(
    in: NSRect(x: 80, y: 60, width: 560, height: 24),
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
