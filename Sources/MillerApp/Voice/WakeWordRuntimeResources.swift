import Foundation
import MillerWake

enum WakeWordRuntimeResourcesError: Error, Equatable, Sendable {
    case unavailable
    case unsafePath
}

struct WakeWordRuntimeResources: Sendable {
    let modelRoot: URL
    let applicationSupportDirectory: URL

    static func resolve(
        resourceRoot: URL,
        applicationSupportDirectory: URL
    ) throws -> WakeWordModelPaths {
        guard resourceRoot.isFileURL,
              applicationSupportDirectory.isFileURL,
              !isSymbolicLink(resourceRoot)
        else { throw WakeWordRuntimeResourcesError.unsafePath }
        let modelRoot = resourceRoot.lastPathComponent == "model"
            ? resourceRoot
            : resourceRoot.appendingPathComponent("model", isDirectory: true)
        let names = [
            "encoder.onnx", "decoder.onnx", "joiner.onnx", "bpe.model", "tokens.txt",
        ]
        let files = names.map { modelRoot.appendingPathComponent($0) }
        guard files.allSatisfy(isRegularFile) else {
            throw WakeWordRuntimeResourcesError.unavailable
        }
        return WakeWordModelPaths(
            encoder: files[0],
            decoder: files[1],
            joiner: files[2],
            tokens: files[4],
            keywords: applicationSupportDirectory
                .appendingPathComponent(WakeWordKeywordMaterializer.keywordFileName)
        )
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        applicationSupportDirectory: URL? = nil
    ) throws -> WakeWordModelPaths {
        let support = applicationSupportDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent(
                "ai.millrace.miller",
                isDirectory: true
            )
        var roots = [URL]()
        if let configured = environment["MILLER_WAKEWORD_RESOURCE_ROOT"],
           !configured.isEmpty
        {
            roots.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        if let bundleRoot = bundle.resourceURL {
            roots.append(bundleRoot.appendingPathComponent("WakeWord", isDirectory: true))
            roots.append(bundleRoot)
        }
        for root in roots {
            if let paths = try? resolve(
                resourceRoot: root,
                applicationSupportDirectory: support
            ) {
                return paths
            }
        }
        throw WakeWordRuntimeResourcesError.unavailable
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard !isSymbolicLink(url),
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: url.path
              )
        else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeRegular
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}
