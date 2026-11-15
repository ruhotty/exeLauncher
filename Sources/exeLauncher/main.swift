import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct exeLauncherApp: App {
    var body: some Scene {
        WindowGroup {
            LauncherView()
                .frame(minWidth: 900, minHeight: 600)
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

struct Bottle: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var directoryName: String
    var createdAt: Date

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.directoryName = UUID().uuidString
        self.createdAt = Date()
    }

    var directoryURL: URL {
        BottleStore.directory.appendingPathComponent(directoryName, isDirectory: true)
    }
}

enum GameStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exeLauncher", isDirectory: true)
    }

    static var gamesDirectory: URL { directory.appendingPathComponent("ImportedGames", isDirectory: true) }
    static var libraryFile: URL { directory.appendingPathComponent("library.json") }

    static func load() -> [Game] {
        guard let data = try? Data(contentsOf: libraryFile) else { return [] }
        return (try? JSONDecoder().decode([Game].self, from: data)) ?? []
    }

    static func save(_ games: [Game]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(games).write(to: libraryFile, options: .atomic)
        } catch {
            print("Could not save game library: \(error)")
        }
    }
}

enum BottleStore {
    static var directory: URL {
        GameStore.directory.appendingPathComponent("Bottles", isDirectory: true)
    }

    static var indexFile: URL { directory.appendingPathComponent("bottles.json") }

    static func load() -> [Bottle] {
        guard let data = try? Data(contentsOf: indexFile) else { return [] }
        return (try? JSONDecoder().decode([Bottle].self, from: data)) ?? []
    }

    static func save(_ bottles: [Bottle]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(bottles)
        try data.write(to: indexFile, options: .atomic)
    }

    static func delete(_ bottle: Bottle) throws {
        if FileManager.default.fileExists(atPath: bottle.directoryURL.path) {
            try FileManager.default.removeItem(at: bottle.directoryURL)
        }
    }
}

enum WineRuntime {
    static let version = "11.16"
    static let releaseURL = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.16")!
    static let preferenceKey = "SelectedWineAppPath"

    static var selectedAppURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: preferenceKey) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Wine Staging.app"
        panel.message = "Choose the Wine .app bundle you installed from Gcenx's release."
        panel.prompt = "Select Wine"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: preferenceKey)
        return url
    }

    static func executable(named name: String, in appURL: URL) -> URL? {
        let candidates = [
            appURL.appendingPathComponent("Contents/Resources/wine/bin/\(name)"),
            appURL.appendingPathComponent("Contents/Resources/bin/\(name)"),
            appURL.appendingPathComponent("Contents/MacOS/\(name)")
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        guard let enumerator = FileManager.default.enumerator(
            at: appURL.appendingPathComponent("Contents", isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator where url.lastPathComponent == name {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var wineExecutable: URL? {
        guard let app = selectedAppURL else { return nil }
        return executable(named: "wine", in: app) ?? executable(named: "wine64", in: app)
    }

    static var winebootExecutable: URL? {
        guard let app = selectedAppURL else { return nil }
        return executable(named: "wineboot", in: app)
    }
}

enum BottleManager {
    static func create(name: String, runtimeApp: URL) throws -> Bottle {
        guard let wineboot = WineRuntime.executable(named: "wineboot", in: runtimeApp) else {
            throw BottleError.winebootNotFound
        }

        let bottle = Bottle(name: name)
        try FileManager.default.createDirectory(
            at: bottle.directoryURL,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = wineboot
        process.arguments = ["--init"]
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = bottle.directoryURL.path
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = "-all"
        environment["WINELOADER"] = WineRuntime.executable(named: "wine", in: runtimeApp)?.path
        process.environment = environment

        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: bottle.directoryURL)
            throw error
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: bottle.directoryURL.appendingPathComponent("drive_c").path) else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: bottle.directoryURL)
            throw BottleError.initializationFailed(detail)
        }

        try BottleStore.save(BottleStore.load() + [bottle])
        return bottle
    }

    enum BottleError: LocalizedError {
        case winebootNotFound
        case initializationFailed(String)

        var errorDescription: String? {
            switch self {
            case .winebootNotFound:
                return "wineboot was not found inside the selected Wine app. Check that you selected the complete Wine .app bundle."
            case .initializationFailed(let detail):
                return detail.isEmpty
                    ? "Wine could not initialize this bottle."
                    : "Wine could not initialize this bottle: \(detail)"
            }
        }
    }
}

enum SteamInstaller {
    static let downloadURL = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!

    static var installerURL: URL {
        GameStore.directory.appendingPathComponent("Installers", isDirectory: true)
            .appendingPathComponent("SteamSetup.exe")
    }

    static func download() async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloadError.invalidResponse
        }
        let destination = installerURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    enum DownloadError: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "Valve's Steam installer server returned an invalid response." }
    }
}

