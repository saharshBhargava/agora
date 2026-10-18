import SwiftUI

/// Launch arguments for unattended device testing (UserDefaults argument domain):
/// - `-DibsAutoShop YES`: skip Home, create a run and open the shopper camera.
/// - `-DibsDebugCrops YES`: also save every trigger crop to Documents/crops/.
enum DebugLaunch {
    static var autoShop: Bool { UserDefaults.standard.bool(forKey: "DibsAutoShop") }
    static var debugCrops: Bool { UserDefaults.standard.bool(forKey: "DibsDebugCrops") }

    /// Creates a run as its shopper and remembers the person id for it.
    static func startAutoShop(api: DibsAPI) async throws -> (runId: String, personId: String) {
        DibsLog.event("autoshop createRun base=\(api.base.absoluteString)")
        let created = try await api.createRun()
        ServerConfig.savePersonId(created.shopperId, runId: created.runId)
        DibsLog.event("autoshop run=\(created.runId) shopper=\(created.shopperId)")
        return (created.runId, created.shopperId)
    }

    /// Writes a crop to Documents/crops/ when `-DibsDebugCrops YES`. Returns the file URL.
    @discardableResult
    static func saveCrop(_ jpeg: Data, index: Int) -> URL? {
        guard debugCrops else { return nil }
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = docs.appendingPathComponent("crops", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let url = dir.appendingPathComponent(String(format: "crop-%03d-%d.jpg", index, stamp))
            try jpeg.write(to: url)
            DibsLog.event("crop saved \(url.lastPathComponent)")
            return url
        } catch {
            DibsLog.event("crop save failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Root for `-DibsAutoShop YES`: creates a run, then shows the shopper camera.
/// Wiring in DibsApp: `if DebugLaunch.autoShop { AutoShopRoot(base: ServerConfig.current()) } else { DibsRootView() ... }`.
struct AutoShopRoot: View {
    let base: URL
    @State private var store: RunStore?
    @State private var ids: (runId: String, personId: String)?
    @State private var error: String?

    var body: some View {
        Group {
            if let store, let ids {
                // No AppModel or receipt route here: the locked screen hides "I've paid · snap the receipt".
                // The stack only gives the shopper screen its paper bar (keeps the status bar off the dark camera).
                NavigationStack {
                    ShopperView(store: store, api: DibsAPI(base: base), runId: ids.runId, personId: ids.personId,
                                onSnapReceipt: nil)
                }
            } else if let error {
                VStack(spacing: 16) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Try again") { Task { await start() } }
                }
                .padding(24)
            } else {
                ProgressView("Starting a run…")
            }
        }
        .task { if store == nil { await start() } }
    }

    private func start() async {
        error = nil
        let api = DibsAPI(base: base)
        do {
            let created = try await DebugLaunch.startAutoShop(api: api)
            store = RunStore(api: api)
            ids = created
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DibsLog.event("autoshop failed: \(text)")
            self.error = text
        }
    }
}
