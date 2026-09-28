import AppKit
import SwiftUI
import AVFoundation
import VideoToolbox
import CoreML
import Vision
import Metal
import MetalKit
import ImagePlayground
import FoundationModels
import UniformTypeIdentifiers

// MARK: - Create with AI: describe anything (a game's world, a place, a mood) or bring your own picture, and Onyx
// turns it into a looping live wallpaper, all on this Mac. Apple's on-device model plans it and picks the weather,
// Image Playground paints it, a depth model works out what's near and far, Apple's upscaler sharpens it to 4K,
// and the GPU animates it (see `living` in Scenes.swift) into a loop whose last frame runs straight into its first.

enum LoopEffect: String, CaseIterable {
    case rain, snow, embers, fireflies, stars, fog, leaves, petals, dust, bubbles, wind, lights
}

extension LoopEffect: Identifiable {
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .rain: "cloud.rain"
        case .snow: "snowflake"
        case .embers: "flame"
        case .fireflies: "sparkle"
        case .stars: "star"
        case .fog: "cloud.fog"
        case .leaves: "leaf"
        case .petals: "camera.macro"
        case .dust: "sun.dust"
        case .bubbles: "bubbles.and.sparkles"
        case .wind: "wind"
        case .lights: "lightbulb.max"
        }
    }
    /// Its switch in the shader.
    var bit: UInt32 { 1 << UInt32(Self.allCases.firstIndex(of: self)!) }

    /// Words that hint at each effect. They make the guess below, and back up (or veto) the on-device model's picks.
    static let clues: [(LoopEffect, [String])] = [
            (.rain, ["rain", "storm", "cyberpunk", "neon", "monsoon", "wet"]), (.snow, ["snow", "winter", "christmas", "ice", "frozen", "arctic", "skyrim"]),
            (.embers, ["fire", "lava", "volcano", "forge", "campfire", "hell", "ember", "dragon", "nether", "torch", "flame", "fiery", "molten", "underworld"]),
            (.fireflies, ["firefl", "forest", "swamp", "meadow", "summer night", "garden", "zelda"]),
            (.stars, ["night", "space", "star", "galaxy", "moon", "cosmic"]), (.fog, ["fog", "mist", "haunt", "spooky", "horror", "ghost", "lake", "mountain", "morning"]),
            (.leaves, ["autumn", "fall", "leaves", "harvest"]), (.petals, ["sakura", "cherry", "blossom", "spring", "japan"]),
            (.dust, ["desert", "sunbeam", "library", "cozy", "ruins", "dusty", "attic"]), (.bubbles, ["underwater", "ocean", "reef", "aquarium", "sea floor", "subnautica"]),
            (.wind, ["grass", "field", "prairie", "windy", "plains", "minecraft"]),
            (.lights, ["lantern", "castle", "village", "cabin", "window", "street", "tavern", "candle", "town", "lamp", "neon", "torch", "lighthouse", "city"]),
        ]
    /// Without Apple Intelligence: a best guess from the words in the idea.
    static func guess(_ text: String) -> [LoopEffect] {
        let hits = LoopEffect.hinted(by: text)
        return hits.isEmpty ? [.dust, .wind] : Array(hits.prefix(2))
    }
    static func hinted(by text: String) -> [LoopEffect] {
        let t = text.lowercased()
        return clues.filter { $0.1.contains { t.contains($0) } }.map(\.0)
    }
}

/// What the on-device model fills in (a schema built at runtime, so it doesn't need Xcode's macros to compile).
enum LoopPlan {
    static let schema: GenerationSchema? = try? GenerationSchema(root: DynamicGenerationSchema(name: "LoopPlan", properties: [
        .init(name: "name", description: "A short name for the wallpaper, 1 to 4 words", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "subject", description: "The character or creature the user asked to see, described only by how it looks: what it is, its shape and colors, and clothes or armor if it wears any, under 15 words (for example 'a tall knight in ornate golden armor with a tattered red cape'). Not scenery. An empty string if the user didn't ask for one.",
              schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "scene", description: "One wide, scenic view for an image generator, under 40 words. If there is a subject, start with it, in the foreground. Keep every place, thing and time of day from the idea, and add the light, colors and mood. Describe how things look instead of naming games, films, brands or characters.",
              schema: DynamicGenerationSchema(type: String.self)),
    ] + questions.map { .init(name: $0.0.rawValue, description: $0.1, schema: DynamicGenerationSchema(type: Bool.self)) }), dependencies: [])

    /// A yes or no for each effect about the scene it just wrote (the small model picks far better this way than from a
    /// list), in the order they win when more than two fit.
    static let questions: [(LoopEffect, String)] = [
        (.rain, "Is it raining in the scene?"), (.snow, "Is there snow or is it winter?"), (.bubbles, "Is the scene underwater?"),
        (.embers, "Is there fire, lava, torches or a forge?"), (.petals, "Are there blossoming trees, like cherry blossoms?"),
        (.leaves, "Is it autumn with colored leaves?"), (.lights, "Are there lit windows, lamps, lanterns or neon signs?"),
        (.fireflies, "Is it a forest, meadow or garden at dusk or night?"), (.stars, "Is the sky dark enough to see stars?"),
        (.fog, "Is there mist or fog?"), (.dust, "Is it dry and dusty, like a desert, ruins or a sunlit room?"),
        (.wind, "Is there grass or leafy trees outdoors?"),
    ]
}

extension ImagePlaygroundStyle {
    var title: String {
        self == .animation ? "Animation" : self == .illustration ? "Illustration" : self == .sketch ? "Sketch"
            : self == .externalProvider ? "ChatGPT" : id.capitalized
    }
}

/// The look of the painting. Realistic, Anime and Painted come from on-device Stable Diffusion models (a one-time
/// download each); Animated and Illustration from Image Playground.
enum ArtStyle: String, CaseIterable, Identifiable {
    case realistic, anime, painted, animated, illustration
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .realistic: "camera.fill"
        case .anime: "sparkles"
        case .painted: "paintbrush.pointed.fill"
        case .animated: "cube.fill"
        case .illustration: "pencil.and.scribble"
        }
    }
    var blurb: String {
        switch self {
        case .realistic: "Like a photograph"
        case .anime: "Anime background art"
        case .painted: "Painted concept art"
        case .animated: "3D animated film"
        case .illustration: "Bold, flat artwork"
        }
    }
    var diffusion: DiffusionStyle? { DiffusionStyle(rawValue: rawValue) }
    var playground: ImagePlaygroundStyle? { self == .animated ? .animation : self == .illustration ? .illustration : nil }
}

