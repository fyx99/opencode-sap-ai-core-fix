# Upstream issues

**Filed:**
- (A) Registry — **anomalyco/models.dev#14467**: https://github.com/anomalyco/models.dev/issues/14467
- (B) Bridge — **anomalyco/opencode#66153**: https://github.com/anomalyco/opencode/issues/66153

Two places carry the durable fix. The registry change (A) is the smallest and fixes it for every
opencode user; the bridge change (B) is a more general hardening (so no V2-interface provider can
crash the session drain). The drafts that were filed are below.

---

## (A) models.dev — `sap-ai-core` should load the V3 provider package

**Repo:** https://github.com/sst/models.dev (provider/registry data)
**Title:** `sap-ai-core` provider pins the AI SDK V2 package → "Schema validation failed" in opencode ≥ 2.4

**Body:**

The `sap-ai-core` entry currently resolves to:

```
npm: @jerome-benoit/sap-ai-provider-v2
```

`@jerome-benoit/sap-ai-provider-v2` implements the AI SDK **V2** `LanguageModel` interface, where
`finishReason` is a plain string. opencode ≥ 2.4 consumes providers through the **V3 (v6)** interface,
where `finishReason` is an object `{ normalized, raw }` and `normalized` is validated against
`stop | length | tool-calls | content-filter | error | unknown`.

The AI SDK V2→V3 bridge maps the V2 string `"unknown"` (and any unmapped fallback) to
`unified: "other"`:

```js
convertV2FinishReasonToV3(finishReason) {
  return { unified: finishReason === "unknown" ? "other" : finishReason, raw: undefined };
}
```

`"other"` is **not** in opencode's step-finish enum, so every SAP AI Core turn fails with
`Error: Schema validation failed` / `Failed to drain Session` (fatal on tool-call turns).

**Fix:** point `sap-ai-core.npm` at the provider's V3/default package:

```
npm: @jerome-benoit/sap-ai-provider
```

Verified end-to-end against a live AI Core tenant (`gpt-6.1-sol`): with `@jerome-benoit/sap-ai-provider`,
both simple and tool-call turns succeed with no schema error. The same provider author publishes both
packages at the same version (`5.1.2`), so this is a one-field change.

---

## (B) opencode — V2→V3 finish-reason bridge emits a value absent from the step-finish schema

**Repo:** https://github.com/anomalyco/opencode
**Title:** Step-finish schema rejects `normalized: "other"` produced by the AI SDK V2→V3 finish-reason bridge

**Body:**

opencode's step-finish schema (`LLM.Event.StepFinish` → `LLM.FinishReasonDetails.normalized`) accepts:

```
stop | length | tool-calls | content-filter | error | unknown
```

But when a provider is loaded through the AI SDK **V2** interface, the bundled bridge
`convertV2FinishReasonToV3` can produce `unified: "other"` (e.g. for V2 `"unknown"` or any unmapped
reason). opencode then normalizes that to `"other"`, which its own schema rejects — aborting the
session drain:

```
message="Failed to drain Session"
cause: ... "path":["reason","normalized"] ...
  AnyOf: [stop|length|tool-calls|content-filter|error|unknown]   // received "other"
```

Repro: configure the `sap-ai-core` provider (which the registry pins to the V2 package
`@jerome-benoit/sap-ai-provider-v2`) and run any prompt; tool-call turns fail fatally.

**Suggested fix:** treat `"other"` as `"unknown"` when normalizing a finish reason (or add `"other"`
to the accepted enum), so a V2-interface provider cannot crash the session drain. Independently, the
`sap-ai-core` registry entry should prefer the provider's V3 package (see models.dev issue above).
