import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OpenAILiveUsageModelTests {
    @Test
    func `filter defaults to all models and retains absent selection after refresh`() async {
        let source = Source()
        let model = OpenAILiveUsageModel(environment: { [:] }, fetch: { _, minutes in
            try await source.fetch(minutes: minutes)
        })
        #expect(model.filter == .allModels)
        #expect(model.windowMinutes == 60)
        model.start()
        await model.waitForRefresh()
        #expect(model.snapshot != nil)
        model.filter = .model("absent-model")
        model.windowMinutes = 15
        await model.waitForRefresh()
        #expect(model.filter == .model("absent-model"))
        #expect(model.snapshot?.windowMinutes == 15)
        #expect(await source.ranges == [60, 15])
        model.stop()
        #expect(!model.isActive)
        #expect(model.nextRefreshAt == nil)
    }

    @Test
    func `failed refresh preserves snapshot and backs off until success`() async {
        let source = Source()
        let model = OpenAILiveUsageModel(environment: { [:] }, fetch: { _, minutes in
            try await source.fetch(minutes: minutes)
        })
        model.start()
        await model.waitForRefresh()
        let good = model.snapshot
        await source.setError(.rateLimited)
        model.refresh()
        await model.waitForRefresh()
        #expect(model.snapshot == good)
        #expect(model.lastError != nil)
        #expect(model.isRateLimited)
        #expect(model.pollingInterval == 60)
        #expect(model.nextRefreshAt != nil)
        model.refresh()
        await model.waitForRefresh()
        #expect(model.pollingInterval == 120)
        await source.setError(nil)
        model.refresh()
        await model.waitForRefresh()
        #expect(model.pollingInterval == 30)
        #expect(model.lastError == nil)
        #expect(!model.isRateLimited)
        model.stop()
    }

    @Test
    func `polling doubles only for rate limits caps at five minutes and resets on success`() {
        #expect(OpenAILiveUsagePolling.interval(after: .rateLimited, previous: 30) == 60)
        #expect(OpenAILiveUsagePolling.interval(after: .rateLimited, previous: 120) == 240)
        #expect(OpenAILiveUsagePolling.interval(after: .rateLimited, previous: 240) == 300)
        #expect(OpenAILiveUsagePolling.interval(after: .rateLimited, previous: 300) == 300)
        #expect(OpenAILiveUsagePolling.interval(after: .apiFailure(500), previous: 60) == 60)
        #expect(OpenAILiveUsagePolling.interval(after: nil, previous: 300) == 30)
    }

    @Test
    func `menu entry follows configured credential availability without AppKit menus`() {
        let settings = testSettingsStore(
            suiteName: "OpenAILiveUsageModelTests", userDefaults: InMemoryUserDefaults())
        let provider = OpenAIAPIProviderImplementation()
        #expect(provider.liveUsageMenuEntries(settings: settings, environment: [:]).isEmpty)
        let entries = provider.liveUsageMenuEntries(settings: settings, environment: ["OPENAI_ADMIN_KEY": "test-key"])
        #expect(entries.count == 1)
        #expect(MenuDescriptor.MenuAction.openOpenAILiveUsage.systemImageName == "chart.bar.xaxis")
        if case let .action(title, action) = entries.first {
            #expect(title == L("Live Usage"))
            #expect(action == .openOpenAILiveUsage)
        } else {
            Issue.record("Expected Live Usage action")
        }
        settings[providerConfig: .openai, field: .apiKey] = "test-config-key"
        #expect(provider.liveUsageMenuEntries(settings: settings, environment: [:]).count == 1)
    }

    @Test
    func `range changes coalesce in flight and closing rejects late results`() async {
        let gate = Gate()
        let model = OpenAILiveUsageModel(environment: { [:] }, fetch: { _, minutes in
            await gate.fetch(minutes: minutes)
        })
        model.start()
        await gate.waitForRequest(1)
        model.refresh()
        model.windowMinutes = 15
        model.windowMinutes = 360
        #expect(await gate.ranges == [60])
        await gate.finish()
        await gate.waitForRequest(2)
        #expect(await gate.ranges == [60, 360])
        #expect(model.snapshot == nil)
        model.stop()
        await gate.finish()
        await model.waitForRefresh()
        #expect(model.snapshot == nil)
        #expect(!model.isLoading)
        #expect(model.nextRefreshAt == nil)
        model.start()
        await gate.waitForRequest(3)
        await gate.finish()
        await model.waitForRefresh()
        #expect(model.snapshot?.windowMinutes == 360)
        model.stop()
    }

    private actor Gate {
        var ranges: [Int] = []
        var pending: CheckedContinuation<OpenAILiveUsageSnapshot, Never>?
        var waiting: CheckedContinuation<Void, Never>?

        func fetch(minutes: Int) async -> OpenAILiveUsageSnapshot {
            self.ranges.append(minutes)
            return await withCheckedContinuation { continuation in
                self.pending = continuation
                self.waiting?.resume()
                self.waiting = nil
            }
        }

        func waitForRequest(_ count: Int) async {
            guard self.ranges.count < count else { return }
            await withCheckedContinuation { self.waiting = $0 }
        }

        func finish() {
            self.pending?.resume(returning: .init(
                minutes: [], windowMinutes: self.ranges.last ?? 60, fetchedAt: Date(), projectID: nil))
            self.pending = nil
        }
    }

    private actor Source {
        var error: OpenAILiveUsageError?
        var ranges: [Int] = []

        func setError(_ error: OpenAILiveUsageError?) {
            self.error = error
        }

        func fetch(minutes: Int) throws -> OpenAILiveUsageSnapshot {
            self.ranges.append(minutes)
            if let error { throw error }
            return .init(minutes: [], windowMinutes: minutes, fetchedAt: Date(), projectID: nil)
        }
    }
}
