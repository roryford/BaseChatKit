# Adversarial tool-call fixtures for OllamaBackend

Each `<name>.json` is **one** Ollama NDJSON line (not a full stream — for
full streams see `Tests/Fixtures/ollama/tool-calls/<version>/`). Each
`<name>.expected.json` describes the outcome a compliant parser must
produce when fed that one line through `OllamaBackend.parseResponseStream`
with the line terminated by `"done":true` on the next chunk.

## expected.json shape

```json
{
  "should_emit": true | false,          // whether a .toolCall event is emitted
  "event_type": "toolCall" | null,       // event kind (room for future kinds)
  "tool_name": "get_weather" | null,     // for .toolCall: the tool invoked
  "arguments_contains": "city" | null,   // substring that must appear in arguments
  "should_log_warning": true | false,    // whether parser should log a warning
  "notes": "optional free-form explanation"
}
```

See `OllamaAdversarialJSONTests` for the replay harness that consumes
these fixtures.
