import AppKit
import SwiftUI

// MARK: - Step-by-step guide for getting a Canvas access token (with illustrations of each screen)

enum CanvasGuide {
    private static var window: NSWindow?

    static func show() {
        NotchController.current?.collapse()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Get a Canvas Token"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.contentViewController = NSHostingController(rootView: CanvasGuideView())
            w.center()
            window = w
        }
        window?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

private let canvasNav = Color(red: 0.18, green: 0.23, blue: 0.27)      // Canvas's dark left bar
private let canvasBlue = Color(red: 0.0, green: 0.46, blue: 0.75)

struct CanvasGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 30)).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect Canvas in 2 minutes").font(.system(size: 20, weight: .bold))
                        Text("You'll make a personal \"access token\" in Canvas and paste it into Onyx. It lets Onyx read your to-do list.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                step(1, "Open Canvas and sign in",
                     "Go to your school's Canvas website in your browser (it usually ends in .instructure.com) and log in like normal. Remember this address. You'll paste it into Onyx.") {
                    BrowserMock()
                }
                step(2, "Click Account, then Settings",
                     "In the dark bar on the left edge of Canvas, click your profile picture labeled Account. A panel slides out; click Settings.") {
                    AccountMenuMock()
                }
                step(3, "Click \"+ New Access Token\"",
                     "On the Settings page, scroll down to Approved Integrations and click the blue + New Access Token button.") {
                    IntegrationsMock()
                }
                step(4, "Name it and generate",
                     "Type Onyx for Purpose. You can leave the expiration blank (or pick a date if your school requires one). Click Generate Token.") {
                    NewTokenMock()
                }
                step(5, "Copy the token right away",
                     "Canvas shows the long token once. Select all of it and copy it (⌘C). If you close this window without copying, just make another token.") {
                    TokenDetailsMock()
                }
                step(6, "Paste it into Onyx",
                     "Open Onyx Settings › Live › Canvas. Enter your school's Canvas address from step 1, paste the token, and click Connect. Then add the Canvas To-Do box on Home.") {
                    OnyxFieldsMock()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Good to know", systemImage: "lightbulb.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.yellow)
                    bullet("Treat the token like a password. Onyx keeps it in your Mac's Keychain and only sends it to your school's Canvas.")
                    bullet("Don't see + New Access Token? Some schools turn it off. Then this feature can't be used with your school's Canvas.")
                    bullet("To revoke access later, delete the \"Onyx\" token in Canvas › Account › Settings, or click Disconnect in Onyx.")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.08)))
                HStack {
                    Spacer()
                    Button("Open Onyx Settings") { (NSApp.delegate as? AppDelegate)?.openSettings() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 500)
    }

    private func step<V: View>(_ n: Int, _ title: String, _ text: String, @ViewBuilder picture: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(canvasBlue))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            picture()
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.12)))
                .overlay(alignment: .bottomTrailing) {
                    Text("Illustration").font(.system(size: 9)).foregroundStyle(.black.opacity(0.35)).padding(6)
                }
                .environment(\.colorScheme, .light)
                .padding(.leading, 36)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) { Text("•"); Text(s).fixedSize(horizontal: false, vertical: true) }
            .font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

// MARK: - Illustrations (drawn to look like the Canvas screens)

/// Red rounded outline + "Click here" callout used to point at the right control.
private struct Highlight: ViewModifier {
    var label = "Click here"
    var edge: Edge = .trailing
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.red, lineWidth: 2.5).padding(-4))
            .overlay(alignment: edge == .trailing ? .trailing : .bottom) {
                HStack(spacing: 3) {
                    if edge == .trailing { Image(systemName: "arrow.left") }
                    Text(label)
                    if edge != .trailing { Image(systemName: "arrow.up") }
                }
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.red))
                .fixedSize()
                .offset(x: edge == .trailing ? 90 : 0, y: edge == .trailing ? 0 : 26)
            }
    }
}
private extension View { func highlight(_ label: String = "Click here", edge: Edge = .trailing) -> some View { modifier(Highlight(label: label, edge: edge)) } }

private struct BrowserMock: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 9) }
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("yourschool.instructure.com").font(.system(size: 11))
                }
                .foregroundStyle(.black.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.06)))
                .highlight("Your school's address", edge: .bottom)
                Spacer()
            }
            .padding(10)
            .background(Color(white: 0.95))
            HStack(spacing: 0) {
                canvasNav.frame(width: 54)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dashboard").font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                    HStack(spacing: 8) {
                        ForEach([Color.blue, .purple, .orange], id: \.self) { c in
                            VStack(spacing: 0) { c.opacity(0.75).frame(height: 36); Color.white.frame(height: 22) }
                                .frame(width: 90).clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.1)))
                        }
                    }
                    Spacer()
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CanvasSideNav: View {
    var highlightAccount = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "graduationcap.fill").foregroundStyle(.white).font(.system(size: 16)).padding(.top, 10)
            navItem("person.crop.circle.fill", "Account").modifier(ConditionalHighlight(on: highlightAccount))
            navItem("speedometer", "Dashboard")
            navItem("book.closed", "Courses")
            navItem("calendar", "Calendar")
            navItem("tray", "Inbox")
            Spacer()
        }
        .frame(width: 64).background(canvasNav)
    }
    private func navItem(_ icon: String, _ t: String) -> some View {
        VStack(spacing: 2) { Image(systemName: icon).font(.system(size: 15)); Text(t).font(.system(size: 8)) }.foregroundStyle(.white)
    }
}

