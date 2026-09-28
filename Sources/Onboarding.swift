import AppKit
import SwiftUI
import EventKit
import AVFoundation
import CoreBluetooth
import ApplicationServices
import Intents

// MARK: - First-run permission wizard (asks for everything up front, like a proper menu-bar app)

@MainActor
final class PermissionsModel: ObservableObject {
    @Published var screen = false
    @Published var calendar = false
    @Published var camera = false
    @Published var automation = false
    @Published var accessibility = false
    @Published var bluetooth = false
    @Published var location = false
    @Published var microphone = false
    @Published var focus = false
    @Published var downloads = false
    private var btManager: CBCentralManager?

    func refresh() {
        location = LocationProvider.shared.allowed
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        focus = INFocusStatusCenter.default.authorizationStatus == .authorized
        // Reading the folder is what asks, so only check once you've clicked Grant (then it never prompts again).
        if UserDefaults.standard.bool(forKey: "askedDownloads") { downloads = Self.canReadDownloads() }
        accessibility = AXIsProcessTrusted()
        bluetooth = CBManager.authorization == .allowedAlways
        screen = CGPreflightScreenCaptureAccess()
        calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestScreen() {
        // Prompts on first call; if already decided, opens the pane so the user can flip it.
        if !CGRequestScreenCaptureAccess() {
            open("Privacy_ScreenCapture")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
    }

    func requestCalendar() {
        CalendarService.shared.store.requestFullAccessToEvents { _, _ in
            CalendarService.shared.store.requestFullAccessToReminders { _, _ in
                DispatchQueue.main.async { CalendarService.shared.start(); self.refresh() }
            }
        }
    }

    /// Volume/brightness HUD, keeping clear of app menus. Prompts, then opens the pane if needed.
    func requestAccessibility() { MenuBarDodger.shared.requestAccess() }

    /// Creating a Bluetooth manager triggers the system prompt (needed for the Bluetooth tool).
    func requestBluetooth() {
        btManager = CBCentralManager(delegate: nil, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { self.refresh() } }
    }

    /// Trigger the Automation (Apple Events) prompt by poking Music/Spotify.
    func requestAutomation() {
        DispatchQueue.global().async {
            _ = MediaController.run("tell application \"System Events\" to return name of first process")
            _ = MediaController.run("tell application \"Music\" to return name")
            DispatchQueue.main.async { self.automation = true }
        }
    }

    func requestLocation() { Task { _ = await LocationProvider.shared.current(); refresh() } }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
    }

    func requestFocus() {
        INFocusStatusCenter.default.requestAuthorization { _ in DispatchQueue.main.async { self.refresh() } }
    }

    func requestDownloads() {
        UserDefaults.standard.set(true, forKey: "askedDownloads")
        if !Self.canReadDownloads() { open("Privacy_FilesAndFolders") }
        refresh()
    }

    nonisolated static func canReadDownloads() -> Bool {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil
    }

    func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

struct OnboardingView: View {
    let done: () -> Void
    @StateObject private var perms = PermissionsModel()
    @State private var page = 0
    @State private var tourStep = 0
    var tourOnly = false   // menu bar icon › Take the Tour

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(hex: "1B1B2E"), Color(hex: "0B0B12")], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 6) {
                    Image(systemName: "capsule.portrait.fill").font(.system(size: 34)).foregroundStyle(.white)
                    Text("Welcome to Onyx").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Text("Every feature included — no subscription.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(height: 150)

            ZStack {
                if page == 0 && !tourOnly {
                    permissionsPage.transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    FeatureTour(step: $tourStep).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Button(page == 0 && !tourOnly ? "Skip" : "Skip Tour") { done() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if page == 0 && !tourOnly {
                    Button("Take the Tour") { withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { page = 1 } }.buttonStyle(.borderedProminent)
                } else {
                    if tourStep > 0 {
                        Button("Back") { withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { tourStep -= 1 } }.buttonStyle(.bordered)
                    }
                    if tourStep < TourStep.allCases.count - 1 {
                        Button("Next") { withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { tourStep += 1 } }.buttonStyle(.borderedProminent)
                    } else {
                        Button(tourOnly ? "Done" : "Start Using Onyx") { done() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 620)
        .background(Color(hex: "0B0B12"))
        .environment(\.colorScheme, .dark)
        .onAppear { perms.refresh() }
        // Pick up permissions granted in System Settings while this window is open.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in perms.refresh() }
    }

    private var permissionsPage: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("Grant these once so every feature works. macOS shows its own prompt for each.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.top, 12)

                row("Accessibility", "Onyx's volume & brightness HUD, and keeping clear of app menus", "accessibility",
                    granted: perms.accessibility) { perms.requestAccessibility() }
                row("Screen Recording", "Circle to Search, AI screen reading, screenshots & recordings", "rectangle.dashed.badge.record",
                    granted: perms.screen) { perms.requestScreen() }
                row("Calendar & Reminders", "Calendar widget + AI can add events/reminders", "calendar",
                    granted: perms.calendar) { perms.requestCalendar() }
                row("Automation", "Show & control Spotify and Apple Music", "music.note",
                    granted: perms.automation) { perms.requestAutomation() }
                row("Camera", "The Mirror widget", "camera",
                    granted: perms.camera) { perms.requestCamera() }
                row("Bluetooth", "Connect and disconnect devices from the notch", "headphones",
                    granted: perms.bluetooth) { perms.requestBluetooth() }
                row("Location", "Accurate local weather and rain alerts", "location",
                    granted: perms.location) { perms.requestLocation() }
                row("Microphone", "Ask Onyx AI by voice (recognized on this Mac)", "mic",
                    granted: perms.microphone) { perms.requestMicrophone() }
                row("Focus", "Show when a Focus is on", "moon",
                    granted: perms.focus) { perms.requestFocus() }
                row("Downloads folder", "Download progress in the notch", "arrow.down.circle",
                    granted: perms.downloads) { perms.requestDownloads() }
                Text("Screen Recording may ask to quit & reopen Onyx. That's normal; onboarding comes back afterward.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)

                Toggle(isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.set($0) })) {
                    Label("Open Onyx automatically at login", systemImage: "power")
                }
                .padding(.horizontal, 20).padding(.top, 6)

                Text("Optional. Each one asks macOS for what it needs when you turn it on.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 6)
                Toggle(isOn: Binding(get: { NotesSync.shared.enabled }, set: { NotesSync.shared.setEnabled($0); perms.objectWillChange.send() })) {
                    Label("Sync notes with Apple Notes (asks to control Notes)", systemImage: "note.text")
                }
                .padding(.horizontal, 20)
                Toggle(isOn: Binding(get: { SettingsSync.shared.enabled }, set: { SettingsSync.shared.setEnabled($0); perms.objectWillChange.send() })) {
                    Label("Sync settings between your Macs (uses iCloud Drive)", systemImage: "icloud")
                }
                .padding(.horizontal, 20)

            }
            .padding(.bottom, 16)
        }
    }

    private func row(_ title: String, _ subtitle: String, _ icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 30).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                    .foregroundStyle(.green).font(.system(size: 18))
            } else {
                Button("Grant", action: action).buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }
}
