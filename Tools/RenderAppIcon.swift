import AppKit

@main
struct RenderAppIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: render-app-icon OUTPUT.iconset\n", stderr)
            exit(2)
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for density in [1, 2] {
                let suffix = density == 2 ? "@2x" : ""
                let filename = "icon_\(points)x\(points)\(suffix).png"
                try render(pixels: points * density).write(to: destination.appendingPathComponent(filename))
            }
        }
    }

    private static func render(pixels: Int) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let scale = CGFloat(pixels) / 1024
        context.scaleBy(x: scale, y: scale)
        let tile = CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                          cornerWidth: 193, cornerHeight: 193, transform: nil)
        context.saveGState()
        context.addPath(tile)
        context.clip()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(srgbRed: 0.22, green: 0.43, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.08, green: 0.28, blue: 0.23, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 115, y: 935), end: CGPoint(x: 910, y: 92),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()

        StasherMark.draw(in: context, bounds: CGRect(x: 207, y: 207, width: 610, height: 610),
                         color: CGColor(srgbRed: 0.97, green: 0.98, blue: 0.92, alpha: 1))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }
}
