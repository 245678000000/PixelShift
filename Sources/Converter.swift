import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Options

enum OutputFormat: String, CaseIterable, Codable, Identifiable {
    case heif = "HEIF", jpeg = "JPEG", pdf = "PDF", png = "PNG", tiff = "TIFF"
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .heif: return "heic"
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    var typeIdentifier: String {
        switch self {
        case .heif: return UTType.heic.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .pdf: return UTType.pdf.identifier
        case .png: return UTType.png.identifier
        case .tiff: return UTType.tiff.identifier
        }
    }

    /// Formats where a quality setting applies.
    var isLossy: Bool { self == .heif || self == .jpeg || self == .pdf }
    /// Formats that can't keep transparency (we composite onto white).
    var needsOpaqueBackground: Bool { self == .jpeg || self == .pdf }
}

enum ImageTransform: String, CaseIterable, Codable, Identifiable {
    case none = "无"
    case rotateCW = "顺时针旋转 90°"
    case rotateCCW = "逆时针旋转 90°"
    case rotate180 = "旋转 180°"
    case flipH = "水平翻转"
    case flipV = "垂直翻转"
    var id: String { rawValue }
    var swapsAxes: Bool { self == .rotateCW || self == .rotateCCW }
}

enum ResizeMode: String, CaseIterable, Codable, Identifiable {
    case percent = "百分比"
    case longEdge = "最长边"
    case exact = "宽 × 高"
    var id: String { rawValue }
}

enum DestinationMode: String, Codable {
    case sameAsSource
    case custom
}

struct ConversionOptions: Codable, Equatable {
    var format: OutputFormat = .jpeg
    var quality: Double = 0.85
    var destination: DestinationMode = .sameAsSource
    var customFolderPath: String? = nil
    var resizeEnabled = false
    var resizeMode: ResizeMode = .longEdge
    var resizePercent: Double = 50
    var resizeLongEdge: Int = 1920
    var resizeWidth: Int = 1920
    var resizeHeight: Int = 1080
    var keepAspect = true
    var noUpscale = true
    var sizeLimitEnabled = false
    var sizeLimitKB: Int = 500
    var transform: ImageTransform = .none
}

// MARK: - Errors

enum ConvertError: LocalizedError {
    case cannotRead, cannotDecode, cannotEncode(String), cannotFit(Int), noFolder

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "无法读取文件"
        case .cannotDecode: return "无法解码图片"
        case .cannotEncode(let f): return "此系统不支持编码为 \(f)"
        case .cannotFit(let kb): return "无法压缩到 \(kb) kB 以内"
        case .noFolder: return "目标文件夹不可用"
        }
    }
}

struct ConversionResult {
    let url: URL
    let bytes: Int
    let pixelSize: CGSize
}

// MARK: - Converter

