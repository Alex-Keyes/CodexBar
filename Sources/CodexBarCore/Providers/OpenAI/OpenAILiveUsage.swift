import Foundation

public enum OpenAILiveUsageModelFilter: Hashable, Sendable {
    case allModels
    case model(String)
}

public struct OpenAILiveUsageSnapshot: Sendable, Equatable {
    public struct ModelUsage: Sendable, Equatable {
        public let name: String
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let requests: Int
        public var totalTokens: Int {
            self.inputTokens + self.outputTokens
        }

        public init(name: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, requests: Int) {
            self.name = name
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.requests = requests
        }
    }

    public struct Minute: Sendable, Equatable {
        public let start: Date
        public let models: [ModelUsage]

        public init(start: Date, models: [ModelUsage]) {
            self.start = start
            self.models = models
        }
    }

    public struct Point: Sendable, Equatable {
        public let start: Date
        public let totalTokens: Int
        public let uncachedInputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let requests: Int
        public let isInProgress: Bool
        public let isPending: Bool
        public var limitCountedTokens: Int {
            self.uncachedInputTokens + self.outputTokens
        }
    }

    public struct ModelStack: Sendable, Equatable {
        public let minute: Date
        public let modelOrOther: String
        public let tokens: Int
        public let isInProgress: Bool
        public let isPending: Bool
    }

    public struct Summary: Sendable, Equatable {
        public let latestTPM: Int
        public let latestMinuteStart: Date?
        public let fiveMinuteAverageTPM: Double
        public let peakTPM: Int
        public let peakMinuteStart: Date?
        public let totalTokens: Int
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let requests: Int
    }

    public struct ModelRow: Sendable, Equatable {
        public let name: String
        public let latestTPM: Int
        public let peakTPM: Int
        public let totalTokens: Int
        public let requests: Int
        public var tpmLimit: Int?
        public var rpmLimit: Int?
        public var projectCap: Int?
        public var peakTPMPercent: Double?
        public var latestTPMPercent: Double?
    }

    public let minutes: [Minute]
    public let windowMinutes: Int
    public let fetchedAt: Date
    public let projectID: String?

    public init(minutes: [Minute], windowMinutes: Int, fetchedAt: Date, projectID: String?) {
        self.minutes = minutes
        self.windowMinutes = windowMinutes
        self.fetchedAt = fetchedAt
        self.projectID = projectID
    }

    public var modelNames: [String] {
        var totals: [String: Int] = [:]
        for minute in self.minutes {
            for model in minute.models {
                totals[model.name, default: 0] += model.totalTokens
            }
        }
        return totals.keys.sorted {
            let left = totals[$0, default: 0]
            let right = totals[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }
    }

    /// A shared reporting frontier keeps lagging buckets from looking like a drop to zero.
    public var reportingFrontier: Date? {
        let complete = self.minutes.filter { $0.start.addingTimeInterval(60) <= self.fetchedAt }
        guard let last = complete.last else { return nil }
        let cutoff = last.start.addingTimeInterval(-9 * 60)
        return complete.last(where: { minute in
            minute.start >= cutoff && minute.models.contains { $0.totalTokens > 0 }
        })?.start ?? last.start
    }

    public func series(for filter: OpenAILiveUsageModelFilter) -> [Point] {
        let frontier = self.reportingFrontier
        return self.minutes.map { minute in
            let models = minute.models.filter {
                switch filter {
                case .allModels: true
                case let .model(name): $0.name == name
                }
            }
            let input = models.reduce(0) { $0 + $1.inputTokens }
            let cached = models.reduce(0) { $0 + $1.cachedInputTokens }
            let output = models.reduce(0) { $0 + $1.outputTokens }
            return Point(
                start: minute.start,
                totalTokens: input + output,
                uncachedInputTokens: input - cached,
                cachedInputTokens: cached,
                outputTokens: output,
                requests: models.reduce(0) { $0 + $1.requests },
                isInProgress: minute.start.addingTimeInterval(60) > self.fetchedAt,
                isPending: frontier.map { minute.start > $0 } ?? true)
        }
    }

    public func stackedByModel(topN: Int = 5) -> [ModelStack] {
        let frontier = self.reportingFrontier
        let names = self.modelNames
        let top = Array(names.prefix(max(0, topN)))
        let topSet = Set(top)
        let hasOther = names.count > top.count
        return self.minutes.flatMap { minute in
            var totals: [String: Int] = [:]
            for model in minute.models {
                let label = topSet.contains(model.name) ? model.name : "Other"
                totals[label, default: 0] += model.totalTokens
            }
            return (top + (hasOther ? ["Other"] : [])).map { name in
                ModelStack(
                    minute: minute.start,
                    modelOrOther: name,
                    tokens: totals[name, default: 0],
                    isInProgress: minute.start.addingTimeInterval(60) > self.fetchedAt,
                    isPending: frontier.map { minute.start > $0 } ?? true)
            }
        }
    }

    public func summary(for filter: OpenAILiveUsageModelFilter) -> Summary {
        let points = self.series(for: filter)
        let frontier = self.reportingFrontier
        let latest = points.first { $0.start == frontier }
        let recent = points.filter { point in
            guard let frontier else { return false }
            return point.start <= frontier && point.start > frontier.addingTimeInterval(-5 * 60)
        }
        // In a tie, keep the earliest peak in the ascending grid.
        let peak = points.max { $0.totalTokens < $1.totalTokens }
        return Summary(
            latestTPM: latest?.totalTokens ?? 0,
            latestMinuteStart: frontier,
            fiveMinuteAverageTPM: recent.isEmpty ? 0 :
                Double(recent.reduce(0) { $0 + $1.totalTokens }) / Double(recent.count),
            peakTPM: peak?.totalTokens ?? 0,
            peakMinuteStart: peak?.start,
            totalTokens: points.reduce(0) { $0 + $1.totalTokens },
            inputTokens: points.reduce(0) { $0 + $1.uncachedInputTokens + $1.cachedInputTokens },
            cachedInputTokens: points.reduce(0) { $0 + $1.cachedInputTokens },
            outputTokens: points.reduce(0) { $0 + $1.outputTokens },
            requests: points.reduce(0) { $0 + $1.requests })
    }

    public var modelRows: [ModelRow] {
        self.modelNames.map { name in
            let summary = self.summary(for: .model(name))
            return ModelRow(
                name: name,
                latestTPM: summary.latestTPM,
                peakTPM: summary.peakTPM,
                totalTokens: summary.totalTokens,
                requests: summary.requests)
        }
    }
}
