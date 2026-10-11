import AppKit

// One vector description drives both the editable SVG and every native icon size.
private struct Color {
    let hex: String
    var cg: CGColor {
        let value = UInt32(hex, radix: 16)!
        return CGColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

private enum Segment {
    case move(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case close
}

private enum Geometry {
    case roundedRect(CGRect, CGFloat)
    case circle(CGPoint, CGFloat)
    case ellipse(CGRect)
    case path([Segment])

    var cg: CGPath {
        switch self {
        case let .roundedRect(rect, radius):
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case let .circle(center, radius):
            return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2), transform: nil)
        case let .ellipse(rect):
            return CGPath(ellipseIn: rect, transform: nil)
        case let .path(segments):
            let path = CGMutablePath()
            for segment in segments {
                switch segment {
                case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
                case let .curve(x1, y1, x2, y2, x, y):
                    path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1),
                                  control2: CGPoint(x: x2, y: y2))
                case .close: path.closeSubpath()
                }
            }
            return path
        }
    }

    func svg(attributes: String) -> String {
        func n(_ value: CGFloat) -> String { String(Int(value)) }
        switch self {
        case let .roundedRect(rect, radius):
            return "<rect x=\"\(n(rect.minX))\" y=\"\(n(rect.minY))\" width=\"\(n(rect.width))\" height=\"\(n(rect.height))\" rx=\"\(n(radius))\" \(attributes)/>"
        case let .circle(center, radius):
            return "<circle cx=\"\(n(center.x))\" cy=\"\(n(center.y))\" r=\"\(n(radius))\" \(attributes)/>"
        case let .ellipse(rect):
            return "<ellipse cx=\"\(n(rect.midX))\" cy=\"\(n(rect.midY))\" rx=\"\(n(rect.width / 2))\" ry=\"\(n(rect.height / 2))\" \(attributes)/>"
        case let .path(segments):
            let data = segments.map { segment in
                switch segment {
                case let .move(x, y): return "M\(n(x)) \(n(y))"
                case let .curve(x1, y1, x2, y2, x, y):
                    return "C\(n(x1)) \(n(y1)) \(n(x2)) \(n(y2)) \(n(x)) \(n(y))"
                case .close: return "Z"
                }
            }.joined(separator: " ")
            return "<path d=\"\(data)\" \(attributes)/>"
        }
    }
}

private struct Shape {
    let geometry: Geometry
    let fill: Color?
    let stroke: Color?
    let width: CGFloat
    init(_ geometry: Geometry, fill: Color? = nil, stroke: Color? = nil, width: CGFloat = 0) {
        self.geometry = geometry; self.fill = fill; self.stroke = stroke; self.width = width
    }
    var svg: String {
        let fillAttribute = "fill=\"\(fill.map { "#" + $0.hex } ?? "none")\""
        let strokeAttribute = stroke.map { " stroke=\"#\($0.hex)\" stroke-width=\"\(Int(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"" } ?? ""
        return geometry.svg(attributes: fillAttribute + strokeAttribute)
    }
    func draw(in context: CGContext) {
        if let fill {
            context.addPath(geometry.cg); context.setFillColor(fill.cg); context.fillPath()
        }
        if let stroke {
            context.addPath(geometry.cg); context.setStrokeColor(stroke.cg)
            context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
            context.strokePath()
        }
    }
}

@main
struct GenerateIcon {
    private static var shapes: [Shape] {
        let coral = Color(hex: "EE6345"), cream = Color(hex: "FFF5EA"), yellow = Color(hex: "FFD9A5")
        return [
            Shape(.roundedRect(CGRect(x: 64, y: 64, width: 896, height: 896), 204), fill: coral),
            // An eighth note beside three queued tracks stays legible at small sizes.
            Shape(.ellipse(CGRect(x: 204, y: 606, width: 182, height: 128)), fill: cream),
            Shape(.roundedRect(CGRect(x: 331, y: 266, width: 55, height: 402), 18), fill: cream),
            Shape(.path([.move(370, 266), .curve(438, 283, 500, 315, 484, 420),
                         .curve(474, 460, 446, 492, 412, 506),
                         .curve(438, 445, 449, 367, 370, 350), .close]), fill: cream),
            Shape(.roundedRect(CGRect(x: 542, y: 402, width: 262, height: 56), 28), fill: yellow),
            Shape(.roundedRect(CGRect(x: 542, y: 541, width: 232, height: 56), 28), fill: yellow),
            Shape(.roundedRect(CGRect(x: 542, y: 680, width: 180, height: 56), 28), fill: yellow)
        ]
    }

    private static func png(size: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "GenerateIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create bitmap"])
        }
        context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
        context.translateBy(x: 0, y: CGFloat(size)); context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
        for shape in shapes { shape.draw(in: context) }
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "GenerateIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
        }
        return data
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "GenerateIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Usage: GenerateIcon output-directory"])
        }
        let files = FileManager.default
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <!-- Generated by tools/GenerateIcon.swift: music note and queued tracks. -->
          \(shapes.map(\.svg).joined(separator: "\n  "))
        </svg>

        """
        try svg.write(to: destination.appendingPathComponent("AppIcon.svg"), atomically: true, encoding: .utf8)
        let scratch = files.temporaryDirectory.appendingPathComponent("menuqueue-icon-" + UUID().uuidString, isDirectory: true)
        let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try files.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        var rendered: [Int: Data] = [:]
        for size in [16, 32, 64, 128, 256, 512, 1024] { rendered[size] = try png(size: size) }
        for size in [16, 32, 128, 256, 512] {
            try rendered[size]!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"), options: .atomic)
            try rendered[size * 2]!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"), options: .atomic)
        }
        try rendered[1024]!.write(to: destination.appendingPathComponent("AppIcon.png"), options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        let icon = scratch.appendingPathComponent("AppIcon.icns")
        process.arguments = ["-c", "icns", iconset.path, "-o", icon.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GenerateIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
        }
        try Data(contentsOf: icon).write(to: destination.appendingPathComponent("AppIcon.icns"), options: .atomic)
        print("Created AppIcon.svg, AppIcon.png and AppIcon.icns in \(destination.path)")
    }
}
