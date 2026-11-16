import Foundation
import PhotonsExtensions
import PhotonsFileAccess

/// Explicit command-line diagnostic for the signed app. Uses synthetic pixels in its own
/// container, never a user's library. External PowerBox grants still require an interactive test.
public enum SandboxDiagnostics {
    public static func run() -> Int32 {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PhotonsSandboxCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            guard SandboxEnvironment.isSandboxed else { throw Failure("App Sandbox is not enabled") }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let bookmark = try FileAccessStore.bookmark(for: scratch)
            let restored = try FileAccessStore.resolve(bookmark).access
            defer { withExtendedLifetime(restored) {} }
            let input = restored.url.appendingPathComponent("input.f32")
            let output = restored.url.appendingPathComponent("output.f32")
            let samples = [Float](repeating: 0.25, count: 64 * 64)
            try samples.withUnsafeBytes { try Data($0).write(to: input) }
            let hdr = try HDRMergeClient(resolvingExplicit: nil)
            let denoise = try AnselDenoiseClient(resolvingExplicit: nil)
            let hdrVersion = try hdr.protocolVersion()
            let denoiseVersion = try denoise.protocolVersion()
            let gpu = try denoise.gpuName()
            guard let model = AnselDenoiseLocation().resolvedModel() else { throw Failure("Bundled denoise model is missing") }
            var options = AnselDenoiseOptions()
            options.noiseA = [0, 0, 0]; options.noiseB = [0.0001, 0.0001, 0.0001]; options.useGPU = true
            _ = try denoise.denoiseImage(model: model, input: input, width: 64, height: 64, output: output, options: options)
            let result = try Data(contentsOf: output)
            guard result.count == samples.count * MemoryLayout<Float>.size else { throw Failure("Denoise output size mismatch") }
            let report: [String: Any] = ["sandbox": true, "bookmarkRoundTrip": true,
                "hdrHelperProtocol": hdrVersion, "denoiseHelperProtocol": denoiseVersion,
                "gpu": gpu ?? "unavailable", "denoiseOutputBytes": result.count,
                "externalFolderAuthorization": "requires interactive file-panel verification"]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return 0
        } catch {
            fputs("sandbox-check: \(error.localizedDescription)\n", stderr); return 1
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
