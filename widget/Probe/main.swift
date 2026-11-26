import Foundation

switch SnapshotFile.load() {
case .success(let snapshot):
    let updatedAt = snapshot.updatedAt.formatted(.iso8601)
    print("OK status=\(snapshot.status.rawValue) invoices=\(snapshot.invoices.count) savedToday=\(snapshot.savedToday) updatedAt=\(updatedAt)")
    exit(0)
case .failure(.missing):
    print("MISSING")
    exit(2)
case .failure(.unreadable(let message)):
    print("UNREADABLE \(message)")
    exit(1)
}
