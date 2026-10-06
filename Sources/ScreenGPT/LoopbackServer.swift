import Foundation
import Network

@MainActor final class LoopbackServer {
    private var listener: NWListener?
    private var ready: CheckedContinuation<String, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []
    private let state: String
    init(state: String) { self.state = state }
    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
            guard let self, self.connections.count < 16 else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: .main)
            self.receive(connection, data: Data())
            }
        }
        return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] value in
                MainActor.assumeIsolated {
                guard let self else { return }
                switch value {
                case .ready:
                    guard let port = listener.port else { self.cancel(AppFailure(L("无法启动登录回调。", "Could not start the sign-in callback."))); return }
                    self.ready?.resume(returning: "http://127.0.0.1:\(port.rawValue)/auth/callback"); self.ready = nil
                case .failed: self.cancel(AppFailure(L("无法启动本地登录服务。", "Could not start the local sign-in service.")))
                default: break
                }
                }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)); self?.cancel(AppFailure(L("登录已超时，请重试。", "Sign-in timed out. Try again."))) } catch {}
            }
        }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
    func wait() async throws -> URL {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { callback = $0 }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
    func cancel(_ error: Error = CancellationError()) {
        ready?.resume(throwing: error); ready = nil
        complete(.failure(error))
        connections.forEach { $0.cancel() }; connections.removeAll()
    }
    private func complete(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value; timeout?.cancel(); listener?.cancel(); listener = nil
        callback?.resume(with: value); callback = nil
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, done, error in
            MainActor.assumeIsolated {
            guard let self else { connection.cancel(); return }
            let accumulated = data + (chunk ?? Data())
            guard accumulated.count <= 16384, error == nil else { self.close(connection); return }
            guard let request = String(data: accumulated, encoding: .utf8), request.contains("\r\n\r\n") else {
                if done { self.close(connection) } else { self.receive(connection, data: accumulated) }; return
            }
            let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"),
                  let url = URL(string: "http://127.0.0.1" + parts[1]), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.path == "/auth/callback", let items = components.queryItems,
                  items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == self.state else {
                let language = AppLocalization.language
                let message = L("登录回调无效。请回到应用重试。", "The sign-in callback is invalid. Return to the app and try again.")
                self.respond(connection, status: "400 Bad Request", body: "<!doctype html><html lang=\"\(language.rawValue)\"><meta charset=utf-8><title>ScreenGPT</title><p>\(message)</p></html>"); return
            }
            let language = AppLocalization.language
            let pageTitle = L("返回 ScreenGPT", "Return to ScreenGPT")
            let pageMessage = L("授权结果已收到。请回到应用查看登录状态。", "Authorization received. Return to the app to check your sign-in status.")
            let body = "<!doctype html><html lang=\"\(language.rawValue)\"><meta charset=utf-8><title>ScreenGPT</title><style>body{font:18px system-ui;padding:12vh 8vw;color:#163d3c;background:#f3f8f7}h1{font-size:32px}</style><h1>\(pageTitle)</h1><p>\(pageMessage)</p></html>"
            self.respond(connection, status: "200 OK", body: body)
            self.connections.filter { $0 !== connection }.forEach { $0.cancel() }
            self.connections = [connection]
            self.complete(.success(url))
            }
        }
    }
    private func close(_ c: NWConnection) { c.cancel(); connections.removeAll { $0 === c } }
    private func respond(_ c: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\n\r\n"
        c.send(content: Data(header.utf8) + payload, completion: .contentProcessed { [weak self] _ in MainActor.assumeIsolated { self?.close(c) } })
    }
}
