// PNG-backed ICNS layers matching the 通用控制结界 project.
// Preserve the supplied artwork and alpha. The 832 px artwork on a 1024 px canvas
// matches the visual footprint of neighbouring macOS icons (96 px transparent margins).
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: build-icon source.png AppIcon.icns\n", stderr)
    exit(64)
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Logo must be a readable image\n", stderr)
    exit(65)
}
func render(_ image: CGImage, side: Int, artworkFraction: Double = 1) -> CGImage {
    guard let context = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot allocate image context")
    }
    let scale = Double(side) * artworkFraction / Double(max(image.width, image.height))
    let width = Double(image.width)*scale, height = Double(image.height)*scale
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (Double(side)-width)/2, y: (Double(side)-height)/2, width: width, height: height))
    guard let rendered = context.makeImage() else { fatalError("Cannot render icon") }
    return rendered
}
func png(_ image: CGImage) -> Data {
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot encode PNG") }
    return bytes as Data
}
func appendLength(_ length: UInt32, to bytes: inout Data) {
    var bigEndian = length.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
}
let master = render(image, side: 1024, artworkFraction: 832.0/1024.0)
try png(master).write(to: outputURL.deletingPathExtension().appendingPathExtension("png"), options: .atomic)
let layers: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
    ("ic08", 256), ("ic09", 512), ("ic10", 1024)
]
var chunks = Data()
for (type, side) in layers {
    let data = png(side == 1024 ? master : render(master, side: side))
    chunks.append(contentsOf: type.utf8)
    appendLength(UInt32(data.count + 8), to: &chunks)
    chunks.append(data)
}
var container = Data("icns".utf8)
appendLength(UInt32(chunks.count + 8), to: &container)
container.append(chunks)
try container.write(to: outputURL, options: .atomic)
print("ICNS layers: 16, 32, 64, 128, 256, 512, 1024; master PNG: 1024×1024; artwork: 832 px with transparent margins")
