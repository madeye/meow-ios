import Foundation
@testable import meow_ios
import Testing

@Suite("ChinaDirectKeywords preset")
struct ChinaDirectKeywordsTests {
    @Test
    func `Every preset row is DOMAIN-KEYWORD,<token>,DIRECT`() {
        for rule in ChinaDirectKeywords.presetRules() {
            #expect(rule.type == "DOMAIN-KEYWORD")
            #expect(rule.proxy == "DIRECT")
            #expect(!rule.payload.isEmpty)
        }
    }

    @Test
    func `No preset keyword is dangerously short — substring matching needs ≥4 chars`() {
        // Substring matching against full hostnames is sloppy when the
        // token is short — `qq`, `mi`, `jd`, `163`, `360` would match
        // unrelated foreign domains. Enforce a minimum length so future
        // additions can't silently regress the safety bar.
        for entry in ChinaDirectKeywords.all {
            #expect(entry.keyword.count >= 4, "Keyword too short: \(entry.keyword)")
        }
    }

    @Test
    func `Preset has no duplicate (type,payload) keys`() {
        var seen = Set<String>()
        for rule in ChinaDirectKeywords.presetRules() {
            let key = "\(rule.type)|\(rule.payload)"
            #expect(!seen.contains(key), "Duplicate preset entry: \(key)")
            seen.insert(key)
        }
    }

    @Test
    func `Merging into an empty list inserts every preset row`() {
        let preset = ChinaDirectKeywords.presetRules()
        let (merged, added) = ChinaDirectKeywords.merge(preset: preset, into: [])
        #expect(added == preset.count)
        #expect(merged.count == preset.count)
    }

    @Test
    func `Re-merging the preset is idempotent (no duplicates)`() {
        let preset = ChinaDirectKeywords.presetRules()
        let (firstPass, addedFirst) = ChinaDirectKeywords.merge(preset: preset, into: [])
        let (secondPass, addedSecond) = ChinaDirectKeywords.merge(preset: preset, into: firstPass)
        #expect(addedFirst == preset.count)
        #expect(addedSecond == 0)
        #expect(secondPass.count == firstPass.count)
    }

    @Test
    func `Existing rules with the same (type,payload) suppress the preset row`() {
        let existing: [EditableRule] = [
            EditableRule(type: "DOMAIN-KEYWORD", payload: "weixin", proxy: "PROXY"),
            EditableRule(type: "MATCH", payload: "", proxy: "PROXY"),
        ]
        let preset = ChinaDirectKeywords.presetRules()
        let (merged, _) = ChinaDirectKeywords.merge(preset: preset, into: existing)

        // The user's own `weixin` rule (pointed at PROXY) must survive
        // unchanged; the preset's DIRECT version should NOT clobber it.
        let weixin = merged.filter { $0.type == "DOMAIN-KEYWORD" && $0.payload == "weixin" }
        #expect(weixin.count == 1)
        #expect(weixin.first?.proxy == "PROXY")
    }

    @Test
    func `Type comparison for dedup is case-insensitive`() {
        let existing: [EditableRule] = [
            EditableRule(type: "domain-keyword", payload: "alipay", proxy: "DIRECT"),
        ]
        let preset = ChinaDirectKeywords.presetRules()
        let (merged, _) = ChinaDirectKeywords.merge(preset: preset, into: existing)
        let alipay = merged.filter { $0.payload == "alipay" }
        #expect(alipay.count == 1, "lower-cased TYPE must still dedup against preset")
    }
}