@MainActor final class LoopMaker: ObservableObject {
    static let shared = LoopMaker()
    enum Step: Equatable { case idle, thinking, drawing, pick, working(String, Double), done(String), failed(String) }
    @Published var step: Step = .idle
    @Published var images: [CGImage] = []
    @Published var name = ""
    @Published var scene = ""
    @Published var effects: Set<LoopEffect> = []
    @Published private(set) var styles: [ImagePlaygroundStyle] = []
    @Published private(set) var canDraw: Bool?
    @Published var detail = ""                 // what's happening while it paints
    @Published var progress = 0.0
    @Published private(set) var art: ArtStyle?  // how the pictures on offer were made (nil for your own picture)
    @Published var subject = ""                // the character or thing you asked for, if any
    @Published var checkNote: String?          // what checking the pictures found
    @Published var checkOK = false
    static let grain: UInt32 = 1 << 12          // the shader's film-grain switch, for photo-like loops
    private var task: Task<Void, Never>?
    private var painting: Task<Void, Error>?

    var busy: Bool {
        switch step { case .thinking, .drawing, .working: true; default: false }
    }

    func checkImagePlayground() async {
        guard canDraw == nil else { return }
        let suitable: [ImagePlaygroundStyle] = [.animation, .illustration, .sketch, .externalProvider]   // not Emoji or Messages backgrounds
        do { styles = try await ImageCreator().availableStyles.filter { suitable.contains($0) }; canDraw = !styles.isEmpty } catch { canDraw = false }
    }

    /// Plans the loop from an idea, then paints versions of it to choose from: two with Stable Diffusion (Realistic, Anime,
    /// Painted), up to four with Image Playground (Animated, Illustration).
    func imagine(_ idea: String, art: ArtStyle, picture: CGImage? = nil) {
        images = []; step = .thinking; detail = ""; progress = 0; self.art = art; checkNote = nil; checkOK = false
        task = Task {
            let awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Painting a live wallpaper")   // no App Nap if you switch away
            defer { ProcessInfo.processInfo.endActivity(awake) }
            let p = await Self.plan(idea, style: art.title)
            name = p.name; scene = p.scene; effects = Set(p.effects); subject = p.subject
            step = .drawing
            do {
                @MainActor func paint(_ scene: String) async throws {
                    if let sd = art.diffusion, picture == nil {
                        if !sd.ready {
                            detail = "Downloading the \(art.title) style (2 GB, just this once)…"
                            try await sd.download { p in Task { @MainActor in LoopMaker.shared.progress = p } }
                        }
                        detail = "Painting…"; progress = 0
                        let people = !p.subject.isEmpty
                        painting = Task.detached(priority: .userInitiated) {
                            try Diffusion(sd).paint(scene, people: people, count: 2, isCancelled: { Task.isCancelled }, progress: { done, total in
                                Task { @MainActor in LoopMaker.shared.progress = Double(done) / Double(total) }
                            }, each: { img in
                                let made = img
                                Task { @MainActor in LoopMaker.shared.images.append(made) }
                            })
                        }
                        try await painting?.value
                        try await Task.sleep(for: .milliseconds(100))   // let the last picture land
                    } else {
                        NSApp.activate()   // Image Playground only draws for the app in front
                        let creator = try await ImageCreator()
                        var concepts: [ImagePlaygroundConcept] = [.text(scene)]
                        if let picture { concepts.insert(.image(picture), at: 0) }
                        for try await made in creator.images(for: concepts, style: art.playground ?? .animation, limit: 4) { images.append(made.cgImage) }
                    }
                }
                try await paint(p.scene)
                // Asked for someone or something? Look for it in what got painted, and paint again if it's missing.
                if !p.subject.isEmpty && !images.isEmpty && picture == nil {
                    try await checkWork(p.subject) { try await paint(p.subject + ", " + p.scene) }
                }
                step = images.isEmpty ? .failed("Nothing got painted. Try describing it differently.") : .pick
            } catch let e as ImageCreator.Error {
                step = images.isEmpty ? (e == .creationCancelled ? .idle : .failed(Self.message(e))) : .pick
            } catch {
                step = images.isEmpty ? (error is CancellationError ? .idle : .failed(error.localizedDescription)) : .pick
            }
        }
    }

    /// Checks each picture for the subject with MobileCLIP, puts the ones that show it first, and paints once more with the
    /// subject up front if none do. Checking is a bonus: if it can't run, the pictures are offered as they are.
    private func checkWork(_ subject: String, repaint: () async throws -> Void) async throws {
        do {
            if !LoopChecker.ready {
                detail = "Getting the picture checker (200 MB, just this once)…"; progress = 0
                try await LoopChecker.download { p in Task { @MainActor in LoopMaker.shared.progress = p } }
            }
            let who = LoopChecker.label(subject)
            detail = "Checking the pictures for \(who)"
            var found = try await LoopChecker.scores(images, subject: subject)
            if !found.contains(where: { $0 >= LoopChecker.threshold }) {
                detail = "Painting again: those were missing \(who)"
                let before = images.count
                try await repaint()
                found += try await LoopChecker.scores(Array(images[before...]), subject: subject)
            }
            let order = found.indices.sorted { found[$0] > found[$1] }
            images = order.map { images[$0] }
            let hits = found.filter { $0 >= LoopChecker.threshold }.count
            checkOK = hits > 0
            checkNote = hits > 0 ? "Checked: \(hits) of \(found.count) show \(who)" : "None clearly show \(who), so the closest are first. Try describing it differently."
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            checkNote = nil
        }
    }

    /// Your own picture, used as it is.
    func use(_ picture: CGImage, name: String, idea: String) {
        art = nil; checkNote = nil
        task = Task {
            images = [picture]; step = .thinking
            let p = await Self.plan(idea.isEmpty ? name : idea)
            self.name = idea.isEmpty ? name : p.name
            scene = idea.isEmpty ? name : p.scene
            effects = Set(p.effects)
            step = .pick
        }
    }

