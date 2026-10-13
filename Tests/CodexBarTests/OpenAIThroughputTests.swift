import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIThroughputTests {
    #if canImport(JavaScriptCore)
    static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif
    static let now = Date(timeIntervalSince1970: 120_025)
    static let model = "model-fixture"
    static let empty = #"{"data":[],"has_more":false}"#

    @Test(arguments: Self.engines)
    func `live throughput does not count audio breakdowns twice`(engine: ProviderPluginEngineKind) async throws {
        // input_tokens/output_tokens already include the audio portions reported in the breakdown fields.
        let body = #"""
        {"data":[{"start_time":119760,"end_time":119820,"results":[{
          "model":"model-fixture","input_tokens":100,"input_audio_tokens":40,"input_cached_tokens":60,
          "output_tokens":15,"output_audio_tokens":5,"num_model_requests":2
        }]}],"has_more":false}
        """#
        let result = try await Self.runtime(transport: Transport(liveBody: body), engine: engine).fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1"],
            secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
            now: Self.now)
        let throughput = try #require(result.usage.throughput)
        #expect(throughput.peakTokensPerMinute == 115)
        #expect(throughput.models.first?.peakLimitCountedTokens == 55)
        let swift = try await OpenAILiveUsageFetcher(transport: Transport(liveBody: body))
            .fetch(environment: ["OPENAI_ADMIN_KEY": "synthetic-admin-key"], now: Self.now)
        #expect(swift.throughput == throughput)
    }

    @Test(arguments: Self.engines)
    func `plugin requests one scoped minute page and maps lagging throughput`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Transport(liveBody: Self.livePage)
        let runtime = try Self.runtime(
            transport: transport,
            engine: engine)
        let result = try await runtime.fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1", "OPENAI_PROJECT_ID": "proj_fixture & scope"],
            secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
            now: Self.now)
        let requests = await transport.requests
        #expect(requests.count == 3)
        let url = try #require(requests.last?.url)
        let query = try #require(URLComponents(
            url: url,
            resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(values == [
            "start_time": "116460", "end_time": "120025", "bucket_width": "1m", "group_by": "model",
            "limit": "60", "project_ids": "proj_fixture & scope",
        ])
        let throughput = try #require(result.usage.throughput)
        #expect(throughput.minutes.count == 60)
        #expect(throughput.frontier == Date(timeIntervalSince1970: 119_820))
        #expect(throughput.latestTokensPerMinute == 75_000_000)
        #expect(throughput.peakTokensPerMinute == 97_000_000)
        #expect(throughput.peakAt == Date(timeIntervalSince1970: 119_760))
        #expect(throughput.fiveMinuteAverageTokensPerMinute == 34_400_000)
        #expect(throughput.minutes.suffix(3).filter { !$0.isPending }.isEmpty)
        #expect(throughput.models.first?.peakLimitCountedTokens == 4_600_000)
        #expect(result.usage.openAIAPIUsage != nil)
        let swift = try await OpenAILiveUsageFetcher(transport: Transport(liveBody: Self.livePage))
            .fetch(
                environment: ["OPENAI_ADMIN_KEY": "synthetic-admin-key"],
                now: Self.now)
        #expect(swift.throughput == throughput)
        let mapped = try await Self.mappedLive(
            Self.liveSource(Self.livePayload),
            engine: engine)
        #expect(mapped.throughput == swift.throughput)
        let mappedSnapshot = try OpenAIAPIProviderDescriptor.mapLiveUsage(
            JSONProviderPluginValue(Self.livePayload),
            projectID: nil,
            maximumEntries: 10000)
        #expect(mappedSnapshot == swift)
    }

    @Test(arguments: Self.engines)
    func `live failures preserve daily data and disabled setting omits the request`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (code, body) in [(500, "{}"), (429, "{}"), (200, "malformed"), (200, #"{"data":false}"#)] {
            let transport = Transport(
                liveBody: body,
                liveStatus: code)
            let runtime = try Self.runtime(
                transport: transport,
                engine: engine)
            let result = try await runtime.fetchResult(
                settings: ["OPENAI_HISTORY_DAYS": "1"],
                secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
                now: Self.now)
            #expect(result.usage.throughput == nil)
            #expect(result.usage.openAIAPIUsage != nil)
            #expect(result.sourceLabel == "admin-api")
            #expect(await transport.requests.count == 3)
        }
        let transport = Transport(liveBody: Self.livePage)
        let runtime = try Self.runtime(
            transport: transport,
            engine: engine)
        let result = try await runtime.fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1", "OPENAI_LIVE_MINUTES": "0"],
            secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
            now: Self.now)
        #expect(result.usage.throughput == nil)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: Self.engines)
    func `invalid live bounds discard only throughput`(engine: ProviderPluginEngineKind) async throws {
        var invalid: [[String: Any]] = []
        for (key, value) in [
            ("windowMinutes", 61), ("startTime", 1), ("fetchedAt", -1),
        ] {
            var payload = Self.livePayload
            payload[key] = value
            invalid.append(payload)
        }
        var payload = Self.livePayload
        payload["buckets"] = Array(
            repeating: ["startTime": 119_820, "models": []] as [String: Any],
            count: 61)
        invalid.append(payload)
        for (field, value) in [
            ("inputTokens", -1.0), ("outputTokens", 1.5), ("requests", 9_007_199_254_740_992.0),
            ("cachedInputTokens", 200.0),
        ] {
            var model: [String: Any] = [
                "name": Self.model,
                "inputTokens": 100,
                "cachedInputTokens": 0,
                "outputTokens": 2,
                "requests": 1,
            ]
            model[field] = value
            var payload = Self.livePayload
            payload["buckets"] = [["startTime": 119_820, "models": [model]]]
            invalid.append(payload)
        }
        var tooMany = Self.livePayload
        tooMany["buckets"] = [["startTime": 119_820, "models": Array(
            repeating: Self.cardModel,
            count: 201)]]
        invalid.append(tooMany)
        var globalCap = Self.livePayload
        globalCap["buckets"] = (0..<51).map { index in
            ["startTime": 116_460 + index * 60, "models": Array(
                repeating: Self.cardModel,
                count: 200)] as [String: Any]
        }
        invalid.append(globalCap)
        for live in invalid {
            let result = try await Self.mappedLive(
                Self.liveSource(live),
                engine: engine)
            #expect(result.throughput == nil)
            #expect(result.openAIAPIUsage != nil)
        }
    }

    @Test
    func `top models are bounded and cached input does not inflate limit utilization`() throws {
        let models = (1...7).map { index in
            OpenAILiveUsageSnapshot.ModelUsage(
                name: "model-\(index)",
                inputTokens: index * 10_000_000,
                cachedInputTokens: index * 9_500_000,
                outputTokens: 1_000_000,
                requests: index)
        }
        let snapshot = try OpenAILiveUsageBuilder.build(
            buckets: [.init(
                start: Self.now.addingTimeInterval(-85),
                models: models)],
            windowMinutes: 60,
            fetchedAt: Self.now,
            projectID: nil)
        #expect(snapshot.throughput.models.map(\.name) == ["model-7", "model-6", "model-5", "model-4", "model-3"])
        let limits = OpenAIOrgLimitResolver(
            manual: [.init(
                model: "model-7",
                tokensPerMinute: 40_000_000)],
            projectCaps: nil)
        let utilization = try #require(snapshot.utilization(
            for: .model("model-7"),
            limits: limits))
        #expect(snapshot.summary(for: .model("model-7")).peakTPM == 71_000_000)
        #expect(utilization.peakTPMPercent == 11.25)
        #expect(utilization.latestTPMPercent == 11.25)
        #expect(snapshot.highestUtilization(limits: limits)?.peakTPMPercent == 11.25)
        #expect(snapshot.modelRows(limits: limits).first?.peakTPMPercent == 11.25)
    }

    @Test
    func `old snapshot JSON decodes and snapshot copies preserve throughput`() async throws {
        let snapshot = try await Self.mappedLive(
            Self.liveSource(Self.livePayload),
            engine: .quickJS)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(
            UsageSnapshot.self,
            from: encoded).throughput == snapshot.throughput)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "throughput")
        let old = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(old.throughput == nil)
        #expect(snapshot.withIdentity(nil).throughput == snapshot.throughput)
        #expect(snapshot.with(providerCost: nil).throughput == snapshot.throughput)
        #expect(snapshot.backfillingResetTimes(from: nil).throughput == snapshot.throughput)
    }

    private static var cardModel: [String: Any] {
        [
            "name": model,
            "inputTokens": 74_000_000,
            "cachedInputTokens": 70_400_000,
            "outputTokens": 1_000_000,
            "requests": 50,
        ]
    }

    static var livePayload: [String: Any] {
        var peak = Self.cardModel
        peak["inputTokens"] = 96_000_000
        peak["cachedInputTokens"] = 92_400_000
        return ["windowMinutes": 60, "startTime": 116_460, "fetchedAt": 120_025, "buckets": [
            ["startTime": 119_760, "models": [peak]],
            ["startTime": 119_820, "models": [Self.cardModel]],
        ]]
    }

    static var livePage: String {
        #"""
        {"data":[
          {"start_time":119760,"end_time":119820,"results":[{
            "model":"model-fixture","input_tokens":96000000,"input_cached_tokens":92400000,
            "output_tokens":1000000,"num_model_requests":50
          }]},
          {"start_time":119820,"end_time":119880,"results":[{
            "model":"model-fixture","input_tokens":74000000,"input_cached_tokens":70400000,
            "output_tokens":1000000,"num_model_requests":50
          }]}
        ],"has_more":false}
        """#
    }

    private static func runtime(
        transport: any ProviderHTTPTransport,
        engine: ProviderPluginEngineKind)
        throws -> ProviderPluginRuntime
    {
        let url = try #require(CodexBarCoreResources.bundle?.url(
            forResource: "openai",
            withExtension: "js"))
        return try ProviderPluginRuntime(
            source: String(
                contentsOf: url,
                encoding: .utf8),
            transport: transport,
            engine: engine)
    }

    static func liveSource(_ live: [String: Any]) throws -> String {
        let card: [String: Any] = ["openAIAPIUsage": ["historyDays": 1, "daily": [], "live": live]]
        let encoded = try JSONSerialization.data(withJSONObject: card)
        let json = try #require(String(data: encoded, encoding: .utf8))
        return """
        defineProvider({ id: "openai",
        name: "Fixture",
        endpoints: ["https://api.openai.com"],
        settings: [],
          async fetchUsage() { return {usage: {identity: {loginMethod: "Admin API"}},
          card: \(json)}; }
        });
        """
    }

    static func mappedLive(
        _ source: String,
        engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        try await ProviderPluginRuntime(
            source: source,
            engine: engine).fetchUsage(now: self.now)
    }

    private actor Transport: ProviderHTTPTransport {
        let liveBody: String
        let liveStatus: Int
        var requests: [URLRequest] = []

        init(
            liveBody: String,
            liveStatus: Int = 200)
        {
            self.liveBody = liveBody
            self.liveStatus = liveStatus
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.requests.append(request)
            let live = request.url?.query?.contains("bucket_width=1m") == true
            return (Data((live ? self.liveBody : OpenAIThroughputTests.empty).utf8), HTTPURLResponse(
                url: request.url!,
                statusCode: live ? self.liveStatus : 200,
                httpVersion: nil,
                headerFields: nil)!)
        }
    }
}
