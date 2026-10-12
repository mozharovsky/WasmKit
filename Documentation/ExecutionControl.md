# Cooperative execution control

This release line builds on WasmKit 0.4.2. It retains an independently writable stop signal for a
single store and accepts SwiftSyntax 604 for consumers using Swift 6.4.

Create an `ExecutionControl` and pass it to `Store(engine:executionControl:)`. The engine may use
token or direct threading. A controller can be claimed only once, including after its store has
been released. The first interruption reason permanently retires that store. Only the controller
crosses threads. The store and its functions keep their serial execution requirements.

## Polling

A token-threaded store polls between groups of at most `pollingInterval` token dispatches.
Superinstructions can represent several WebAssembly operations in one dispatch.

A direct-threaded store polls at checkpoints that translation places in the guest code, and it
counts WebAssembly operators. Every reachable operator of a function body counts once. This
includes `nop`, `drop`, `block`, `loop`, `else`, `end`, `return` and `unreachable`, which fuel
metering leaves free. Checkpoints sit at function entries, loop headers, `if` arms, after calls,
at the end labels of blocks that contain a checkpoint, and every `pollingInterval` operators of
straight-line code. Each checkpoint charges the operators of the code up to the next one against a
budget in the store before that code runs. A poll reads the controller and refills the budget less
the code that resumes. From one poll to the next, the guest therefore runs at most
`pollingInterval` operators. The budget carries across calls, nested host entries and resumable
pauses.

The default interval is 1,024 for either model. The two models count different units, so the same
value allows different amounts of work. Neither count is a wall-clock deadline. Work inside one
operator, such as copying block results or a call's arguments, counts as that operator.

Export entry and completion, native import return, and caught guest exceptions also check the
controller. On a token-threaded store, debugger entry, resume, and steps check it too. A stop takes precedence over host results, host
errors, and result validation. A guest trap raised before the next check is reported as that trap.

## Resumable invocations

Resumable invocations check the controller at entry, when a host call returns, throws, or asks to
pause, and before their results return. A stop outranks a host function's request to pause. A
resume checks the controller before it judges the completion, so a stop also outranks a stale,
foreign, or mistyped answer. A resumed invocation continues under the polling of its store. A
direct-threaded store continues with the budget that the pause left, and refused completions,
cancellation and dropping the invocation leave that budget unchanged. The controller does not
release a paused invocation. Its owner resumes or cancels the continuation, and a resume after a
stop throws the stop's reason.

## Native work

The host owns timers and requests `deadlineExceeded` when its deadline expires. Parsing,
translation, native imports, bulk memory operations, memory growth and blocking atomic waits must
return before interruption can unwind them. A host import that is running when the stop arrives
completes, and the store checks the controller when it returns, before its results reach the
guest. The controller does not preempt native code or coordinate separate stores.

## Configurations

A controller works with token threading, which checks bounds in software, and with direct
threading under software, mprotect or the platform's default bounds. Fuel metering combines with
either model. Fuel keeps its own prices, remaining budget, refills and `outOfFuel` trap, and the
controller neither reads nor refills it.

Two uses of a direct-threaded store with a controller are refused, because their code would run
outside the controller's reach.

- A debuggable instance is translated without checkpoints. `Module.instantiate(store:imports:isDebuggable:)`
  with `isDebuggable: true` and the debugger refuse it and throw `unsupportedThreadingModel`
  before any guest code runs. Debugging a controlled token store or an uncontrolled direct store
  is unchanged.
- A WASI threads worker runs in a fresh store of its own, which a stop of the spawning store would
  not reach. `WASIThreads.makeImports(store:)` refuses any store with a controller and throws
  `WASIThreadsError.controlledStore` before it builds an import, so the guest cannot reach
  `thread-spawn`. Shared memories and atomics remain available to a controlled direct store.

Ordinary stores retain upstream token and direct execution. The fork's tests exercise ordinary
execution alongside controlled stores, including the upstream specification fixtures on
controlled token stores and on controlled direct stores with software and mprotect bounds.
