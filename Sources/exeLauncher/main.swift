import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

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
    static let version = "MetalSharp Wine (latest Apple Silicon release)"
    static let releaseURL = URL(string: "https://github.com/metalsharp/MetalSharp-Wine/releases/latest")!
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
    private static let releaseAPI = URL(string: "https://api.github.com/repos/metalsharp/MetalSharp-Wine/releases/latest")!

    static func install() async throws -> URL {
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

        // Use the native Apple Silicon FEX build. It includes the graphics backends
        // and does not require Rosetta.
        let matchingAssets = assets.compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  name.lowercased().hasPrefix("metalsharp-wine-"),
                  name.lowercased().contains("arm64"),
                  !name.lowercased().contains("x86_64"),
                  name.lowercased().hasSuffix(".zip"),
                  let url = URL(string: urlString) else { return nil }
            return (name, url)
        }

        guard let archive = matchingAssets.first else {
            throw InstallerError.noDownloadFound
        }

        let (downloadURL, downloadResponse) = try await URLSession.shared.download(from: archive.1)
        guard let downloadHTTP = downloadResponse as? HTTPURLResponse,
              (200...299).contains(downloadHTTP.statusCode) else {
            throw InstallerError.downloadFailed
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("exeLauncher-MetalSharp-Wine-\(UUID().uuidString)", isDirectory: true)
        let extractionDirectory = temporaryDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let localArchive = temporaryDirectory.appendingPathComponent(archive.0)
        try fileManager.moveItem(at: downloadURL, to: localArchive)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", localArchive.path, extractionDirectory.path]
        let errors = Pipe()
        unzip.standardError = errors
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            let details = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

        guard WineRuntime.executable(named: "wine", in: destination) != nil,
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
            if WineRuntime.executable(named: "wine", in: url) != nil &&
               WineRuntime.executable(named: "wineboot", in: url) != nil {
                return url
            }
        }
        return nil
    }

    enum InstallerError: LocalizedError {
        case releaseLookupFailed
        case noDownloadFound
        case downloadFailed
        case extractionFailed(String)
        case appBundleNotFound
        case invalidWineBundle

        var errorDescription: String? {
            switch self {
            case .releaseLookupFailed:
                return "Could not retrieve the latest MetalSharp Wine release from GitHub."
            case .noDownloadFound:
                return "No native Apple Silicon MetalSharp Wine package was found in the latest release."
            case .downloadFailed:
                return "The MetalSharp Wine download did not complete successfully."
            case .extractionFailed(let details):
                return details.isEmpty ? "Could not extract MetalSharp Wine." : "Could not extract MetalSharp Wine: \\(details)"
            case .appBundleNotFound:
                return "The downloaded archive did not contain MetalSharp-Wine.app."
            case .invalidWineBundle:
                return "The downloaded app bundle is missing Wine executables."
            }
        }
    }
}

enum CabextractInstaller {
    private static let formulaURL = URL(string: "https://formulae.brew.sh/api/formula/cabextract.json")!

    static var installDirectory: URL {
        WineRuntime.installDirectory
            .appendingPathComponent("Dependencies", isDirectory: true)
            .appendingPathComponent("cabextract", isDirectory: true)
    }

    static var executableURL: URL {
        installDirectory.appendingPathComponent("bin/cabextract")
    }

    static func installIfNeeded() async throws -> URL {
        if FileManager.default.isExecutableFile(atPath: executableURL.path) {
            return executableURL
        }

        var request = URLRequest(url: formulaURL)
        request.setValue("exeLauncher", forHTTPHeaderField: "User-Agent")
        let (metadata, metadataResponse) = try await URLSession.shared.data(for: request)
        guard let metadataHTTP = metadataResponse as? HTTPURLResponse,
              (200...299).contains(metadataHTTP.statusCode),
              let formula = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let bottle = formula["bottle"] as? [String: Any],
              let stable = bottle["stable"] as? [String: Any],
              let files = stable["files"] as? [String: Any] else {
            throw InstallerError.metadataUnavailable
        }

        let tag = bottleTag()
        guard let selected = files[tag] as? [String: Any],
              let urlString = selected["url"] as? String,
              let expectedSHA = selected["sha256"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw InstallerError.unsupportedMac
        }

        let (archiveURL, response) = try await URLSession.shared.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InstallerError.downloadFailed
        }

        let archiveData = try Data(contentsOf: archiveURL)
        let actualSHA = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
            throw InstallerError.checksumMismatch
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("exeLauncher-cabextract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let archive = temporaryDirectory.appendingPathComponent("cabextract.tar.gz")
        try fileManager.moveItem(at: archiveURL, to: archive)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", temporaryDirectory.path]
        let errors = Pipe()
        tar.standardError = errors
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallerError.extractionFailed(detail)
        }

