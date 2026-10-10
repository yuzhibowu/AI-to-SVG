import Foundation

// Stored ZIP records with UTF-8 names (PKWARE APPNOTE, sections 4.3 and 4.4).
// SVG files are small; writing directly avoids resource forks and external processes.
enum ZIPWriter {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB88320 }
        return crc
    }
    static func write(directory: URL, to destination: URL, includeRoot: Bool = true, progress: ((Int, Int, String) -> Void)? = nil) throws {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: includeRoot ? [.skipsHiddenFiles] : []) else {
            throw ConversionError.malformed("无法读取要打包的 SVG")
        }
        let files = iterator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        guard files.count <= 65535 else { throw ConversionError.unsupported("单个 ZIP 最多支持 65535 个 SVG，请分批导出。") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ConversionError.malformed("无法创建 ZIP 文件")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var central = Data()
        var offset: UInt64 = 0
        let parentComponents = directory.resolvingSymlinksInPath().pathComponents.count - (includeRoot ? 1 : 0)
        for (index, file) in files.enumerated() {
            let name = Data(file.resolvingSymlinksInPath().pathComponents.dropFirst(parentComponents).joined(separator: "/").utf8)
            let data = try Data(contentsOf: file)
            guard name.count <= 65535, data.count <= UInt32.max, offset + UInt64(data.count) + UInt64(name.count) + 30 < UInt32.max else {
                throw ConversionError.unsupported("ZIP 内容过大，请分批导出。")
            }
            let crc = data.reduce(UInt32.max) { (crc, byte) in crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) } ^ UInt32.max
            let size = UInt32(data.count)
            var local = Data()
            local.u32(0x04034B50); local.u16(20); local.u16(0x0800); local.u16(0)
            local.u16(0); local.u16(0x0021); local.u32(crc); local.u32(size); local.u32(size)
            local.u16(UInt16(name.count)); local.u16(0); local.append(name)
            try handle.write(contentsOf: local); try handle.write(contentsOf: data)
            central.u32(0x02014B50); central.u16(0x0314); central.u16(20); central.u16(0x0800); central.u16(0)
            central.u16(0); central.u16(0x0021); central.u32(crc); central.u32(size); central.u32(size)
            central.u16(UInt16(name.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
            central.u32(0o100644 << 16); central.u32(UInt32(offset)); central.append(name)
            offset += UInt64(local.count + data.count)
            progress?(index+1, files.count, file.lastPathComponent)
        }
        guard offset + UInt64(central.count) + 22 < UInt32.max else { throw ConversionError.unsupported("ZIP 内容过大，请分批导出。") }
        try handle.write(contentsOf: central)
        var end = Data()
        end.u32(0x06054B50); end.u16(0); end.u16(0); end.u16(UInt16(files.count)); end.u16(UInt16(files.count))
        end.u32(UInt32(central.count)); end.u32(UInt32(offset)); end.u16(0)
        try handle.write(contentsOf: end)
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16))
    }
}
