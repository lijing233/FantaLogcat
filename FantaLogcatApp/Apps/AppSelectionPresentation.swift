import Foundation

enum AppSelectionPresentation {
    static func searchResults(_ apps: [AppDescriptor], query: String) -> [AppDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return apps.filter {
            $0.presentation.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.packageName.value.localizedCaseInsensitiveContains(trimmed)
        }
    }

    static func otherApps(
        _ apps: [AppDescriptor],
        recent: [AppDescriptor],
        favorites: [AppDescriptor]
    ) -> [AppDescriptor] {
        let featured = Set((recent + favorites).map(\.id))
        return apps.filter { !featured.contains($0.id) }
    }
}
