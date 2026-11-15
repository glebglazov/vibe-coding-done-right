@testable import vcdr_ios

@MainActor
final class SpyBackgroundTaskRunner: BackgroundTaskRunner {
    private(set) var names: [String] = []
    private(set) var running = 0

    func run<T>(named name: String, _ work: () async -> T) async -> T {
        names.append(name)
        running += 1
        let result = await work()
        running -= 1
        return result
    }
}
