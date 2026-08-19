import SwiftUI

struct AppSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var isBrowsingAllApps = false

    private var searchResults: [AppDescriptor] {
        AppSelectionPresentation.searchResults(model.availableApps, query: search)
    }

    private var otherApps: [AppDescriptor] {
        AppSelectionPresentation.otherApps(
            model.availableApps,
            recent: model.recentApps,
            favorites: model.favoriteApps
        )
    }

    private var hasSearch: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                searchField

                if model.availableApps.isEmpty {
                    if model.isLoadingApps {
                        loadingInstalledApps
                    } else {
                        emptyInstalledApps
                    }
                } else if hasSearch {
                    searchSection
                } else {
                    defaultSections
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { await model.loadApps() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image("FantaMascot")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.copy("选择应用", "Choose an app"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(model.copy("从常用应用开始，或按应用 ID 搜索。", "Start with an app you use often, or search by its application ID."))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            CurrentDeviceMenu()
            Button {
                model.openToolbox()
            } label: {
                Label(model.copy("工具箱", "Toolbox"), systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.bordered)
            Button {
                Task { await model.loadApps() }
            } label: {
                Label(model.copy("刷新", "Refresh"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            Button {
                model.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(model.copy("设置", "Settings"))
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(model.copy("搜索应用名称或应用 ID", "Search app name or application ID"), text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var defaultSections: some View {
        if !model.recentApps.isEmpty {
            AppSection(title: "Recent") {
                ForEach(model.recentApps) { app in
                    AppRow(app: app)
                }
            }
        }

        if !model.favoriteApps.isEmpty {
            AppSection(title: "Favorites") {
                ForEach(model.favoriteApps) { app in
                    AppRow(app: app)
                }
            }
        }

        if model.recentApps.isEmpty && model.favoriteApps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.copy("选择第一个应用", "Choose your first app"))
                    .font(.headline)
                Text(model.copy("搜索游戏名称或应用 ID，也可以浏览下方已安装应用。", "Search for a game or application ID, or browse the installed apps below."))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
        }

        DisclosureGroup(isExpanded: $isBrowsingAllApps) {
            if otherApps.isEmpty {
                Text("Every installed app is already shown above.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                LazyVGrid(columns: AppSectionLayout.columns, alignment: .leading, spacing: 8) {
                    ForEach(otherApps) { app in
                        AppRow(app: app)
                    }
                }
                .padding(.top, 10)
            }
        } label: {
            Label(model.copy("浏览全部已安装应用", "Browse all installed apps"), systemImage: "square.grid.2x2")
                .font(.headline)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var searchSection: some View {
        if searchResults.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No installed app matches \(search)")
                    .font(.headline)
                Text("Try part of the app name or its full application ID.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            AppSection(title: "Search results") {
                ForEach(searchResults) { app in
                    AppRow(app: app)
                }
            }
        }
    }

    private var emptyInstalledApps: some View {
        VStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(model.copy("没有找到第三方应用", "No third-party apps found"))
                .font(.headline)
            Text(model.copy("请在所选设备安装或打开应用后再刷新。", "Install or open an app on the selected device, then refresh this list."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private var loadingInstalledApps: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(model.copy("正在读取已安装应用…", "Loading installed apps…"))
                .font(.headline)
            Text(model.copy("首次读取可能需要几秒钟。", "The first scan can take a few seconds."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}

private struct AppSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.9)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: AppSectionLayout.columns, alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}

private enum AppSectionLayout {
    static let columns = [
        GridItem(.adaptive(minimum: 360, maximum: 560), spacing: 10, alignment: .top)
    ]
}

private struct AppRow: View {
    @EnvironmentObject private var model: AppModel
    let app: AppDescriptor

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.selectApp(app)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(app.presentation.displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        if app.presentation.provenance == .preset {
                            Text("TEAM")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(app.packageName.value)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.toggleFavorite(app)
            } label: {
                Image(systemName: model.isFavorite(app) ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(model.isFavorite(app) ? .yellow : .secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.isFavorite(app) ? "Remove favorite" : "Add favorite")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        }
    }
}
