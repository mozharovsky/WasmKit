import WASI
import WasmKit

public typealias WASIBridgeToHost = WASI.WASIBridgeToHost
public typealias MemoryFileSystem = WASI.MemoryFileSystem

extension WASIBridgeToHost {

    /// Register the WASI implementation to the given `imports`.
    ///
    /// - Parameters:
    ///   - imports: The imports scope to register the WASI implementation.
    ///   - store: The store to create the host functions.
    public func link(to imports: inout Imports, store: Store) {
        for (moduleName, module) in wasiHostModules {
            for (name, function) in module.functions {
                imports.define(
                    module: moduleName,
                    name: name,
                    Function(store: store, type: function.type, body: makeHostFunction(function))
                )
            }
        }
    }

    @available(*, deprecated, renamed: "link(to:store:)", message: "Use `Engine`-based API instead")
    public var hostModules: [String: HostModule] {
        wasiHostModules.mapValues { (module: WASIHostModule) -> HostModule in
            HostModule(
                functions: module.functions.mapValues { function -> HostFunction in
                    HostFunction(type: function.type, implementation: makeHostFunction(function))
                })
        }
    }

    private func makeHostFunction(_ function: WASIHostFunction) -> Function.Implementation {
        { caller, values -> [Value] in
            guard case .memory(let memory) = caller.instance?.export("memory") else {
                throw WASIError(description: "Missing required \"memory\" export")
            }
            return try function.implementation(memory, values)
        }
    }

    /// Start a WASI application as a `command` instance.
    ///
    /// See <https://github.com/WebAssembly/WASI/blob/main/legacy/application-abi.md>
    /// for more information about the WASI Preview 1 Application ABI.
    ///
    /// - Parameter instance: The WASI application instance.
    /// - Returns: The exit code returned by the WASI application.
    /// - Throws: A missing entry point, a guest or native failure, or requested execution
    ///   termination. Blocking native imports must return before interruption can be observed.
    public func start(_ instance: Instance) throws -> UInt32 {
        do {
            guard let start = instance.exports[function: "_start"] else {
                throw WASIError(description: "Missing required \"_start\" function")
            }
            _ = try start()
        } catch let code as WASIExitCode {
            return code.code
        }
        return 0
    }

    /// Start a WASI application as a `reactor` instance.
    ///
    /// See <https://github.com/WebAssembly/WASI/blob/main/legacy/application-abi.md>
    /// for more information about the WASI Preview 1 Application ABI.
    ///
    /// - Parameter instance: The WASI application instance.
    /// - Throws: An initialization failure or requested execution termination. A reactor without
    ///   an initialization export requires no guest invocation.
    public func initialize(_ instance: Instance) throws {
        if let initialize = instance.exports[function: "_initialize"] {
            // Call the optional `_initialize` function.
            _ = try initialize()
        }
    }

    /// Starts a command through its instance's store for callers of the deprecated runtime API.
    ///
    /// - Parameters:
    ///   - instance: The WASI command instance whose entry point should run.
    ///   - runtime: The unused legacy runtime. The instance retains its own store and engine.
    /// - Returns: The command's exit code.
    /// - Throws: A missing entry point, a guest or native failure, or requested execution termination.
    @available(*, deprecated, message: "Use `Engine`-based API instead")
    public func start(_ instance: Instance, runtime: Runtime) throws -> UInt32 {
        return try start(instance)
    }
}
