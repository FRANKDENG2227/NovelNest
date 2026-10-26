import Darwin
import Foundation

public struct HTTPResponse: Sendable {
    /// The final URL after redirects.
    public var url: URL
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public init(url: URL, status: Int, headers: [String: String] = [:], data: Data) {
        self.url = url
        self.status = status
        self.headers = headers
        self.data = data
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

/// Sends requests; injectable so tests don't touch the network.
public protocol HTTPFetching: Sendable {
    /// `allowedHosts` limits where redirects may lead.
    func send(_ request: SourceRequest, allowedHosts: HostPolicy) async throws -> HTTPResponse
}

/// The domains a source may be fetched from: the site of its
/// `bookSourceUrl` and that site's subdomains (e.g. `m.` and `www.`).
/// Nothing on this device or the local network is ever allowed, so a
/// source can't reach a router or other home devices (SSRF), nor pair a
/// local address with an outside one to send what it read elsewhere.
public struct HostPolicy: Sendable, Equatable {
    public var domains: Set<String>

    public init(source: LegadoSource) {
        domains = Set([source.baseURL.host].compactMap { $0 }.filter { !Self.isLocal($0) }.map(Self.registrableDomain))
    }

    public init(domains: Set<String>) {
        self.domains = domains
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !Self.isLocal(host) else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let secondLevel: Set<String> = ["com", "net", "org", "gov", "edu", "co", "ac"]

    /// Hosting domains where each subdomain belongs to someone else, so a
    /// source on one may not reach the others.
    static let sharedSuffixes: Set<String> = [
        "github.io", "gitlab.io", "gitee.io", "netlify.app", "vercel.app", "pages.dev", "workers.dev",
        "herokuapp.com", "blogspot.com", "web.app", "firebaseapp.com", "appspot.com", "azurewebsites.net",
        "cloudfront.net", "glitch.me", "fly.dev", "onrender.com", "repl.co", "deno.dev", "surge.sh",
    ]

    /// `m.example.com.cn` → `example.com.cn`; `alice.github.io` stays whole.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        if labels.allSatisfy({ Int($0) != nil }) || labels.count <= 2 { return host.lowercased() }
        var keep = labels.count >= 3 && secondLevel.contains(String(labels[labels.count - 2])) && labels.last!.count == 2 ? 3 : 2
        if sharedSuffixes.contains(labels.suffix(2).joined(separator: ".")) { keep = 3 }
        return labels.suffix(keep).joined(separator: ".")
    }

    /// This device, the local network, or a special-use address: loopback,
    /// private and link-local ranges (also written as one number or in hex,
    /// e.g. `2130706433` = 127.0.0.1), `localhost`, `.local` names.
    public static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.isEmpty || host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".lan", ".internal", ".home.arpa", ".intranet"] where host.hasSuffix(suffix) { return true }
        if host.contains(":") { return isLocalIPv6(host) }
        // Anything inet_aton reads as an address (dotted, decimal, hex, octal).
        var address = in_addr()
        guard host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }), inet_aton(host, &address) != 0 else {
            return !host.contains(".")   // single-label names resolve on the local network
        }
        let ip = UInt32(bigEndian: address.s_addr)
        let ranges: [(UInt32, UInt32)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
            (0xAC10_0000, 12), (0xC000_0000, 24), (0xC0A8_0000, 16), (0xC612_0000, 15), (0xE000_0000, 3),
        ]
        return ranges.contains { base, bits in ip >> (32 - bits) == base >> (32 - bits) }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        if host == "::1" || host == "::" { return true }
        if host.hasPrefix("::ffff:") { return isLocal(String(host.dropFirst(7))) }
        return ["fe8", "fe9", "fea", "feb", "fc", "fd", "ff"].contains(where: host.hasPrefix)
    }
}

/// Keeps a minimum interval between requests to the same host (spec §9).
actor RequestThrottle {
    static let shared = RequestThrottle()

    var minimumInterval: Duration = .milliseconds(500)
    private var nextAllowed: [String: ContinuousClock.Instant] = [:]

    func wait(for host: String) async throws {
        let clock = ContinuousClock()
        let now = clock.now
        let slot = max(now, nextAllowed[host] ?? now)
        nextAllowed[host] = slot + minimumInterval
        if slot > now { try await clock.sleep(until: slot) }
    }
}

