import Foundation

enum ConversionError: Error, LocalizedError {
    case readFailed(URL, Error)
    case writeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .readFailed(let url, let err):
            return "Could not read \(url.lastPathComponent): \(err.localizedDescription)"
        case .writeFailed(let url, let err):
            return "Could not write \(url.lastPathComponent): \(err.localizedDescription)"
        }
    }
}

struct ConversionResult {
    let source: URL
    let destination: URL
    let blocks: Int
    let durationMS: Double
}

enum HTMLToDocxConverter {

    /// Reads `htmlURL`, parses HTML + CSS, runs the cascade, and writes a
    /// `.docx` into `targetDirectory`.
    @discardableResult
    static func convert(htmlURL: URL,
                        targetDirectory: URL) throws -> ConversionResult {
        let start = Date()

        let html: String
        do {
            html = try String(contentsOf: htmlURL, encoding: .utf8)
        } catch {
            do {
                let data = try Data(contentsOf: htmlURL)
                html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
            } catch {
                throw ConversionError.readFailed(htmlURL, error)
            }
        }

        let parsed = HTMLDOMParser().parse(html)
        let resolver = StyleResolver(stylesheet: parsed.stylesheet)
        let (entries, blockCount) = DocxBuilder.buildArchiveFiles(
            from: parsed, resolver: resolver
        )
        let archive = ZipWriter.archive(
            entries: entries.map { ZipWriter.Entry(name: $0.name, data: $0.data) }
        )

        let destURL = targetDirectory
            .appendingPathComponent(htmlURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("docx")

        do {
            try FileManager.default.createDirectory(
                at: targetDirectory, withIntermediateDirectories: true
            )
            try archive.write(to: destURL, options: .atomic)
        } catch {
            throw ConversionError.writeFailed(destURL, error)
        }

        let durationMS = Date().timeIntervalSince(start) * 1000.0
        return ConversionResult(
            source: htmlURL,
            destination: destURL,
            blocks: blockCount,
            durationMS: durationMS
        )
    }
}
