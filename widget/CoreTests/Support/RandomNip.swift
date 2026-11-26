import Foundation

private let weights = [6, 5, 7, 2, 3, 4, 5, 6, 7]

/// Random NIP matching the KSeF pattern ^[1-9]((\d[1-9])|([1-9]\d))\d{7}$ with a valid checksum.
func randomNip() -> String {
    while true {
        var digits = (0..<9).map { _ in Int.random(in: 0...9) }
        digits[0] = Int.random(in: 1...9)
        if digits[1] == 0 && digits[2] == 0 { continue }
        let sum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
        let check = sum % 11
        if check == 10 { continue }
        return (digits + [check]).map(String.init).joined()
    }
}
