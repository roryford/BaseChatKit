import Darwin
import Foundation

/// Stores a secret string in a heap-allocated mutable buffer that is zeroed
/// via `memset_s` on deallocation.
///
/// This reduces the window during which API keys linger in freed memory once a
/// backend is unloaded or reconfigured. `memset_s` is used instead of plain
/// `memset` because the C standard allows optimising-compilers to elide a
/// `memset` call whose result is never read; `memset_s` carries a conformance
/// obligation that prevents that elision.
///
/// **Scope of the guarantee**: only the bytes owned by this object are zeroed.
/// Any `String` value returned by ``stringValue`` is a separate Swift-managed
/// copy and is not covered.
final class SecureBytes: @unchecked Sendable {

    private let buffer: UnsafeMutableBufferPointer<UInt8>

    init?(_ string: String) {
        let utf8 = string.utf8
        guard !utf8.isEmpty else { return nil }
        buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: utf8.count)
        _ = buffer.initialize(from: utf8)
    }

    /// Returns the stored bytes decoded as a UTF-8 string.
    var stringValue: String {
        String(decoding: buffer, as: UTF8.self)
    }

    deinit {
        _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
        buffer.deallocate()
    }
}
