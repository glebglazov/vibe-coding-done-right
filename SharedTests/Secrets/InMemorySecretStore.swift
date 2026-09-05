import Foundation
import os
import Security
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Secret Store double for the suites: holds secrets in memory, and can be told to
/// refuse a key so the unreadable-Store path is drivable. Lock-guarded because the
/// protocol is `Sendable`; `OSAllocatedUnfairLock` matches `FakeLLMAdapter`.
final class InMemorySecretStore: SecretStore {
    private struct State {
        var secrets: [String: String] = [:]
        var unreadableKeys: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(secrets: [String: String] = [:]) {
        state.withLock { $0.secrets = secrets }
    }

    /// Makes reads of `key` fail the way a keychain the process cannot reach does.
    func failRead(forKey key: String) {
        state.withLock { $0.unreadableKeys.insert(key) }
    }

    nonisolated func secret(forKey key: String) throws -> String? {
        try state.withLock { state in
            guard !state.unreadableKeys.contains(key) else {
                throw SecretStoreError.readFailed(key: key, status: errSecInternalError)
            }
            return state.secrets[key]
        }
    }

    nonisolated func setSecret(_ secret: String?, forKey key: String) throws {
        state.withLock { $0.secrets[key] = secret?.isEmpty == false ? secret : nil }
    }
}
