import AppKit
import Foundation

/// Original aperture/M artwork. This build utility only writes PNG icon assets.
@main struct MeshMonitorIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "MeshMonitorIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: MeshMonitorIcon /absolute/output.iconset"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                try render(pixels: size * scale).write(to: url)
            }
        }
    }

    static func render(pixels: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let cg = graphics.cgContext
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)
        let colors = CGColorSpaceCreateDeviceRGB()
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            NSColor(calibratedRed: r, green: g, blue: b, alpha: a).cgColor
        }
        let ice = color(0.53, 0.90, 1), blue = color(0.22, 0.43, 1), violet = color(0.61, 0.48, 1)
        let tile = CGPath(roundedRect: CGRect(x: 68, y: 68, width: 888, height: 888), cornerWidth: 199, cornerHeight: 199, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -15), blur: 32, color: color(0, 0, 0, 0.4))
        cg.addPath(tile); cg.setFillColor(color(0.025, 0.041, 0.078)); cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(tile); cg.clip()
        let backdrop = CGGradient(colorsSpace: colors, colors: [color(0.095, 0.145, 0.235), color(0.019, 0.030, 0.068), color(0.035, 0.028, 0.082)] as CFArray, locations: [0, 0.57, 1])!
        cg.drawLinearGradient(backdrop, start: CGPoint(x: 230, y: 970), end: CGPoint(x: 830, y: 40), options: [])
        let glow = CGGradient(colorsSpace: colors, colors: [color(0.25, 0.45, 1, 0.14), color(0.25, 0.45, 1, 0)] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 530), startRadius: 30, endCenter: CGPoint(x: 512, y: 530), endRadius: 465, options: [])
        // The hairline orbit stays quiet; the six aperture blades carry the silhouette.
        if pixels >= 64 {
            cg.setStrokeColor(color(0.4, 0.64, 1, 0.10)); cg.setLineWidth(1.5)
            cg.strokeEllipse(in: CGRect(x: 162, y: 162, width: 700, height: 700))
        }
        let side: CGFloat = 710, origin: CGFloat = (1024 - side) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin + x * side, y: origin + (1 - y) * side) }
        let blade = CGMutablePath()
        blade.move(to: p(0.49, 0.07))
        blade.addCurve(to: p(0.84, 0.23), control1: p(0.62, 0.055), control2: p(0.75, 0.12))
        blade.addLine(to: p(0.58, 0.24))
        blade.addCurve(to: p(0.30, 0.41), control1: p(0.45, 0.23), control2: p(0.35, 0.31))
        blade.addLine(to: p(0.33, 0.20))
        blade.addCurve(to: p(0.49, 0.07), control1: p(0.36, 0.12), control2: p(0.42, 0.09))
        blade.closeSubpath()
        for index in 0..<6 {
            cg.saveGState()
            cg.translateBy(x: 512, y: 512); cg.rotate(by: -CGFloat(index) * .pi / 3); cg.translateBy(x: -512, y: -512)
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 21, color: color(0.22, 0.5, 1, 0.3))
            cg.addPath(blade); cg.setFillColor(blue); cg.fillPath()
            cg.restoreGState()
            cg.addPath(blade); cg.clip()
            let gradient = CGGradient(colorsSpace: colors, colors: [ice, index.isMultiple(of: 2) ? blue : violet] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: p(0.35, 0.07), end: p(0.70, 0.35), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            cg.restoreGState()
            // A narrow edge separates blades at small Dock sizes without visual noise.
            cg.saveGState()
            cg.translateBy(x: 512, y: 512); cg.rotate(by: -CGFloat(index) * .pi / 3); cg.translateBy(x: -512, y: -512)
            cg.addPath(blade); cg.setStrokeColor(color(0.68, 0.92, 1, 0.28)); cg.setLineWidth(1.8); cg.strokePath()
            cg.restoreGState()
        }
        let monogram = CGMutablePath()
        monogram.move(to: p(0.35, 0.64)); monogram.addLine(to: p(0.35, 0.40))
        monogram.addLine(to: p(0.5, 0.53)); monogram.addLine(to: p(0.65, 0.40))
        monogram.addLine(to: p(0.65, 0.64))
        cg.saveGState()
        cg.addPath(monogram); cg.setLineWidth(side * 0.061); cg.setLineCap(.round); cg.setLineJoin(.round)
        cg.replacePathWithStrokedPath(); cg.clip()
        let center = CGGradient(colorsSpace: colors, colors: [ice, color(0.60, 0.60, 1)] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(center, start: p(0.5, 0.4), end: p(0.5, 0.67), options: [])
        cg.restoreGState()
        cg.restoreGState()
        cg.addPath(tile); cg.setStrokeColor(color(0.49, 0.66, 0.89, 0.34)); cg.setLineWidth(2); cg.strokePath()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
