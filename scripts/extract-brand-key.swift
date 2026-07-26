#!/usr/bin/env swift
//
// Extracts the green key from the MyPass app icon into BrandKey PNG assets.
// Usage: swift scripts/extract-brand-key.swift [source.png]

import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let defaultSources = [
    repoRoot.appendingPathComponent("MyPass/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"),
    URL(fileURLWithPath: "/Users/lucheninov/.cursor/projects/Users-lucheninov-Documents-Works-all-sync-docs-mypass/assets/mypass-app-icon-final.png"),
    repoRoot.appendingPathComponent("MyPass/Assets.xcassets/AppIcon.appiconset/icon_512x512.png"),
]

let sourcePath: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    for candidate in defaultSources where FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }
    fputs("No source icon found.\n", stderr)
    exit(1)
}()

let outputDir = repoRoot.appendingPathComponent("MyPass/Assets.xcassets/BrandKey.imageset")

func loadImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return image
}

func isGreenKeyPixel(r: UInt8, g: UInt8, b: UInt8, x: Int, y: Int, width: Int, height: Int) -> Bool {
    let rf = Double(r) / 255.0
    let gf = Double(g) / 255.0
    let bf = Double(b) / 255.0
    let maxC = max(rf, gf, bf)
    let minC = min(rf, gf, bf)

    // Remove fingerprint badge: pink/red in bottom-right quadrant.
    let inBadgeRegion = x > width * 55 / 100 && y > height * 55 / 100
    if inBadgeRegion && rf > 0.35 && rf > gf * 1.05 && rf > bf {
        return false
    }

    // Remove dark charcoal plate.
    if maxC < 0.22 && gf < 0.18 {
        return false
    }

    // Keep green key pixels (dominant green channel).
    if gf > 0.25 && gf >= rf * 0.95 && gf >= bf * 0.95 {
        return true
    }

    // Soft near-key shadow: very dark green tint adjacent to key body.
    if gf > 0.12 && gf > rf && gf > bf && maxC < 0.35 {
        return true
    }

    // Drop neutral dark shadows on the plate.
    if maxC - minC < 0.08 && maxC < 0.35 {
        return false
    }

    return false
}

func extractKey(from image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0

    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let r = pixels[offset]
            let g = pixels[offset + 1]
            let b = pixels[offset + 2]

            if isGreenKeyPixel(r: r, g: g, b: b, x: x, y: y, width: width, height: height) {
                pixels[offset + 3] = 255
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            } else {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 0
            }
        }
    }

    guard minX <= maxX, minY <= maxY else {
        fputs("No key pixels detected.\n", stderr)
        return nil
    }

    let cropW = maxX - minX + 1
    let cropH = maxY - minY + 1
    let padX = Int(Double(cropW) * 0.10)
    let padY = Int(Double(cropH) * 0.10)
    let paddedMinX = max(0, minX - padX)
    let paddedMinY = max(0, minY - padY)
    let paddedMaxX = min(width - 1, maxX + padX)
    let paddedMaxY = min(height - 1, maxY + padY)
    let paddedW = paddedMaxX - paddedMinX + 1
    let paddedH = paddedMaxY - paddedMinY + 1

    guard let cropped = context.makeImage()?.cropping(to: CGRect(
        x: paddedMinX,
        y: paddedMinY,
        width: paddedW,
        height: paddedH
    )) else {
        return nil
    }

    return cropped
}

func resize(_ image: CGImage, targetHeight: Int) -> CGImage? {
    let aspect = Double(image.width) / Double(image.height)
    let targetWidth = Int(Double(targetHeight) * aspect)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

guard let sourceImage = loadImage(at: sourcePath) else {
    fputs("Failed to load source: \(sourcePath.path)\n", stderr)
    exit(1)
}

guard let extracted = extractKey(from: sourceImage) else {
    exit(1)
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let exports: [(String, Int)] = [
    ("BrandKey.png", 200),
    ("BrandKey@2x.png", 400),
]

for (filename, height) in exports {
    guard let resized = resize(extracted, targetHeight: height),
          writePNG(resized, to: outputDir.appendingPathComponent(filename)) else {
        fputs("Failed to write \(filename)\n", stderr)
        exit(1)
    }
    print("Wrote \(filename): \(resized.width)x\(resized.height)")
}

let contentsJSON = """
{
  "images" : [
    { "filename" : "BrandKey.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "BrandKey@2x.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

try contentsJSON.write(to: outputDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Source: \(sourcePath.lastPathComponent) (\(sourceImage.width)x\(sourceImage.height))")
print("Output: \(outputDir.path)")
