import Foundation
import Testing
import WASTRunner
import WasmKit

@Suite
struct SpectestTests {
    static let projectDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let testsuite =
        projectDir
        .appendingPathComponent("Vendor/testsuite")
    /// Whether the default engine can back a shared memory here (requires mprotect: not ASan,
    /// not token threading, 64-bit macOS/Linux).
    static let sharedMemorySupported: Bool = {
        // A shared memory type only validates with the threads feature.
        var configuration = EngineConfiguration()
        configuration.features.insert(.threads)
        let store = Store(engine: Engine(configuration: configuration))
        return (try? Memory(store: store, type: MemoryType(min: 1, max: 1, shared: true))) != nil
    }()

    static var testPaths: [String] {
        return [
            // Wasm 3.0, which includes memory64, tail calls, exception handling, extended
            // constant expressions, relaxed SIMD, typed function references and multi-memory.
            Self.testsuite.path,
            Self.testsuite.appendingPathComponent("custom").path,
            Self.testsuite.appendingPathComponent("proposals/wide-arithmetic").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/memory64").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/function-references").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/multi-memory").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/fuel").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/gc").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/annotations").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/wide-arithmetic").path,
        ]
    }

    /// The threads proposal tests declare shared memories, so they are skipped where one
    /// cannot be created. Token threading never has one, as it checks bounds in software.
    static var sharedMemoryTestPaths: [String] {
        guard sharedMemorySupported else { return [] }
        return [
            Self.testsuite.appendingPathComponent("proposals/threads").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite/multi-memory/threads").path,
        ]
    }

    static func testCases(in paths: [String]) throws -> [TestCase] {
        var exclude = SpectestDiscovery(path: []).exclude
        exclude += UnsupportedSpectests.files.map { "Vendor/testsuite/\($0)" }
        return try SpectestDiscovery(path: paths, exclude: exclude).discover()
    }

    static func run(
        test: TestCase, configuration: EngineConfiguration, executionControl: ExecutionControl? = nil
    ) throws {
        let skip =
            UnsupportedSpectests.directives.first { test.path.hasSuffix("Vendor/testsuite/\($0.key)") }?.value ?? [:]
        try SpectestRunner(configuration: configuration)
            .run(
                test: test, reporter: NullSpectestProgressReporter(), skip: skip,
                executionControl: executionControl)
    }

    #if !os(Android)
        /// Exercises every specification case that token threading runs through a live
        /// grouped-dispatch store.
        ///
        /// - Parameter test: A specification fixture with its own store and controller lifetime.
        /// - Throws: Fixture construction or specification conformance failures.
        @Test(arguments: try SpectestTests.testCases(in: SpectestTests.testPaths))
        func runWithExecutionControl(test: TestCase) throws {
            try Self.run(
                test: test, configuration: EngineConfiguration(threadingModel: .token),
                executionControl: ExecutionControl()
            )
        }

        /// Exercises every specification case through a direct-threaded store with a live
        /// controller, with software bounds.
        ///
        /// An interval of one ends a control segment after every operator, so a checkpoint sits
        /// between almost every two operators and the poll runs at every other one. A fusion or an
        /// accumulator hand-off that a checkpoint broke would change a result here.
        ///
        /// - Parameters:
        ///   - test: A specification fixture with its own store and controller lifetime.
        ///   - pollingInterval: The operators the controller allows between polls.
        /// - Throws: Fixture construction or specification conformance failures.
        @Test(arguments: try SpectestTests.testCases(in: SpectestTests.testPaths), [UInt32(1), 1024])
        func runWithDirectExecutionControl(test: TestCase, pollingInterval: UInt32) throws {
            try Self.run(
                test: test,
                configuration: EngineConfiguration(threadingModel: .direct, memoryBoundsChecking: .software),
                executionControl: ExecutionControl(pollingInterval: pollingInterval)
            )
        }

        /// Exercises every specification case through a direct-threaded store with a live
        /// controller and mprotect bounds, including the threads proposal's shared memories and
        /// atomics.
        ///
        /// An engine that cannot back mprotect bounds, such as one under AddressSanitizer, falls
        /// back to software bounds, which ``runWithDirectExecutionControl(test:pollingInterval:)``
        /// already covers, so the case returns without running there.
        ///
        /// - Parameters:
        ///   - test: A specification fixture with its own store and controller lifetime.
        ///   - pollingInterval: The operators the controller allows between polls.
        /// - Throws: Fixture construction or specification conformance failures.
        @Test(
            arguments: try SpectestTests.testCases(in: SpectestTests.testPaths + SpectestTests.sharedMemoryTestPaths),
            [UInt32(1), 1024])
        func runWithDirectExecutionControlAndMprotect(test: TestCase, pollingInterval: UInt32) throws {
            let configuration = EngineConfiguration(threadingModel: .direct, memoryBoundsChecking: .mprotect)
            guard Engine(configuration: configuration).configuration.memoryBoundsChecking == .mprotect else { return }
            try Self.run(
                test: test, configuration: configuration,
                executionControl: ExecutionControl(pollingInterval: pollingInterval)
            )
        }

        @Test(
            .disabled("unable to run spectest on Android due to missing files on emulator", platforms: [.android]),
            arguments: try SpectestTests.testCases(in: SpectestTests.testPaths + SpectestTests.sharedMemoryTestPaths)
        )
        func run(test: TestCase) throws {
            try Self.run(test: test, configuration: EngineConfiguration())
        }

        @Test(
            .disabled("unable to run spectest on Android due to missing files on emulator", platforms: [.android]),
            arguments: try SpectestTests.testCases(in: SpectestTests.testPaths)
        )
        func runWithTokenThreading(test: TestCase) throws {
            var defaultConfig = EngineConfiguration()
            guard defaultConfig.threadingModel != .token else { return }
            defaultConfig.threadingModel = .token
            // Sanity check that non-default threading models work.
            try Self.run(test: test, configuration: defaultConfig)
        }
    #endif
}
