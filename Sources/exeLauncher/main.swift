import SwiftUI
import UniformTypeIdentifiers

@main
struct exeLauncherApp: App {
    var body: some Scene {
        WindowGroup {
            LauncherView()
                .frame(minWidth: 850, minHeight: 560)
        }
        .windowStyle(.automatic)
    }
}

struct Game: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var executablePath: String
    var source: String

    init(name: String, executablePath: String, source: String = "Standalone") {
        self.id = UUID()
        self.name = name
        self.executablePath = executablePath
        self.source = source
    }
}

enum GameStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exeLauncher", isDirectory: true)
    }

    static var gamesDirectory: URL {
        directory.appendingPathComponent("ImportedGames", isDirectory: true)
    }

    static var libraryFile: URL {
        directory.appendingPathComponent("library.json")
    }

    static func load() -> [Game] {
        do {
            let data = try Data(contentsOf: libraryFile)
            return try JSONDecoder().decode([Game].self, from: data)
        } catch {
            return []
        }
    }

    static func save(_ games: [Game]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(games)
            try data.write(to: libraryFile, options: .atomic)
        } catch {
            print("Could not save game library: \(error)")
        }
    }
}

enum SteamInstaller {
    // Valve's official Windows Steam installer. The binary is downloaded on demand,
    // rather than committed to this repository, so users always get Valve's current copy.
    static let downloadURL = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!

    static var installerURL: URL {
        GameStore.directory
            .appendingPathComponent("Installers", isDirectory: true)
            .appendingPathComponent("SteamSetup.exe")
    }

    static func download() async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DownloadError.invalidResponse
        }

        let destination = installerURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    enum DownloadError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            "Valve's Steam installer server returned an invalid response."
        }
    }
}

struct LauncherView: View {
    @State private var games = GameStore.load()
    @State private var selectedGameID: UUID?
    @State private var showingFileImporter = false
    @State private var isDownloadingSteam = false
    @State private var steamInstallerPath: String?
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingLaunchInfo = false

    private var selectedGame: Game? {
        games.first { $0.id == selectedGameID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedGameID) {
                Section("Library") {
                    Label("All Games", systemImage: "square.grid.2x2")
                        .tag(Optional<UUID>.none)
                }

                Section("Your Games") {
                    ForEach(games) { game in
                        Label(game.name, systemImage: "gamecontroller")
                            .tag(Optional(game.id))
                    }
                    .onDelete(perform: deleteGames)
                }

                Section("Windows Steam") {
                    Label("Steam for Windows", systemImage: "steam")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("exeLauncher")
            .toolbar {
                ToolbarItem {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Add Game", systemImage: "plus")
                    }
                    .help("Add a Windows .exe file to your library")
                }
            }
        } detail: {
            if let game = selectedGame {
                gameDetail(game)
            } else {
                homeView
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            importGame(result)
        }
        .alert("Something went wrong", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .alert("Launching games is not ready yet", isPresented: $showingLaunchInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The library and Windows Steam installer download are in place. The Wine runtime and Windows game launching are the next development step.")
        }
    }

    private var homeView: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)

            Text("Your game library")
                .font(.largeTitle.bold())

            Text("Add standalone Windows games or prepare the Windows version of Steam.")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Add Windows game", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await downloadSteamInstaller() }
                } label: {
                    if isDownloadingSteam {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading Steam…")
                    } else {
                        Label("Get Windows Steam", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isDownloadingSteam)
                .buttonStyle(.bordered)
            }

            if let steamInstallerPath {
                Label("SteamSetup.exe downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(steamInstallerPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("\(games.count) games in your library")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func gameDetail(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(game.name)
                .font(.largeTitle.bold())

            Label(game.source, systemImage: "folder")
                .foregroundStyle(.secondary)

            GroupBox("Executable") {
                Text(game.executablePath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }

            Button {
                showingLaunchInfo = true
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
            .help("Game launching will be enabled after Wine integration.")

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func importGame(_ result: Result<URL, Error>) {
        do {
            let sourceURL = try result.get()
            guard sourceURL.pathExtension.lowercased() == "exe" else {
                showError("Please select a Windows .exe file.")
                return
            }
            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            try FileManager.default.createDirectory(
                at: GameStore.gamesDirectory,
                withIntermediateDirectories: true
            )

            let destination = GameStore.gamesDirectory
                .appendingPathComponent(sourceURL.lastPathComponent)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)

            let game = Game(
                name: sourceURL.deletingPathExtension().lastPathComponent,
                executablePath: destination.path
            )
            games.append(game)
            GameStore.save(games)
            selectedGameID = game.id
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func deleteGames(at offsets: IndexSet) {
        let removedGames = offsets.map { games[$0] }
        for game in removedGames {
            try? FileManager.default.removeItem(atPath: game.executablePath)
        }
        games.remove(atOffsets: offsets)
        GameStore.save(games)
    }

    @MainActor
    private func downloadSteamInstaller() async {
        isDownloadingSteam = true
        defer { isDownloadingSteam = false }

        do {
            let url = try await SteamInstaller.download()
            steamInstallerPath = url.path
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