enum Converter {
    static func convert(_ src: URL, options o: ConversionOptions, crop: CGRect? = nil) throws -> ConversionResult {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw ConvertError.cannotRead }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let pw = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let ph = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        // Decode at full size with EXIF orientation applied.
        let decodeOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOpts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConvertError.cannotDecode }

        // Crop (normalized rect, top-left origin, in oriented image space).
        var image = decoded
        if let c = crop {
            let W = CGFloat(decoded.width), H = CGFloat(decoded.height)
            let r = CGRect(x: (c.minX * W).rounded(), y: (c.minY * H).rounded(),
                           width: max(1, (c.width * W).rounded()), height: max(1, (c.height * H).rounded()))
                .intersection(CGRect(x: 0, y: 0, width: W, height: H))
            if !r.isNull, let cropped = decoded.cropping(to: r) { image = cropped }
        }

        if o.format != .pdf {
            let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            if !supported.contains(o.format.typeIdentifier) { throw ConvertError.cannotEncode(o.format.rawValue) }
        }

        let base = targetSize(for: CGSize(width: image.width, height: image.height), options: o)
        let limit = o.sizeLimitEnabled ? max(o.sizeLimitKB, 1) * 1024 : nil

        var scale: CGFloat = 1
        var output: (Data, CGSize)? = nil
        for _ in 0..<14 {
            let size = CGSize(width: max(1, (base.width * scale).rounded()),
                              height: max(1, (base.height * scale).rounded()))
            let rendered = try render(image, drawSize: size, transform: o.transform,
                                      opaque: o.format.needsOpaqueBackground)
            let outSize = CGSize(width: rendered.width, height: rendered.height)

            guard let limit else {
                output = (try encode(rendered, format: o.format, quality: o.quality), outSize)
                break
            }
            if let d = try fit(rendered, format: o.format, maxQuality: o.quality, limit: limit) {
                output = (d, outSize)
                break
            }
            if size.width <= 16 || size.height <= 16 { break }
            scale *= 0.8
        }
        guard let (data, outSize) = output else { throw ConvertError.cannotFit(o.sizeLimitKB) }

        let folder: URL
        if o.destination == .custom, let p = o.customFolderPath {
            folder = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            folder = src.deletingLastPathComponent()
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw ConvertError.noFolder
        }
        let dest = uniqueURL(in: folder, base: src.deletingPathExtension().lastPathComponent,
                             ext: o.format.fileExtension)
        try data.write(to: dest, options: .atomic)
        return ConversionResult(url: dest, bytes: data.count, pixelSize: outSize)
    }

    /// Try the requested quality, then binary-search lower qualities to fit `limit`.
    private static func fit(_ img: CGImage, format: OutputFormat, maxQuality: Double, limit: Int) throws -> Data? {
        let first = try encode(img, format: format, quality: maxQuality)
        if first.count <= limit { return first }
        guard format.isLossy else { return nil }
        var lo = 0.05, hi = maxQuality
        let floor = try encode(img, format: format, quality: lo)
        guard floor.count <= limit else { return nil }
        var best = floor
        for _ in 0..<7 {
            let mid = (lo + hi) / 2
            let d = try encode(img, format: format, quality: mid)
            if d.count <= limit { best = d; lo = mid } else { hi = mid }
        }
        return best
    }

    static func targetSize(for s: CGSize, options o: ConversionOptions) -> CGSize {
        guard o.resizeEnabled, s.width > 0, s.height > 0 else { return s }
        var t: CGSize
        switch o.resizeMode {
        case .percent:
            let f = max(o.resizePercent, 1) / 100
            t = CGSize(width: s.width * f, height: s.height * f)
        case .longEdge:
            let f = CGFloat(max(o.resizeLongEdge, 1)) / max(s.width, s.height)
            t = CGSize(width: s.width * f, height: s.height * f)
        case .exact:
            let w = CGFloat(max(o.resizeWidth, 1)), h = CGFloat(max(o.resizeHeight, 1))
            if o.keepAspect {
                let f = min(w / s.width, h / s.height)
                t = CGSize(width: s.width * f, height: s.height * f)
            } else {
                t = CGSize(width: w, height: h)
            }
        }
        if o.noUpscale && (t.width > s.width || t.height > s.height) {
            if o.resizeMode == .exact && !o.keepAspect {
                t = CGSize(width: min(t.width, s.width), height: min(t.height, s.height))
            } else {
                t = s
            }
        }
        return CGSize(width: max(1, t.width.rounded()), height: max(1, t.height.rounded()))
    }

    private static func render(_ image: CGImage, drawSize: CGSize, transform: ImageTransform, opaque: Bool) throws -> CGImage {
        let w = drawSize.width, h = drawSize.height
        let canvas = transform.swapsAxes ? CGSize(width: h, height: w) : drawSize
        let space: CGColorSpace = {
            if let cs = image.colorSpace, cs.model == .rgb { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertError.cannotDecode
        }
        ctx.interpolationQuality = .high
        if opaque {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: canvas))
        }
        let t: CGAffineTransform
        switch transform {
        case .none: t = .identity
        case .rotateCW: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rotateCCW: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .rotate180: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .flipH: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .flipV: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConvertError.cannotDecode }
        return out
    }

    private static func encode(_ image: CGImage, format: OutputFormat, quality: Double) throws -> Data {
        if format == .pdf { return try encodePDF(image, quality: quality) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else {
            throw ConvertError.cannotEncode(format.rawValue)
        }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff {
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.cannotEncode(format.rawValue) }
        return data as Data
    }

    /// One page per image; the image is embedded as JPEG so quality/size limits work.
    private static func encodePDF(_ image: CGImage, quality: Double) throws -> Data {
        let jpeg = try encode(image, format: .jpeg, quality: quality)
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let jpegImage = CGImage(jpegDataProviderSource: provider, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent) else {
            throw ConvertError.cannotEncode("PDF")
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw ConvertError.cannotEncode("PDF")
        }
        ctx.beginPDFPage(nil)
        ctx.draw(jpegImage, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
