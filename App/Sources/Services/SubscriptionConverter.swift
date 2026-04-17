import Foundation

/// Normalizes a raw subscription body into Clash YAML. The authoritative
/// converter is Rust — `meow_engine_convert_subscription` handles Clash YAML
/// passthrough, base64-wrapped v2rayN URI lists, and plain URI lists. Tests
/// inject a stub to simulate fetch responses without hitting the network.
protocol SubscriptionConverter: Sendable {
    func convert(_ body: Data) async throws -> String
}

/// Default converter: forwards the body to the Rust FFI.
struct ClashYAMLConverter: SubscriptionConverter {
    func convert(_ body: Data) async throws -> String {
        return try body.withUnsafeBytes { raw -> String in
            guard let base = raw.baseAddress else {
                throw SubscriptionError.decodeFailed
            }
            let ptr = base.assumingMemoryBound(to: CChar.self)
            let len = Int32(raw.count)

            // First pass: probe required buffer size.
            let needed = meow_engine_convert_subscription(ptr, len, nil, 0)
            if needed < 0 {
                throw SubscriptionError.conversionFailed(lastCoreError())
            }
            let cap = Int(needed) + 1
            var buffer = [CChar](repeating: 0, count: cap)
            let wrote = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                meow_engine_convert_subscription(ptr, len, buf.baseAddress, Int32(cap))
            }
            if wrote < 0 {
                throw SubscriptionError.conversionFailed(lastCoreError())
            }
            return String(cString: buffer)
        }
    }
}

private func lastCoreError() -> String {
    if let cstr = meow_core_last_error() { return String(cString: cstr) }
    return "unknown error"
}
