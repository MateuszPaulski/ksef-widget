import Foundation

do {
    let data = try Data(contentsOf: SnapshotFile.url)
    print("OK \(data.count) bytes")
    exit(0)
} catch {
    let nsError = error as NSError
    var message = "FAILED \(error)"
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        message += " underlying=\(underlying.domain) \(underlying.code)"
    }
    print(message)
    exit(1)
}
