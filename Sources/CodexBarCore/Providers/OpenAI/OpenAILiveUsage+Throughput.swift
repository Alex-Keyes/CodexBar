import Foundation

extension OpenAILiveUsageSnapshot {
    public var throughput: ProviderThroughputSnapshot {
        let summary = self.summary(for: .allModels)
        return ProviderThroughputSnapshot(
            minutes: self.series(for: .allModels).map {
                .init(
                    start: $0.start,
                    totalTokens: $0.totalTokens,
                    requests: $0.requests,
                    isPending: $0.isPending)
            },
            frontier: self.reportingFrontier,
            latestTokensPerMinute: self.reportingFrontier == nil ? nil : summary.latestTPM,
            peakTokensPerMinute: summary.peakTPM,
            peakAt: summary.peakMinuteStart,
            fiveMinuteAverageTokensPerMinute: summary.fiveMinuteAverageTPM,
            models: self.modelNames.prefix(5).map { name in
                let summary = self.summary(for: .model(name))
                return .init(
                    name: name,
                    latestTPM: summary.latestTPM,
                    peakTPM: summary.peakTPM,
                    totalTokens: summary.totalTokens,
                    peakLimitCountedTokens: self.series(for: .model(name)).filter { !$0.isPending }
                        .map(\.limitCountedTokens).max() ?? 0)
            },
            windowMinutes: self.windowMinutes,
            fetchedAt: self.fetchedAt)
    }
}
