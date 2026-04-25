// Compile-time helper: when the `CloudSaaS` trait is disabled, the
// `OpenAIBackend` symbol does not exist. Without this stub, downstream
// callers see only a generic "cannot find type 'OpenAIBackend' in scope"
// error. The `#warning` below makes the cause and fix explicit.
//
// When `CloudSaaS` IS enabled, this file is empty and `OpenAIBackend.swift`
// supplies the real type.
#if !CloudSaaS
#warning("OpenAIBackend requires the CloudSaaS trait. Add `traits: [\"CloudSaaS\"]` to your .package(...) entry — see CHANGELOG migration notes.")
#endif