    /// Animates the chosen picture into a loop, adds it to the library and puts it on.
    func make(_ picture: CGImage, motion: Float) {
        let fx = effects.reduce(art == .realistic ? Self.grain : 0) { $0 | $1.bit }, prompt = scene, title = name.isEmpty ? "AI Loop" : name
        step = .working("Getting started…", 0)
        task = Task {
            let awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Making a live wallpaper")
            defer { ProcessInfo.processInfo.endActivity(awake) }
            do {
                let url = try await Self.build(picture, fx: fx, motion: motion) { stage, p in
                    Task { @MainActor in if self.busy { self.step = .working(stage, p) } }
                }
                try Task.checkCancellation()
                let w = try await WallpaperLibrary.shared.add(url, name: title, move: true, prompt: prompt)
                WallpaperEngine.shared.set(w)
                step = .done(w.id)
            } catch is CancellationError {
                step = .pick
            } catch {
                step = .failed((error as? VoiceError)?.message ?? error.localizedDescription)
            }
        }
    }

    func cancel() { painting?.cancel(); task?.cancel() }
    func reset() { if !busy { step = .idle; images = [] } }

    static func message(_ e: ImageCreator.Error) -> String {
        switch e {
        case .notSupported: "Image Playground doesn't work on this Mac. You can still bring your own picture to life."
        case .unavailable: "Image Playground isn't ready. Turn on Apple Intelligence in System Settings and let it finish downloading, or use your own picture."
        case .conceptsRequirePersonIdentity, .faceInImageTooSmall: "Image Playground can't draw people for this. Describe a place instead."
        case .unsupportedLanguage: "Image Playground didn't understand that language. Try English."
        case .unsupportedInputImage: "Image Playground can't use that picture. Try a different one."
        case .backgroundCreationForbidden: "Keep the Live Wallpapers window in front while it draws."
        case .creationCancelled: "Stopped."
        default: "Image Playground couldn't draw that. Try describing it a different way."
        }
    }

    // MARK: Planning

    /// How well-known game worlds look, since the small on-device model often doesn't know. Only the look is passed
    /// on to the painter, never the name.
    nonisolated static let looks: [(keys: [String], look: String)] = [
        (["minecraft"], "blocky voxel world built from cubes, pixelated square textures, cube-shaped trees, hills and clouds"),
        (["zelda", "hyrule", "breath of the wild", "tears of the kingdom"], "painterly cel-shaded fantasy landscape, soft watercolor grass, rolling hills, ancient stone ruins"),
        (["stardew"], "cozy 16-bit pixel art farm, pixel crops, wooden fences and a little farmhouse"),
        (["terraria"], "2D pixel art side-view world, layered pixel forest over glowing caves"),
        (["animal crossing"], "cute rounded toy-like island village, soft pastel colors"),
        (["pokemon", "pokémon"], "bright anime-style meadow, rolling hills and tall grass"),
        (["fortnite"], "bright stylized cartoon island, saturated colors, chunky shapes"),
        (["elden ring"], "dark epic fantasy, a colossal glowing golden tree in the sky, misty castle ruins"),
        (["dark souls", "bloodborne"], "gothic ruined castles under an ashen sky, eerie mist"),
        (["skyrim", "elder scrolls"], "snowy Nordic mountains, pine forests, ancient stone watchtowers, aurora"),
        (["hollow knight"], "hand-drawn 2D gothic underground kingdom, blue and black ink tones, glowing lanterns"),
        (["celeste"], "pixel art snowy mountain at night, purple and teal tones"),
        (["cyberpunk", "blade runner"], "rain-soaked neon megacity at night, holographic billboards, towering skyscrapers"),
        (["no man's sky", "no mans sky"], "vivid alien planet, strange colorful plants, giant planets in the sky"),
        (["subnautica"], "underwater alien ocean, bioluminescent coral, light rays from above"),
        (["halo"], "sci-fi ringworld arching into the sky over green grassland, sleek alien structures"),
        (["destiny", "starfield"], "rocky alien world with ancient megastructures and a huge ringed planet in the sky"),
        (["genshin", "honkai"], "anime-style fantasy landscape, floating islands, vivid skies"),
        (["mario"], "bright cartoon world of green pipes, floating blocks and round grassy hills"),
        (["sonic"], "checkered green hills with loops, palm trees, bright blue sky"),
        (["roblox"], "blocky low-poly toy world, simple bright plastic shapes"),
        (["overwatch", "valorant"], "stylized futuristic city with vibrant painterly colors"),
        (["journey"], "vast golden sand dunes, flowing red cloth banners, a glowing distant mountain"),
        (["red dead", "wild west"], "wild west frontier at golden hour, red rock canyons, dusty plains"),
        (["gta", "grand theft auto", "vice city"], "sunny coastal city, palm trees, neon sunset over the skyline"),
        (["witcher"], "misty medieval countryside, dark forests, an old stone castle"),
        (["final fantasy"], "epic fantasy landscape with crystal spires and airships"),
        (["ghibli", "totoro"], "hand-painted anime countryside, fluffy summer clouds, lush green hills"),
        (["hades"], "fiery underworld, glowing red rivers, dramatic ink-outlined art"),
        (["among us"], "cartoon spaceship interior window looking out at stars"),
    ]
    nonisolated static func look(for idea: String) -> String? {
        let t = idea.lowercased()
        return looks.first { $0.keys.contains { t.contains($0) } }?.look
    }

    nonisolated(unsafe) static var planError: String?   // why the last plan fell back to the word-based guess (for tests)

