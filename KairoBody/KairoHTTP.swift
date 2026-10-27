import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which credential authenticates one call. The sensory bearer never submits
/// jobs and lives only on the memory service; every Agent Platform call is
/// authenticated by the Agent token, with the owner proof riding as the
/// `X-Kairo-Device` correlation header that the server treats as pairing proof.
enum Credential {
    case agent
    case sensory
}

/// One narrow HTTP core for the Agent Platform and the memory body service.
/// Bodies are encoded with sorted keys so a retried request is byte-identical,
/// responses are size-bounded, and conditional reads answer 304 from a cache
/// validator the caller owns.
final class KairoHTTP {
    private let session: URLSession
    private let responseLimit: Int
    private let credentials: () -> (agent: String, owner: String)

    init(session: URLSession = TransportConfig.sharedSession, responseLimit: Int = 4 * 1024 * 1024,
         credentials: @escaping () -> (agent: String, owner: String) = { (AppConfig.agentToken, AppConfig.ownerProof) }) {
        self.session = session
        self.responseLimit = responseLimit
        self.credentials = credentials
    }

    /// GET/POST an Agent Platform path (`api/...`). Throws HTTPStatusError or
    /// MalformedResponse; callers classify with RequestFailure.
    func agent(_ path: String, method: String = "GET", body: [String: Any]? = nil,
               timeout: TimeInterval = 20) async throws -> Any {
        try await request(path, method: method, body: body, credential: .agent, timeout: timeout)
    }

    func agentObject(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                     timeout: TimeInterval = 20) async throws -> [String: Any] {
        let value = try await agent(path, method: method, body: body, timeout: timeout)
        guard let object = value as? [String: Any] else { throw MalformedResponse() }
        return object
    }

    func agentArray(_ path: String) async throws -> [[String: Any]] {
        let value = try await agent(path)
        guard let rows = value as? [[String: Any]] else { throw MalformedResponse() }
        return rows
    }

    /// A conditional Agent-API read carrying the owner proof as X-Kairo-Device
    /// (the only way the live server accepts a pairing proof). `validator` is
    /// an If-None-Match value from a previous response; a matching read
    /// returns .notModified with no body.
    func agentConditional(_ path: String, validator: String?) async throws
        -> (response: ObserverResponse, object: [String: Any]?, validator: String?) {
        guard let base = URL(string: AppConfig.agentOrigin),
              let url = Self.endpoint(base, path: path) else { throw HTTPStatusError(status: 0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let token = credentials().agent
        guard !token.isEmpty else { throw HTTPStatusError(status: 401) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let proof = credentials().owner
        if !proof.isEmpty { request.setValue(proof, forHTTPHeaderField: "X-Kairo-Device") }
        if let validator, !validator.isEmpty { request.setValue(validator, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MalformedResponse() }
        let classified = ObserverResponse.classify(status: http.statusCode, sentValidator: validator != nil)
        switch classified {
        case .notModified:
            return (.notModified, nil, validator)
        case .fresh:
            guard data.count <= responseLimit,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MalformedResponse()
            }
            return (.fresh, object, http.value(forHTTPHeaderField: "ETag"))
        default:
            return (classified, nil, nil)
        }
    }

    /// POST to the memory body service with the sensory bearer (pairing redeem).
    func sensory(url: URL, body: [String: Any]) async throws -> [String: Any] {
        let base = url.baseURL ?? url
        guard let scheme = base.scheme?.lowercased(), ["http", "https"].contains(scheme),
              base.host == "connect.kairo.icu", base.user == nil, base.password == nil else {
            throw HTTPStatusError(status: 0)
        }
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        let token = AppConfig.sensoryToken
        guard !token.isEmpty else { throw HTTPStatusError(status: 401) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MalformedResponse() }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode, code: Self.errorCode(data))
        }
        guard data.count <= responseLimit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MalformedResponse()
        }
        return object
    }

    @discardableResult
    func agentRaw(_ path: String, method: String, body: [String: Any]?,
                  accept: String? = nil) async throws -> Data {
        guard let base = URL(string: AppConfig.agentOrigin),
              let url = Self.endpoint(base, path: path) else { throw HTTPStatusError(status: 0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let token = credentials().agent
        guard !token.isEmpty else { throw HTTPStatusError(status: 401) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 90
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MalformedResponse() }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode, code: Self.errorCode(data))
        }
        guard data.count <= responseLimit else { throw MalformedResponse() }
        return data
    }

    private func request(_ path: String, method: String, body: [String: Any]?,
                         credential: Credential, timeout: TimeInterval = 20) async throws -> Any {
        guard let base = URL(string: AppConfig.agentOrigin),
              let url = Self.endpoint(base, path: path) else { throw HTTPStatusError(status: 0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        switch credential {
        case .agent:
            let token = credentials().agent
            guard !token.isEmpty else { throw HTTPStatusError(status: 401) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Owner-scoped routes read this header as the pairing proof; the
            // Agent bearer alone gets a different (public) scope.
            let owner = credentials().owner
            if !owner.isEmpty { request.setValue(owner, forHTTPHeaderField: "X-Kairo-Device") }
        case .sensory:
            let token = AppConfig.sensoryToken
            guard !token.isEmpty else { throw HTTPStatusError(status: 401) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MalformedResponse() }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode, code: Self.errorCode(data))
        }
        guard data.count <= responseLimit else { throw MalformedResponse() }
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw MalformedResponse() }
        return value
    }

    /// Paths are built segment by segment; the query tail is re-encoded, never
    /// concatenated raw into the URL.
    static func endpoint(_ base: URL, path: String) -> URL? {
        guard base.scheme == "https", base.host == "connect.kairo.icu",
              base.user == nil, base.password == nil,
              base.path.isEmpty || base.path == "/" else { return nil }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var url = base
        var components = URLComponents()
        components.path = "/" + parts[0].split(separator: "/").map { piece in
            piece.replacingOccurrences(of: " ", with: "-")
        }.joined(separator: "/")
        guard let appended = components.url else { return nil }
        url.appendPathComponent(appended.path)
        if parts.count == 2, var query = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Caller-supplied query text can never abort the process: existing
            // percent escapes and RFC 3986 query punctuation survive; anything
            // else (spaces, '#', quotes…) is percent-encoded.
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?@!$&'()*+,;=%")
            query.percentEncodedQuery = parts[1].addingPercentEncoding(withAllowedCharacters: allowed) ?? parts[1]
            if let queryURL = query.url { url = queryURL }
        }
        return url
    }

    static func errorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String else { return nil }
        return String(code.prefix(80))
    }
}

