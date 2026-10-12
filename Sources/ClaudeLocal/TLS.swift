import CryptoKit
import Foundation
import Network
import Security

/// Self-signed certificate for HTTPS sharing. Made with macOS's own /usr/bin/openssl and kept in
/// ~/Library/Application Support/ClaudeLocal/tls (owner-only). Other computers trust it by importing
/// the certificate once (the Sharing tab gives copy-ready Windows and Mac steps).
enum TLSCert {
    static let dir = AppConfig.directory.appendingPathComponent("tls", isDirectory: true)
    static let certURL = dir.appendingPathComponent("claude-local.pem")
    static let keyURL = dir.appendingPathComponent("claude-local.key")
    static let p12URL = dir.appendingPathComponent("claude-local.p12")
    static let namesURL = dir.appendingPathComponent("names.txt")

    /// Every name and address the certificate should cover right now.
    static func currentNames() -> [String] {
        var names = ["DNS:\(LAN.localHostName())", "DNS:localhost", "IP:127.0.0.1"]
        names += LAN.lanAddresses().map { "IP:\($0.ip)" }
        return names
    }

    /// Makes (or remakes, when this Mac's addresses changed) the certificate, then returns it as a
    /// TLS identity. Remaking means other computers must import the new certificate.
    static func identity(regenerate: Bool = false) throws -> sec_identity_t {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = currentNames().joined(separator: ",")
        let stored = (try? String(contentsOf: namesURL, encoding: .utf8)) ?? ""
        let covered = Set(stored.split(separator: ","))
        let missing = !Set(names.split(separator: ",")).isSubset(of: covered)
        if regenerate || !fm.fileExists(atPath: p12URL.path) || missing {
            try generate(names: names)
        }
        return try load()
    }

    private static func generate(names: String) throws {
        let pass = passphrase()
        try run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "825",
                 "-keyout", keyURL.path, "-out", certURL.path,
                 "-subj", "/CN=LLM Switcher (\(LAN.localHostName()))/O=LLM Switcher",
                 "-addext", "subjectAltName=\(names)",
                 "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign",
                 "-addext", "extendedKeyUsage=serverAuth"])
        try run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", keyURL.path, "-in", certURL.path,
                 "-out", p12URL.path, "-passout", "pass:\(pass)", "-name", "LLM Switcher"])
        for u in [keyURL, certURL, p12URL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        }
        try names.write(to: namesURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namesURL.path)
        Log.write("made a new HTTPS certificate for \(names)")
    }

    private static func load() throws -> sec_identity_t {
        let data = try Data(contentsOf: p12URL)
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase()]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let ident = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "ClaudeLocal.TLS", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Couldn't load the HTTPS certificate (\(status))"])
        }
        // swiftlint:disable:next force_cast
        guard let identity = sec_identity_create(ident as! SecIdentity) else {
            throw NSError(domain: "ClaudeLocal.TLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Couldn't use the HTTPS certificate"])
        }
        return identity
    }

    /// PEM text of the certificate (public; safe to share).
    static func pem() -> String { (try? String(contentsOf: certURL, encoding: .utf8)) ?? "" }

    /// SHA-256 fingerprint of the certificate, for checking it on the other computer.
    static func fingerprint() -> String {
        let body = pem().components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { return "" }
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// A random passphrase for the .p12, kept in the login keychain.
    private static func passphrase() -> String {
        let service = "com.depaloconsulting.claudelocal.tls"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "p12", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
           let s = String(data: d, encoding: .utf8) { return s }
        let fresh = AppConfig.newShareKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "p12", kSecValueData as String: Data(fresh.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "ClaudeLocal.TLS", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "openssl failed: \(msg.prefix(300))"])
        }
    }
}
