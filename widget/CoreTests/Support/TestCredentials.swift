import Foundation

enum KeyType { case rsa, ec }

struct TestCredentialFiles {
    let certificateURL: URL
    let keyURL: URL
    let password: String
}

struct OpensslFailure: Error, CustomStringConvertible {
    let description: String
}

enum TestCredentials {
    /// Self-signed certificate + encrypted PKCS#8 key, as /usr/bin/openssl produces them.
    static func make(nip: String, keyType: KeyType, rsaBits: Int = 2048, in dir: URL) throws -> TestCredentialFiles {
        let password = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let certificateURL = dir.appendingPathComponent("\(nip).crt")
        let keyURL = dir.appendingPathComponent("\(nip).key")
        let keyArguments = keyType == .rsa
            ? ["-newkey", "rsa:\(rsaBits)"]
            : ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-pkeyopt", "ec_param_enc:named_curve"]
        try runOpenssl(
            ["req", "-x509"] + keyArguments + [
                "-keyout", keyURL.path, "-out", certificateURL.path,
                "-days", "30", "-passout", "pass:\(password)",
                "-subj", "/GN=Jan/SN=Testowy/serialNumber=TINPL-\(nip)/CN=Jan Testowy/C=PL",
            ]
        )
        return TestCredentialFiles(certificateURL: certificateURL, keyURL: keyURL, password: password)
    }

    private static func runOpenssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpensslFailure(description: String(decoding: output, as: UTF8.self))
        }
    }
}
