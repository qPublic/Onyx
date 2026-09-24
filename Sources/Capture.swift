import AppKit
import SwiftUI

// MARK: - Quick capture: screenshots and screen recordings, dropped straight into the Shelf

final class QuickCapture: ObservableObject {
    static let shared = QuickCapture()
    enum Mode { case region, window, screen }

    @Published var recording = false
    @Published var startedAt: Date?
    private var recorder: Process?
    private var stdin: Pipe?

    /// ~/Pictures/Onyx Captures — easy to find in Finder, and the Shelf just references the files.
    static var folder: URL {
        let u = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onyx Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    func screenshot(_ mode: Mode) {
        guard !recording else { return }
        NotchController.current?.collapse()
        let url = Self.folder.appendingPathComponent("Screenshot \(Self.stamp()).png")
        var args: [String] = []
        switch mode {
        case .region: args = ["-i"]            // drag a region (Space toggles window mode)
        case .window: args = ["-i", "-W"]      // click a window
        case .screen: args = []
        }
        args.append(url.path)
        // Give the collapse animation a moment so the open notch isn't in the shot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = args
                guard (try? p.run()) != nil else { return }
                p.waitUntilExit()
                guard FileManager.default.fileExists(atPath: url.path) else { return }   // user pressed Esc
                DispatchQueue.main.async { self.deliver(url, icon: "camera.viewfinder", kind: "Screenshot") }
            }
        }
    }

    func toggleRecording() { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        NotchController.current?.collapse()
        let url = Self.folder.appendingPathComponent("Recording \(Self.stamp()).mov")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-v", "-k", url.path]   // -v video of the main display, -k shows clicks
        let pipe = Pipe()
        p.standardInput = pipe                  // screencapture stops when it reads a character
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.recording = false; self.startedAt = nil; self.recorder = nil; self.stdin = nil
                if FileManager.default.fileExists(atPath: url.path) { self.deliver(url, icon: "film", kind: "Recording") }
            }
        }
        guard (try? p.run()) != nil else { return }
        recorder = p; stdin = pipe
        recording = true; startedAt = Date()
    }

    private func stopRecording() {
        guard let p = recorder else { return }
        stdin?.fileHandleForWriting.write(Data("q\n".utf8))
        // Fallback if it didn't stop on input.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.interrupt() } }
    }

    private func deliver(_ url: URL, icon: String, kind: String) {
        ShelfStore.shared.add([url])
        NotchModel.shared.flash(.message(icon: icon, text: "\(kind) saved to Shelf", tint: .green))
    }

    func openFolder() { NSWorkspace.shared.open(Self.folder) }
}

// MARK: - Tools tab page

struct CaptureView: View {
    @ObservedObject var cap = QuickCapture.shared
    @State private var allowed = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                btn("Region", "rectangle.dashed", .captureRegion) { cap.screenshot(.region) }
                btn("Window", "macwindow", nil) { cap.screenshot(.window) }
                btn("Screen", "display", .captureScreen) { cap.screenshot(.screen) }
                btn(cap.recording ? "Stop" : "Record", cap.recording ? "stop.circle.fill" : "record.circle",
                    .toggleRecording, tint: .red) { cap.toggleRecording() }
            }
            if !allowed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Needs Screen Recording permission").font(.caption)
                    Button("Grant") {
                        if !CGRequestScreenCaptureAccess() {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        allowed = CGPreflightScreenCaptureAccess()
                    }.buttonStyle(.link).font(.caption)
                }
            }
            HStack {
                Text("Saved to Pictures › Onyx Captures and added to the Shelf.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open folder") { cap.openFolder() }.buttonStyle(.link).font(.caption)
            }
            Spacer(minLength: 0)
        }
        .onAppear { allowed = CGPreflightScreenCaptureAccess() }
    }

    private func btn(_ title: String, _ icon: String, _ hk: HotAction?, tint: Color = .white,
                     _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .medium))
                Text(hk.flatMap { Shortcuts.get($0)?.display } ?? " ").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
