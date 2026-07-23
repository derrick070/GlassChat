import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum ImageCompressor {
    struct Result: Sendable {
        var imageData: Data
        var mimeType: String
        var width: Int
        var height: Int
        var thumbnailData: Data
    }

    enum Error: Swift.Error {
        case decodeFailed
        case encodeFailed
        case exceedsCap
    }

    static func prepare(imageData: Data, maxBytes: Int) throws -> Result {
        guard let image = UIImage(data: imageData) else { throw Error.decodeFailed }
        let full = try encode(
            image: image,
            maxEdge: MediaConstants.fullMaxEdge,
            maxBytes: maxBytes,
            preferHEIC: true
        )
        let thumb = try encode(
            image: image,
            maxEdge: MediaConstants.thumbnailMaxEdge,
            maxBytes: MediaConstants.thumbnailMaxBytes,
            preferHEIC: true
        )
        return Result(
            imageData: full.data,
            mimeType: full.mimeType,
            width: full.width,
            height: full.height,
            thumbnailData: thumb.data
        )
    }

    private struct Encoded {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
    }

    private static func encode(
        image: UIImage,
        maxEdge: CGFloat,
        maxBytes: Int,
        preferHEIC: Bool
    ) throws -> Encoded {
        let scaled = scale(image, maxEdge: maxEdge)
        guard let cgImage = scaled.cgImage else { throw Error.encodeFailed }
        let width = cgImage.width
        let height = cgImage.height

        let types: [(UTType, String, CGFloat)]
        if preferHEIC {
            types = [(.heic, "image/heic", 0.72), (.jpeg, "image/jpeg", 0.7)]
        } else {
            types = [(.jpeg, "image/jpeg", 0.7)]
        }

        var lastError: Swift.Error = Error.encodeFailed
        for (type, mime, quality) in types {
            var q = quality
            for _ in 0..<6 {
                do {
                    let data = try encodeCGImage(cgImage, type: type, quality: q)
                    if data.count <= maxBytes {
                        return Encoded(data: data, mimeType: mime, width: width, height: height)
                    }
                    q *= 0.82
                    lastError = Error.exceedsCap
                } catch {
                    lastError = error
                    break
                }
            }
        }
        throw lastError
    }

    private static func scale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func encodeCGImage(_ cgImage: CGImage, type: UTType, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw Error.encodeFailed
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.encodeFailed
        }
        return data as Data
    }
}
