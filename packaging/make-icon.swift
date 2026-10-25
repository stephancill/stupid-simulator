import AppKit

// The app icon and the social banner, drawn in code so every size comes from one description rather
// than from exported files that drift: two device windows, one in front of the other, which is what
// this app does that the tool it replaces does not.
// The artwork is a drawing, packaging/AppIcon.png: a square picture on white. Found beside this file
// at compile time, so `swiftc` run from anywhere still finds it.
let artworkURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AppIcon.png")
guard let artwork = NSImage(contentsOf: artworkURL) else {
    print("could not read \(artworkURL.path)")
    exit(1)
}

/// The drawing's own paper and ink, used wherever something has to match it.
let paper = NSColor.white
let ink = NSColor.black

func drawArtwork(in rect: NSRect) {
    artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

// `edgeToEdge` drops the rounded plate and the transparent margin around it, filling the square
// instead. Avatars are cropped to a circle or a rounded square by whoever displays them, so a
// picture that rounds its own corners first loses a ring of artwork to the second rounding.
func drawIcon(size: CGFloat, edgeToEdge: Bool = false) {
    // The plate sits on Apple's icon grid: 864 of 1024 units, rounded at 190, with a transparent
    // margin macOS expects. The drawing fills the plate, clipped to its corners.
    let unit = size / 1024
    let frame = edgeToEdge
        ? NSRect(x: 0, y: 0, width: size, height: size)
        : NSRect(x: 80 * unit, y: 80 * unit, width: 864 * unit, height: 864 * unit)
    let radius = edgeToEdge ? 0 : 190 * unit
    let plate = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    paper.setFill()
    plate.fill()
    drawArtwork(in: frame)
    NSGraphicsContext.restoreGraphicsState()
}

// Drawn into a bitmap of exactly the asked for pixel size. Going through `NSImage.lockFocus` instead
// hands back the main display's backing scale, so on a Retina Mac every file came out at twice the
// size its name promised.
func png(size: Int, edgeToEdge: Bool = false) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        print("could not make a \(size) bitmap")
        exit(1)
    }
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawIcon(size: CGFloat(size), edgeToEdge: edgeToEdge)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        print("could not encode \(size)")
        exit(1)
    }
    return data
}

// GitHub asks for at least 640x320 and shows 1280x640 best. It also crops the edges in some places,
// so everything that matters stays well inside the frame.
func socialPreview(width: Int = 1280, height: Int = 640) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        print("could not make the banner bitmap")
        exit(1)
    }
    bitmap.size = NSSize(width: width, height: width == 0 ? 0 : height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    paper.setFill()
    frame.fill()

    let side: CGFloat = 470
    drawArtwork(in: NSRect(x: 245 - side / 2, y: (CGFloat(height) - side) / 2, width: side, height: side))

    let left: CGFloat = 470
    let title = "stupid simulator"
    let tagline = "iOS simulators in windows again, for people and agents."
    let footnote = "A fork of OpenDeviceHub. MIT licensed. For Xcode 27 on macOS 14 or later."

    title.draw(
        at: NSPoint(x: left, y: CGFloat(height) / 2 + 16),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 76, weight: .bold),
            .foregroundColor: ink,
        ]
    )
    tagline.draw(
        at: NSPoint(x: left + 4, y: CGFloat(height) / 2 - 44),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 31, weight: .regular),
            .foregroundColor: ink.withAlphaComponent(0.85),
        ]
    )
    footnote.draw(
        at: NSPoint(x: left + 4, y: CGFloat(height) / 2 - 100),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 23, weight: .regular),
            .foregroundColor: ink.withAlphaComponent(0.55),
        ]
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        print("could not encode the banner")
        exit(1)
    }
    return data
}

// The download button on the README. Drawn rather than written as SVG text, because a web font is
// not guaranteed where the README is rendered and clipped lettering is worse than a picture.
func downloadButton(scale: CGFloat = 2) -> Data {
    let label = "Download for macOS"
    let font = NSFont.systemFont(ofSize: 25 * scale, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let text = label.size(withAttributes: attributes)

    let arrow = 22 * scale
    let padding = 30 * scale
    let gap = 14 * scale
    // Sized to the text it was measured with, so a longer label cannot run off the end.
    let width = Int((padding * 2 + arrow + gap + text.width).rounded())
    let height = Int((text.height + 26 * scale).rounded())

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        print("could not make the button bitmap")
        exit(1)
    }
    bitmap.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    let pill = NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
    ink.setFill()
    pill.fill()

    let centre = frame.height / 2
    let arrowX = padding + arrow / 2
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: arrowX, y: centre + arrow * 0.55))
    stem.line(to: NSPoint(x: arrowX, y: centre - arrow * 0.15))
    stem.lineWidth = 3 * scale
    stem.lineCapStyle = .round
    NSColor.white.setStroke()
    stem.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: arrowX - arrow * 0.42, y: centre - arrow * 0.02))
    head.line(to: NSPoint(x: arrowX, y: centre - arrow * 0.5))
    head.line(to: NSPoint(x: arrowX + arrow * 0.42, y: centre - arrow * 0.02))
    head.lineWidth = 3 * scale
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let tray = NSBezierPath()
    tray.move(to: NSPoint(x: arrowX - arrow * 0.5, y: centre - arrow * 0.62))
    tray.line(to: NSPoint(x: arrowX + arrow * 0.5, y: centre - arrow * 0.62))
    tray.lineWidth = 3 * scale
    tray.lineCapStyle = .round
    tray.stroke()

    label.draw(
        at: NSPoint(x: padding + arrow + gap, y: (frame.height - text.height) / 2),
        withAttributes: attributes
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        print("could not encode the button")
        exit(1)
    }
    return data
}

let outputDirectory = CommandLine.arguments[1]

if CommandLine.arguments.contains("--button") {
    try downloadButton().write(to: URL(fileURLWithPath: "\(outputDirectory)/download-button.png"))
    print("wrote the download button to \(outputDirectory)")
    exit(0)
}

if CommandLine.arguments.contains("--social") {
    try socialPreview().write(to: URL(fileURLWithPath: "\(outputDirectory)/social-preview.png"))
    print("wrote the social preview to \(outputDirectory)")
    exit(0)
}

if CommandLine.arguments.contains("--marketing") {
    // Sizes people actually ask for: favicons, a README header, an avatar, and one big enough to
    // hand to a designer or to a store listing.
    for size in [16, 32, 48, 64, 128, 180, 256, 512, 1024] {
        try png(size: size).write(to: URL(fileURLWithPath: "\(outputDirectory)/icon-\(size).png"))
    }
    for size in [400, 512, 1024] {
        try png(size: size, edgeToEdge: true)
            .write(to: URL(fileURLWithPath: "\(outputDirectory)/icon-square-\(size).png"))
    }
    print("wrote the marketing icons to \(outputDirectory)")
    exit(0)
}

// The ten slots `iconutil` reads, by the only names it accepts. A file named anything else, such as
// `icon_64x64.png` or `icon_1024x1024.png`, is ignored without a word, which is how the icon came to
// stop at 512 and look soft wherever macOS asks for a bigger one.
let slots: [(pixels: Int, name: String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]
var rendered: [Int: Data] = [:]
for slot in slots {
    let data = rendered[slot.pixels] ?? png(size: slot.pixels)
    rendered[slot.pixels] = data
    try data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(slot.name).png"))
}
print("wrote icon set to \(outputDirectory)")
