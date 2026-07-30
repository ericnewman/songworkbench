import SwiftUI

/// Browser/picker for the macOS Music app library. Lists local songs with
/// title/artist search; openable tracks load through the normal import path,
/// DRM/cloud tracks are shown disabled with a clear reason.
struct MusicLibraryPickerView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [MusicLibraryItem] {
        guard !query.isEmpty else { return model.musicLibraryItems }
        return model.musicLibraryItems.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Open from Music", systemImage: "music.note.list")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            TextField("Search by title or artist", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search Music library")

            if let notice = model.musicLibraryNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.swCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding()
        .frame(width: 560, height: 540)
        .swSurfacePanel(cornerRadius: 12)
        .onAppear { model.loadMusicLibraryIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        if model.isLoadingMusicLibrary {
            ProgressView("Reading your Music library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.musicLibraryError {
            VStack(spacing: 10) {
                ContentUnavailableView(
                    "Music Library Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                Button("Try Again") { model.loadMusicLibrary() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No Songs" : "No Matches",
                systemImage: "music.note",
                description: Text(
                    query.isEmpty
                        ? "No songs were found in your Music library."
                        : "No tracks match “\(query)”.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered) { item in row(item) }
                .listStyle(.inset)
        }
    }

    private func row(_ item: MusicLibraryItem) -> some View {
        let openable = item.openability().canOpen
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                    .foregroundStyle(openable ? Color.swTextPrimary : Color.swTextSecondary)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let reason = item.unopenableReason {
                    Label(reason, systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.swCoral)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Open") { model.openMusicLibraryItem(item) }
                .swProminentButtonStyle()
                .disabled(!openable)
                .accessibilityHint(
                    openable ? "Loads this track for analysis" : "Track can't be opened")
        }
        .padding(.vertical, 2)
    }
}
