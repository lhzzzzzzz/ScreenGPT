import AppKit
import Foundation
import Security
import LocalAuthentication
import ScreenGPTCore

struct AccountRecord: Codable, Identifiable, Sendable {
    var id: String { clientID + ":" + subject }
    let clientID: String
    let subject: String
    let email: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]
    var connected: Bool { accessToken != nil && scopes.contains("chatgpt.tokens.use.direct") }
    var label: String { (email ?? L("ChatGPT 账号", "ChatGPT account")) + " · " + String(clientID.suffix(6)) }
}
private enum CredentialVault {
    static let service = "io.github.screengpt.app.oauth"
    static func read(allowInteraction: Bool = false) throws -> [AccountRecord] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "profiles", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context]
        // The file-based macOS login keychain also needs this query flag for ACL
        // prompts; LAContext alone does not suppress those prompts on macOS 15.
        if !allowInteraction { query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw AppFailure(L("无法读取钥匙串中的账号。请允许 ScreenGPT 访问自己的登录凭据。", "Could not read accounts from Keychain. Allow ScreenGPT to access its login credentials.")) }
        return try JSONDecoder().decode([AccountRecord].self, from: data)
    }
    static func write(_ records: [AccountRecord]) throws {
        let data = try JSONEncoder().encode(records)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "profiles"]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure(L("保存登录信息失败。请检查钥匙串权限后重试。", "Could not save login information. Check Keychain permissions and try again.")) }
    }
}
@MainActor final class ChatGPTAccount: ObservableObject {
    @Published private(set) var profiles: [AccountRecord] = []
    @Published private(set) var models: [ModelChoice] = []
    @Published private(set) var busy = false
    @Published private(set) var loadingModels = false
    @Published private(set) var needsCredentialAccess = false
    @Published private(set) var restoringCredentials = false
    @Published var status: String?
    @Published var activeID: String { didSet { UserDefaults.standard.set(activeID, forKey: "activeAccount") } }
    var active: AccountRecord? { profiles.first { $0.id == activeID } }
    private var server: LoopbackServer?
    private var loginTask: Task<Void, Never>?
    private var loginAttempt: UUID?
    private var modelLoadID = UUID()
    private var refreshTask: Task<AccountRecord, Error>?
    private var generation = UUID()
    private let session: URLSession
    init() {
        activeID = UserDefaults.standard.string(forKey: "activeAccount") ?? ""
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        Task { await loadSavedAccounts(allowInteraction: false) }
    }
    func restoreSavedAccounts() async {
        await loadSavedAccounts(allowInteraction: true)
    }
    private func loadSavedAccounts(allowInteraction: Bool) async {
        guard !busy else { return }
        busy = true; restoringCredentials = true
        status = allowInteraction ? L("请在 macOS 的钥匙串提示中完成确认。", "Confirm access in the macOS Keychain prompt.") : L("正在读取已保存的账号…", "Loading saved accounts…")
        defer { busy = false; restoringCredentials = false }
        do {
            // A system credential prompt must not block the application event loop.
            let records = try await Task.detached { try CredentialVault.read(allowInteraction: allowInteraction) }.value
            profiles = records; needsCredentialAccess = false; status = nil
            if active == nil { activeID = records.first?.id ?? "" }
            await loadModels()
        } catch {
            needsCredentialAccess = true
            status = L("需要在 macOS 钥匙串提示中确认访问，才能恢复已保存的 ChatGPT 账号。", "Confirm access in the macOS Keychain prompt to restore saved ChatGPT accounts.")
        }
    }
    func select(_ id: String) {
        cancelLogin(); generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        activeID = id; models = []; status = nil; modelLoadID = UUID(); loadingModels = false
        Task { await loadModels() }
    }
    func cancelLogin() {
        guard loginAttempt != nil else { return }
        loginAttempt = nil; loginTask?.cancel(); loginTask = nil
        server?.cancel(); server = nil
        if busy { status = L("已取消登录。", "Sign-in canceled.") }; busy = false
    }
    func signIn(existingID: String? = nil) async {
        guard !busy, !needsCredentialAccess else { return }; busy = true; status = nil
        let attempt = UUID(); loginAttempt = attempt
        let task = Task { await performSignIn(existingID: existingID, attempt: attempt) }
        loginTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if loginAttempt == attempt { loginTask = nil; loginAttempt = nil; busy = false; server = nil }
    }
    private func performSignIn(existingID: String?, attempt: UUID) async {
        let original = profiles.first { $0.id == existingID }
        do {
            let state = try IdentityValidation.random(), nonce = try IdentityValidation.random(), verifier = try IdentityValidation.random()
            let server = LoopbackServer(state: state); self.server = server
            defer { server.cancel() }
            let redirect = try await server.start()
            let d = UserDefaults.standard
            let host = d.string(forKey: "oauthHost") ?? "urn:uuid:" + UUID().uuidString.lowercased()
            d.set(host, forKey: "oauthHost")
            var params = ["client_id": original?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": host,
                          "response_type": "code", "redirect_uri": redirect, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                          "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                          "code_challenge_method": "S256", "code_challenge": IdentityValidation.challenge(verifier)]
            if let original {
                params["id_token_hint"] = original.idToken; params["login_hint"] = original.email
            } else { params["agent_name_hint"] = "ScreenGPT" }
            var authorize = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
            authorize.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = authorize.url, NSWorkspace.shared.open(url) else { throw AppFailure(L("无法打开默认浏览器。", "Could not open the default browser.")) }
            let callback = try await server.wait()
            try Task.checkCancellation()
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for name in ["state", "code", "error", "client_id"] where items.filter({ $0.name == name }).count > 1 { throw AppFailure(L("登录返回参数重复，请重试。", "The sign-in response contains duplicate parameters. Try again.")) }
            func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
            guard value("state") == state else { throw AppFailure(L("登录验证失败，请重试。", "Sign-in verification failed. Try again.")) }
            if value("error") != nil { throw AppFailure(L("登录未完成或套餐使用未获授权，请重试。", "Sign-in was not completed or plan usage was not authorized. Try again.")) }
            let clientID = value("client_id") ?? original?.clientID
            guard let clientID, !clientID.isEmpty, clientID != "dynamic_agent_client", let code = value("code"), !code.isEmpty else { throw AppFailure(L("账号注册未完成，请重试。", "Account registration was not completed. Try again.")) }
            guard original == nil || original?.clientID == clientID else { throw AppFailure(L("返回的账号与所选连接不符。", "The returned account does not match the selected connection.")) }
            let token = try await tokenRequest(["grant_type": "authorization_code", "client_id": clientID, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "resource": "https://api.openai.com/v1"])
            guard let idToken = token["id_token"] as? String else { throw AppFailure(L("登录缺少身份凭据。", "The sign-in response is missing an identity credential.")) }
            let discovery = try await discovery()
            guard let jwksURL = discovery["jwks_uri"] as? String, let jwks = URL(string: jwksURL), jwks.scheme == "https", jwks.host == "auth.openai.com" else { throw AppFailure(L("身份验证服务地址无效。", "The identity verification service URL is invalid.")) }
            let (keys, response) = try await session.data(from: jwks)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure(L("无法获取身份验证密钥，请重试。", "Could not retrieve identity verification keys. Try again.")) }
            let identity = try IdentityValidation.validate(token: idToken, jwks: keys, clientID: clientID, nonce: nonce)
            guard original == nil || identity.subject == original?.subject else { throw AppFailure(L("账号身份不一致，请添加为新账号。", "The account identity does not match. Add it as a new account.")) }
            try Task.checkCancellation()
            guard loginAttempt == attempt else { throw CancellationError() }
            var record = AccountRecord(clientID: clientID, subject: identity.subject, email: identity.email, expiresAt: .distantPast, scopes: [])
            try apply(token, to: &record)
            record.idToken = idToken
            try save(record)
            generation = UUID(); refreshTask?.cancel(); refreshTask = nil
            activeID = record.id; models = []; modelLoadID = UUID(); loadingModels = false
            if !record.connected { status = L("账号已登录，但未授权使用 ChatGPT 套餐。请重新登录并允许套餐使用。", "The account is signed in, but ChatGPT plan usage is not authorized. Sign in again and allow plan usage.") }
            else { await loadModels() }
            NSApp.activate(ignoringOtherApps: true)
        } catch is CancellationError { if loginAttempt == attempt { status = L("已取消登录。", "Sign-in canceled.") } }
        catch { if loginAttempt == attempt { status = error.localizedDescription } }
    }
    private func save(_ record: AccountRecord) throws {
        var all = profiles
        if let index = all.firstIndex(where: { $0.id == record.id }) { all[index] = record } else { all.append(record) }
        try CredentialVault.write(all); profiles = all
    }
    private func apply(_ token: [String: Any], to record: inout AccountRecord) throws {
        guard let access = token["access_token"] as? String, !access.isEmpty,
              (token["token_type"] as? String)?.lowercased() == "bearer", let expiry = token["expires_in"] as? Double, expiry > 0 else { throw AppFailure(L("登录凭据不完整，请重试。", "The sign-in credentials are incomplete. Try again.")) }
        record.accessToken = access; record.expiresAt = Date().addingTimeInterval(expiry)
        if let refresh = token["refresh_token"] as? String { record.refreshToken = refresh }
        // Retain the previously verified ID token on refresh. It is only a login hint.
        if let scope = token["scope"] as? String { record.scopes = scope.split(separator: " ").map(String.init) }
    }
    private func tokenRequest(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(parameters)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure(L("ChatGPT 登录已失效或被拒绝，请重新登录。", "ChatGPT sign-in expired or was rejected. Sign in again.")) }
        return json
    }
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let record = active, record.connected else { throw AppFailure(L("请先在设置里登录 ChatGPT，并允许使用套餐。", "Sign in to ChatGPT in Settings and allow plan usage first.")) }
        if !forceRefresh && record.expiresAt > Date().addingTimeInterval(90), let token = record.accessToken { return token }
        guard let refresh = record.refreshToken else { throw AppFailure(L("登录已过期，请重新登录 ChatGPT。", "Sign-in expired. Sign in to ChatGPT again.")) }
        if let refreshTask { return try await refreshTask.value.accessToken ?? "" }
        let version = generation
        let task = Task { () throws -> AccountRecord in
            let token = try await tokenRequest(["grant_type": "refresh_token", "client_id": record.clientID, "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
            try Task.checkCancellation()
            guard generation == version && activeID == record.id else { throw CancellationError() }
            var updated = record; try apply(token, to: &updated); try save(updated)
            guard updated.connected else { throw AppFailure(L("此账号已不再允许使用 ChatGPT 套餐，请重新授权。", "This account is no longer authorized to use the ChatGPT plan. Authorize it again.")) }
            return updated
        }
        refreshTask = task
        defer { if generation == version { refreshTask = nil } }
        return try await task.value.accessToken ?? ""
    }
    func loadModels() async {
        guard active?.connected == true else { return }
        let accountID = activeID, requestID = UUID(); modelLoadID = requestID; loadingModels = true
        defer { if modelLoadID == requestID { loadingModels = false } }
        do {
            let token = try await accessToken()
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard accountID == activeID && modelLoadID == requestID else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure(L("无法读取可用模型。请检查套餐授权后刷新。", "Could not load available models. Check plan authorization and refresh.")) }
            struct Catalog: Decodable { let models: [ModelChoice] }
            models = try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
            if models.isEmpty { throw AppFailure(L("此账号暂时没有可用模型。请检查 ChatGPT 套餐及工作区权限。", "No models are currently available for this account. Check the ChatGPT plan and workspace permissions.")) }
            status = nil
        } catch { if accountID == activeID && modelLoadID == requestID { status = error.localizedDescription } }
    }
    func signOut() async {
        guard var record = active, !busy else { return }
        busy = true; defer { busy = false }
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; models = []; modelLoadID = UUID(); loadingModels = false
        var revoked = record.refreshToken == nil
        if let token = record.refreshToken {
            do {
                let metadata = try await discovery()
                guard let endpoint = metadata["revocation_endpoint"] as? String, let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" else { throw AppFailure(L("注销服务不可用。", "The sign-out service is unavailable.")) }
                var request = URLRequest(url: url); request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = form(["token": token, "token_type_hint": "refresh_token", "client_id": record.clientID])
                let (_, response) = try await session.data(for: request)
                revoked = (response as? HTTPURLResponse)?.statusCode == 200
            } catch { revoked = false }
        }
        record.accessToken = nil; record.refreshToken = nil; record.idToken = nil; record.expiresAt = .distantPast
        do { try save(record); status = revoked ? L("已退出登录。", "Signed out.") : L("本机凭据已清除。未能确认远程撤销，可到 ChatGPT 设置中移除此连接。", "Local credentials were cleared. Remote revocation could not be confirmed. You can remove this connection in ChatGPT Settings.") }
        catch { status = error.localizedDescription }
    }
    private func discovery() async throws -> [String: Any] {
        let (data, response) = try await session.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["issuer"] as? String == "https://auth.openai.com" else { throw AppFailure(L("无法验证 ChatGPT 身份服务。", "Could not verify the ChatGPT identity service.")) }
        return object
    }
    private func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }
}
