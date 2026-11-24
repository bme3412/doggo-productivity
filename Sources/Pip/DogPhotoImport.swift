import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ImportedDog: Identifiable, Sendable {
    var profile: DogProfile
    let sourcePhoto: Data
    var id: UUID { profile.id }
}

enum DogPhotoImport {
    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Doggo couldn’t open this photo. Try a JPEG, PNG, or HEIC image." }
    }

    static func drafts(from urls: [URL]) throws -> [ImportedDog] {
        try urls.flatMap { url in
            try drafts(from: url, limit: urls.count == 1 ? DogAppearance.limit : 1)
        }.enumerated().map { index, draft in
            var draft = draft
            draft.profile.name = "Dog \(index + 1)"
            return draft
        }
    }

    private static func drafts(from url: URL, limit: Int) throws -> [ImportedDog] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 960
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadable
        }

        let original = try photoData(from: image)
        let cropped = dogCrops(in: image, limit: limit)
        return try (cropped.isEmpty ? [image] : cropped).map { crop in
            ImportedDog(profile: try profile(from: crop), sourcePhoto: original)
        }
    }

    static func crop(_ draft: ImportedDog, to region: CGRect) throws -> ImportedDog {
        guard let source = CGImageSourceCreateWithData(draft.sourcePhoto as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImportError.unreadable }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(x: region.minX * bounds.width, y: region.minY * bounds.height,
                          width: region.width * bounds.width, height: region.height * bounds.height)
            .integral.intersection(bounds)
        guard rect.width >= 24, rect.height >= 24, let part = image.cropping(to: rect) else { throw ImportError.unreadable }
        var result = try profile(from: part)
        result.id = draft.id
        result.name = draft.profile.name
        return ImportedDog(profile: result, sourcePhoto: draft.sourcePhoto)
    }

    private static func profile(from image: CGImage) throws -> DogProfile {
        let subject = foreground(in: image)
        let palette = colors(in: subject ?? image, centerOnly: subject == nil)
        var look = DogLook()
        if let first = palette.first(where: { $0.luma >= 32 }) ?? palette.first {
            let dark = palette.first { $0.luma < first.luma * 0.68 }
            let light = palette.first { $0.luma > first.luma + 56 }
            let coat = first.luma < 32 ? DogLook.shade(first.hex, by: 0.12) : first.hex
            look.coat = coat
            look.muzzle = dark?.hex ?? DogLook.shade(coat, by: -0.22)
            look.earColor = dark?.hex ?? DogLook.shade(coat, by: -0.32)
            if let light {
                look.markings = .patches
                look.markingsColor = light.hex
            } else {
                look.markingsColor = DogLook.shade(coat, by: -0.34)
            }
        }
        return DogProfile(name: "", look: look, referencePhoto: try photoData(from: image))
    }

    private static func photoData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.unreadable
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ImportError.unreadable }
        return data as Data
    }

    private static func dogCrops(in image: CGImage, limit: Int) -> [CGImage] {
        let request = VNRecognizeAnimalsRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = (request.results ?? []).compactMap { observation -> (CGRect, Float)? in
            guard let label = observation.labels.first(where: { $0.identifier == VNAnimalIdentifier.dog.rawValue }),
                  label.confidence >= 0.4 else { return nil }
            return (observation.boundingBox, label.confidence)
        }.sorted { $0.1 > $1.1 }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return observations.prefix(limit).sorted { $0.0.midX < $1.0.midX }.compactMap { box, _ in
            let rect = CGRect(x: box.minX * bounds.width, y: (1 - box.maxY) * bounds.height,
                              width: box.width * bounds.width, height: box.height * bounds.height)
            let padded = rect.insetBy(dx: -rect.width * 0.045, dy: -rect.height * 0.045).integral.intersection(bounds)
            return padded.isEmpty ? nil : image.cropping(to: padded)
        }
    }

    private static func foreground(in image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                                from: handler, croppedToInstancesExtent: true) else { return nil }
        let masked = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(masked, from: masked.extent)
    }

    private struct ColorBucket {
        var red = 0, green = 0, blue = 0, count = 0

        mutating func add(_ r: Int, _ g: Int, _ b: Int) {
            red += r
            green += g
            blue += b
            count += 1
        }

        var hex: UInt32 { UInt32(((red / count) << 16) | ((green / count) << 8) | (blue / count)) }
        var luma: Double { (0.213 * Double(red) + 0.715 * Double(green) + 0.072 * Double(blue)) / Double(count) }
    }

    private static func colors(in image: CGImage, centerOnly: Bool) -> [ColorBucket] {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        return pixels.withUnsafeMutableBytes { raw -> [ColorBucket] in
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: info) else { return [] }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            let inset = centerOnly ? size / 4 : 0
            var buckets: [Int: ColorBucket] = [:]
            for y in inset..<(size - inset) {
                for x in inset..<(size - inset) {
                    let index = (y * size + x) * 4
                    guard raw[index + 3] > 240 else { continue }
                    let (r, g, b) = (Int(raw[index]), Int(raw[index + 1]), Int(raw[index + 2]))
                    let key = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5)
                    buckets[key, default: ColorBucket()].add(r, g, b)
                }
            }
            return buckets.values.filter { $0.count >= 16 }.sorted { $0.count > $1.count }
        }
    }
}
