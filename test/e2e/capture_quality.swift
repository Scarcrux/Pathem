import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureVerdict {
    let valid: Bool
    let reason: String
    let detail: String
}

func assess(_ data: Data, expected: (Int, Int)? = nil) -> CaptureVerdict {
    func reject(_ reason: String, _ detail: String = "") -> CaptureVerdict {
        .init(valid: false, reason: reason, detail: detail)
    }
    guard data.count <= 64 * 1024 * 1024 else { return reject("input-too-large") }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetType(source) as String? == UTType.png.identifier
    else { return reject("decode-failed") }
    // A decoder can tolerate a missing terminal chunk. Evidence must be complete.
    let end: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
    guard data.suffix(end.count) == Data(end), CGImageSourceGetStatus(source) == .statusComplete,
        CGImageSourceGetCount(source) == 1
    else { return reject("incomplete-png") }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int
    else { return reject("missing-dimensions") }
    if let expected, (width, height) != expected {
        return reject(
            "size-mismatch", "actual=\(width)x\(height) expected=\(expected.0)x\(expected.1)")
    }
    guard width >= 64, height >= 64, width <= 8192, height <= 8192 else {
        return reject("invalid-dimensions", "\(width)x\(height)")
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 128,
        kCGImageSourceShouldCache: false,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return reject("decode-failed")
    }
    let sample = 128
    var pixels = [UInt8](repeating: 0, count: sample * sample * 4)
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard
            let context = CGContext(
                data: bytes.baseAddress, width: sample, height: sample,
                bitsPerComponent: 8, bytesPerRow: sample * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: sample, height: sample))
        return true
    }
    guard drawn else { return reject("rasterization-failed") }
    var opaque = 0
    var colors = Set<Int>()
    var minima = [Int](repeating: 255, count: 16)
    var maxima = [Int](repeating: 0, count: 16)
    for index in 0..<(sample * sample) {
        let offset = index * 4
        guard pixels[offset + 3] >= 250 else { continue }
        opaque += 1
        let r = Int(pixels[offset])
        let g = Int(pixels[offset + 1])
        let b = Int(pixels[offset + 2])
        colors.insert((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4))
        let luminance = (r + g + b) / 3
        let tile = (index / sample / 32) * 4 + (index % sample / 32)
        minima[tile] = min(minima[tile], luminance)
        maxima[tile] = max(maxima[tile], luminance)
    }
    let fraction = Double(opaque) / Double(sample * sample)
    let range = max(0, (maxima.max() ?? 0) - (minima.min() ?? 255))
    let detailedTiles = zip(minima, maxima).filter { $1 - $0 >= 24 }.count
    let detail =
        "size=\(width)x\(height) opaque=\(String(format: "%.3f", fraction)) range=\(range) colors=\(colors.count) tiles=\(detailedTiles)/16"
    guard fraction >= 0.95 else { return reject("mostly-transparent", detail) }
    guard range >= 40 else { return reject("flat-capture", detail) }
    guard colors.count >= 8, detailedTiles >= 4 else {
        return reject("insufficient-detail", detail)
    }
    return .init(valid: true, reason: "usable-pixels-not-visual-approval", detail: detail)
}

func png(width: Int = 128, height: Int = 128, fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8))
    -> Data
{
    var pixels = [UInt8]()
    for y in 0..<height {
        for x in 0..<width {
            let color = fill(x, y)
            pixels += [color.0, color.1, color.2, color.3]
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = CFDataCreateMutable(nil, 0)!
    let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

if CommandLine.arguments.contains("--self-test") {
    let gradient: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in
        (UInt8(x * 2), UInt8(y * 2), UInt8((x ^ y) * 2), 255)
    }
    let good = png(fill: gradient)
    let controls: [(String, Data, (Int, Int)?, Bool)] = [
        ("good", good, (128, 128), true),
        ("black", png { _, _ in (0, 0, 0, 255) }, nil, false),
        ("white", png { _, _ in (255, 255, 255, 255) }, nil, false),
        ("transparent", png { _, _ in (0, 0, 0, 0) }, nil, false),
        ("corrupt", Data([1, 2, 3]), nil, false),
        ("truncated", Data(good.dropLast(12)), nil, false),
        ("clipped", png(width: 64, fill: gradient), (128, 128), false),
    ]
    var passed = 0
    for (name, data, expected, shouldPass) in controls {
        let result = assess(data, expected: expected)
        let ok = result.valid == shouldPass
        if ok { passed += 1 }
        print(
            "CAPTURECONTROL: \(ok ? "PASS" : "FAIL") \(name) actual=\(result.reason) \(result.detail)"
        )
    }
    print("RESULT: \(passed == controls.count ? "PASS" : "FAIL") (\(passed)/\(controls.count))")
    exit(passed == controls.count ? 0 : 1)
}

var paths = Array(CommandLine.arguments.dropFirst())
var expected: (Int, Int)?
if paths.first == "--expected-size", paths.count >= 3 {
    let parts = paths[1].split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else {
        print("ERROR: expected size must be WIDTHxHEIGHT")
        exit(64)
    }
    expected = (parts[0], parts[1])
    paths.removeFirst(2)
}
guard !paths.isEmpty else {
    print("ERROR: PNG path required")
    exit(64)
}
var valid = true
for path in paths {
    let url = URL(fileURLWithPath: path)
    let result: CaptureVerdict
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 64 * 1024 * 1024,
        let data = try? Data(contentsOf: url, options: .mappedIfSafe)
    {
        result = assess(data, expected: expected)
    } else {
        result = .init(valid: false, reason: "unreadable-or-too-large", detail: "")
    }
    valid = valid && result.valid
    print(
        "CAPTURE: \(result.valid ? "PASS" : "REJECT") \(url.lastPathComponent) [\(result.reason)] \(result.detail)"
    )
}
print("RESULT: \(valid ? "PASS" : "FAIL")")
exit(valid ? 0 : 1)
