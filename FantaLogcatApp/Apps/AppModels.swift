import Foundation

enum AppPresentationProvenance: Sendable, Equatable { case preset, generic }

struct AppPreset: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let packageName: AndroidPackageName
    let displayName: String
    let symbolName: String?
    let favoriteOrder: Int?
    let group: String?
}

struct AppPresentation: Sendable, Equatable {
    let displayName: String
    let symbolName: String?
    let provenance: AppPresentationProvenance
}

struct AppDescriptor: Identifiable, Sendable, Equatable {
    let packageName: AndroidPackageName
    let presentation: AppPresentation
    var id: String { packageName.value }
}

struct ProcessDescriptor: Sendable, Equatable {
    let pid: Int32
    let name: String
}
