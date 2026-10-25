import AppKit
import AVFoundation
import OpenDeviceHubEngine

/// The card that appears beside a device after a capture, and what happens to the file.
///
/// Left alone it files the capture and disappears, which is what the simulator this replaces does.
/// Acted on, it does that instead. Nothing is written to the capture folder until one of those
/// happens.
@MainActor
public final class CapturePreviewPresenter {
    public static let lifetime: TimeInterval = 6

    private var showing: [CapturePreviewPanel] = []
    private let filer: CaptureFiler
    private let report: (String) -> Void

    public init(filer: CaptureFiler = CaptureFiler(), report: @escaping (String) -> Void = { _ in }) {
        self.filer = filer
        self.report = report
    }

    public func show(_ capture: PendingCapture, beside window: NSWindow?) {
        guard let image = Self.thumbnail(for: capture.temporary) else {
            // Nothing to show is not a reason to lose the file.
            settle(capture)
            return
        }
        let isStill = NSImage(contentsOf: capture.temporary) != nil

        // Screenshots taken while one is on screen join it, so a run of them can be copied or
        // saved together. Anything else files what is showing first: one card at a time, as the
        // simulator this replaces does.
        if isStill, let panel = showing.last, panel.holdsOnlyStills {
            panel.add(capture, image: image)
            place(panel)
            panel.startCountdown(Self.lifetime)
            return
        }
        settleEverything()

        let panel = CapturePreviewPanel(capture: capture, image: image, isStill: isStill)
        panel.onFinish = { [weak self] outcome in self?.finish(panel, outcome) }
        panel.anchor = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.visibleArea = (window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        place(panel)
        showing.append(panel)
        panel.orderFrontRegardless()
        panel.startCountdown(Self.lifetime)
    }

    private func place(_ panel: CapturePreviewPanel) {
        panel.setFrame(
            CapturePreviewLayout.frame(size: panel.stackSize, beside: panel.anchor, visible: panel.visibleArea),
            display: true
        )
    }

    /// Everything still on screen is filed, so quitting does not quietly lose a capture.
    public func settleEverything() {
        for panel in showing {
            panel.onFinish = nil
            panel.stopCountdown()
            panel.captures.forEach(settle)
            panel.close()
        }
        showing.removeAll()
    }

    private func finish(_ panel: CapturePreviewPanel, _ outcome: CapturePreviewOutcome) {
        showing.removeAll { $0 === panel }
        // Finished once: a late hover or menu close must not start its countdown again.
        panel.onFinish = nil
        panel.stopCountdown()
        panel.close()
        switch outcome {
        case .settle:
            panel.captures.forEach(settle)
        case .discard:
            panel.captures.forEach(filer.discard)
        case .saved(let urls):
            for url in urls {
                report("saved \(url.path(percentEncoded: false))")
            }
            // Any the action could not move are filed as if left alone, which says why if that
            // fails too, rather than staying behind in the staging folder.
            for capture in panel.captures
            where FileManager.default.fileExists(atPath: capture.temporary.path(percentEncoded: false)) {
                settle(capture)
            }
        }
    }

    private func settle(_ capture: PendingCapture) {
        do {
            let landed = try filer.settle(capture)
            report("saved \(landed.path(percentEncoded: false))")
        } catch {
            report("could not save the capture: \(error.localizedDescription)")
        }
    }

    /// A still for an image, and the first frame for a recording, so a video does not show as a
    /// blank card.
    static func thumbnail(for url: URL) -> NSImage? {
        if let image = NSImage(contentsOf: url), image.size.width > 0 {
            return image
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: frame, size: CGSize(width: frame.width, height: frame.height))
    }
}

public enum CapturePreviewOutcome {
    case settle
    case discard
    case saved([URL])
}

@MainActor
final class CapturePreviewPanel: NSPanel {
    /// Oldest first; the newest is the card in front.
    private(set) var captures: [PendingCapture]
    private(set) var holdsOnlyStills: Bool
    var anchor: CGRect = .zero
    var visibleArea: CGRect = .zero
    var onFinish: ((CapturePreviewOutcome) -> Void)?

    private var countdown: Task<Void, Never>?
    private var lifetime: TimeInterval = 0
    private var isHovered = false
    private var isMenuOpen = false
    private let filer = CaptureFiler()
    private let stack: CapturePreviewView
    private var saveItem: NSMenuItem?

    init(capture: PendingCapture, image: NSImage, isStill: Bool) {
        captures = [capture]
        holdsOnlyStills = isStill
        stack = CapturePreviewView(image: image)
        super.init(
            contentRect: .zero,
            // Borderless and non activating: this is a notice, not something to switch apps for.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        stack.autoresizingMask = [.width, .height]
        stack.onClick = { [weak self] in self?.open() }
        stack.onHover = { [weak self] inside in
            self?.isHovered = inside
            self?.holdChanged()
        }
        stack.menu = buildMenu()
        contentView = stack
    }

    /// The front card is sized by the newest capture, so a stack across devices follows the last.
    var stackSize: CGSize {
        CapturePreviewLayout.stackSize(card: stack.cardSize, count: captures.count)
    }

    func add(_ capture: PendingCapture, image: NSImage) {
        captures.append(capture)
        stack.add(image)
        saveItem?.title = captures.count > 1 ? "Save To\u{2026}" : "Save As\u{2026}"
    }

    func startCountdown(_ seconds: TimeInterval) {
        lifetime = seconds
        countdown?.cancel()
        // Held while the pointer is on it, a new capture joining must not start the clock.
        guard !isHovered, !isMenuOpen else {
            countdown = nil
            return
        }
        countdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.onFinish?(.settle)
        }
    }

