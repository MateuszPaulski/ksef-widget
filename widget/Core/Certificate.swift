import Foundation
import Security

private let attributeLabels: [String: String] = [
    "2.5.4.3": "CN",
    "2.5.4.4": "SN",
    "2.5.4.5": "serialNumber",
    "2.5.4.6": "C",
    "2.5.4.7": "L",
    "2.5.4.8": "ST",
    "2.5.4.9": "street",
    "2.5.4.10": "O",
    "2.5.4.11": "OU",
    "2.5.4.12": "title",
    "2.5.4.42": "GN",
    "2.5.4.97": "organizationIdentifier",
    "1.2.840.113549.1.9.1": "emailAddress",
]

private func unreadable(_ reason: String) -> KsefError {
    KsefError("Nie można odczytać certyfikatu: \(reason)")
}

// @unchecked: SecKey is an immutable CF object that Security documents as thread-safe.
struct Certificate: @unchecked Sendable {
    let pem: String
    let der: Data
    let issuerName: String
    let serialNumber: String
    let publicKey: SecKey

    init(pem: String) throws {
        guard let body = pemBody(pem, label: "CERTIFICATE") else {
            throw unreadable("oczekiwano -----BEGIN CERTIFICATE-----")
        }
        let serial: DERElement
        let issuerText: String
        do {
            var reader = DERReader(body)
            let certificate = try reader.next()
            guard certificate.tag == 0x30, let tbs = try certificate.children().first, tbs.tag == 0x30 else { throw DERError() }
            var fields = try tbs.children()[...]
            if fields.first?.tag == 0xA0 { fields.removeFirst() }
            guard let serialField = fields.popFirst(), serialField.tag == 0x02,
                  fields.popFirst()?.tag == 0x30,
                  let issuerField = fields.popFirst(), issuerField.tag == 0x30
            else { throw DERError() }
            serial = serialField
            issuerText = try Self.format(issuer: issuerField)
        } catch is DERError {
            throw unreadable("uszkodzona struktura")
        }
        guard let secCertificate = SecCertificateCreateWithData(nil, Data(body) as CFData),
              let key = SecCertificateCopyKey(secCertificate)
        else { throw unreadable("nieprawidłowy certyfikat") }

        self.pem = pem
        self.der = Data(body)
        self.issuerName = issuerText
        self.serialNumber = Self.decimal(serial.body)
        self.publicKey = key
    }

    // Matches Node's X509Certificate.issuer: RDNs reversed, multi-valued RDNs joined with " + ", RFC 2253 escaping.
    private static func format(issuer name: DERElement) throws -> String {
        try name.children().reversed().map { rdn in
            try rdn.children().map { attribute in
                let parts = try attribute.children()
                guard attribute.tag == 0x30, parts.count == 2, parts[0].tag == 0x06 else { throw DERError() }
                let oid = oidString(parts[0].body)
                return "\(attributeLabels[oid] ?? oid)=\(escape(text(parts[1])))"
            }.joined(separator: " + ")
        }.joined(separator: ", ")
    }

    private static func text(_ value: DERElement) -> String {
        switch value.tag {
        case 0x1E: String(bytes: value.body, encoding: .utf16BigEndian) ?? ""
        case 0x14: String(bytes: value.body, encoding: .isoLatin1) ?? ""
        default: String(decoding: value.body, as: UTF8.self)
        }
    }

    private static func escape(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case ",", "+", "\"", "\\", "<", ">", ";":
                result += "\\\(scalar)"
            case "#" where index == 0, " " where index == 0, " " where index == scalars.count - 1:
                result += "\\\(scalar)"
            case "\u{0}"..."\u{1F}", "\u{7F}":
                result += "\\" + String(format: "%02X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // Unsigned big-endian bytes to decimal by repeated division, so serials longer than 64 bits work.
    private static func decimal(_ bytes: [UInt8]) -> String {
        var number = bytes
        var digits: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in number.indices {
                let value = remainder * 256 + Int(number[index])
                number[index] = UInt8(value / 10)
                remainder = value % 10
            }
            digits.append(Character(String(remainder)))
        }
        return digits.isEmpty ? "0" : String(digits.reversed())
    }
}