public final class URLSessionFetcher: HTTPFetching {
    public static let shared = URLSessionFetcher()

    static let maxBytes = 5_000_000
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 NovelNest/0.1"

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = URLCache(memoryCapacity: 8_000_000, diskCapacity: 0)
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: SourceRequest, allowedHosts: HostPolicy) async throws -> HTTPResponse {
        guard allowedHosts.allows(request.url) else { throw WebSourceError.disallowedHost(request.url.host ?? request.url.absoluteString) }
        try await RequestThrottle.shared.wait(for: request.url.host ?? "")

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.limitedData(for: urlRequest, maxBytes: Self.maxBytes,
                                                             delegate: RedirectGuard(policy: allowedHosts))
        } catch let error as URLError where error.code == .timedOut {
            throw WebSourceError.timedOut
        }
        guard let http = response as? HTTPURLResponse else { throw WebSourceError.httpStatus(0) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(url: http.url ?? request.url, status: http.statusCode, headers: headers, data: data)
    }
}

/// Cancels redirects that leave the source's domains.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let policy: HostPolicy

    init(policy: HostPolicy) {
        self.policy = policy
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // Not following leaves the 3xx response, which `PageDecoder` reports.
        guard let url = request.url, policy.allows(url) else { return nil }
        return request
    }
}

/// Turns a response into page text, refusing what must not be retried
/// around: 401/403, CAPTCHA pages, 429/503 (spec §9).
enum PageDecoder {
    static func text(of response: HTTPResponse, request: SourceRequest, policy: HostPolicy) throws -> String {
        guard policy.allows(response.url) else { throw WebSourceError.disallowedHost(response.url.host ?? "") }
        switch response.status {
        case 200..<300: break
        case 300..<400:
            let location = response.header("Location").flatMap { URL(string: $0, relativeTo: response.url) }
            throw WebSourceError.disallowedHost(location?.host ?? "")
        case 401, 403: throw WebSourceError.blocked(response.status)
        case 429, 503:
            throw WebSourceError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        default: throw WebSourceError.httpStatus(response.status)
        }
        let contentType = response.header("Content-Type")?.lowercased() ?? ""
        if ["image/", "audio/", "video/", "font/"].contains(where: contentType.hasPrefix) {
            throw WebSourceError.notText(contentType)
        }
        guard response.data.count <= URLSessionFetcher.maxBytes else { throw WebSourceError.tooLarge }

        let declared = request.charset ?? charset(inContentType: contentType) ?? metaCharset(in: response.data)
        guard let decoded = EncodingDetector.decode(response.data, declared: declared) else { throw WebSourceError.undecodable }
        if looksLikeChallenge(decoded.text) { throw WebSourceError.captcha }
        return decoded.text
    }

    static func charset(inContentType type: String) -> TextEncoding? {
        guard let range = type.range(of: "charset=") else { return nil }
        let label = type[range.upperBound...].split(separator: ";").first.map(String.init) ?? ""
        return TextEncoding(label: label.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
    }

    /// `<meta charset=gbk>` or `<meta http-equiv … content="…charset=gbk">`
    /// in the first few kilobytes.
    static func metaCharset(in data: Data) -> TextEncoding? {
        let head = String(decoding: data.prefix(4096).map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self).lowercased()
        guard let range = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression) else { return nil }
        let label = head[range].split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) } ?? ""
        return TextEncoding(label: label)
    }

    private static let challengeMarkers = ["cf-browser-verification", "challenge-platform", "cf_chl_", "<title>just a moment", "<title>attention required", "人机验证", "安全验证</title>"]

    static func looksLikeChallenge(_ text: String) -> Bool {
        let head = text.prefix(20_000).lowercased()
        return challengeMarkers.contains { head.contains($0) }
    }
}

extension URLSession {
    /// The response body, read as it arrives and abandoned as soon as it
    /// passes `maxBytes`, so a huge or endless response can't fill memory.
    public func limitedData(for request: URLRequest, maxBytes: Int,
                            delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await self.bytes(for: request, delegate: delegate)
        if response.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw WebSourceError.tooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(maxBytes)))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                throw WebSourceError.tooLarge
            }
        }
        return (data, response)
    }
}
