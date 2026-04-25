// Compile-time helper: when the `CloudSaaS` trait is disabled, the
// `ClaudeBackend` symbol does not exist. Without this stub, downstream
// callers see only a generic "cannot find type 'ClaudeBackend' in scope"
// error. The `#warning` below makes the cause and fix explicit.
//
// When `CloudSaaS` IS enabled, this file is empty and `ClaudeBackend.swift`
// supplies the real type.
#if !CloudSaaS
#warning("ClaudeBackend requires the CloudSaaS trait. Add `traits: [\"CloudSaaS\"]` to your .package(...) entry — see CHANGELOG migration notes.")
#endif