private struct ConditionalHighlight: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { if on { content.highlight("1. Account") } else { content } }
}

private struct AccountMenuMock: View {
    var body: some View {
        HStack(spacing: 0) {
            CanvasSideNav(highlightAccount: true)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Circle().fill(Color.gray.opacity(0.3)).frame(width: 30)
                    Text("Your Name").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                }
                ForEach(["Notifications", "Profile", "Files"], id: \.self) {
                    Text($0).font(.system(size: 12)).foregroundStyle(canvasBlue)
                }
                Text("Settings").font(.system(size: 12, weight: .semibold)).foregroundStyle(canvasBlue).highlight("2. Settings")
                Text("ePortfolios").font(.system(size: 12)).foregroundStyle(canvasBlue)
                Spacer()
            }
            .padding(14).frame(width: 190, alignment: .leading)
            .background(Color.white.shadow(.drop(color: .black.opacity(0.15), radius: 6)))
            Color(white: 0.97)
        }
    }
}

private struct IntegrationsMock: View {
    var body: some View {
        HStack(spacing: 0) {
            CanvasSideNav()
            VStack(alignment: .leading, spacing: 10) {
                Text("Approved Integrations").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                Text("These are the third-party applications you have authorized to access the Canvas site on your behalf:")
                    .font(.system(size: 10)).foregroundStyle(.black.opacity(0.6))
                HStack {
                    ForEach(["App", "Purpose", "Dates", "Last Used"], id: \.self) {
                        Text($0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.black.opacity(0.7)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6).background(Color(white: 0.95))
                HStack {
                    Spacer()
                    Text("+ New Access Token").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(canvasBlue))
                        .highlight(edge: .bottom)
                    Spacer()
                }
                Spacer()
            }
            .padding(14)
        }
    }
}

private struct NewTokenMock: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 9) {
                Text("New Access Token").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                Divider()
                field("Purpose", "Onyx", mark: true)
                field("Expires", "", mark: false)
                HStack {
                    Spacer()
                    Text("Cancel").font(.system(size: 11)).foregroundStyle(.black).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.92)))
                    Text("Generate Token").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(canvasBlue))
                        .highlight("Then click", edge: .bottom)
                }
            }
            .padding(14).frame(width: 330)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .offset(y: -12)
        }
    }
    private func field(_ l: String, _ v: String, mark: Bool) -> some View {
        HStack {
            Text(l).font(.system(size: 11)).foregroundStyle(.black.opacity(0.7)).frame(width: 56, alignment: .leading)
            Text(v.isEmpty ? " " : v).font(.system(size: 11)).foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading).padding(5)
                .background(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25)))
                .modifier(TypeHere(on: mark))
        }
    }
}

private struct TypeHere: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: 2.5).padding(-3)) } else { content }
    }
}

private struct TokenDetailsMock: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 9) {
                Text("Access Token Details").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                Divider()
                Text("Your access token is shown below. Copy it now — it won't be shown in full again.")
                    .font(.system(size: 10)).foregroundStyle(.black.opacity(0.65))
                HStack {
                    Text("Token").font(.system(size: 11)).foregroundStyle(.black.opacity(0.7)).frame(width: 44, alignment: .leading)
                    Text("7~aB3dEfGh1JkLmN0pQrStUvWxYz…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.black)
                        .padding(5).background(Color.yellow.opacity(0.25))
                        .highlight("Select all · ⌘C", edge: .bottom)
                }
                Spacer().frame(height: 18)
            }
            .padding(14).frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .offset(y: -10)
        }
    }
}

private struct OnyxFieldsMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Onyx Settings › Live › Canvas").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.7))
            row("School's Canvas address", "yourschool.instructure.com")
            row("Access token", "••••••••••••••••••••")
            HStack {
                Text("Connect").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                    .highlight("Click", edge: .trailing)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.96))
    }
    private func row(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l).font(.system(size: 11)).foregroundStyle(.black.opacity(0.7)).frame(width: 150, alignment: .leading)
            Text(v).font(.system(size: 11)).foregroundStyle(.black).frame(maxWidth: .infinity, alignment: .leading).padding(5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.15)))
        }
    }
}
