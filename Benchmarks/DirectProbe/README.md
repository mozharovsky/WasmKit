# Direct execution probe

This directory compares WasmKit's two dispatch models on Release Swift-WASM. Token dispatch runs
with and without an `ExecutionControl`. Direct dispatch runs without one, because a controlled
store accepts only token dispatch. The comparison holds every other setting equal. Each variant
translates lazily, uses the default stack and software memory bounds, and runs without fuel. A
separate measurement shows direct dispatch with mprotect bounds, so that a bounds effect is not
counted as a dispatch effect.

`Guest` is a small Swift package built for `wasm32-unknown-wasip1` in Release. It exports
workloads with computation and branches, Swift collections and generics, strings, a short export
for batches of calls, a loop over host imports, and a longer action that grows memory while it
passes buffers to the host. `Workloads.swift` is also compiled natively into the harness, which
computes the expected answer of every call from it.

`Host` is the harness. Its modes are the following.

- `verify` runs every export over several inputs on every variant, compares each answer with the
  native result and with the other variants, and checks host-side counters and memory growth.
- `warm` runs paired rounds. Each round runs every variant in a rotating order with the same
  warm-up, and every sample checks its answer. Short calls are timed in batches.
- `cold` measures one fresh process: parsing, instantiation, initialization, and the first and
  second call of each export.
- `spin` keeps one variant busy so that a sampler can confirm which dispatch loop runs.

`scripts/run.py` runs the modes and the WasmiBenchmarks replay in sequence on one machine, each
child under a time limit. `scripts/analyze.py` forms every ratio inside one round before it
summarizes the rounds. `ci.env` holds the sizes and repetitions that the CI workflow uses.

Local use needs the standalone Swift 6.4.0 release with its WebAssembly SDK and Xcode 27.

```sh
swift build -c release --swift-sdk swift-6.4.0-RELEASE_wasm --package-path Guest
xcrun swift build -c release --package-path Host
python3 scripts/run.py --bench Host/.build/release/DirectProbeBench \
  --wasm "$(swift build -c release --swift-sdk swift-6.4.0-RELEASE_wasm --package-path Guest --show-bin-path)/ProbeGuest.wasm" \
  --out results
python3 scripts/analyze.py results
```

The variants without a controller are only meant for this bench, which runs finite trusted inputs
under an external time limit.
