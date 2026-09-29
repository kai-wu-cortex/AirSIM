#!/usr/bin/env swift

import CryptoKit
import Foundation

enum ToolError: LocalizedError {
    case usage
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .usage:
            return "用法：ed25519-tool.swift generate <私钥> <公钥> | sign <私钥> <输入> <签名> | verify <公钥> <输入> <签名>"
        case .invalidPrivateKey:
            return "Ed25519 私钥必须正好为 32 字节"
        }
    }
}

func writePrivateFile(_ data: Data, to url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: url, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { throw ToolError.usage }

    switch arguments[1] {
    case "generate":
        guard arguments.count == 4 else { throw ToolError.usage }
        let privateKey = Curve25519.Signing.PrivateKey()
        let privateURL = URL(fileURLWithPath: arguments[2])
        let publicURL = URL(fileURLWithPath: arguments[3])
        try writePrivateFile(privateKey.rawRepresentation, to: privateURL)
        try privateKey.publicKey.rawRepresentation.write(to: publicURL, options: .atomic)
    case "sign":
        guard arguments.count == 5 else { throw ToolError.usage }
        let privateData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        guard privateData.count == 32 else { throw ToolError.invalidPrivateKey }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
        let input = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        let signature = try privateKey.signature(for: input)
        try signature.write(to: URL(fileURLWithPath: arguments[4]), options: .atomic)
    case "verify":
        guard arguments.count == 5 else { throw ToolError.usage }
        let publicData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        let input = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        let signature = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
        guard publicKey.isValidSignature(signature, for: input) else {
            throw NSError(domain: "DJOneHubRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "签名校验失败"])
        }
    default:
        throw ToolError.usage
    }
}

do {
    try run()
} catch {
    fputs("错误：\(error.localizedDescription)\n", stderr)
    exit(64)
}
