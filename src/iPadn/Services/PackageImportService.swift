import Foundation

enum PackageImportService {
    static func prepare(_ source: URL, id: UUID) throws -> StoreApp {
        guard source.isFileURL, ["ipa", "zip"].contains(source.pathExtension.lowercased()) else {
            throw ToolError.message(AppText.text("Choose an IPA package"))
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let stage = LocalResources.stagingURL(id)
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: stage) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return try PackageService.inspect(stage)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }
}
