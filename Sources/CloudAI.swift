import AppKit
import SwiftUI
import FoundationModels

// MARK: - Cloud models: Onyx AI can run on Claude, ChatGPT, Gemini, Grok and others with your own API key.
// Apple's on-device model stays the default (free and private). Keys live in your Keychain, and they're only read when
// a cloud model is actually used.

enum AIProvider: String, CaseIterable, Identifiable {
    case apple, anthropic, openai, gemini, xai, mistral, deepseek, groq, openrouter, ollama, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: OS.mayHaveAppleAI ? "Apple on-device (free, private)" : "Apple on-device (\(OS.noAppleAIReason))"
        case .anthropic: "Claude (Anthropic)"
        case .openai: "ChatGPT (OpenAI)"
        case .gemini: "Gemini (Google, free with your Google account)"
        case .xai: "Grok (xAI)"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .groq: "Groq"
        case .openrouter: "OpenRouter (hundreds of models)"
        case .ollama: "Ollama (models on this Mac)"
        case .custom: "Other (OpenAI-compatible)"
        }
    }
    var short: String {
        switch self {
        case .apple: "Apple"
        case .anthropic: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        case .xai: "Grok"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .groq: "Groq"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama"
        case .custom: "Custom"
        }
    }
    var anthropicAPI: Bool { self == .anthropic }
    var needsKey: Bool { self != .apple && self != .ollama }
    var baseURL: String {
        if let test = ProcessInfo.processInfo.environment["ONYX_AI_BASE"] { return test }   // tests: a local stand-in server
        return switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openai: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .xai: "https://api.x.ai/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: UserDefaults.standard.string(forKey: "ai.custom.url") ?? ""
        case .apple: ""
        }
    }
    var keyPage: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .xai: URL(string: "https://console.x.ai")
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .ollama: URL(string: "https://ollama.com/download")
        default: nil
        }
    }
    /// Used until you pick one from the provider's list (which Onyx fetches once your key is in).
    var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5"
        case .openai: "gpt-5"
        case .gemini: "gemini-2.5-flash"
        case .xai: "grok-4"
        case .mistral: "mistral-large-latest"
        case .deepseek: "deepseek-chat"
        case .groq: "llama-3.3-70b-versatile"
        case .openrouter: "anthropic/claude-sonnet-5"
        case .ollama: "llama3.2"
        default: ""
        }
    }
}

struct CloudMessage {
    enum Role { case user, assistant }
    var role: Role
    var text: String
    var images: [Data] = []   // JPEG
}

struct CloudError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CloudAI {
    static let providerKey = "ai.provider"
    static var provider: AIProvider { AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .apple }
    static var active: Bool { provider != .apple && ProcessInfo.processInfo.environment["ONYX_AI_FORCE_APPLE"] == nil }
    static func modelKey(_ p: AIProvider) -> String { "ai.model.\(p.rawValue)" }
    static func model(_ p: AIProvider = provider) -> String {
        let m = UserDefaults.standard.string(forKey: modelKey(p)) ?? ""
        return m.isEmpty ? p.defaultModel : m
    }
    static func keyAccount(_ p: AIProvider) -> String { "ai.key.\(p.rawValue)" }
    /// ONYX_AI_TEST_KEY supplies a key for automated tests without touching the Keychain.
    static func key(_ p: AIProvider) -> String? {
        if let k = ProcessInfo.processInfo.environment["ONYX_AI_TEST_KEY"] { return k }
        return p.needsKey ? Keychain.get(keyAccount(p)) : ""
    }
    static var label: String { active ? "\(provider.short) · \(model())" : "Apple on-device" }

    // MARK: Requests

