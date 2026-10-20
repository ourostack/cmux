import CmuxControlSocket
import CryptoKit
import Darwin
import Foundation
import Testing

@Suite struct ShepherdHookExecutableIdentityTests {
    @Test func theSharedHashBindsEveryByteAndTheNativeHeader() throws {
        let root = try executableFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("claude").path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let identity = try ShepherdHookExecutableIdentity(fileDescriptor: descriptor)
        let digest = try identity.hash(fileDescriptor: descriptor)
        let expected = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest.sha256 == expected)
        #expect(digest.isNativeExecutable)
    }

    @Test func theSharedHashRejectsAnAlreadyChangedFileAndAnIncompleteDescriptor() throws {
        let root = try executableFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("claude").path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let identity = try ShepherdHookExecutableIdentity(fileDescriptor: descriptor)
        #expect(lseek(descriptor, 1, SEEK_SET) == 1)
        #expect(throws: (any Error).self) { try identity.hash(fileDescriptor: descriptor) }
        #expect(lseek(descriptor, 0, SEEK_SET) == 0)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try file.seekToEnd()
        try file.write(contentsOf: Data([0]))
        try file.close()
        #expect(throws: (any Error).self) { try identity.hash(fileDescriptor: descriptor) }
    }

    @Test func hashCompletenessCannotTurnAnInterpreterScriptIntoANativeExecutable() throws {
        let root = try executableFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("script")
        let content = Data("#!/bin/sh\nexit 0\n".utf8)
        try content.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let descriptor = open(path.path, O_RDONLY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let identity = try ShepherdHookExecutableIdentity(fileDescriptor: descriptor)
        let digest = try identity.hash(fileDescriptor: descriptor)
        #expect(!digest.isNativeExecutable)
        #expect(digest.sha256 == SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
    }

    @Test func descriptorAndPathCaptureBindTheSameExecutableFile() throws {
        let root = try executableFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("claude").path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let identity = try ShepherdHookExecutableIdentity(fileDescriptor: descriptor)
        #expect(identity.isValid)
        #expect(try ShepherdHookExecutableIdentity.capture(path: path) == identity)
    }

    @Test func inPlaceChangesCannotRetainTheRegisteredExecutableIdentity() throws {
        let root = try executableFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        let before = try ShepherdHookExecutableIdentity.capture(path: executable.path)
        let file = try FileHandle(forWritingTo: executable)
        try file.seekToEnd()
        try file.write(contentsOf: Data([0]))
        try file.close()
        #expect(try ShepherdHookExecutableIdentity.capture(path: executable.path) != before)
    }

    @Test func replacingAPathCannotBorrowTheOriginalInode() throws {
        let root = try executableFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        let before = try ShepherdHookExecutableIdentity.capture(path: executable.path)
        try FileManager.default.moveItem(at: executable, to: root.appendingPathComponent("old"))
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(try ShepherdHookExecutableIdentity.capture(path: executable.path) != before)
    }

    @Test(arguments: ["symlink", "writable", "directory", "fifo"])
    func unsafeOrNonRegularFilesCannotSupplyExecutableIdentity(kind: String) throws {
        let root = try executableFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var path = root.appendingPathComponent("claude").path
        switch kind {
        case "symlink":
            path = root.appendingPathComponent("link").path
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/bin/sleep")
        case "writable":
            try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: path)
        case "directory": path = root.path
        default:
            path = root.appendingPathComponent("fifo").path
            #expect(mkfifo(path, 0o600) == 0)
        }
        #expect(throws: (any Error).self) {
            try ShepherdHookExecutableIdentity.capture(path: path)
        }
    }
}

private func executableFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let executable = root.appendingPathComponent("claude")
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return root
}
