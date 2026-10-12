# Cooperative execution control

This release line builds on WasmKit 0.4.2. It retains an independently writable stop signal for a
single store and accepts SwiftSyntax 604 for consumers using Swift 6.4.

Create an `ExecutionControl`, configure an engine for token threading, and pass the controller to
`Store(engine:executionControl:)`. A controller can be claimed only once, including after its store
has been released. The first interruption reason permanently retires that store.

The interpreter polls between groups of at most `pollingInterval` token dispatches. The default is
1,024 dispatches. Superinstructions can represent several WebAssembly operations, so the interval
is neither an instruction count nor a wall-clock deadline. Export entry and completion, native
import return, caught guest exceptions, and debugger entry, resume, and steps also check the
controller.
A stop takes precedence over host results, host errors, and result validation.

Resumable invocations check the controller at entry, when a host call returns, throws, or asks to
pause, and before their results return. A stop outranks a host function's request to pause. A
resume checks the controller before it judges the completion, so a stop also outranks a stale,
foreign, or mistyped answer. A resumed invocation continues in the polling loop. The controller
does not release a paused invocation. Its owner resumes or cancels the continuation, and a resume
after a stop throws the stop's reason.

The host owns timers and requests `deadlineExceeded` when its deadline expires. Parsing,
translation, native imports, and blocking atomic waits must return before interruption can unwind
them. The controller does not preempt native code or coordinate separate stores. WASI thread
spawning requires direct threading and cannot be combined with a controlled token store.

Ordinary stores retain upstream token and direct execution. Passing a controller to a direct engine
throws `unsupportedThreadingModel` before the controller is claimed. The fork's tests exercise
ordinary execution alongside controlled stores, including the upstream specification fixtures.