extension View {
    @ViewBuilder
    func exeLauncherGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
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

    private var selectedGame: Game? { games.first { $0.id == selectedGameID } }

    var body: some View {
        TabView {
            libraryTab
                .tabItem { Label("Library", systemImage: "gamecontroller") }
            BottlesView()
                .tabItem { Label("Bottles", systemImage: "shippingbox") }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data],
            allowsMultipleSelection: false
        ) { result in importGame(result) }
        .alert("Something went wrong", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var libraryTab: some View {
        NavigationSplitView {
            List(selection: $selectedGameID) {
                Section("Library") {
                    Label("All Games", systemImage: "square.grid.2x2").tag(Optional<UUID>.none)
                }
                Section("Your Games") {
                    ForEach(games) { game in
                        Label(game.name, systemImage: "gamecontroller").tag(Optional(game.id))
                    }
                    .onDelete(perform: deleteGames)
                }
                Section("Windows Steam") {
                    Label("Steam for Windows", systemImage: "steam").foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("exeLauncher")
            .toolbar {
                ToolbarItem {
                    Button { showingFileImporter = true } label: {
                        Label("Add Game", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let game = selectedGame { gameDetail(game) } else { homeView }
        }
    }

    private var homeView: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Your game library").font(.largeTitle.bold())
            Text("Add standalone Windows games or prepare the Windows version of Steam.")
                .foregroundStyle(.secondary)
            HStack {
                Button { showingFileImporter = true } label: {
                    Label("Add Windows game", systemImage: "plus")
                }.exeLauncherGlassButton(prominent: true)
                Button { Task { await downloadSteamInstaller() } } label: {
                    if isDownloadingSteam {
                        ProgressView().controlSize(.small)
                        Text("Downloading Steam…")
                    } else {
                        Label("Get Windows Steam", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isDownloadingSteam)
                .exeLauncherGlassButton()
            }
            if let steamInstallerPath {
                Label("SteamSetup.exe downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(steamInstallerPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("\(games.count) games in your library").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func gameDetail(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(game.name).font(.largeTitle.bold())
            Label(game.source, systemImage: "folder").foregroundStyle(.secondary)
            GroupBox("Executable") {
                Text(game.executablePath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            Label("Game launching will be connected to bottles in the next step.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func importGame(_ result: Result<[URL], Error>) {
        do {
            let selectedURLs = try result.get()
            guard let sourceURL = selectedURLs.first else { return }
            guard sourceURL.pathExtension.lowercased() == "exe" else {
                showError("Please select a Windows .exe file.")
                return
            }
            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: GameStore.gamesDirectory, withIntermediateDirectories: true)
            let destination = GameStore.gamesDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let game = Game(name: sourceURL.deletingPathExtension().lastPathComponent, executablePath: destination.path)
            games.append(game)
            GameStore.save(games)
            selectedGameID = game.id
        } catch { showError(error.localizedDescription) }
    }

    private func deleteGames(at offsets: IndexSet) {
        let removedGames = offsets.map { games[$0] }
        for game in removedGames { try? FileManager.default.removeItem(atPath: game.executablePath) }
        games.remove(atOffsets: offsets)
        GameStore.save(games)
    }

    @MainActor
    private func downloadSteamInstaller() async {
        isDownloadingSteam = true
        defer { isDownloadingSteam = false }
        do { steamInstallerPath = try await SteamInstaller.download().path }
        catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

struct BottlesView: View {
    @State private var bottles = BottleStore.load()
    @State private var runtimeApp = WineRuntime.selectedAppURL
    @State private var newBottleName = ""
    @State private var isCreating = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var bottlePendingDeletion: Bottle?

    private var runtimeReady: Bool { WineRuntime.wineExecutable != nil && WineRuntime.winebootExecutable != nil }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Wine runtime") {
                    HStack {
                        Image(systemName: runtimeReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(runtimeReady ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(runtimeReady ? "Wine is ready" : "Wine not configured")
                            Text(runtimeApp?.lastPathComponent ?? "No Wine app selected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Select Wine app…") { selectRuntime() }
                    Button("Download Wine 11.16…") {
                        NSWorkspace.shared.open(WineRuntime.releaseURL)
                    }
                }
                Section("Your bottles") {
                    if bottles.isEmpty {
                        Text("No bottles yet").foregroundStyle(.secondary)
                    }
                    ForEach(bottles) { bottle in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bottle.name)
                            Text(bottle.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([bottle.directoryURL])
                            }
                            Button("Delete Bottle", role: .destructive) {
                                bottlePendingDeletion = bottle
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Bottles")
        } detail: {
            bottleHome
        }
        .alert("Something went wrong", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .confirmationDialog(
            "Delete this bottle and everything installed inside it?",
            isPresented: Binding(
                get: { bottlePendingDeletion != nil },
                set: { if !$0 { bottlePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Bottle", role: .destructive) { deletePendingBottle() }
            Button("Cancel", role: .cancel) { bottlePendingDeletion = nil }
        }
    }

    private var bottleHome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Wine bottles").font(.largeTitle.bold())
            Text("Each bottle is its own Windows environment. Programs installed in one bottle stay separate from the others.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Wine runtime") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(runtimeReady ? "Ready to create bottles" : "Install Wine to continue")
                        Spacer()
                        Circle().fill(runtimeReady ? .green : .orange).frame(width: 9, height: 9)
                    }
                    Text("Wine Staging 11.16 for macOS")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Wine download page") {
                            NSWorkspace.shared.open(WineRuntime.releaseURL)
                        }.exeLauncherGlassButton()
                        Button("Select installed Wine…") { selectRuntime() }
                            .exeLauncherGlassButton(prominent: true)
                    }
                }.padding(4)
            }

            GroupBox("Create a bottle") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Bottle name, for example Minecraft", text: $newBottleName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        createBottle()
                    } label: {
                        if isCreating {
                            ProgressView().controlSize(.small)
                            Text("Creating Windows environment…")
                        } else {
                            Label("Create bottle", systemImage: "plus")
                        }
                    }
                    .disabled(!runtimeReady || newBottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    .exeLauncherGlassButton(prominent: true)
                    if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(4)
            }

            Text("\(bottles.count) bottles")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func selectRuntime() {
        if let selected = WineRuntime.chooseApp() {
            runtimeApp = selected
            if !runtimeReady {
                showError("I couldn't find the Wine and wineboot executables in that app. Select the Wine Staging .app bundle, not the downloaded archive.")
            }
        }
    }

    private func createBottle() {
        guard let runtimeApp else { return }
        let name = newBottleName.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        statusMessage = "Running wineboot. The first setup can take a few minutes."
        Task {
            do {
                let bottle = try await Task.detached(priority: .userInitiated) {
                    try BottleManager.create(name: name, runtimeApp: runtimeApp)
                }.value
                bottles.append(bottle)
                newBottleName = ""
                statusMessage = "Bottle '\(bottle.name)' is ready."
            } catch {
                showError(error.localizedDescription)
                statusMessage = nil
            }
            isCreating = false
        }
    }

    private func deletePendingBottle() {
        guard let bottle = bottlePendingDeletion else { return }
        do {
            try BottleStore.delete(bottle)
            bottles.removeAll { $0.id == bottle.id }
            try BottleStore.save(bottles)
        } catch { showError(error.localizedDescription) }
        bottlePendingDeletion = nil
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