    func stopCountdown() {
        countdown?.cancel()
        countdown = nil
    }

    /// The card stays while the pointer is on it or its menu is open, and gets its full time again
    /// once left, so it never closes under someone reaching for it. Tracked apart because opening
    /// the menu can move the pointer out of the card.
    private func holdChanged() {
        guard onFinish != nil else { return }
        if isHovered || isMenuOpen {
            stopCountdown()
        } else if countdown == nil {
            startCountdown(lifetime)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for (title, action) in [
            ("Open", #selector(open)),
            ("Save As\u{2026}", #selector(saveAs)),
            ("Copy", #selector(copyToPasteboard)),
            ("Reveal in Finder", #selector(reveal)),
            ("Delete", #selector(deleteCapture)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            if action == #selector(saveAs) { saveItem = item }
        }
        return menu
    }

    /// Opening, revealing and copying a recording all need the file where it is going to live, so
    /// they settle it first. Only Delete and the countdown decide otherwise.
    private func settleAll() -> [URL] {
        captures.compactMap { try? filer.settle($0) }
    }

    @objc private func open() {
        stopCountdown()
        let landed = settleAll()
        landed.forEach { NSWorkspace.shared.open($0) }
        onFinish?(.saved(landed))
    }

    @objc private func reveal() {
        stopCountdown()
        let landed = settleAll()
        NSWorkspace.shared.activateFileViewerSelecting(landed)
        onFinish?(.saved(landed))
    }

    /// Each screenshot goes on the pasteboard as its own item holding only the picture, oldest
    /// first, so pasting a stack pastes every image in it. Writing the file's URL as well made a
    /// second item that paste targets took first, so they pasted the temporary path, which no
    /// longer exists once the capture is filed. A recording has no picture to copy, so it is filed
    /// first and copied as the file where it landed.
    @objc private func copyToPasteboard() {
        stopCountdown()
        let pasteboard = NSPasteboard.general
        if holdsOnlyStills {
            let items = captures.compactMap { capture -> NSPasteboardItem? in
                guard let png = Self.pngData(at: capture.temporary) else { return nil }
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
                return item
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
            onFinish?(.settle)
            return
        }
        let landed = settleAll()
        pasteboard.clearContents()
        pasteboard.writeObjects(landed.map { $0 as NSURL })
        onFinish?(.saved(landed))
    }

    /// The capture as PNG: the file itself when it already is one, otherwise re-encoded. Nil for a
    /// recording.
    private static func pngData(at url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url),
           NSImage(data: data) != nil {
            return data
        }
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// One capture is named in a save panel. A stack keeps its names and asks only for a folder.
    @objc private func saveAs() {
        stopCountdown()
        guard captures.count > 1 else {
            let capture = captures[0]
            let panel = NSSavePanel()
            panel.nameFieldStringValue = capture.name
            panel.directoryURL = capture.destination
            guard panel.runModal() == .OK, let chosen = panel.url,
                  let landed = try? filer.save(capture, to: chosen) else {
                // Cancelled, so the capture is still pending and keeps its original fate.
                onFinish?(.settle)
                return
            }
            onFinish?(.saved([landed]))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Choose a folder for \(captures.count) screenshots."
        panel.directoryURL = captures[0].destination
        guard panel.runModal() == .OK, let folder = panel.url else {
            onFinish?(.settle)
            return
        }
        let landed = captures.compactMap { capture in
            try? filer.save(
                capture,
                to: CaptureFiler.availableURL(folder.appending(path: capture.name), manager: .default)
            )
        }
        onFinish?(.saved(landed))
    }

    @objc private func deleteCapture() {
        stopCountdown()
        onFinish?(.discard)
    }
}

extension CapturePreviewPanel: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        holdChanged()
    }

    // Sent before the chosen item's action, which stops the countdown again.
    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        holdChanged()
    }
}

/// The newest capture in front, with up to `CapturePreviewLayout.stackDepth` older ones peeking
/// out behind it and a count once there is more than one.
private final class CapturePreviewView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var images: [NSImage]

    private static let cornerRadius: CGFloat = 10

    init(image: NSImage) {
        images = [image]
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    var cardSize: CGSize { CapturePreviewLayout.size(for: images.last?.size ?? .zero) }

    func add(_ image: NSImage) {
        images.append(image)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let card = cardSize
        let behind = images.dropLast().suffix(CapturePreviewLayout.stackDepth)
        // Back to front, so the deepest card is drawn first and the newest lands on top.
        for (index, image) in behind.enumerated() {
            let depth = CGFloat(behind.count - index)
            let origin = CGPoint(x: depth * CapturePreviewLayout.stackOffset, y: depth * CapturePreviewLayout.stackOffset)
            drawCard(image, in: CGRect(origin: origin, size: card), dimmed: true)
        }
        if let front = images.last {
            drawCard(front, in: CGRect(origin: .zero, size: card), dimmed: false)
        }
        if images.count > 1 {
            drawBadge(images.count, on: CGRect(origin: .zero, size: card))
        }
    }

    private func drawCard(_ image: NSImage, in rect: CGRect, dimmed: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.6 : 1)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        border.lineWidth = 1
        border.stroke()
    }

    private func drawBadge(_ count: Int, on card: CGRect) {
        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let height: CGFloat = 20
        let width = max(height, textSize.width + 12)
        let badge = CGRect(x: card.minX + 6, y: card.maxY - height - 6, width: width, height: height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: height / 2, yRadius: height / 2).fill()
        text.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        // Control click is a right click, which is how the menu is reached on a one button mouse.
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        onClick?()
    }
}