        guard let found = findCabextract(in: temporaryDirectory) else {
            throw InstallerError.executableNotFound
        }

        try fileManager.createDirectory(at: installDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installDirectory.path) {
            try fileManager.removeItem(at: installDirectory)
        }
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let binDirectory = installDirectory.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: found, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return executableURL
    }

    private static func bottleTag() -> String {
        #if arch(arm64)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let codename: String
        switch major {
        case 27...: codename = "golden_gate"
        case 26: codename = "tahoe"
        case 15: codename = "sequoia"
        case 14: codename = "sonoma"
        case 13: codename = "ventura"
        case 12: codename = "monterey"
        default: codename = "big_sur"
        }
        return "arm64_\(codename)"
        #else
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let codename = major >= 15 ? "sonoma" : (major == 14 ? "sonoma" : (major == 13 ? "ventura" : "monterey"))
        return codename
        #endif
    }

    private static func findCabextract(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == "cabextract" {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    enum InstallerError: LocalizedError {
        case metadataUnavailable
        case unsupportedMac
        case downloadFailed
        case checksumMismatch
        case extractionFailed(String)
        case executableNotFound

        var errorDescription: String? {
            switch self {
            case .metadataUnavailable: return "Could not retrieve cabextract package information."
            case .unsupportedMac: return "No compatible cabextract package was found for this Mac."
            case .downloadFailed: return "The cabextract download failed."
            case .checksumMismatch: return "The cabextract download failed its SHA-256 check."
            case .extractionFailed(let detail): return detail.isEmpty ? "Could not extract cabextract." : "Could not extract cabextract: " + detail
            case .executableNotFound: return "The downloaded package did not contain the cabextract executable."
            }
        }
    }
}

enum WinetricksInstaller {
    static let scriptURL = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks")!

    static var scriptPath: URL {
        WineRuntime.installDirectory
            .appendingPathComponent("Dependencies", isDirectory: true)
            .appendingPathComponent("winetricks")
    }

    static func installCommonDependencies(prefix: URL, runtimeApp: URL, cabextractURL: URL) throws {
        guard let wine = WineRuntime.executable(named: "wine", in: runtimeApp)
                ?? WineRuntime.executable(named: "wine64", in: runtimeApp) else {
            throw DependencyError.wineNotFound
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scriptPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: scriptPath.path) {
            let data: Data
            do {
                data = try Data(contentsOf: scriptURL, options: .mappedIfSafe)
            } catch {
                throw DependencyError.downloadFailed
            }
            guard !data.isEmpty else { throw DependencyError.downloadFailed }
            try data.write(to: scriptPath, options: .atomic)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath.path, "-q", "corefonts", "vcrun2022", "d3dcompiler_47"]

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "WINEARCH")
        environment["WINEPREFIX"] = prefix.path
                environment["WINE"] = wine.path
        environment["WINELOADER"] = wine.path
        environment["WINEDEBUG"] = "-all"
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = cabextractURL.deletingLastPathComponent().path + ":" + existingPath
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let details = String(data: outputData, encoding: .utf8) ?? ""
            throw DependencyError.installationFailed(details)
        }
    }

    enum DependencyError: LocalizedError {
        case wineNotFound
        case downloadFailed
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .wineNotFound:
                return "Wine was not found, so the bottle dependencies could not be installed."
            case .downloadFailed:
                return "Could not download the official Winetricks script."
            case .installationFailed(let details):
                return details.isEmpty
                    ? "Winetricks could not install the common Windows dependencies. Check that cabextract is installed."
                    : "Winetricks could not install the common Windows dependencies: " + details
            }
        }
    }
}

enum BottleManager {
    static func create(name: String, runtimeApp: URL) async throws -> Bottle {
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
        process.arguments = ["-i"]
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = bottle.directoryURL.path
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

        do {
            let cabextract = try await CabextractInstaller.installIfNeeded()
            try WinetricksInstaller.installCommonDependencies(
                prefix: bottle.directoryURL,
                runtimeApp: runtimeApp,
                cabextractURL: cabextract
            )
        } catch {
            try? FileManager.default.removeItem(at: bottle.directoryURL)
            throw error
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
        WineRuntime.selectedAppURL?.lastPathComponent == "MetalSharp-Wine.app" &&
        WineRuntime.wineExecutable != nil &&
        WineRuntime.winebootExecutable != nil
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
                                Text(runtimeApp?.lastPathComponent ?? "Install MetalSharp Wine to create Windows environments.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Text("Install MetalSharp Wine for Apple Silicon. It includes Mullion, DXVK, VKD3D-Proton and MoltenVK graphics backends.")
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
                            Text("Downloading and unpacking the Wine runtime and graphics components. This can take a while.")
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
        statusMessage = "Connecting to GitHub and downloading MetalSharp Wine."
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
                    try await BottleManager.create(name: name, runtimeApp: runtimeApp)
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