import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
enum ItemImageCapturer {
    /// Last good capture per item. Hidden items aren't drawn anywhere, so their images
    /// have to be grabbed while they're visible and reused afterwards.
    private static var cache: [String: NSImage] = [:]

    static func cachedImages(for items: [MenuBarItem]) -> [String: NSImage] {
        var result: [String: NSImage] = [:]
        for item in items {
            result[item.id] = cache[item.id]
        }
        return result
    }

    /// Looking up shareable content is slow (especially the first time), so displays are cached.
    private static var displays: [CGDirectDisplayID: SCDisplay] = [:]

    static func prewarm() {
        guard Permissions.screenRecording else { return }
        Task { await refreshDisplays() }
    }

    private static func refreshDisplays() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        displays = Dictionary(content.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Captures the menu bar strip once and cuts each visible item out of it as a template image.
    /// `isStillValid` is checked once the screenshot is back, since the menu bar may have changed meanwhile.
    @discardableResult
    static func capture(_ items: [MenuBarItem], isStillValid: () -> Bool = { true }) async -> [String: NSImage] {
        var result = cachedImages(for: items)
        guard !items.isEmpty, Permissions.screenRecording,
              let screen = screen(containing: items[0].frame),
              let strip = await captureMenuBar(of: screen),
              isStillValid()
        else { return result }

        for item in items where MenuBarScanner.isClickable(item.frame) {
            guard let image = templateIcon(for: item, in: strip) else { continue }
            cache[item.id] = image
            result[item.id] = image
        }
        return result
    }

    private struct Strip {
        let image: CGImage
        let origin: CGPoint
        let scale: CGFloat
    }

    private static func screen(containing frame: CGRect) -> NSScreen? {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.cgFrame.contains(point) } ?? NSScreen.screens.first
    }

    private static func captureMenuBar(of screen: NSScreen) async -> Strip? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        if displays[displayID] == nil {
            await refreshDisplays()
        }
        guard let display = displays[displayID] else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let height = screen.menuBarHeight
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: height)
        config.width = Int(screen.frame.width * scale)
        config.height = Int(height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            displays[displayID] = nil
            return nil
        }
        return Strip(image: image, origin: screen.cgFrame.origin, scale: scale)
    }

    /// The menu bar is translucent, so a raw crop includes a slice of wallpaper.
    /// Estimate the background from the crop's edges and keep only the glyph as alpha.
    private static func templateIcon(for item: MenuBarItem, in strip: Strip) -> NSImage? {
        let rect = CGRect(
            x: (item.frame.minX - strip.origin.x) * strip.scale,
            y: (item.frame.minY - strip.origin.y) * strip.scale,
            width: item.frame.width * strip.scale,
            height: item.frame.height * strip.scale
        ).integral
        guard let cropped = strip.image.cropping(to: rect) else { return nil }

        let width = cropped.width, height = cropped.height
        guard width > 2, height > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)
            else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var luma = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Float(pixels[i * 4]), g = Float(pixels[i * 4 + 1]), b = Float(pixels[i * 4 + 2])
            luma[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }

        var edge: [Float] = []
        for x in 0..<width {
            edge.append(luma[x])
            edge.append(luma[(height - 1) * width + x])
        }
        for y in 0..<height {
            edge.append(luma[y * width])
            edge.append(luma[y * width + width - 1])
        }
        edge.sort()
        let background = edge[edge.count / 2]

        let deltas = luma.map { $0 - background }
        let lighter = deltas.filter { $0 > 0.12 }.count
        let darker = deltas.filter { $0 < -0.12 }.count
        guard lighter + darker > 0 else { return nil }
        let glyphIsLight = lighter >= darker
        let range = max(abs((glyphIsLight ? 1 : 0) - background), 0.25)

        var output = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let delta = glyphIsLight ? deltas[i] : -deltas[i]
            let alpha = min(max((delta - 0.04) / (range - 0.04), 0), 1)
            output[i * 4 + 3] = UInt8(alpha * 255)
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                 space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        let image = NSImage(cgImage: mask, size: item.frame.size)
        image.isTemplate = true
        return image
    }
}