    nonisolated static func plan(_ idea: String, style: String? = nil) async -> (name: String, scene: String, effects: [LoopEffect], subject: String) {
        let trimmed = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        let look = look(for: trimmed)
        let someone = asksForSomeone(trimmed)
        let fallback = (name: trimmed.split(separator: " ").prefix(4).joined(separator: " ").capitalized, scene: (look.map { $0 + ", " } ?? "") + trimmed + ", wide scenic landscape",
                        effects: LoopEffect.guess(trimmed), subject: someone ? trimmed : "")
        planError = nil
        guard case .available = SystemLanguageModel.default.availability, !trimmed.isEmpty, let schema = LoopPlan.schema else { return fallback }
        let styleLine = style.map { "\nIt will be drawn in a \($0.lowercased()) style." } ?? ""
        let who = someone ? "\nThe idea asks for a character or creature. Keep the one it names; if it just says character, invent one that fits this world."
            : "\nNo characters, people or animals: just the place."
        var prompt = "Wallpaper idea: \(trimmed)" + (look.map { "\nIts art style: \($0)" } ?? "") + who + styleLine
        for attempt in 0..<3 {
            do {
                let s = LanguageModelSession(instructions: """
                    You plan looping animated desktop wallpapers. If the idea names a video game, film, show or other world, \
                    describe its distinctive art style first (for example blocky voxel cubes, pixel art, cel-shaded, low-poly or painterly) \
                    and its signature scenery, colors and lighting (and its typical characters, if asked for one), without using its name. \
                    Then answer each question about your scene.
                    """)
                let p = try await s.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0.6)).content
                var name = try p.value(String.self, forProperty: "name").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
                if name == name.lowercased() { name = name.capitalized }
                var scene = brief(try p.value(String.self, forProperty: "scene"), dropping: style.map { "\($0.lowercased()) style" })   // it sometimes repeats the style line
                if let look, !look.split(separator: ",").contains(where: { scene.lowercased().contains($0.split(separator: " ").prefix(2).joined(separator: " ").lowercased()) }) {
                    scene = look + ". " + scene   // keep the look
                }
                // A yes only counts when the words back it up, so a sunny meadow doesn't get stars.
                let dark = ["night", "dusk", "evening", "twilight", "dark", "moon"].contains { (trimmed + " " + scene).lowercased().contains($0) }
                let hinted = LoopEffect.hinted(by: trimmed + " " + scene).filter { dark || $0 != .fireflies }   // no fireflies in daylight
                let fx = LoopPlan.questions.map(\.0).filter { (try? p.value(Bool.self, forProperty: $0.rawValue)) == true && hinted.contains($0) }
                let picks = Array((fx.isEmpty ? hinted : fx).prefix(2))
                // A subject only when the idea asks for someone or something, not one it made up for a plain landscape.
                var subject = (try? p.value(String.self, forProperty: "subject"))?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\".'"))) ?? ""
                if !someone || ["none", "n/a", "nothing"].contains(subject.lowercased()) { subject = "" }
                if someone && subject.isEmpty { subject = trimmed }
                subject = subject.split(separator: " ").prefix(18).joined(separator: " ")
                // The painter pays most attention to the start, so that's where the subject goes.
                if !subject.isEmpty && !scene.lowercased().hasPrefix(subject.lowercased().prefix(12)) { scene = subject + ". " + brief(scene, words: 35) }
                return (name.isEmpty ? fallback.name : name, scene.isEmpty ? fallback.scene : scene, picks.isEmpty ? [.dust, .wind] : picks, subject)
            } catch let e as LanguageModelSession.GenerationError where attempt < 2 {
                planError = "\(e)"
                switch e {
                case .rateLimited, .concurrentRequests: try? await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))   // busy: wait a moment
                case .guardrailViolation, .refusal:   // some game names trip the safety filter: ask again with just the look
                    guard let look else { return fallback }
                    prompt = "Wallpaper idea: a scenic world drawn as \(look)" + who + styleLine
                default: return fallback
                }
            } catch { planError = "\(error)"; return fallback }
        }
        return fallback
    }

    /// Whether the idea asks for a character, creature or thing to be in it, not just a place.
    nonisolated static func asksForSomeone(_ idea: String) -> Bool {
        let words = Set(idea.lowercased().split { !$0.isLetter }.map(String.init))
        let who = ["character", "characters", "hero", "heroine", "boss", "knight", "warrior", "soldier", "samurai", "ninja", "wizard", "witch",
                   "mage", "king", "queen", "princess", "prince", "girl", "boy", "man", "woman", "person", "people", "player", "villain",
                   "creature", "monster", "dragon", "robot", "mech", "cat", "dog", "fox", "wolf", "bird", "horse", "deer", "owl", "car",
                   "ship", "spaceship", "astronaut", "portrait"]
        return who.contains(where: words.contains)
    }

    /// The first sentences, up to about 50 words (the painters only read so much, and the model can ramble).
    nonisolated static func brief(_ text: String, dropping: String? = nil, words limit: Int = 50) -> String {
        var kept: [String] = [], count = 0
        for sentence in text.split(separator: ".").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !sentence.isEmpty && !(dropping.map { sentence.lowercased().contains($0) } ?? false) {
            let n = sentence.split(separator: " ").count
            if !kept.isEmpty && count + n > limit { break }
            kept.append(sentence); count += n
        }
        return kept.isEmpty ? "" : kept.joined(separator: ". ") + "."
    }

    // MARK: Building the loop (off the main thread)

    struct DepthMap: Sendable { var values: [Float]; var width: Int; var height: Int }

    nonisolated static func build(_ picture: CGImage, fx: UInt32, motion: Float, seconds: Double = 12, fps: Int = 30,
                                  progress: @escaping @Sendable (String, Double) -> Void) async throws -> URL {
        // The size of your widest display (at least 1440p, at most 4K), in its shape.
        let px: CGSize = await MainActor.run {
            guard let s = NSScreen.screens.max(by: { $0.frame.width < $1.frame.width }) else { return CGSize(width: 2560, height: 1600) }
            return CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
        }
        let aspect = Double(px.width / px.height)
        let W = Int(min(max(px.width, 2560), 3840)) / 2 * 2
        let H = Int((Double(W) / aspect).rounded()) / 2 * 2
        let art = crop(picture, aspect: aspect)

        progress(DepthModel.ready ? "Working out what's near and far…" : "Downloading the depth model (48 MB, once)…", 0)
        let model = try await DepthModel.load { p in progress("Downloading the depth model (48 MB, once)…", p * 0.2) }
        progress("Working out what's near and far…", 0.2)
        let depth = try DepthModel.depth(art, model: model)
        try Task.checkCancellation()

        progress("Sharpening it to full resolution…", 0.3)
        let sharp = await upscale(art, to: W) { p in progress("Downloading Apple's upscaling model (once)…", 0.3 + p * 0.05) } ?? art
        try Task.checkCancellation()

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-loop-\(UUID().uuidString).mov")
        do {
            try await animate(sharp, depth: depth, fx: fx, motion: motion, width: W, height: H, seconds: seconds, fps: fps, to: out) { p in
                progress("Animating the loop…", 0.35 + p * 0.65)
            }
        } catch { try? FileManager.default.removeItem(at: out); throw error }
        return out
    }

    nonisolated static func crop(_ img: CGImage, aspect: Double) -> CGImage {
        let w = Double(img.width), h = Double(img.height)
        // Taller pictures keep more of the top: peaks and skies matter more than foreground grass.
        let r = w > h * aspect ? CGRect(x: (w - h * aspect) / 2, y: 0, width: h * aspect, height: h)
                               : CGRect(x: 0, y: (h - w / aspect) * 0.3, width: w, height: w / aspect)
        return img.cropping(to: r.integral) ?? img
    }

    /// Apple's on-device super resolution (the still-image model), when the picture is smaller than the screen.
    nonisolated static func upscale(_ img: CGImage, to width: Int, modelProgress: @escaping @Sendable (Double) -> Void) async -> CGImage? {
        guard VTSuperResolutionScalerConfiguration.isSupported, img.width < width * 9 / 10, img.width <= 1920, img.height <= 1920 else { return nil }
        let factors = VTSuperResolutionScalerConfiguration.supportedScaleFactors.filter { $0 > 1 }.sorted()
        guard let f = factors.first(where: { img.width * $0 >= width * 9 / 10 }) ?? factors.last,
              let c = VTSuperResolutionScalerConfiguration(frameWidth: img.width, frameHeight: img.height, scaleFactor: f, inputType: .image,
                                                           usePrecomputedFlow: false, qualityPrioritization: .normal,
                                                           revision: VTSuperResolutionScalerConfiguration.defaultRevision) else { return nil }
        do {
            if c.configurationModelStatus != .ready {
                try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                    c.downloadConfigurationModel { err in if let err { k.resume(throwing: err) } else { k.resume() } }
                    Task { while c.configurationModelStatus == .downloading { modelProgress(Double(c.configurationModelPercentageAvailable) / 100); try? await Task.sleep(for: .milliseconds(300)) } }
                }
                guard c.configurationModelStatus == .ready else { return nil }
            }
            func buffer(_ attrs: [String: Any]?) -> CVPixelBuffer? {
                guard let attrs else { return nil }
                var pool: CVPixelBufferPool?, b: CVPixelBuffer?
                CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
                if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b) }
                return b
            }
            var transfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            guard let bgra = pixelBuffer(img), let src = buffer(c.sourcePixelBufferAttributes), let dst = buffer(c.destinationPixelBufferAttributes),
                  let transfer, VTPixelTransferSessionTransferImage(transfer, from: bgra, to: src) == noErr,
                  let sf = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: .zero),
                  let df = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: .zero),
                  let p = VTSuperResolutionScalerParameters(sourceFrame: sf, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                                                            submissionMode: .random, destinationFrame: df) else { return nil }
            let proc = VTFrameProcessor()
            try proc.startSession(configuration: c)
            defer { proc.endSession() }
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                proc.process(parameters: p) { _, err in if let err { k.resume(throwing: err) } else { k.resume() } }
            }
            var out: CGImage?
            VTCreateCGImageFromCVPixelBuffer(dst, options: nil, imageOut: &out)
            return out
        } catch { return nil }
    }

    nonisolated static func pixelBuffer(_ img: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, img.width, img.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return pb
    }

    /// Any picture as a BGRA texture with mipmaps (the fog samples a blurry mip for its color).
    nonisolated static func texture(_ img: CGImage, device: MTLDevice, queue: MTLCommandQueue) async throws -> MTLTexture {
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        guard drawn, let tex = device.makeTexture(descriptor: d), let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
            throw VoiceError("Ran out of graphics memory.")
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        blit.generateMipmaps(for: tex); blit.endEncoding()
        cmd.commit(); await cmd.completed()
        return tex
    }

    /// Renders every frame on the GPU straight into the video encoder's buffers (HEVC).
    nonisolated static func animate(_ img: CGImage, depth: DepthMap, fx: UInt32, motion: Float, width W: Int, height H: Int,
                                    seconds: Double, fps: Int, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let device = GPU.device, let queue = GPU.queue, GPU.pipeline("living") != nil else {
            throw VoiceError("This Mac's graphics couldn't start the animation. \(GPU.compileError ?? "")")
        }
        let imgTex = try await texture(img, device: device, queue: queue)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: depth.width, height: depth.height, mipmapped: false)
        dd.usage = .shaderRead
        guard let depTex = device.makeTexture(descriptor: dd) else { throw VoiceError("Ran out of graphics memory.") }
        depth.values.withUnsafeBytes { depTex.replace(region: MTLRegionMake2D(0, 0, depth.width, depth.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: depth.width * 4) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(W * H * fps / 6, 40_000_000), AVVideoExpectedSourceFrameRateKey: fps],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VoiceError("Couldn't start the video.") }
        writer.startSession(atSourceTime: .zero)
        var cacheOut: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheOut)
        guard let cache = cacheOut else { throw VoiceError("Couldn't start the video.") }

        let frames = Int(seconds * Double(fps)), seed = Float(Int.random(in: 0..<500))
        for f in 0..<frames {
            if Task.isCancelled { writer.cancelWriting(); throw CancellationError() }
            var pbOut: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) }
            var cvTex: CVMetalTexture?
            guard let pb = pbOut, CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, W, H, 0, &cvTex) == kCVReturnSuccess,
                  let cvTex, let tex = CVMetalTextureGetTexture(cvTex), let cmd = queue.makeCommandBuffer() else { throw VoiceError("Ran out of memory for video frames.") }
            var u = LivingUniforms(res: SIMD2(Float(W), Float(H)), time: Float(Double(f) / Double(fps)), period: Float(seconds), motion: motion, fx: fx, seed: seed)
            guard GPU.encode(cmd, into: tex, fragment: "living", bytes: &u, length: MemoryLayout<LivingUniforms>.stride, textures: [imgTex, depTex]) else {
                throw VoiceError("The animation couldn't draw a frame.")
            }
            cmd.commit(); await cmd.completed()
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? VoiceError("Couldn't write a frame.")
            }
            progress(Double(f + 1) / Double(frames))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? VoiceError("Couldn't finish the video.") }
    }
}

