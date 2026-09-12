## Reflection question

Judge the route, not the quality of the implementation.

1. Is the current work required by `prompt.md`?
2. Was a direct maintainer correction bypassed?
3. Do the last 40 completed tools show repeated work at the same point?
4. What is the next concrete step?

Return exactly one JSON object. Allowed verdicts are `NO_ISSUE`, `ROUTE_CORRECTION`, and
`CANNOT_JUDGE`. Every verdict needs a non-empty `reason`. `ROUTE_CORRECTION` also needs a
non-empty `next_step` and at least one exact quote as
`{"source":"maintainer.md|prompt.md|NOTES.md","text":"verbatim text"}`. Quote only text
present in the named source; never paraphrase. Use `CANNOT_JUDGE` when no maintainer words
support a route judgement.

The exact shape, with no other keys:

```json
{"verdict": "NO_ISSUE | ROUTE_CORRECTION | CANNOT_JUDGE", "reason": "...",
 "next_step": "...", "quotes": [{"source": "maintainer.md", "text": "..."}]}
```
