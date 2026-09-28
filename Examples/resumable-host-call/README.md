# Resumable host call

This example runs a guest compiled from Swift on a worker actor. The guest calls an imported
`measure` function with an ordinary synchronous signature. The host function pauses the
invocation with `HostCallSuspension`, and the worker awaits a measurement that only the main
actor may perform. The worker answers other messages during that wait. It then continues the
same invocation with the reading through `SuspendedCall.resume(returning:completing:in:)`.

The worker keeps at most one paused invocation, because a guest compiled from Swift keeps a
shadow stack in its linear memory. Cancelling a paused invocation releases it. A reading that
arrives afterwards is refused, either by the worker or by WasmKit when another invocation has
paused in the meantime. When the evaluating task is cancelled, the worker checks for that before
it continues the guest, so a reading that returns faster than the cancellation handler is refused
too. Cancellation is cooperative and does not undo a measurement that already ran.

## Building the guest

The guest in `Guest/resumable_guest.swift` needs a Swift release toolchain and the WebAssembly
Swift SDK of the same release. The script defaults to Swift 6.3.2 and writes the module to
`.build/guest/resumable_guest.wasm`.

```sh
SWIFT_TOOLCHAIN=~/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain \
SWIFT_SDK=swift-6.3.2-RELEASE_wasm \
    Guest/build.sh
```

## Running

```sh
swift run resumable-host-call
swift test
```

The first part of the output shows one invocation that pauses three times. The main actor asks
the worker for the guest's progress before each measurement, and the worker answers while the
invocation is paused. The result matches the native reference.

```text
1. evaluate(3) pauses at each measure call and continues with the main actor's reading
  1. started(count: 3)
  2. paused(input: 30)
  3. answeredWhilePaused(completedSteps: 0)
  4. measured(input: 30, reading: 907)
  5. delivering(reading: 907)
  6. noted(step: 0)
  ...
  17. finished(result: 8842)
result 8842, native reference 8842
guest completed steps 3, main actor measured [30, 31, 32]
```

The second part cancels an invocation while its measurement runs and starts another one. The
late reading reaches WasmKit while the new invocation is paused, and WasmKit refuses it as stale.
The new invocation then continues with its own reading.

```text
late reading: refused(WasmKit.ResumeRejection.staleSuspension)
  ...
  7. measured(input: 20, reading: 407)
  8. delivering(reading: 407)
  9. refusedLateReading(reading: 407)
  ...
  14. finished(result: 214)
next invocation result 214, native reference 214
```

The third part cancels the evaluating task inside the measurement, just before the reading
returns. The worker refuses the reading and the guest's step count stays the same.

```text
3. A task cancelled just before a fast reading returns does not continue the guest
cancelled evaluation: cancelled
  ...
  4. measured(input: 10, reading: 107)
  5. cancelled(input: 10)
  6. refusedLateReading(reading: 107)
guest completed steps 4 before and 4 after, still paused: false
```

The tests run each scenario under both dispatch models and bound every wait with a deadline.
