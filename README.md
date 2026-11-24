# opencode + SAP AI Core — "Schema validation failed" fix

Using **SAP AI Core** models (e.g. `sap-ai-core/gpt-6.1-sol`, `sap-ai-core/anthropic--claude-4.6-sonnet`)
inside [opencode](https://github.com/anomalyco/opencode) **v2.4.1** fails on any non-trivial turn:

- every message ends with `Error: Schema validation failed`
- the server log shows `message="Failed to drain Session" ... LLM.Event.StepFinish`
- prompts that build a plan or call tools (e.g. *"create an A2A capable agent"*) die mid-turn —
  the questionnaire / plan never renders.

Third-party models (e.g. DeepSeek) work fine. The problem is specific to the SAP AI Core provider path.

## TL;DR — the fix

Point opencode's `sap-ai-core` provider at the provider's **V3 package** (`@jerome-benoit/sap-ai-provider`)
instead of the `-v2` package that the model registry pins by default. Add this to your opencode config
(`~/.config/opencode/opencode.json`, or a project-local `opencode.json`):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "sap-ai-core": {
      "npm": "@jerome-benoit/sap-ai-provider"
    }
  }
}
```

Restart the background service so it reloads the provider:

```bash
opencode service restart
```

Credentials are unchanged — keep using `AICORE_SERVICE_KEY` + `AICORE_RESOURCE_GROUP` exactly as before:

```bash
opencode service set env AICORE_SERVICE_KEY '{"clientid":"...","clientsecret":"...","url":"https://<tenant>.authentication.sap.hana.ondemand.com","serviceurls":{"AI_API_URL":"https://<host>.ml.hana.ondemand.com"}}'
opencode service set env AICORE_RESOURCE_GROUP 'default'
opencode service restart
```

That's it. No code patch, no fork of the provider required.

See [`examples/opencode.json`](examples/opencode.json) for the full config and
[`scripts/validate.sh`](scripts/validate.sh) for a reproducible before/after check.

## Root cause

opencode v2.4.1 consumes a language-model provider through the **AI SDK V3 (v6) `LanguageModel`
interface**. In that interface a finish event carries `finishReason` as an **object**
`{ normalized, raw }`, and opencode validates `normalized` against a fixed enum:

```
stop | length | tool-calls | content-filter | error | unknown
```

The opencode model registry ([models.dev](https://models.dev)) pins the SAP AI Core provider to the
**`-v2`** npm package, `@jerome-benoit/sap-ai-provider-v2`, which implements the **older V2 interface**
where `finishReason` is a plain **string**. The AI SDK bridges V2 → V3 with:

```js
// node_modules/ai/dist/index.js
convertV2FinishReasonToV3(finishReason) {
  return { unified: finishReason === "unknown" ? "other" : finishReason, raw: undefined };
}
```

So any V2 string that is `"unknown"` — or any fallback the provider can't classify — is turned into
`unified: "other"`. opencode then normalizes that to `"other"`, which **is not in its enum**, so
validation throws and the whole session drain aborts:

```
message="Failed to drain Session"
cause: ... "path":["reason","normalized"] ... AnyOf [stop|length|tool-calls|content-filter|error|unknown]
```

Simple one-shot replies sometimes surface it only as a trailing cosmetic `Error:`, but multi-step /
tool-call turns reliably hit a step whose finish reason maps to `"other"` and die — which is why
"build me a plan" / "create an agent" prompts break.

**The V2 interface is structurally incompatible with opencode 2.4.1.** No string value chosen by the
provider survives the bridge (even remapping the provider's fallback to `"unknown"` fails, because
`convertV2FinishReasonToV3` maps `"unknown"` straight back to `"other"`). The provider's **V3/default**
build emits the native `{ unified, raw }` object opencode expects, so switching the entrypoint is the fix.

## Is this the right provider? (vs. litellm etc.)

Yes. `@jerome-benoit/sap-ai-provider` is a first-class AI SDK provider that opencode already
auto-loads, and it handles SAP AI Core auth (XSUAA / service key), orchestration, foundation-models
and the responses API natively. A litellm proxy would add a separate process and lose the native
AI Core orchestration integration. The defect here is a one-line interface/wiring mismatch, not an
architecture problem — no rewrite and no proxy needed.

## Validated

Reproduced and fixed end-to-end against a live SAP AI Core tenant with `gpt-6.1-sol`:

| Case | `-v2` (default) | `@jerome-benoit/sap-ai-provider` (V3, this fix) |
|------|-----------------|--------------------------------------------------|
| `reply with exactly: PONG` | `PONG` + `Error: Schema validation failed` | `PONG`, clean |
| `say hi` | `Hi` + `Error: Schema validation failed` | `Hi`, clean |
| tool-call turn (`ls` + describe) | `Failed to drain Session`, aborts | tool runs, answer renders, clean |

## The proper upstream fix

The durable fix belongs in opencode's model registry: the `sap-ai-core` entry on
[models.dev](https://models.dev) should load `@jerome-benoit/sap-ai-provider` (V3), not
`@jerome-benoit/sap-ai-provider-v2`. Alternatively opencode's V2→V3 finish-reason bridge should not
collapse unmapped/`"unknown"` reasons to `"other"` (a value absent from its own step-finish schema).

A ready-to-file issue is in [`docs/upstream-issue.md`](docs/upstream-issue.md).

## Credits

Diagnosis by decoding the opencode `effect` schema error, live-instrumenting the provider's
finish-reason path, and tracing the AI SDK V2→V3 bridge.
