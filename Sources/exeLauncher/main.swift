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
    static let version = "11.21"
    static let releaseURL = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.21")!
    static let preferenceKey = "SelectedWineAppPath"

    static var installDirectory: URL {
        GameStore.directory.appendingPathComponent("Runtime", isDirectory: true)
    }

    static var selectedAppURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: preferenceKey) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Wine Staging.app"
        panel.message = "Choose the complete Wine .app bundle."
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

enum WineRuntimeInstaller {
    private static let releaseAPI = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/tags/11.21")!

    static func install() async throws -> URL {
        try checkRosetta()

        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("exeLauncher", forHTTPHeaderField: "User-Agent")
        let (releaseData, releaseResponse) = try await URLSession.shared.data(for: request)
        guard let http = releaseResponse as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw InstallerError.releaseLookupFailed
        }

        guard let release = try JSONSerialization.jsonObject(with: releaseData) as? [String: Any],
              let assets = release["assets"] as? [[String: Any]] else {
            throw InstallerError.noDownloadFound
        }

        let archives = assets.compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  name.lowercased().contains("staging"),
                  name.lowercased().hasSuffix(".tar.xz"),
                  let url = URL(string: urlString) else { return nil }
            return (name, url)
        }

        guard let archive = archives.first(where: {
            $0.0.lowercased().contains("osx64") || $0.0.lowercased().contains("x86_64")
        }) ?? archives.first else {
            throw InstallerError.noDownloadFound
        }

        let (archiveURL, downloadResponse) = try await URLSession.shared.download(from: archive.1)
        guard let downloadHTTP = downloadResponse as? HTTPURLResponse,
              (200...299).contains(downloadHTTP.statusCode) else {
            throw InstallerError.downloadFailed
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("exeLauncher-Wine-\(UUID().uuidString)", isDirectory: true)
        let extractionDirectory = temporaryDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let localArchive = temporaryDirectory.appendingPathComponent(archive.0)
        try fileManager.moveItem(at: archiveURL, to: localArchive)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", localArchive.path, "-C", extractionDirectory.path]
        let tarErrors = Pipe()
        tar.standardError = tarErrors
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let details = String(data: tarErrors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallerError.extractionFailed(details)
        }

        guard let appBundle = findWineApp(in: extractionDirectory) else {
            throw InstallerError.appBundleNotFound
        }

        try fileManager.createDirectory(at: WineRuntime.installDirectory, withIntermediateDirectories: true)
        let destination = WineRuntime.installDirectory.appendingPathComponent(appBundle.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: appBundle, to: destination)

        guard WineRuntime.executable(named: "wine", in: destination) != nil ||
              WineRuntime.executable(named: "wine64", in: destination) != nil,
              WineRuntime.executable(named: "wineboot", in: destination) != nil else {
            try? fileManager.removeItem(at: destination)
            throw InstallerError.invalidWineBundle
        }

        UserDefaults.standard.set(destination.path, forKey: WineRuntime.preferenceKey)
        return destination
    }

    private static func findWineApp(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            if WineRuntime.executable(named: "wine", in: url) != nil ||
               WineRuntime.executable(named: "wine64", in: url) != nil {
                return url
            }
        }
        return nil
    }

    private static func checkRosetta() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallerError.rosettaRequired
        }
        guard process.terminationStatus == 0 else {
            throw InstallerError.rosettaRequired
        }
    }

    enum InstallerError: LocalizedError {
        case rosettaRequired
        case releaseLookupFailed
        case noDownloadFound
        case downloadFailed
        case extractionFailed(String)
        case appBundleNotFound
        case invalidWineBundle

        var errorDescription: String? {
            switch self {
            case .rosettaRequired:
                return "Rosetta 2 is required for this Wine build. Install it in Terminal with: softwareupdate --install-rosetta"
            case .releaseLookupFailed:
                return "Could not retrieve the official Wine release information from GitHub."
            case .noDownloadFound:
                return "No Wine Staging macOS archive was found in the official release."
            case .downloadFailed:
                return "The Wine download did not complete successfully."
            case .extractionFailed(let details):
                return details.isEmpty ? "Could not extract the Wine archive." : "Could not extract Wine: \(details)"
            case .appBundleNotFound:
                return "The downloaded archive did not contain a Wine app bundle."
            case .invalidWineBundle:
                return "The downloaded app bundle is missing Wine executables."
            }
        }
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

enum LauncherSection: Hashable {
    case library
    case bottles
}

struct LauncherView: View {
    @State private var games = GameStore.load()
    @State private var selectedSection: LauncherSection = .library
    @State private var selectedGameID: UUID?
    @State private var showingFileImporter = false
    @State private var isDownloadingSteam = false
    @State private var steamInstallerPath: String?
    @State private var errorMessage: String?
    @State private var showingError = false

    private var selectedGame: Game? { games.first { $0.id == selectedGameID } }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
        } detail: {
            Group {
                if selectedSection == .bottles {
                    BottlesView()
                } else if let game = selectedGame {
                    gameDetail(game)
                } else {
                    homeView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if selectedSection == .library {
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Add Game", systemImage: "plus")
                        }
                        .help("Add a Windows game")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
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

    private var sidebar: some View {
        List {
            Section("Library") {
                Button {
                    selectedSection = .library
                    selectedGameID = nil
                } label: {
                    Label("All Games", systemImage: "square.grid.2x2")
                        .foregroundStyle(selectedSection == .library && selectedGameID == nil ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)

                ForEach(games) { game in
                    Button {
                        selectedSection = .library
                        selectedGameID = game.id
                    } label: {
                        Label(game.name, systemImage: "gamecontroller")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Game", role: .destructive) {
                            deleteGame(game)
                        }
                    }
                }
            }

            Section("Manage") {
                Button {
                    selectedSection = .bottles
                    selectedGameID = nil
                } label: {
                    Label("Bottles", systemImage: "shippingbox")
                        .foregroundStyle(selectedSection == .bottles ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }

            Section("Windows Steam") {
                Label("Steam for Windows", systemImage: "steam")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("exeLauncher")
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
                }
                .exeLauncherGlassButton(prominent: true)

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
            selectedSection = .library
            selectedGameID = game.id
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func deleteGame(_ game: Game) {
        try? FileManager.default.removeItem(atPath: game.executablePath)
        games.removeAll { $0.id == game.id }
        GameStore.save(games)
        if selectedGameID == game.id { selectedGameID = nil }
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
    @State private var isInstallingDependencies = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var bottlePendingDeletion: Bottle?

    private var runtimeReady: Bool {
        WineRuntime.wineExecutable != nil && WineRuntime.winebootExecutable != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: runtimeReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(runtimeReady ? Color.green : Color.orange)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(runtimeReady ? "Wine is ready" : "Wine dependencies are missing")
                                    .font(.headline)
                                Text(runtimeApp?.lastPathComponent ?? "Install Wine Staging to create Windows environments.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Text("Install Wine Staging 11.21. This package includes GStreamer, Wine Gecko and Wine Mono.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button {
                                installDependencies()
                            } label: {
                                if isInstallingDependencies {
                                    ProgressView().controlSize(.small)
                                    Text("Downloading dependencies…")
                                } else if runtimeReady {
                                    Label("Dependencies installed", systemImage: "checkmark")
                                } else {
                                    Label("Download Dependencies", systemImage: "arrow.down.circle")
                                }
                            }
                            .disabled(isInstallingDependencies || runtimeReady)
                            .exeLauncherGlassButton(prominent: true)

                            Button("Select Wine manually…") {
                                selectRuntime()
                            }
                            .disabled(isInstallingDependencies)
                            .exeLauncherGlassButton()
                        }

                        if isInstallingDependencies {
                            ProgressView()
                                .progressViewStyle(.linear)
                            Text("Downloading and unpacking Wine. This can take a few minutes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Create a bottle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A bottle is a separate Windows environment. Install each program in the bottle you want to use.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Bottle name, for example Minecraft", text: $newBottleName)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                createBottle()
                            } label: {
                                if isCreating {
                                    ProgressView().controlSize(.small)
                                    Text("Creating…")
                                } else {
                                    Label("Create bottle", systemImage: "plus")
                                }
                            }
                            .disabled(!runtimeReady || newBottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                            .exeLauncherGlassButton(prominent: true)
                        }
                    }
                    .padding(6)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Your bottles").font(.title2.bold())
                        Spacer()
                        Text("\(bottles.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if bottles.isEmpty {
                        ContentUnavailableView(
                            "No bottles yet",
                            systemImage: "shippingbox",
                            description: Text("Install the dependencies above, then create your first bottle.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(bottles) { bottle in
                            HStack {
                                Image(systemName: "shippingbox")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bottle.name).font(.headline)
                                    Text(bottle.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([bottle.directoryURL])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .help("Show in Finder")
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    bottlePendingDeletion = bottle
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Delete bottle")
                                .buttonStyle(.borderless)
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bottles")
                .font(.largeTitle.bold())
            Text("Manage separate Windows environments for your games and apps.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func installDependencies() {
        guard !runtimeReady else { return }
        isInstallingDependencies = true
        statusMessage = "Connecting to GitHub and downloading Wine Staging."
        Task {
            do {
                let installedApp = try await WineRuntimeInstaller.install()
                runtimeApp = installedApp
                statusMessage = "Wine Staging \(WineRuntime.version) and its bundled dependencies are installed."
            } catch {
                showError(error.localizedDescription)
                statusMessage = nil
            }
            isInstallingDependencies = false
        }
    }

    private func selectRuntime() {
        if let selected = WineRuntime.chooseApp() {
            runtimeApp = selected
            if !runtimeReady {
                showError("I couldn't find the Wine and wineboot executables in that app. Select the complete Wine .app bundle.")
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
        } catch {
            showError(error.localizedDescription)
        }
        bottlePendingDeletion = nil
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}