    private static func request(_ p: AIProvider, path: String, body: [String: Any]?) throws -> URLRequest {
        guard let url = URL(string: p.baseURL + path) else { throw CloudError(message: "The server address for \(p.short) isn't valid.") }
        var r = URLRequest(url: url, timeoutInterval: 90)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = key(p) ?? ""
        if p.needsKey && key.isEmpty { throw CloudError(message: "Add your \(p.short) API key in Settings › Privacy › AI.") }
        if p.anthropicAPI {
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if p == .openrouter { r.setValue("https://github.com/qPublic/Onyx", forHTTPHeaderField: "HTTP-Referer"); r.setValue("Onyx", forHTTPHeaderField: "X-Title") }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private static func send(_ r: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch code {
            case 401, 403: throw CloudError(message: "\(provider.short) didn't accept the API key. Check it in Settings › Privacy › AI.")
            case 429: throw CloudError(message: "\(provider.short) says you're over your rate or spending limit: \(msg)")
            default: throw CloudError(message: "\(provider.short) error \(code): \(msg)")
            }
        }
        return json
    }

    /// The provider's model list (for the picker in Settings).
    static func models(_ p: AIProvider) async throws -> [String] {
        let j = try await send(try request(p, path: "/models", body: nil))
        let ids = ((j["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.map { $0.replacingOccurrences(of: "models/", with: "") }
        let chatty = ids.filter { id in !["embed", "whisper", "tts", "dall-e", "image", "moderation", "audio", "transcribe", "realtime", "search"].contains { id.lowercased().contains($0) } }
        return chatty.sorted()
    }

    /// One answer, no tools.
    static func complete(system: String, prompt: String, maxTokens: Int = 800, images: [Data] = []) async throws -> String {
        try await chat(system: system, history: [CloudMessage(role: .user, text: prompt, images: images)], tools: [], maxTokens: maxTokens, onTool: { _, _ in })
    }

    /// A conversation turn with tools: calls the model, runs any tools it asks for, and repeats until it answers.
    static func chat(system: String, history: [CloudMessage], tools: [AgentTool], maxTokens: Int = 1500,
                     onTool: @escaping (String, String) -> Void) async throws -> String {
        let p = provider, m = model(p)
        var msgs: [[String: Any]] = history.map { encode($0, anthropic: p.anthropicAPI) }
        var useTools = !tools.isEmpty
        for _ in 0..<8 {
            try Task.checkCancellation()
            var body: [String: Any] = ["model": m, "messages": p.anthropicAPI ? msgs : [["role": "system", "content": system]] + msgs]
            if p.anthropicAPI { body["system"] = system; body["max_tokens"] = maxTokens }
            if useTools { body["tools"] = tools.map { schema($0, anthropic: p.anthropicAPI) } }
            let j: [String: Any]
            do { j = try await send(try request(p, path: p.anthropicAPI ? "/messages" : "/chat/completions", body: body)) }
            catch let e as CloudError where useTools && e.message.lowercased().contains("tool") {
                useTools = false; continue   // a model that can't use tools: ask again without them
            }
            if p.anthropicAPI {
                let blocks = j["content"] as? [[String: Any]] ?? []
                let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                let uses = blocks.filter { $0["type"] as? String == "tool_use" }
                guard !uses.isEmpty else { return text }
                msgs.append(["role": "assistant", "content": blocks])
                var results: [[String: Any]] = []
                for u in uses {
                    let name = u["name"] as? String ?? "", input = u["input"] as? [String: Any] ?? [:]
                    let out = await run(name, input, tools: tools)
                    onTool(name, out)
                    results.append(["type": "tool_result", "tool_use_id": u["id"] as? String ?? "", "content": out])
                }
                msgs.append(["role": "user", "content": results])
            } else {
                let msg = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
                let text = msg["content"] as? String ?? ""
                let calls = msg["tool_calls"] as? [[String: Any]] ?? []
                guard !calls.isEmpty else { return text }
                msgs.append(["role": "assistant", "content": text, "tool_calls": calls])
                for c in calls {
                    let f = c["function"] as? [String: Any] ?? [:], name = f["name"] as? String ?? ""
                    let args = (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    let out = await run(name, args, tools: tools)
                    onTool(name, out)
                    msgs.append(["role": "tool", "tool_call_id": c["id"] as? String ?? "", "content": out])
                }
            }
        }
        throw CloudError(message: "\(p.short) kept calling tools without answering.")
    }

    private static func run(_ name: String, _ input: [String: Any], tools: [AgentTool]) async -> String {
        guard let t = tools.first(where: { $0.name == name }) else { return "No tool called \(name)" }
        let strings = input.mapValues { v -> String in (v as? String) ?? "\(v)" }
        guard let d = try? JSONSerialization.data(withJSONObject: strings), let json = String(data: d, encoding: .utf8),
              let args = try? ToolArgs(json: json) else { return "Couldn't read the arguments" }
        do { return try await t.call(arguments: args) } catch { return "TOOL ERROR: \(error.localizedDescription)" }
    }

    private static func schema(_ t: AgentTool, anthropic: Bool) -> [String: Any] {
        let props = Dictionary(uniqueKeysWithValues: t.params.map { ($0.name, ["type": "string", "description": $0.info] as [String: Any]) })
        let params: [String: Any] = ["type": "object", "properties": props, "required": t.params.filter { !$0.optional }.map(\.name)]
        return anthropic ? ["name": t.name, "description": t.description, "input_schema": params]
                         : ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": params]]
    }

    private static func encode(_ m: CloudMessage, anthropic: Bool) -> [String: Any] {
        let role = m.role == .user ? "user" : "assistant"
        guard !m.images.isEmpty else { return ["role": role, "content": m.text] }
        var parts: [[String: Any]] = m.images.map { d in
            anthropic ? ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": d.base64EncodedString()]]
                      : ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]]
        }
        parts.append(["type": "text", "text": m.text])
        return ["role": role, "content": parts]
    }

    /// A picture as JPEG, at most 1568 px on its long side (what the big models read best).
    static func jpeg(_ img: CGImage) -> Data? {
        let scale = min(1, 1568 / Double(max(img.width, img.height)))
        let w = Int(Double(img.width) * scale), h = Int(Double(img.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

// MARK: - Settings › Privacy › AI › Model

struct AIModelSettings: View {
    @AppStorage(CloudAI.providerKey) private var providerRaw = AIProvider.apple.rawValue
    @AppStorage("ai.custom.url") private var customURL = ""
    @State private var key = ""
    @State private var hasKey = false
    @State private var model = ""
    @State private var models: [String] = []
    @State private var status: String?
    @State private var testing = false
    private var p: AIProvider { AIProvider(rawValue: providerRaw) ?? .apple }

    var body: some View {
        Picker("Model", selection: $providerRaw) {
            ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .onChange(of: providerRaw) { _, _ in load() }
        .onAppear { load() }
        if p == .apple && !OS.mayHaveAppleAI {
            Text("Apple's free on-device AI \(OS.noAppleAIReason), so Onyx AI is off on this Mac. Pick Gemini above for a free key with your Google account, or Ollama to run a model on this Mac.")
                .font(.caption).foregroundStyle(.orange)
        } else if p == .apple {
            Text("Runs on your Mac: free, private and offline. It's a small model, so for hard questions you can switch to a bigger one here.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            if p == .custom { TextField("Server address, like https://example.com/v1", text: $customURL) }
            if p.needsKey {
                HStack {
                    SecureField(hasKey ? "Key saved in your Keychain (paste a new one to replace it)" : "Paste your \(p.short) API key", text: $key)
                    Button("Save") { saveKey() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey { Button("Remove", role: .destructive) { Keychain.delete(CloudAI.keyAccount(p)); hasKey = false; models = [] } }
                }
            }
            if let page = p.keyPage { Link(p == .ollama ? "Get Ollama" : p == .gemini ? "Get a free Gemini key with your Google account" : "Get a \(p.short) API key", destination: page).font(.caption) }
            if p == .anthropic {
                Text("Claude needs an API key, and Anthropic charges for it. Signing in with your Claude or Google account only works in Anthropic's own apps, not in other apps like Onyx. For a big model that's free, pick Gemini and get a free key with your Google account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if p == .gemini {
                Text("Free: sign in to Google AI Studio with your Google account, press Create API key and paste it here. The free tier has daily limits, and Google may use what you send it to improve its models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Model", text: $model).onSubmit(saveModel)
                if !models.isEmpty {
                    Menu("Choose") { ForEach(models, id: \.self) { m in Button(m) { model = m; saveModel() } } }.fixedSize()
                }
                Button(testing ? "Testing…" : "Test") { Task { await test() } }.disabled(testing)
            }
            if let status { Text(status).font(.caption).foregroundStyle(status.hasPrefix("✓") ? .green : .orange) }
            Text("With \(p.short), what you ask Onyx AI goes to \(p == .ollama ? "Ollama on this Mac" : p.short), along with anything you attach: pictures, files, selected text and your screen when you let it look. \(p == .ollama ? "Nothing leaves your Mac." : "Their pricing and privacy terms apply.") Memory, briefings, Circle to Search, flashcards and Create with AI's planning use it too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        model = UserDefaults.standard.string(forKey: CloudAI.modelKey(p)) ?? p.defaultModel
        hasKey = p.needsKey && (Keychain.get(CloudAI.keyAccount(p))?.isEmpty == false)
        models = []; status = nil; key = ""
        if hasKey || !p.needsKey, p != .apple { Task { await fetchModels() } }
    }
    private func saveKey() {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: CloudAI.keyAccount(p))
        key = ""; hasKey = true
        Task { await fetchModels(); await test() }
    }
    private func saveModel() { UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: CloudAI.modelKey(p)) }
    private func fetchModels() async { models = (try? await CloudAI.models(p)) ?? [] }
    private func test() async {
        saveModel(); testing = true; defer { testing = false }
        do {
            let r = try await CloudAI.complete(system: "Reply in five words or fewer.", prompt: "Say hello to the user.", maxTokens: 40)
            status = "✓ \(CloudAI.model()) answered: \(r.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))"
        } catch { status = error.localizedDescription }
    }
}
