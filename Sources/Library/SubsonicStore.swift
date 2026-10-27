import Foundation
import Observation
import Security

/// Holds the configured Subsonic server and its live client, and owns the
/// connect / sign-out flow. The password lives in the Keychain, never in
/// UserDefaults; only the URL and username are plain preferences.
@MainActor
@Observable
final class SubsonicStore {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var isConfigured = false
    private(set) var state: ConnectionState = .idle
    private(set) var serverURLString = ""
    private(set) var username = ""
    private(set) var client: SubsonicClient?

    private let urlKey = "subsonic.baseURL"
    private let userKey = "subsonic.username"
    private let pwAccount = "subsonic.password"

    init() { load() }

    private func load() {
        let d = UserDefaults.standard
        serverURLString = d.string(forKey: urlKey) ?? ""
        username = d.string(forKey: userKey) ?? ""
        let password = Keychain.get(pwAccount) ?? ""
        if let url = URL(string: serverURLString), !username.isEmpty, !password.isEmpty {
            client = SubsonicClient(credentials: .init(baseURL: url, username: username, password: password))
            isConfigured = true
        }
    }

    /// Verify credentials with a ping, and only persist them once it succeeds, so a
    /// typo never gets saved as a "configured" server.
    func connect(serverURL: String, username: String, password: String) async {
        state = .connecting
        guard let url = URL(string: Self.normalize(serverURL)) else {
            state = .failed("That server address isn't valid.")
            return
        }
        let creds = SubsonicCredentials(baseURL: url, username: username, password: password)
        let probe = SubsonicClient(credentials: creds)
        do {
            try await probe.ping()
            UserDefaults.standard.set(url.absoluteString, forKey: urlKey)
            UserDefaults.standard.set(username, forKey: userKey)
            Keychain.set(password, for: pwAccount)
            self.serverURLString = url.absoluteString
            self.username = username
            self.client = probe
            self.isConfigured = true
            self.state = .connected
        } catch {
            self.state = .failed((error as? SubsonicError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        Keychain.delete(pwAccount)
        client = nil
        isConfigured = false
        state = .idle
        serverURLString = ""
        username = ""
    }

    /// Default to http:// when no scheme is typed and strip a trailing slash, so a
    /// bare host like "140.245.229.48:4533" works.
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://") { t = "http://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }
}

/// Minimal Keychain wrapper for a single-string secret (the server password).
enum Keychain {
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
