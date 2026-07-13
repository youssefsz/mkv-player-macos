import Foundation

public struct ResolvedBookmark: Sendable, Equatable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public protocol BookmarkProviding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark
}

/// Produces app-scoped, security-scoped bookmarks suitable for a sandboxed macOS app.
public struct SecurityScopedBookmarkProvider: BookmarkProviding {
    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedBookmark(url: url, isStale: isStale)
    }
}

public protocol SecurityScopedResourceAccess: AnyObject, Sendable {
    var url: URL { get }
    var didAcquireSecurityScope: Bool { get }
    func stop()
}

public protocol SecurityScopedResourceAccessing: Sendable {
    func beginAccessing(_ url: URL) -> any SecurityScopedResourceAccess
}

public struct SystemSecurityScopedResourceAccessor: SecurityScopedResourceAccessing {
    public init() {}

    public func beginAccessing(_ url: URL) -> any SecurityScopedResourceAccess {
        SecurityScopedResourceToken(url: url)
    }
}

public final class SecurityScopedResourceToken: SecurityScopedResourceAccess, @unchecked Sendable {
    public let url: URL
    public let didAcquireSecurityScope: Bool

    private let lock = NSLock()
    private var isStopped = false

    fileprivate init(url: URL) {
        self.url = url
        self.didAcquireSecurityScope = url.startAccessingSecurityScopedResource()
    }

    public func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        lock.unlock()

        if didAcquireSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        stop()
    }
}
