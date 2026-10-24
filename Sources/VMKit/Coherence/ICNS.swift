import Foundation

/// Crea archivos .icns (iconos de apps de macOS) a partir de un PNG cuadrado.
/// Un .icns puede guardar el PNG tal cual, con un código de tipo según su tamaño.
enum ICNS {
    static let types: [Int: String] = [
        16: "icp4", 32: "icp5", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10",
    ]

    /// Ancho y alto leídos de la cabecera IHDR del PNG.
    static func pngSize(_ png: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](png.prefix(24))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count == 24, Array(bytes[0..<8]) == signature, Array(bytes[12..<16]) == Array("IHDR".utf8)
        else { return nil }
        func be32(_ i: Int) -> Int { bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (be32(16), be32(20))
    }

    /// nil si el PNG no es cuadrado o no tiene un tamaño estándar de icono.
    static func make(png: Data) -> Data? {
        guard let size = pngSize(png), size.width == size.height, let type = types[size.width] else { return nil }
        var data = Data("icns".utf8)
        data.append(bigEndian: UInt32(16 + png.count))
        data.append(Data(type.utf8))
        data.append(bigEndian: UInt32(8 + png.count))
        data.append(png)
        return data
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
