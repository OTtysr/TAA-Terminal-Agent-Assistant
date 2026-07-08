import SwiftUI
import UniformTypeIdentifiers

struct ProviderExchangePayload: Codable {
    var schemaVersion: Int = 1
    var exportedAt: Date = Date()
    var providers: [ProviderProfile]
}

struct ProviderExchangeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var payload: ProviderExchangePayload

    init(providers: [ProviderProfile] = []) {
        self.payload = ProviderExchangePayload(providers: providers)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let payload = try? decoder.decode(ProviderExchangePayload.self, from: data) {
            self.payload = payload
        } else {
            self.payload = ProviderExchangePayload(providers: try decoder.decode([ProviderProfile].self, from: data))
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return FileWrapper(regularFileWithContents: data)
    }
}
