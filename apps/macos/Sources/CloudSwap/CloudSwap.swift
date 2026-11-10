import SwiftUI
import Darwin
import Network
import CryptoKit
import PagingStore

struct Scenario: Decodable { let name: String; let passed: Bool }
struct LabResult: Decodable { let mode: String; let passed: Bool; let scenarios: [Scenario] }

@MainActor final class Monitor: ObservableObject {
    @Published var swap = "Reading…"
    @Published var free = "Reading…"
    @Published var network = "Checking…"
    @Published var labStatus = "Not run"
    @Published var scenarios: [Scenario] = []
    @Published var running = false
    private let path = NWPathMonitor()
    private var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        path.pathUpdateHandler = { [weak self] state in
            let label = state.status == .satisfied ? "Available (R2 not verified)" : "Offline"
            Task { @MainActor in self?.network = label }
        }
        path.start(queue: DispatchQueue(label: "cloudswap.network"))
    }
    func refresh() {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
            swap = ByteCountFormatter.string(fromByteCount: Int64(usage.xsu_used), countStyle: .binary)
        } else { swap = "Unavailable in this environment" }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let bytes = attributes[.systemFreeSize] as? NSNumber {
            free = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .binary)
        } else { free = "Unavailable" }
    }
    func runDriveLab() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Test this folder"
        panel.message = "Choose a folder on the external drive. CLOUDSWAP writes and verifies 1 MiB of encrypted synthetic data in a temporary subfolder."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        running = true
        scenarios = []
        labStatus = "Writing and verifying encrypted test pages…"
        Task {
            let result = await Task.detached { () -> String in
                let root = selected.appendingPathComponent("cloudswap-test-" + UUID().uuidString)
                do {
                    let key = SymmetricKey(size: .bits256)
                    var store: PagingStore? = try PagingStore(directory: root, key: key)
                    for block in 0..<64 {
                        try store!.write(block: block, data: Data(repeating: UInt8(block), count: PagingStore.blockSize))
                    }
                    store = nil
                    let reopened = try PagingStore(directory: root, key: key)
                    for block in 0..<64 {
                        guard try reopened.read(block: block) == Data(repeating: UInt8(block), count: PagingStore.blockSize) else {
                            throw PagingError.invalid
                        }
                    }
                    try FileManager.default.removeItem(at: root)
                    return "Passed: 1 MiB verified after reopening; test files removed. This does not test unplugging or system swap."
                } catch {
                    return "Drive test failed. Encrypted synthetic files may remain in \(root.lastPathComponent). No system swap was changed."
                }
            }.value
            labStatus = result
            running = false
        }
    }
    func runLab() {
        guard !running else { return }
        running = true
        labStatus = "Running simulated connection failures…"
        scenarios = []
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cloudswap-lab")
        Task {
            let result = await Task.detached { () -> Result<LabResult, Error> in
                do {
                    let process = Process()
                    let output = Pipe()
                    process.executableURL = executable
                    process.standardOutput = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw NSError(domain: "CloudSwapLab", code: Int(process.terminationStatus))
                    }
                    return .success(try JSONDecoder().decode(LabResult.self, from: data))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let report):
                scenarios = report.scenarios
                labStatus = report.passed ? "Simulation passed" : "Simulation failed"
            case .failure(let error): labStatus = "Lab unavailable: \(error.localizedDescription)"
            }
            running = false
        }
    }
}

@main struct CloudSwapApp: App {
    @StateObject private var monitor = Monitor()
    var body: some Scene {
        MenuBarExtra("CLOUDSWAP", systemImage: "cloud") {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("CLOUDSWAP").font(.headline); Spacer(); Text("Research build").foregroundStyle(.secondary).font(.caption) }
                Group {
                    LabeledContent("Mac swap used", value: monitor.swap)
                    LabeledContent("Disk space available", value: monitor.free)
                    LabeledContent("Network", value: monitor.network)
                }.font(.callout)
                Divider()
                Label("System swap integration not connected", systemImage: "info.circle")
                    .font(.callout)
                Text("Test the storage failure policy with synthetic data. Your apps and Mac swap are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(monitor.running ? "Running…" : "Run connection-loss simulation") { monitor.runLab() }
                    .disabled(monitor.running)
                Button("Test external drive folder…") { monitor.runDriveLab() }
                    .disabled(monitor.running)
                Text(monitor.labStatus).font(.caption)
                ForEach(monitor.scenarios, id: \.name) { item in
                    Label(item.name.replacingOccurrences(of: "_", with: " "), systemImage: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.passed ? .green : .red).font(.caption)
                }
                Divider()
                HStack {
                    Link("Project & research", destination: URL(string: "https://github.com/EmotiveImpact/CLOUDSWAP")!)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
            }.padding(18).frame(width: 380)
        }.menuBarExtraStyle(.window)
    }
}
