import SwiftUI
import AppKit

// MARK: - Widgets

struct WidgetsPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var store = WidgetStore.shared

    private static let cities: [String] = [
        "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "America/Toronto", "America/Mexico_City",
        "America/Sao_Paulo", "Europe/London", "Europe/Dublin", "Europe/Paris", "Europe/Berlin", "Europe/Madrid", "Europe/Rome",
        "Europe/Amsterdam", "Europe/Stockholm", "Europe/Istanbul", "Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos",
        "Asia/Dubai", "Asia/Karachi", "Asia/Kolkata", "Asia/Dhaka", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong",
        "Asia/Shanghai", "Asia/Seoul", "Asia/Tokyo", "Australia/Perth", "Australia/Sydney", "Pacific/Auckland", "Pacific/Honolulu",
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Show Widgets on Desktop", isOn: $prefs.widgetsEnabled)
                Toggle("Dim Widgets While Using Apps", isOn: $prefs.widgetsDimInApps)
                    .disabled(!prefs.widgetsEnabled)
                LabeledContent("Widgets") {
                    HStack {
                        Text(store.instances.count == 1 ? "1 on desktop" : "\(store.instances.count) on desktop").foregroundStyle(.secondary)
                        Button("Edit Widgets…") { WidgetManager.shared.beginEditing() }
                    }
                }
            } footer: {
                Text("Widgets show in full colour on the desktop. While you work in an app they fade to a quieter monochrome so they never compete with your windows.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                ForEach(prefs.worldClocks, id: \.self) { id in
                    HStack {
                        Text(WorldClockWidget.city(TimeZone(identifier: id) ?? .current))
                        Spacer()
                        Text(TimeZone(identifier: id).map { WorldClockWidget.offset($0, date: Date()) } ?? "").foregroundStyle(.secondary)
                        Button {
                            prefs.worldClocks.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(WorldClockWidget.city(TimeZone(identifier: id) ?? .current))")
                    }
                }
                Menu("Add City") {
                    ForEach(Self.cities.filter { !prefs.worldClocks.contains($0) }, id: \.self) { id in
                        Button(WorldClockWidget.city(TimeZone(identifier: id) ?? .current)) { prefs.worldClocks.append(id) }
                    }
                }
                .disabled(prefs.worldClocks.count >= 4)
            } header: {
                Text("World Clock")
            } footer: {
                Text("Up to four cities.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - StandBy

struct StandByPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var desktopNote: String?

    private var chosen: Wallpaper? { Wallpapers.named(prefs.standByWallpaper) }

    var body: some View {
        Form {
            Section {
                Toggle("Turn On StandBy Automatically", isOn: $prefs.standByEnabled)
                Picker("After", selection: $prefs.standByDelay) {
                    Text("2 Minutes").tag(120.0)
                    Text("5 Minutes").tag(300.0)
                    Text("10 Minutes").tag(600.0)
                    Text("15 Minutes").tag(900.0)
                }
                .disabled(!prefs.standByEnabled)
                Toggle("Only While Charging", isOn: $prefs.standByChargingOnly)
                    .disabled(!prefs.standByEnabled)
            } footer: {
                Text("When your Mac sits idle, StandBy turns the display into a clock with your widgets. Move the pointer or press any key to go back. It never starts during video, presentations or calls.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                WallpaperGrid(selection: $prefs.standByWallpaper)
                    .padding(.vertical, 4)
                Toggle("Depth Effect", isOn: $prefs.standByDepth)
                LabeledContent("Desktop") {
                    HStack {
                        if let desktopNote { Text(desktopNote).foregroundStyle(.secondary) }
                        Button("Set as Desktop Picture") {
                            guard let chosen else { return }
                            desktopNote = Wallpapers.setDesktop(chosen.id) ? "Done" : "Couldn’t set it"
                        }
                        .disabled(chosen == nil)
                    }
                }
            } header: {
                Text("Wallpaper")
            } footer: {
                Text("Original 4K renders. With Depth Effect on, pictures that have a foreground — like Dunes — tuck the time behind it. In StandBy, press ↑ or ↓ to try another.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Clock") {
                Picker("Style", selection: $prefs.standByClockStyle) {
                    ForEach(StandByClockStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Colour") {
                    HStack(spacing: 8) {
                        ForEach(StandByAccent.allCases) { accent in
                            Button {
                                prefs.standByAccent = accent.rawValue
                            } label: {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: prefs.standByAccent == accent.rawValue ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accent.label)
                            .accessibilityAddTraits(prefs.standByAccent == accent.rawValue ? .isSelected : [])
                        }
                    }
                }
                .disabled(prefs.standByClockStyle == StandByClockStyle.glass.rawValue)
                Toggle("Night Mode", isOn: $prefs.standByNightMode)
            }
            Section {
                Toggle("Show Now Playing When Music Plays", isOn: $prefs.standByMusicFirst)
                Toggle("Show Lyrics", isOn: $prefs.standByLyrics)
            } header: {
                Text("Now Playing")
            } footer: {
                Text("Time-synced lyrics float beside the song. They come from LRCLIB, an open lyrics database: Mac Flow sends the song’s title, artist, album and length — nothing about you — and remembers the answer. Without a match it uses the lyrics Music keeps with the song.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Try It") {
                    Button("Enter StandBy") { StandByController.shared.enter(manual: true) }
                }
            } footer: {
                Text("Press Control-Command-S at any time. Use ← and → to change pages, ↑ and ↓ to change the wallpaper or move through widgets, Space to play or pause, L for lyrics. Night Mode turns the clock dim red from 10 PM to 6 AM; Now Playing always keeps the album’s colours.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

/// Shuffle, Black and each picture, as 16:10 tiles.
private struct WallpaperGrid: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
            tile(Wallpapers.shuffle, "Shuffle") {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.36, green: 0.3, blue: 0.62), Color(red: 0.92, green: 0.52, blue: 0.42)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "shuffle").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
            }
            tile(Wallpapers.none, "Black") {
                ZStack {
                    Color.black
                    Text("9:41").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                }
            }
            ForEach(Wallpapers.available) { w in
                tile(w.id, w.name) { WallpaperThumb(id: w.id) }
            }
        }
    }

    private func tile<V: View>(_ id: String, _ name: String, @ViewBuilder _ content: () -> V) -> some View {
        let on = selection == id
        return Button {
            selection = id
        } label: {
            VStack(spacing: 5) {
                content()
                    .aspectRatio(1.6, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: on ? 2.5 : 0))
                Text(name).font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A picture's thumbnail, decoded off the main thread the first time.
private struct WallpaperThumb: View {
    let id: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: id) {
            guard image == nil else { return }
            if RenderMode.snapshot {
                image = Wallpapers.thumbnail(id)
                return
            }
            let loaded = await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    nonisolated(unsafe) let thumb = Wallpapers.thumbnail(id)
                    done.resume(returning: thumb)
                }
            }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

// MARK: - Dock

struct DockPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Toggle("Dock Companion", isOn: $prefs.dockCompanion)
                LabeledContent("Show Now") {
                    Button("Show Dock Companion") { DockBarController.shared.show() }
                }
                .disabled(!prefs.dockCompanion)
            } footer: {
                Text("Move the pointer just past the top of the Dock to bring up what’s playing, your recent files, favourite folders and Mac Flow’s actions.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Drop Tray Above Dock", isOn: $prefs.dockDropZone)
            } footer: {
                Text("While you drag files toward the Dock, a tray offers Hold on Shelf, AirDrop, Share and Compress.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Show Mac Flow in Dock", isOn: $prefs.showInDock)
            } footer: {
                Text("The icon shows a running timer or the current album, and its menu holds every Mac Flow action.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}
