import Foundation

/// Swift-friendly wrapper around the Go-exported C symbols in mihomo_go.h.
/// Isolated behind `MIHOMO_GO_LINKED` so the Swift side still compiles before
/// the XCFramework is produced — all call sites gracefully fall back when the
/// native lib is not linked.
enum MihomoGoBridge {
    static func convertSubscription(_ raw: Data) throws -> String {
        #if MIHOMO_GO_LINKED
        let capacity = 1 << 20
        var outBuf = [CChar](repeating: 0, count: capacity)
        let written: Int32 = raw.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Int32 in
            guard let base = rawBuf.baseAddress else { return -1 }
            return base.withMemoryRebound(to: CChar.self, capacity: rawBuf.count) { src in
                meowConvertSubscription(src, Int32(rawBuf.count), &outBuf, Int32(capacity))
            }
        }
        if written < 0 { throw SubscriptionError.conversionFailed(MihomoErrorReader.read()) }
        return String(cString: outBuf)
        #else
        throw SubscriptionError.conversionFailed("Go bridge not linked")
        #endif
    }
}
