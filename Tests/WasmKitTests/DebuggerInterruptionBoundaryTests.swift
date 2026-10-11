#if WasmDebuggingSupport
    import Testing
    import WAT

    @testable import WasmKit

    /// Completion checks for debugger entry and resume paths that bypass Function.invoke.
    @Suite
    struct DebuggerInterruptionBoundaryTests {
        /// Rejects a stopped debugger before it invokes an entrypoint backed by native code.
        ///
        /// - Throws: Fixture construction, debugger setup, or an unexpected execution failure.
        @Test
        func stoppedDebuggerDoesNotEnterHostExport() throws {
            let control = try ExecutionControl()
            let store = try Store(engine: Engine(configuration: EngineConfiguration(threadingModel: .token)), executionControl: control)
            var hostEntries = 0
            var imports = Imports()
            imports.define(
                module: "host", name: "start",
                Function(store: store, parameters: []) { _, _ in
                    hostEntries += 1
                    return []
                })
            let module = try parseWasm(bytes: wat2wasm("(module (import \"host\" \"start\" (func $start)) (export \"_start\" (func $start)))"))
            var debugger = try Debugger(module: module, store: store, imports: imports)
            control.requestInterruption()
            do {
                try debugger.run()
                Issue.record("The stopped debugger entered its native export.")
            } catch let reason as ExecutionTermination {
                #expect(reason == .interrupted)
            }
            #expect(hostEntries == 0)
        }

        /// Keeps an armed breakpoint intact when termination rejects a pending resume.
        ///
        /// - Throws: Fixture construction, debugger setup, or an unexpected execution failure.
        @Test
        func stoppedDebuggerKeepsItsBreakpoint() throws {
            let control = try ExecutionControl()
            let store = try Store(engine: Engine(configuration: EngineConfiguration(threadingModel: .token)), executionControl: control)
            let module = try parseWasm(bytes: wat2wasm("(module (func (export \"_start\")))"))
            var debugger = try Debugger(module: module, store: store, imports: [:])
            try debugger.stopAtEntrypoint()
            try debugger.run()
            guard case .stoppedAtBreakpoint = debugger.state else {
                Issue.record("The debugger did not stop at its entrypoint.")
                return
            }
            let armed = debugger.armedBreakpointAddresses
            control.requestInterruption()
            do {
                try debugger.run()
                Issue.record("The stopped debugger resumed guest execution.")
            } catch let reason as ExecutionTermination {
                #expect(reason == .interrupted)
            }
            #expect(debugger.armedBreakpointAddresses == armed)
        }

        /// Observes interruption requested in the final dispatch group before debugger success.
        ///
        /// - Parameters:
        ///   - resumed: Whether execution first stops at the entrypoint breakpoint.
        ///   - interrupted: Whether the final function-exit interceptor requests termination.
        /// - Throws: Fixture construction, debugger setup, or an unexpected execution failure.
        @Test(arguments: [false, true], [false, true])
        func completionChecksTheLastDispatchGroup(resumed: Bool, interrupted: Bool) throws {
            let control = try ExecutionControl(pollingInterval: .max)
            let interceptor = DebuggerExitInterruption(control: interrupted ? control : nil)
            let engine = Engine(
                configuration: EngineConfiguration(threadingModel: .token, compilationMode: .lazy),
                interceptor: interceptor
            )
            let store = try Store(engine: engine, executionControl: control)
            let module = try parseWasm(bytes: wat2wasm("(module (func (export \"_start\") (result i32) i32.const 42))"))
            var debugger = try Debugger(module: module, store: store, imports: [:])
            if resumed {
                try debugger.stopAtEntrypoint()
                try debugger.run()
                guard case .stoppedAtBreakpoint = debugger.state else {
                    Issue.record("The debugger did not stop before its first instruction.")
                    return
                }
                #expect(interceptor.exitCount == 0)
            }
            if interrupted {
                do {
                    try debugger.run()
                    Issue.record("The debugger reported completion after its controller stopped.")
                } catch let reason as ExecutionTermination {
                    #expect(reason == .interrupted)
                }
                if case .entrypointReturned = debugger.state {
                    Issue.record("An interrupted debugger entrypoint was marked successful.")
                }
            } else {
                try debugger.run()
                guard case .entrypointReturned(let values) = debugger.state else {
                    Issue.record("The live debugger entrypoint did not finish.")
                    return
                }
                #expect(values == [.i32(42)])
            }
            #expect(interceptor.exitCount == 1)
        }

        /// The ways a stopped debugger runs guest code without taking its breakpoint out.
        enum Step: CaseIterable, Sendable {
            /// A single step with ``Debugger/step()``.
            case step
            /// A resume with ``Debugger/runPreservingCurrentBreakpoint()``.
            case runPreservingBreakpoint
        }

        /// Rejects a step from a stopped debugger before the step enters a host import.
        ///
        /// A step runs instructions without the run loop, so only the entry check keeps the host
        /// from running.
        ///
        /// - Parameter step: How the debugger runs guest code from its breakpoint.
        /// - Throws: Fixture construction, debugger setup, or an unexpected execution failure.
        @Test(arguments: Step.allCases)
        func stoppedDebuggerDoesNotStepIntoHostImport(step: Step) throws {
            let control = try ExecutionControl()
            let store = try Store(engine: Engine(configuration: EngineConfiguration(threadingModel: .token)), executionControl: control)
            var hostEntries = 0
            var imports = Imports()
            imports.define(
                module: "host", name: "call",
                Function(store: store, parameters: [.i32], results: [.i32]) { _, arguments in
                    hostEntries += 1
                    return [.i32(arguments[0].i32 &+ 1)]
                })
            let module = try parseWasm(
                bytes: wat2wasm(
                    """
                    (module
                      (import "host" "call" (func $call (param i32) (result i32)))
                      (func (export "_start") (result i32) (i32.const 7) (call $call)))
                    """))
            var debugger = try Debugger(module: module, store: store, imports: imports)
            // The call follows the two bytes of `i32.const 7`.
            let callSite = try debugger.enableBreakpoint(address: module.functions[0].code.originalAddress + 2)
            try debugger.run()
            guard case .stoppedAtBreakpoint(let stop) = debugger.state, stop.wasmPc == callSite else {
                Issue.record("The debugger did not stop at the host call.")
                return
            }
            let armed = debugger.armedBreakpointAddresses
            control.requestInterruption()
            do {
                switch step {
                case .step: try debugger.step()
                case .runPreservingBreakpoint: try debugger.runPreservingCurrentBreakpoint()
                }
                Issue.record("The stopped debugger stepped guest code.")
            } catch let reason as ExecutionTermination {
                #expect(reason == .interrupted)
            }
            #expect(hostEntries == 0)
            #expect(debugger.armedBreakpointAddresses == armed)
        }

        /// Observes interruption requested by the entrypoint's exit when a step completes it.
        ///
        /// - Parameter interrupted: Whether the function-exit interceptor requests termination.
        /// - Throws: Fixture construction, debugger setup, or an unexpected execution failure.
        @Test(arguments: [false, true])
        func steppedCompletionChecksTheEntrypointReturn(interrupted: Bool) throws {
            let control = try ExecutionControl(pollingInterval: .max)
            let interceptor = DebuggerExitInterruption(control: interrupted ? control : nil)
            let engine = Engine(
                configuration: EngineConfiguration(threadingModel: .token, compilationMode: .lazy),
                interceptor: interceptor
            )
            let store = try Store(engine: engine, executionControl: control)
            let module = try parseWasm(bytes: wat2wasm("(module (func (export \"_start\") (result i32) i32.const 42))"))
            var debugger = try Debugger(module: module, store: store, imports: [:])
            try debugger.stopAtEntrypoint()
            try debugger.run()
            var steps = 0
            do {
                while case .stoppedAtBreakpoint = debugger.state, steps < 8 {
                    try debugger.step()
                    steps += 1
                }
                #expect(!interrupted, "A step reported completion after its controller stopped.")
            } catch let reason as ExecutionTermination {
                #expect(interrupted)
                #expect(reason == .interrupted)
            }
            if interrupted {
                if case .entrypointReturned = debugger.state {
                    Issue.record("An interrupted stepped entrypoint was marked successful.")
                }
            } else {
                guard case .entrypointReturned(let values) = debugger.state else {
                    Issue.record("The live stepped entrypoint did not finish.")
                    return
                }
                #expect(values == [.i32(42)])
            }
            #expect(interceptor.exitCount == 1)
        }
    }

    /// Requests stop after the final guest function has executed its ordinary instructions.
    private final class DebuggerExitInterruption: EngineInterceptor {
        /// The optional controller leaves the paired normal-completion case uninterrupted.
        private let control: ExecutionControl?
        /// The number of exits verifies that a breakpoint resume reaches the same function once.
        private(set) var exitCount = 0

        /// Captures the signal without changing the interpreter's control-flow shape.
        ///
        /// - Parameter control: The controller to stop at exit, or nil for the normal control.
        init(control: ExecutionControl?) {
            self.control = control
        }

        /// Leaves entry and breakpoint handling unchanged before the measured final group.
        ///
        /// - Parameter function: The guest function entering its native interceptor boundary.
        func onEnterFunction(_ function: Function) {}

        /// Signals before the remaining return and EndOfExecution instructions dispatch.
        ///
        /// - Parameter function: The guest function whose final instructions have completed.
        func onExitFunction(_ function: Function) {
            exitCount += 1
            control?.requestInterruption()
        }
    }
#endif
