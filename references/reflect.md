# The reflection checkpoint

Read this when watch has printed `REFLECT`, or when the maintainer has just corrected the
route by hand. It is the executable half of "at the hundredth step, ask once whether this is
still what the maintainer wanted": a bounded, read-only inquiry beside the worker.

`oc_watch.sh` counts completed tools per worker (successful ones only) and prints `REFLECT`
once at 100 tools or 45 elapsed minutes, never in the worker's final ten minutes, and not again
until the inquiry it announced has finished.

When watch prints `REFLECT`, run the shown `oc_reflect.sh` command once. The inquiry has ten
tools and at most 390 seconds including wrapper backstops; it is not progress:

- `NO_ISSUE`: continue supervision.
- `CANNOT_JUDGE`: inspect the named sources instead of re-dispatching.
- `ROUTE_CORRECTION`: verify its exact quotes, then send only your correction with `oc_note.sh`.

A direct maintainer correction requires `oc_reflect.sh <run> <label> --trigger maintainer`.
Reflection is a reminder, not a pause: the worker keeps running and reads a correction only at
its next live-notes checkpoint. With a custom watch `--state`, pass the same path to reflection;
`oc_status.sh` reads only the default `<run>/.watch-state`.

The verdict lands as `reflect-<n>.json` next to the worker, a failed inquiry as `reflect-<n>.error`;
neither is re-dispatched by anything. `maintainer.md` in the run directory holds the maintainer's
exact words, which are the only text a `ROUTE_CORRECTION` may quote.
