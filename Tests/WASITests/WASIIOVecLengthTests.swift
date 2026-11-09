import Testing
import WasmTypes

@_spi(WASIPlatform) @testable import WASI

/// The buffers of one vectored call may overlap, so their lengths can add up
/// to more than a `size` can count, even in a small memory.
@Suite struct WASIIOVecLengthTests {
    /// The size of guest memory. Every buffer starts at address 0.
    static let memorySize: UInt32 = 0x10_0000

    /// Writes `count` iovecs at address 0. Each covers all of memory, except
    /// that the last one is `lastLength` bytes long.
    private func writeOverlappingIOVecs(
        count: UInt32, lastLength: UInt32, to memory: TestSupport.TestGuestMemory
    ) -> UnsafeGuestBufferPointer<WASIAbi.IOVec> {
        let iovs = UnsafeGuestBufferPointer<WASIAbi.IOVec>(baseAddress: .init(offset: 0), count: count)
        for index in 0..<count {
            let length = index == count - 1 ? lastLength : Self.memorySize
            iovs.write(at: index, WASIAbi.IOVec(buffer: .init(offset: 0), length: length), to: memory)
        }
        return iovs
    }

    /// Runs `body` with `hello.txt` open as descriptor 4 and an in-memory null
    /// device as standard output.
    private func withWASI(_ body: (WASIImplementation) throws -> Void) throws {
        let fileSystem = try MemoryFileSystem()
        try fileSystem.addFile(at: "/hello.txt", content: "hello")
        let null = MemoryCharacterDeviceEntry(deviceNode: MemoryCharacterDeviceNode(kind: .null), accessMode: .write)
        let bridge = try WASIBridgeToHost(
            fileSystem: .memory(fileSystem)
                .withStdio(stdin: null, stdout: null, stderr: null)
                .withPreopens([.init(guestPath: "/", hostPath: "/")])
        )
        try bridge.runAndClose { bridge in
            let wasi = bridge.underlying
            let fd = try wasi.path_open(
                dirFd: 3, dirFlags: [], path: "hello.txt", oflags: [],
                fsRightsBase: [.FD_READ, .FD_TELL], fsRightsInheriting: [], fdflags: [])
            try #require(fd == 4)
            try body(wasi)
        }
    }

    /// 4096 buffers of 1 MiB add up to 4 GiB, one byte more than a `size`
    /// counts.
    @Test func aWriteOfMoreThanSizeMaxBytesIsInvalid() throws {
        let memory = TestSupport.TestGuestMemory(size: Int(Self.memorySize))
        let iovs = writeOverlappingIOVecs(count: 4096, lastLength: Self.memorySize, to: memory)
        try withWASI { wasi in
            #expect(throws: WASIAbi.Errno.EINVAL) {
                try wasi.fd_write(fileDescriptor: 1, ioVectors: iovs, memory: memory)
            }
        }
    }

    @Test func aWriteOfSizeMaxBytesIsCounted() throws {
        let memory = TestSupport.TestGuestMemory(size: Int(Self.memorySize))
        let iovs = writeOverlappingIOVecs(count: 4096, lastLength: Self.memorySize - 1, to: memory)
        try withWASI { wasi in
            let written = try wasi.fd_write(fileDescriptor: 1, ioVectors: iovs, memory: memory)
            #expect(written == WASIAbi.Size.max)
        }
    }

    /// The call fails before it reads anything, so the file position and the
    /// iovecs at the start of memory stay as they were.
    @Test func aReadOfMoreThanSizeMaxBytesReadsNothing() throws {
        let memory = TestSupport.TestGuestMemory(size: Int(Self.memorySize))
        let iovs = writeOverlappingIOVecs(count: 4096, lastLength: Self.memorySize, to: memory)
        let iovecBytes = memory.read(count: 8)
        try withWASI { wasi in
            #expect(throws: WASIAbi.Errno.EINVAL) {
                try wasi.fd_read(fd: 4, iovs: iovs, memory: memory)
            }
            let position = try wasi.fd_tell(fd: 4)
            #expect(position == 0)
            #expect(memory.read(count: 8) == iovecBytes)
        }
    }
}
