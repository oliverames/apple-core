// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fetches a Client ID Metadata Document, under the constraints from section 8
// of the draft. This is the only place in Apple Core that makes an outbound
// request to a URL somebody else chose, so it is written as though that URL is
// hostile, because it is attacker-controlled by definition: anyone who can
// reach the authorization endpoint can name it.
//
// The rules that matter here:
//   - https only, and the host must not resolve to a special-use address.
//     This process sits on a home network with a router, printers and other
//     Macs on private addresses, and an unguarded fetch would reach all of it.
//   - Redirects are never followed. The document must live at its identifier.
//   - At most 5KB is read.
//   - Nothing that fails is ever cached.

import Darwin
import Foundation
import OSLog

private let log = Logger.service("cimd")

actor ClientIDMetadataFetcher {
    static let shared = ClientIDMetadataFetcher()

    /// Bounds on how long a document is reused, whatever the origin asks for.
    private static let minimumCacheSeconds: TimeInterval = 60
    private static let maximumCacheSeconds: TimeInterval = 24 * 60 * 60
    private static let maximumCacheEntries = 256

    private struct CacheEntry {
        let metadata: ClientIDMetadata
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(
                configuration: configuration,
                delegate: NoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    /// Returns validated metadata for a client identifier URL.
    ///
    /// Only successful, valid documents are cached. A failure is never cached,
    /// so a client that fixes its document is not locked out for an hour.
    func metadata(for identifier: ClientIDMetadataURL, now: Date = Date()) async throws
        -> ClientIDMetadata
    {
        cache = cache.filter { $0.value.expiresAt > now }
        if let cached = cache[identifier.value], cached.expiresAt > now {
            return cached.metadata
        }

        try await refuseSpecialUseAddresses(host: identifier.host)

        guard let url = URL(string: identifier.value) else {
            throw ClientIDMetadataError.malformedURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw ClientIDMetadataError.unexpectedStatus(0)
        }
        // The delegate stops redirects rather than following them, so a 3xx
        // arrives here intact and is reported as what it is.
        if (300 ..< 400).contains(http.statusCode) {
            throw ClientIDMetadataError.redirected(
                to: http.value(forHTTPHeaderField: "Location") ?? "another location"
            )
        }
        guard http.statusCode == 200 else {
            throw ClientIDMetadataError.unexpectedStatus(http.statusCode)
        }
        let data = try await ClientIDMetadata.boundedBody(from: bytes)

        let metadata = try ClientIDMetadata.validated(
            data: data,
            fetchedFrom: identifier,
            redirectURIIsAcceptable: OAuthSupport.isAllowedRedirectURI
        )
        if cache[identifier.value] == nil, cache.count >= Self.maximumCacheEntries,
            let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
        {
            cache.removeValue(forKey: oldest)
        }
        cache[identifier.value] = CacheEntry(
            metadata: metadata,
            expiresAt: now.addingTimeInterval(cacheLifetime(from: http))
        )
        log.info("Fetched client metadata for \(identifier.host, privacy: .public)")
        return metadata
    }

    /// Honours the origin's caching preference within our own bounds.
    private func cacheLifetime(from response: HTTPURLResponse) -> TimeInterval {
        guard let header = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased() else {
            return Self.minimumCacheSeconds
        }
        if header.contains("no-store") || header.contains("no-cache") {
            return 0
        }
        guard let range = header.range(of: "max-age="),
            let seconds = TimeInterval(
                header[range.upperBound...].prefix { $0.isNumber }
            )
        else {
            return Self.minimumCacheSeconds
        }
        return min(max(seconds, Self.minimumCacheSeconds), Self.maximumCacheSeconds)
    }

    /// Refuses a host that resolves to any special-use address.
    ///
    /// Every address is checked, not just the first: a host that answers with
    /// one public address and one private address is the obvious way to smuggle
    /// a request onto the local network.
    ///
    /// This narrows the hole rather than closing it. The name is resolved here
    /// and again by URLSession when it connects, so a DNS answer that changes
    /// in between still gets through. Closing that properly means pinning the
    /// connection to the address checked here, which URLSession does not
    /// expose; it is worth doing if this ever guards something more than a
    /// consent screen's name and icon.
    private func refuseSpecialUseAddresses(host: String) async throws {
        let addresses = try Self.resolve(host: host)
        guard !addresses.isEmpty else {
            throw ClientIDMetadataError.unresolvableHost(host)
        }
        for address in addresses where SpecialUseAddress.isSpecialUse(address) {
            throw ClientIDMetadataError.blockedAddress(host: host, address: address)
        }
    }

    nonisolated static func resolve(host: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else {
            throw ClientIDMetadataError.unresolvableHost(host)
        }
        defer { freeaddrinfo(head) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let text = String(cString: buffer)
                if !text.isEmpty { addresses.append(text) }
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }
}

/// Stops URLSession following redirects, as section 5 requires.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
