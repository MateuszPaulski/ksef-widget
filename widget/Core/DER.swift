import Foundation

struct DERError: Error {}

struct DERElement {
    let tag: UInt8
    let body: [UInt8]

    func children() throws -> [DERElement] {
        var reader = DERReader(body)
        var elements: [DERElement] = []
        while !reader.isAtEnd { elements.append(try reader.next()) }
        return elements
    }
}

struct DERReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { position >= bytes.count }

    mutating func next() throws -> DERElement {
        guard position + 2 <= bytes.count else { throw DERError() }
        let tag = bytes[position]
        guard tag & 0x1F != 0x1F else { throw DERError() }
        var length = Int(bytes[position + 1])
        position += 2
        if length >= 0x80 {
            let lengthBytes = length & 0x7F
            guard (1...4).contains(lengthBytes), position + lengthBytes <= bytes.count else { throw DERError() }
            length = bytes[position..<position + lengthBytes].reduce(0) { $0 << 8 | Int($1) }
            position += lengthBytes
        }
        guard length <= bytes.count - position else { throw DERError() }
        defer { position += length }
        return DERElement(tag: tag, body: Array(bytes[position..<position + length]))
    }
}

func oidString(_ body: [UInt8]) -> String {
    var arcs: [UInt64] = []
    var value: UInt64 = 0
    for byte in body {
        value = value << 7 | UInt64(byte & 0x7F)
        if byte & 0x80 == 0 {
            arcs.append(value)
            value = 0
        }
    }
    guard let first = arcs.first else { return "" }
    let head: [UInt64] = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80]
    return (head + arcs.dropFirst()).map(String.init).joined(separator: ".")
}

func pemBody(_ text: String, label: String) -> [UInt8]? {
    guard let begin = text.range(of: "-----BEGIN \(label)-----"),
          let end = text.range(of: "-----END \(label)-----", range: begin.upperBound..<text.endIndex),
          let data = Data(base64Encoded: String(text[begin.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters)
    else { return nil }
    return [UInt8](data)
}