// MARK: - Checking its own work (MobileCLIP-S2, Apple's image–text model in Core ML; downloads once, 200 MB)

enum LoopChecker {
    static let base = "https://huggingface.co/apple/coreml-mobileclip/resolve/main/mobileclip_s2_"
    static let tokenizer = "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/"   // MobileCLIP reads CLIP's tokens
    static var dir: URL { DepthModel.dir.appendingPathComponent("MobileCLIP", isDirectory: true) }
    static var ready: Bool { ["image.mlmodelc", "text.mlmodelc", "merges.txt"].allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) } }
    /// A picture counts as showing the subject when it's clearly likelier to be "a picture of <subject>" than an empty
    /// landscape (a 0.05 margin: in tests, pictures with the character scored 0.11–0.21, ones without it 0.02 at most).
    static let threshold: Float = 0.5

    /// Just who or what it is, without where it's standing ("a fox with a bushy tail, standing in the snow" → "a fox
    /// with a bushy tail"), so scenery in the picture doesn't count as finding it.
    static func core(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        for cut in [" standing ", " sitting ", " walking ", " floating ", " perched ", " in a ", " in the ", " on a ", " on the ", " at "] {
            if let r = s.range(of: cut, options: .caseInsensitive), r.lowerBound > s.startIndex { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",")))
    }

    /// A short name for it in messages: "a tall humanoid figure with golden skin…".
    static func label(_ subject: String) -> String {
        let words = core(subject).split(separator: " ")
        let s = words.prefix(7).joined(separator: " ") + (words.count > 7 ? "…" : "")
        return s.prefix(1).lowercased() + s.dropFirst()
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        func fetch(_ url: String, to dest: URL) async throws {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: URL(string: url)!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("Couldn't download the picture checker. Check your internet connection.") }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        for f in ["vocab.json", "merges.txt.part"] { try await fetch(tokenizer + f.replacingOccurrences(of: ".part", with: ""), to: dir.appendingPathComponent(f)) }
        for (i, part) in ["image", "text"].enumerated() {
            let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-clip-\(UUID().uuidString).mlpackage")
            defer { try? FileManager.default.removeItem(at: pkg) }
            for f in DepthModel.files { try await fetch(base + part + ".mlpackage/" + f, to: pkg.appendingPathComponent(f)) }
            let c = try await MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(part).mlmodelc"))
            try FileManager.default.moveItem(at: c, to: dir.appendingPathComponent("\(part).mlmodelc"))
            progress(Double(i + 1) / 2)
        }
        // merges.txt last, since `ready` looks for it: a download that stopped halfway starts over next time.
        try FileManager.default.moveItem(at: dir.appendingPathComponent("merges.txt.part"), to: dir.appendingPathComponent("merges.txt"))
    }

    /// For each picture, how sure it is (0…1) that the subject is in it.
    static func scores(_ images: [CGImage], subject: String) async throws -> [Float] {
        let folder = dir
        return try await Task.detached(priority: .userInitiated) {
            let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
            let tokens = try CLIPTokenizer(vocab: folder.appendingPathComponent("vocab.json"), merges: folder.appendingPathComponent("merges.txt"))
            func unit(_ out: MLFeatureProvider) throws -> [Float] {
                guard let a = out.featureValue(for: "final_emb_1")?.multiArrayValue else { throw VoiceError("The picture checker didn't answer.") }
                var v = (0..<a.count).map { Float(truncating: a[$0]) }
                let n = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-6)
                for i in v.indices { v[i] /= n }
                return v
            }
            let textModel = try MLModel(contentsOf: folder.appendingPathComponent("text.mlmodelc"), configuration: cfg)
            func text(_ s: String) throws -> [Float] {
                var ids = tokens.encode(s)
                if let end = ids.firstIndex(of: 49407) { for i in (end + 1)..<ids.count { ids[i] = 0 } }   // padded with 0s, as it was trained
                let a = try MLMultiArray(shape: [1, 77], dataType: .int32)
                for (i, t) in ids.enumerated() { a[i] = NSNumber(value: t) }
                return try unit(textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": a])))
            }
            let want = try text("a picture of " + LoopChecker.core(subject)), empty = try text("a picture of an empty landscape with nobody in it")
            let imageModel = try MLModel(contentsOf: folder.appendingPathComponent("image.mlmodelc"), configuration: cfg)
            guard let c = imageModel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw VoiceError("The picture checker didn't load right.") }
            return try images.map { img in
                let v = try MLFeatureValue(cgImage: img, constraint: c, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
                let e = try unit(imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": v])))
                let margin = zip(e, want).reduce(0) { $0 + $1.0 * $1.1 } - zip(e, empty).reduce(0) { $0 + $1.0 * $1.1 }
                return 1 / (1 + exp(-100 * (margin - 0.05)))   // CLIP's usual logit scale, centered on the 0.05 margin
            }
        }.value
    }
}

