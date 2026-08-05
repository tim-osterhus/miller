import AppKit
import CoreGraphics
import Foundation
import ImageIO

private let canvasSize = 72
private let opticalBoxSize = 64

private func fail() -> Never {
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail()
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard
    let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
    image.width > 0,
    image.height > 0,
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: canvasSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
    )
else {
    fail()
}

context.interpolationQuality = .high
context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

let scale = min(
    CGFloat(opticalBoxSize) / CGFloat(image.width),
    CGFloat(opticalBoxSize) / CGFloat(image.height)
)
let drawSize = CGSize(
    width: CGFloat(image.width) * scale,
    height: CGFloat(image.height) * scale
)
let drawRect = CGRect(
    x: (CGFloat(canvasSize) - drawSize.width) / 2,
    y: (CGFloat(canvasSize) - drawSize.height) / 2,
    width: drawSize.width,
    height: drawSize.height
)
context.draw(image, in: drawRect)

let rendered = context.data!.assumingMemoryBound(to: UInt8.self)
var alpha = Array(repeating: UInt8.zero, count: canvasSize * canvasSize)
for index in alpha.indices {
    alpha[index] = rendered[index * 4 + 3]
}

guard
    let outputContext = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: canvasSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
    ),
    let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)
else {
    fail()
}

outputContext.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
let output = outputContext.data!.assumingMemoryBound(to: UInt8.self)
for index in alpha.indices {
    output[index * 4 + 3] = alpha[index]
}

guard let outputImage = outputContext.makeImage() else {
    fail()
}

CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fail()
}
