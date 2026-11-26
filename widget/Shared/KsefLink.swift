import Foundation

enum KsefLink {
    static let hosts: Set<String> = ["qr.ksef.mf.gov.pl", "qr-test.ksef.mf.gov.pl", "qr-demo.ksef.mf.gov.pl"]

    // The snapshot is a plain file in the owner's home: only https links to the KSeF view hosts are followed.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host else { return false }
        return hosts.contains(host)
    }
}