// MARK: - Depth (Depth Anything V2 Small, Apple's Core ML version; downloads once, 48 MB)

enum DepthModel {
    static let base = "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage/"
    static let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    static var dir: URL { Prefs.supportDir.appendingPathComponent("Models", isDirectory: true) }
    static var compiled: URL { dir.appendingPathComponent("DepthAnythingV2Small.mlmodelc") }
    static var ready: Bool { FileManager.default.fileExists(atPath: compiled.path) }

    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> MLModel {
        if !ready {
            let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-depth-\(UUID().uuidString).mlpackage")
            defer { try? FileManager.default.removeItem(at: pkg) }
            for (i, f) in files.enumerated() {
                let dest = pkg.appendingPathComponent(f)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (tmp, resp) = try await URLSession.shared.download(from: URL(string: base + f)!)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("Couldn't download the depth model. Check your internet connection.") }
                try FileManager.default.moveItem(at: tmp, to: dest)
                progress(Double(i + 1) / Double(files.count))
            }
            let c = try await MLModel.compileModel(at: pkg)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: c, to: compiled)
        }
        return try MLModel(contentsOf: compiled)
    }

    /// How near each part of the picture is: 0 far … 1 near, smoothed so edges don't tear when things shift.
    static func depth(_ img: CGImage, model: MLModel) throws -> LoopMaker.DepthMap {
        guard let c = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw VoiceError("The depth model didn't load right.") }
        let input = try MLFeatureValue(cgImage: img, constraint: c, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let pb = out.featureValue(for: "depth")?.imageBufferValue else { throw VoiceError("The depth model didn't answer.") }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw VoiceError("The depth model didn't answer.") }
        let half = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent16Half
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr)
            for x in 0..<w { v[y * w + x] = half ? Float(row.assumingMemoryBound(to: Float16.self)[x]) : row.assumingMemoryBound(to: Float.self)[x] }
        }
        // Stretch the 2nd–98th percentile to 0…1.
        let sorted = v.sorted()
        let lo = sorted[sorted.count / 50], hi = max(sorted[sorted.count * 49 / 50], lo + 1e-6)
        v = v.map { min(max(($0 - lo) / (hi - lo), 0), 1) }
        // Line its edges up with the picture's (a guided filter at 1024 px wide), so objects move as solid shapes; then
        // grow near things by a couple of pixels so their soft edges travel with them instead of smearing into the background.
        let gw = 1024, gh = max(64, Int((Double(gw) * Double(img.height) / Double(img.width)).rounded()))
        let guide = luminance(img, gw, gh)
        var d = resize(v, w, h, gw, gh)
        d = guided(guide, d, gw, gh, r: 10, eps: 0.004)
        d = grow(d, gw, gh, r: 2)
        d = box(d, gw, gh, 1).map { min(max($0, 0), 1) }
        return LoopMaker.DepthMap(values: d, width: gw, height: gh)
    }

    private static func luminance(_ img: CGImage, _ w: Int, _ h: Int) -> [Float] {
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { b in
            let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.interpolationQuality = .high
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px.map { Float($0) / 255 }
    }

    private static func resize(_ a: [Float], _ w: Int, _ h: Int, _ W: Int, _ H: Int) -> [Float] {
        var o = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            let fy = (Float(y) + 0.5) * Float(h) / Float(H) - 0.5, y0 = max(0, min(h - 1, Int(fy.rounded(.down)))), y1 = min(h - 1, y0 + 1), ty = max(0, fy - Float(y0))
            for x in 0..<W {
                let fx = (Float(x) + 0.5) * Float(w) / Float(W) - 0.5, x0 = max(0, min(w - 1, Int(fx.rounded(.down)))), x1 = min(w - 1, x0 + 1), tx = max(0, fx - Float(x0))
                let top = a[y0 * w + x0] * (1 - tx) + a[y0 * w + x1] * tx, bottom = a[y1 * w + x0] * (1 - tx) + a[y1 * w + x1] * tx
                o[y * W + x] = top * (1 - ty) + bottom * ty
            }
        }
        return o
    }

    /// Mean over a (2r+1)² square, via a summed-area table.
    private static func box(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var sat = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w { row += Double(a[y * w + x]); sat[(y + 1) * (w + 1) + x + 1] = sat[y * (w + 1) + x + 1] + row }
        }
        var o = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h - 1, y + r)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                let sum = sat[(y1 + 1) * (w + 1) + x1 + 1] - sat[y0 * (w + 1) + x1 + 1] - sat[(y1 + 1) * (w + 1) + x0] + sat[y0 * (w + 1) + x0]
                o[y * w + x] = Float(sum / Double((y1 - y0 + 1) * (x1 - x0 + 1)))
            }
        }
        return o
    }

    /// He et al.'s guided filter: smooths p while keeping the edges that the guide i has.
    private static func guided(_ i: [Float], _ p: [Float], _ w: Int, _ h: Int, r: Int, eps: Float) -> [Float] {
        let mi = box(i, w, h, r), mp = box(p, w, h, r)
        let ii = box(zip(i, i).map { $0 * $1 }, w, h, r), ip = box(zip(i, p).map { $0 * $1 }, w, h, r)
        var a = [Float](repeating: 0, count: w * h), b = a
        for k in 0..<(w * h) {
            let v = ii[k] - mi[k] * mi[k], c = ip[k] - mi[k] * mp[k]
            a[k] = c / (v + eps); b[k] = mp[k] - a[k] * mi[k]
        }
        let ma = box(a, w, h, r), mb = box(b, w, h, r)
        return (0..<(w * h)).map { ma[$0] * i[$0] + mb[$0] }
    }

    /// Nearest wins: each pixel takes the nearest depth within r (a max filter, one direction at a time).
    private static func grow(_ a: [Float], _ w: Int, _ h: Int, r: Int) -> [Float] {
        var t = a, o = a
        for y in 0..<h { for x in 0..<w { var m: Float = 0; for dx in -r...r { let xx = x + dx; if xx >= 0 && xx < w { m = max(m, a[y * w + xx]) } }; t[y * w + x] = m } }
        for y in 0..<h { for x in 0..<w { var m: Float = 0; for dy in -r...r { let yy = y + dy; if yy >= 0 && yy < h { m = max(m, t[yy * w + x]) } }; o[y * w + x] = m } }
        return o
    }
}

