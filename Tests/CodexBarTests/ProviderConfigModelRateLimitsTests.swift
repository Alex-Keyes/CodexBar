import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ProviderConfigModelRateLimitsTests {
    @Test
    func `model rate limits round trip and empty values are omitted`() throws {
        let config = ProviderConfig(id: .openai, modelRateLimits: [
            .init(model: "gpt-5", tokensPerMinute: 40_000_000, requestsPerMinute: 15000),
            .init(model: "gpt-4o", tokensPerMinute: 100),
        ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(decoded.modelRateLimits == config.modelRateLimits)
        #expect(decoded.id == config.id)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(json["modelRateLimits"] as? [[String: Any]])
        #expect(rows.first?["model"] as? String == "gpt-5")
        #expect(rows.first?["tokensPerMinute"] as? Int == 40_000_000)
        for value: [ProviderModelRateLimit]? in [nil, []] {
            let empty = try JSONEncoder().encode(ProviderConfig(id: .openai, modelRateLimits: value))
            #expect(try #require(String(data: empty, encoding: .utf8)).contains("modelRateLimits") == false)
        }
        let old = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"id":"openai"}"#.utf8))
        #expect(old.modelRateLimits == nil)
        #expect(try JSONEncoder().encode(old) == JSONEncoder().encode(ProviderConfig(id: .openai)))
    }

    @Test
    func `loading trims drops invalid counts and uses the last duplicate`() throws {
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"""
        {"id":"openai","modelRateLimits":[
          {"model":" ","tokensPerMinute":10},
          {"model":"zero","tokensPerMinute":0},
          {"model":"negative","tokensPerMinute":-1},
          {"model":" gpt-5 ","tokensPerMinute":100,"requestsPerMinute":5},
          {"model":"gpt-5","tokensPerMinute":200,"requestsPerMinute":0},
          {"model":"gpt-4o","tokensPerMinute":100,"requestsPerMinute":-1}
        ]}
        """#.utf8))
        #expect(config.modelRateLimits == [
            .init(model: "gpt-5", tokensPerMinute: 200), .init(model: "gpt-4o", tokensPerMinute: 100),
        ])
    }

    @Test
    func `limits sync as nonsecret intent and do not change fetch identity`() throws {
        let initial = ProviderConfig(id: .openai)
        var edited = initial
        edited.modelRateLimits = [.init(model: "gpt-5", tokensPerMinute: 100)]
        #expect(try JSONEncoder().encode(edited.fetchIdentityConfig) ==
            JSONEncoder().encode(initial.fetchIdentityConfig))
        let payload = ProviderIntentPayload(config: edited)
        let decoded = try JSONDecoder().decode(ProviderIntentPayload.self, from: JSONEncoder().encode(payload))
        let applied = try decoded.applying(to: initial, secretFields: [:], canEnable: { _, _ in false })
        #expect(applied.modelRateLimits == edited.modelRateLimits)
        let cleared = try ProviderIntentPayload(config: initial).applying(
            to: edited, secretFields: [:], canEnable: { _, _ in false })
        #expect(cleared.modelRateLimits == [])
    }

    @Test(arguments: ["40000000", "40,000,000", "40M", "40m", " 40M "])
    func `plain grouped and suffix counts parse`(text: String) {
        #expect(ProviderRateLimitNumber.parse(text) == 40_000_000)
    }

    @Test
    func `decimal suffixes round trip exactly without floating point loss`() {
        #expect(ProviderRateLimitNumber.parse("150k") == 150_000)
        #expect(ProviderRateLimitNumber.parse("1.5M") == 1_500_000)
        #expect(ProviderRateLimitNumber.parse("1.001k") == 1001)
        #expect(ProviderRateLimitNumber.parse(String(Int.max)) == Int.max)
        for value in [1, 1001, 150_000, 1_500_000, 40_000_000, Int.max] {
            #expect(ProviderRateLimitNumber.parse(ProviderRateLimitNumber.format(value)) == value)
        }
        #expect(ProviderRateLimitNumber.format(40_000_000) == "40M")
        #expect(ProviderRateLimitNumber.format(150_000) == "150K")
    }

    @Test(arguments: [
        "",
        "0",
        "-1",
        "+1",
        "1.5",
        "1,50",
        "1,,000",
        "1e3",
        "1.0001k",
        "NaN",
        "∞",
        "4B",
        "9223372036854775808",
        "9999999999999999999999999999999999999999999999999M"
    ])
    func `invalid and overflowing counts are rejected`(text: String) {
        #expect(ProviderRateLimitNumber.parse(text) == nil)
    }
}
