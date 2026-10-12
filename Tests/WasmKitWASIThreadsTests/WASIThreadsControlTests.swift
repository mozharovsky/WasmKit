#if os(macOS) || os(Linux)
    import Foundation
    import Synchronization
    import Testing
    import WAT
    import WasmKit
    import WasmKitWASIThreads

    /// Checks of WASI threads for stores with an execution controller.
    ///
    /// A worker runs in a store of its own, which a stop of the spawning store would not reach. A
    /// store with a controller therefore gets no `thread-spawn` import, while shared memory and
    /// atomics stay available to it.
    @Suite(.enabled(if: Engine().configuration.memoryBoundsChecking == .mprotect))
    struct WASIThreadsControlTests {
        /// A guest whose worker counts in shared memory until the flag at offset 4 is set.
        static let wat = """
            (module
              (import "env" "memory" (memory 1 1 shared))
              (import "wasi" "thread-spawn" (func $spawn (param i32) (result i32)))
              (func (export "wasi_thread_start") (param i32 i32)
                (loop $spin
                  (drop (i32.atomic.rmw.add (i32.const 0) (i32.const 1)))
                  (br_if $spin (i32.eqz (i32.atomic.load (i32.const 4))))))
              (func (export "run") (result i32) (call $spawn (i32.const 0)))
              (func (export "count") (result i32) (i32.atomic.load (i32.const 0)))
              (func (export "finish") (i32.atomic.store (i32.const 4) (i32.const 1))))
            """

        /// Refuses the imports of a controlled store before the child imports are built, and leaves
        /// the group's only worker slot to an uncontrolled store.
        ///
        /// The group allows one worker beside the main thread. An uncontrolled store spawns it
        /// after the refusal, so the refusal reserved no slot and started no worker. The refused
        /// store keeps its controller and still runs shared memory atomics of its own.
        ///
        /// - Parameter model: The dispatch model of the controlled store.
        /// - Throws: Fixture construction or invocation failures.
        @Test(arguments: [EngineConfiguration.ThreadingModel.direct, .token])
        func aControlledStoreGetsNoThreadSpawn(model: EngineConfiguration.ThreadingModel) throws {
            let engine = Engine(configuration: .init(threadingModel: .direct, features: [.threads]))
            let module = try parseWasm(bytes: try wat2wasm(Self.wat, features: [.threads]), features: [.threads])
            let builds = Mutex(0)
            let threads = try WASIThreads(
                module: module,
                engine: engine,
                configuration: WASIThreadsConfiguration(maximumThreads: 2),
                processControl: .init(
                    terminateAfterMainReturn: { _ in fatalError("not reached") },
                    terminateAfterWorkerFailure: { error in fatalError("unexpected worker failure: \(error)") }
                ),
                childImports: { _ in
                    builds.withLock { $0 += 1 }
                    return Imports()
                }
            )

            let control = try ExecutionControl()
            let controlled = try Store(
                engine: Engine(configuration: .init(threadingModel: model, features: [.threads])),
                executionControl: control)
            #expect {
                _ = try threads.makeImports(store: controlled)
            } throws: { error in
                guard case WASIThreadsError.controlledStore = error else { return false }
                return true
            }
            #expect(builds.withLock { $0 } == 0)
            #expect(control.termination == nil)
            // Only a direct engine with mprotect bounds backs a shared memory.
            let memory = model == .direct ? "(memory 1 1 shared)" : "(memory 1 1)"
            let atomics = try parseWasm(
                bytes: try wat2wasm(
                    """
                    (module \(memory)
                      (func (export "add") (result i32) (i32.atomic.rmw.add (i32.const 0) (i32.const 5))))
                    """, features: [.threads]), features: [.threads]
            ).instantiate(store: controlled)
            let add = try #require(atomics.exports[function: "add"])
            _ = try add()
            #expect(try add() == [.i32(5)])

            let store = Store(engine: engine)
            let instance = try module.instantiate(store: store, imports: threads.makeImports(store: store))
            #expect(builds.withLock { $0 } == 1)
            let run = try #require(instance.exports[function: "run"])
            let count = try #require(instance.exports[function: "count"])
            let finish = try #require(instance.exports[function: "finish"])
            #expect(try run() == [.i32(1)])
            #expect(try run() == [.i32(UInt32(bitPattern: -1))])
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while try count() == [.i32(0)], ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            #expect(try count() != [.i32(0)])
            try finish()
        }
    }
#endif