// MARK: - The "Create with AI" sheet

struct CreateLoopSheet: View {
    let close: () -> Void
    @ObservedObject var maker = LoopMaker.shared
    @State private var idea = ""
    @AppStorage("loop.art") private var artRaw = ArtStyle.realistic.rawValue
    private var art: ArtStyle { ArtStyle(rawValue: artRaw) ?? .realistic }
    @State private var fromPicture = false
    @State private var picture: CGImage?
    @State private var pictureName = ""
    @State private var restyle = false
    @State private var chosen = 0
    @State private var motion = 1
    @State private var dropping = false
    @State private var removed = 0     // redraws the style cards after a download is removed

    private let examples = ["Blocky voxel world at sunset", "Neon racing city in the rain", "Cozy farm at dusk", "Haunted castle on a hill",
                            "Floating sky islands", "Underwater temple ruins", "Enchanted forest at night", "Volcanic forge realm"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Create with AI", systemImage: "wand.and.sparkles").font(.system(size: 20, weight: .bold))
                Spacer()
                Button(maker.busy ? "Hide" : "Close") { if !maker.busy { maker.reset() }; close() }.buttonStyle(.glass)
            }
            switch maker.step {
            case .idle, .failed: form
            case .thinking, .drawing: drawing
            case .pick: pick
            case .working(let stage, let p): working(stage, p)
            case .done: done
            }
        }
        .padding(22)
        .frame(width: 640, height: 640, alignment: .top)
        .environment(\.colorScheme, .dark)
        .task { await maker.checkImagePlayground(); if maker.canDraw == false { fromPicture = true } }
    }

    // MARK: Step 1: the idea

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $fromPicture) {
                Text("Describe it").tag(false)
                Text("Use a picture").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()

            if fromPicture {
                pictureDrop
                TextField("What's in it? (optional, helps pick the effects)", text: $idea).textFieldStyle(.roundedBorder)
                if maker.canDraw == true { Toggle("Repaint it with Image Playground first (Animated style)", isOn: $restyle) }
            } else {
                Text("Any game's world, a place, a mood. Onyx paints it, then brings it to life as a seamless loop.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("e.g. a blocky voxel forest at sunset", text: $idea, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder).onSubmit(start)
                FlowChips(items: examples) { idea = $0 }
                styles
                if art.playground != nil && maker.canDraw == false {
                    Label(LoopMaker.message(.unavailable), systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            if case .failed(let why) = maker.step {
                Label(why, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Everything happens on this Mac. Nothing is uploaded.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { start() } label: { Label(fromPicture && !restyle ? "Next" : "Create", systemImage: "sparkles") }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(fromPicture ? picture == nil : (idea.trimmingCharacters(in: .whitespaces).isEmpty || (art.playground != nil && maker.canDraw != true)))
            }
        }
    }

    /// Five looks, each a small glass card; the Stable Diffusion ones say whether they still need their download.
    private var styles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Art style").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ArtStyle.allCases) { a in
                    let on = a == art, needs = a.diffusion.map { !$0.ready } ?? false
                    Button { artRaw = a.rawValue } label: {
                        VStack(spacing: 4) {
                            Image(systemName: a.icon).font(.system(size: 17)).frame(height: 20)
                            Text(a.title).font(.system(size: 12, weight: .semibold))
                            Text(needs ? "2 GB download" : a.blurb).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(on ? RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cyan.opacity(0.3)) : nil)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                    .opacity(a.playground != nil && maker.canDraw == false ? 0.4 : 1)
                }
            }
            if let sd = art.diffusion, sd.ready {
                HStack(spacing: 4) {
                    Text("\(art.title) is downloaded (2 GB).").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Button("Remove") { sd.remove(); removed += 1 }.buttonStyle(.link).font(.system(size: 10.5))
                }
            }
        }
        .id(removed)
    }

    private var pictureDrop: some View {
        Button { choosePicture() } label: {
            ZStack {
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 26, weight: .light))
                        Text("Choose a picture, or drop one here").font(.system(size: 13, weight: .semibold))
                        Text("A game screenshot, artwork or photo").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity).frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .overlay { if dropping { RoundedRectangle(cornerRadius: 16).strokeBorder(.cyan, style: StrokeStyle(lineWidth: 2, dash: [7])) } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { load(u) } } }
            return true
        }
    }

    private func choosePicture() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Choose a picture to bring to life"
        guard p.runModal() == .OK, let u = p.url else { return }
        load(u)
    }

    private func load(_ u: URL) {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 4096,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
        picture = img
        pictureName = u.deletingPathExtension().lastPathComponent
    }

    private func start() {
        chosen = 0
        if fromPicture, let picture {
            if restyle { maker.imagine(idea.isEmpty ? "a scenic wallpaper of this" : idea, art: .animated, picture: picture) }
            else { maker.use(picture, name: pictureName, idea: idea) }
        } else if !idea.trimmingCharacters(in: .whitespaces).isEmpty {
            maker.imagine(idea, art: art)
        }
    }

    // MARK: Step 2: drawing, then picking

    private var drawing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(maker.step == .thinking ? "Planning it…" : maker.detail.isEmpty ? "Painting…" : maker.detail).font(.system(size: 13, weight: .semibold))
            }
            if maker.step == .drawing && !maker.detail.isEmpty { ProgressView(value: maker.progress).tint(.cyan) }
            if !maker.scene.isEmpty && maker.step == .drawing { Text(maker.scene).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
            grid(selectable: false)
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Stop") { maker.cancel() }.buttonStyle(.glass) }
        }
    }

    private func grid(selectable: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(0..<max(maker.images.count, selectable ? 0 : maker.art?.diffusion != nil ? 2 : 4), id: \.self) { i in
                ZStack {
                    Color.white.opacity(0.06)
                    if i < maker.images.count {
                        Image(decorative: maker.images[i], scale: 1).resizable().scaledToFill()
                    } else { ProgressView().controlSize(.small) }
                }
                .frame(height: maker.images.count <= 2 && selectable ? 180 : 150)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { if selectable && chosen == i { RoundedRectangle(cornerRadius: 12).strokeBorder(.cyan, lineWidth: 3) } }
                .onTapGesture { if selectable { chosen = i } }
            }
        }
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = maker.checkNote {
                Label(note, systemImage: maker.checkOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(maker.checkOK ? .green : .orange)
            }
            ScrollView { grid(selectable: true) }.frame(height: maker.images.count <= 2 ? 180 : 310).scrollIndicators(.hidden)
            HStack {
                Text("Name").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Name", text: $maker.name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Effects").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                FlowChips(items: LoopEffect.allCases.map(\.rawValue), selected: Set(maker.effects.map(\.rawValue))) { raw in
                    guard let e = LoopEffect(rawValue: raw) else { return }
                    if maker.effects.contains(e) { maker.effects.remove(e) } else { maker.effects.insert(e) }
                }
            }
            HStack {
                Text("Motion").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: $motion) { Text("Subtle").tag(0); Text("Normal").tag(1); Text("Strong").tag(2) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { maker.reset() }.buttonStyle(.glass)
                Spacer()
                Button { if chosen < maker.images.count { maker.make(maker.images[chosen], motion: [0.004, 0.007, 0.012][motion]) } } label: {
                    Label("Make Loop", systemImage: "play.circle")
                }
                .buttonStyle(.glassProminent).controlSize(.large)
            }
        }
    }

    // MARK: Step 3: making it

    private func working(_ stage: String, _ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if chosen < maker.images.count {
                Image(decorative: maker.images[chosen], scale: 1).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text(stage).font(.system(size: 13, weight: .semibold))
            ProgressView(value: p).tint(.cyan)
            Text("About a minute. You can hide this window; it keeps going.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Cancel") { maker.cancel() }.buttonStyle(.glass) }
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.cyan)
            Text("\"\(maker.name)\" is on your desktop").font(.system(size: 16, weight: .semibold))
            Text("It's in your library too, so you can put it on another display, use it after sunset, or make it smoother with Enhance with AI.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer()
            HStack {
                Button("Make Another") { maker.reset() }.buttonStyle(.glass)
                Button("Done") { maker.reset(); close() }.buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small glass chips that wrap onto new lines.
struct FlowChips: View {
    let items: [String]
    var selected: Set<String>? = nil
    let tap: (String) -> Void
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                let on = selected?.contains(item) == true
                Button {
                    tap(item)
                } label: {
                    HStack(spacing: 4) {
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                        else if let e = LoopEffect(rawValue: item) { Image(systemName: e.icon).font(.system(size: 10)) }
                        Text(LoopEffect(rawValue: item)?.title ?? item).font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(on ? Capsule().fill(Color.cyan.opacity(0.35)) : nil)
                }
                .buttonStyle(.plain)
                .glassEffect(on ? .regular.tint(.cyan.opacity(0.5)).interactive() : .regular.interactive(), in: .capsule)
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}
