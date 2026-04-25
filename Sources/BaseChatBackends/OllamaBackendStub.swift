// Compile-time helper: when the `Ollama` trait is disabled, the
// `OllamaBackend` symbol does not exist. Without this stub, downstream
// callers see only a generic "cannot find type 'OllamaBackend' in scope"
// error. The `#warning` below makes the cause and fix explicit.
//
// `Ollama` IS in the default trait set this release; consumers who
// explicitly disable defaults via `--disable-default-traits` get the
// warning. The trait moves out of defaults in the next major release —
// at that point this stub becomes the primary fix-it for first-time users.
#if !Ollama
#warning("OllamaBackend requires the Ollama trait. Add `traits: [\"Ollama\"]` to your .package(...) entry — see CHANGELOG migration notes.")
#endif
