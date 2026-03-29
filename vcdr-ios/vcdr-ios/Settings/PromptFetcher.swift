import Foundation
import OSLog

enum PromptFetcher {
    // MARK: - Constants

    private static let promptsURL = "https://vcdr-server.glebglazov.me/v1/prompts"
    private static let requestTimeout: TimeInterval = 10

    // MARK: - Public API

    /// Fetches updated prompts from the server if available.
    /// Silently fails on network errors — cached/default prompts are used instead.
    static func refreshIfNeeded() async {
        let cachedTimestamp = BuiltInPrompts.cachedTimestamp

        guard var urlComponents = URLComponents(string: promptsURL) else { return }
        if cachedTimestamp > 0 {
            urlComponents.queryItems = [URLQueryItem(name: "since", value: String(cachedTimestamp))]
        }
        guard let url = urlComponents.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 304 {
                Logger.app.info("Prompts up to date (304)")
                return
            }
            guard statusCode == 200 else {
                Logger.app.warning("Prompts fetch returned status \(statusCode)")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prompts = json["prompts"] as? [String: String],
                  let timestamp = json["timestamp"] as? Int,
                  let dictation = prompts["dictation"] else { return }

            BuiltInPrompts.updateCache(dictation: dictation, timestamp: timestamp)
            Logger.app.info("Updated dictation prompt from server (timestamp: \(timestamp))")
        } catch {
            Logger.app.warning("Failed to fetch prompts: \(error.localizedDescription)")
        }
    }
}
