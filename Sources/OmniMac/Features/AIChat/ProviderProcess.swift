import Foundation

struct ProviderProcessSpecification: Equatable {
    let executable: URL
    let arguments: [String]
    var environment: [String: String]? = nil
}

final class ProviderProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let queue = DispatchQueue(label: "com.seergiii.omnimac.ai-process")
    private var stderr = BoundedDataBuffer(limit: 64 * 1024)

    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32, Data) -> Void)?

    func start(_ specification: ProviderProcessSpecification) throws {
        process.executableURL = specification.executable
        process.arguments = specification.arguments
        if let environment = specification.environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.onOutput?(data) }
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.stderr.append(data) }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                self.output.fileHandleForReading.readabilityHandler = nil
                self.error.fileHandleForReading.readabilityHandler = nil
                self.onExit?(process.terminationStatus, self.stderr.data)
            }
        }
        try process.run()
    }

    func writeJSON(_ object: Any) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Cierra stdin: el modo «stream-json» de entrada no termina hasta recibir el fin de archivo.
    func closeInput() { try? input.fileHandleForWriting.close() }

    func cancel() {
        guard process.isRunning else { return }
        process.interrupt()
    }

    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { terminate() }
}
