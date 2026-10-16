import CryptoKit
import Foundation
import Network
import Security

public enum SorcererError: LocalizedError {
    case notSignedIn
    case missingGoogleClient
    case oauth(String)
    case http(Int, String)
    case remindersAccessDenied
    case listNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Google. Sign in from Settings (or run `sorcerer auth`)."
        case .missingGoogleClient: return "Google OAuth client ID/secret not set. See README → Google setup."
        case .oauth(let m): return "Google sign-in failed: \(m)"
        case .http(let code, let body): return "Google API error \(code): \(body.prefix(300))"
        case .remindersAccessDenied: return "Reminders access was denied. Allow it in System Settings → Privacy & Security → Reminders."
        case .listNotFound(let name): return "List not found: \(name)"
        }
    }
}

/// Stores the Google refresh token in the login keychain.
public enum Keychain {
    static let service = "TaskSorcerer.google"
    static let account = "refresh-token"

    public static func readRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func saveRefreshToken(_ token: String) {
        deleteRefreshToken()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    public static func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Google OAuth for installed apps: browser sign-in with PKCE and a one-shot
/// loopback listener on 127.0.0.1 to receive the authorization code.
public actor GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/tasks"
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private let clientID: String
    private let clientSecret: String
    private var accessToken: String?
    private var expiry: Date = .distantPast

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public nonisolated var isSignedIn: Bool { Keychain.readRefreshToken() != nil }

    public func signOut() {
        Keychain.deleteRefreshToken()
        accessToken = nil
    }

    /// Opens the browser for consent and waits for Google to redirect back.
    public func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw SorcererError.missingGoogleClient }
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)

        let receiver = LoopbackReceiver()
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        openURL(comps.url!)

        let params = try await receiver.waitForRedirect()
        guard params["state"] == state else { throw SorcererError.oauth("state mismatch") }
        if let error = params["error"] { throw SorcererError.oauth(error) }
        guard let code = params["code"] else { throw SorcererError.oauth("no authorization code returned") }

        let json = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else {
            throw SorcererError.oauth("Google did not return a refresh token")
        }
        Keychain.saveRefreshToken(refresh)
        store(json)
    }

    /// A valid access token, refreshed when it's about to expire.
    public func token() async throws -> String {
        if let accessToken, expiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = Keychain.readRefreshToken() else { throw SorcererError.notSignedIn }
        let json = try await tokenRequest([
            "refresh_token": refresh,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
        ])
        store(json)
        guard let accessToken else { throw SorcererError.oauth("no access token returned") }
        return accessToken
    }

    private func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3000)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((body.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "token request failed"
            if json["error"] as? String == "invalid_grant" { Keychain.deleteRefreshToken() }
            throw SorcererError.oauth(message)
        }
        return json
    }

    static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens on 127.0.0.1 for the single OAuth redirect request.
final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TaskSorcerer.oauth")
    private var listener: NWListener?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
    }

    /// Waits (up to 5 minutes) for the browser redirect and returns its query parameters.
    func waitForRedirect() async throws -> [String: String] {
        guard let listener else { throw SorcererError.oauth("listener not started") }
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            let finish: @Sendable (Result<[String: String], Error>) -> Void = { result in
                if once.claim() { cont.resume(with: result) }
            }
            queue.asyncAfter(deadline: .now() + 300) { finish(.failure(SorcererError.oauth("timed out waiting for the browser"))) }
            listener.newConnectionHandler = { conn in
                conn.start(queue: self.queue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    // "GET /?code=...&state=... HTTP/1.1"
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
                    let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                    guard params["code"] != nil || params["error"] != nil else {
                        conn.cancel()   // e.g. a favicon request
                        return
                    }
                    let html = "<html><body style='font-family:-apple-system;padding:40px'>"
                        + "<h2>TaskSorcerer is connected to Google Tasks.</h2><p>You can close this tab.</p></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                        + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    finish(.success(params))
                }
            }
        }
    }
}

/// Makes sure a continuation is resumed exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
