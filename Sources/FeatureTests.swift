import AppKit
import AVFoundation
import Speech
import ImagePlayground
import Metal

// MARK: - Self-test (debug): ONYX_FEATURES_TEST=<dir> checks AirPods, rain, weather stations, voice and settings sync,
// writing features.log (and a screenshot of the AirPods pop-up) there, then quits. Never touches your real settings.

enum FeatureSelfTest {
    @MainActor static func run(_ dir: String) async {
        var log: [String] = [], fails = 0
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/features.log", atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool) { note((ok ? "PASS " : "FAIL ") + name); if !ok { fails += 1 } }

        // Rain: dry now, rain in the 15 minutes ending 30 min from now → "Rain in ~15 min".
        let now = Date(timeIntervalSince1970: 1_800_000_000), t = now.timeIntervalSince1970
        func wx(_ cur: Double, _ curCode: Int, _ mm: [Double], _ codes: [Int]) -> [String: Any] {
            ["current": ["precipitation": cur, "weather_code": curCode],
             "minutely_15": ["time": mm.indices.map { t + Double($0 + 1) * 900 }, "precipitation": mm, "weather_code": codes]]
        }
        check("rain in ~15 min", RainWatch.alert(wx(0, 1, [0, 0.4, 1], [2, 61, 63]), now: now)?.text == "Rain in ~15 min")
        check("rain starting soon", RainWatch.alert(wx(0, 1, [0.3, 1], [61, 63]), now: now)?.text == "Rain starting soon")
        check("snow is called snow", RainWatch.alert(wx(0, 3, [0, 0, 0.5], [3, 3, 73]), now: now)?.text == "Snow in ~30 min")
        check("no alert while it's already raining", RainWatch.alert(wx(0.8, 63, [1, 1], [63, 63]), now: now) == nil)
        check("no alert when it stays dry", RainWatch.alert(wx(0, 0, [0, 0, 0, 0], [0, 1, 2, 3]), now: now) == nil)
        check("no alert for rain over an hour away", RainWatch.alert(wx(0, 0, [0, 0, 0, 0, 0, 0.5], [0, 0, 0, 0, 0, 61]), now: now) == nil)

        // Weather stations: condition codes, distance, picking the closest fresh one.
        check("METAR light rain → 61", WeatherSources.code(metarWeather: "-RA", covers: ["OVC"]) == 61)
        check("METAR thunderstorm → 95", WeatherSources.code(metarWeather: "+TSRA", covers: []) == 95)
        check("METAR broken clouds → 3, few → 1, clear → 0",
              WeatherSources.code(metarWeather: nil, covers: ["BKN"]) == 3 && WeatherSources.code(metarWeather: nil, covers: ["FEW"]) == 1
              && WeatherSources.code(metarWeather: nil, covers: ["CLR"]) == 0)
        check("NWS text → codes", WeatherSources.code(nwsText: "Light Rain") == 61 && WeatherSources.code(nwsText: "Partly Cloudy") == 2
              && WeatherSources.code(nwsText: "Mostly Cloudy") == 3 && WeatherSources.code(nwsText: "Clear") == 0 && WeatherSources.code(nwsText: "Fog/Mist") == 45)
        check("distance Seattle → Tacoma ≈ 40 km", abs(WeatherSources.distanceKm(47.61, -122.33, 47.25, -122.44) - 40.9) < 2)
        func r(_ id: String, _ lat: Double, _ age: TimeInterval) -> StationReading {
            StationReading(source: "T", id: id, name: id, lat: lat, lon: 0, tempC: 10, code: nil, time: now.addingTimeInterval(-age))
        }
        check("closest fresh station wins", WeatherSources.pick([r("far", 0.1, 60), r("near", 0.03, 60)], lat: 0, lon: 0, now: now)?.id == "near")
        check("stale station skipped", WeatherSources.pick([r("old", 0.01, 3 * 3600), r("ok", 0.05, 60)], lat: 0, lon: 0, now: now)?.id == "ok")
        check("nothing within 20 km → forecast model", WeatherSources.pick([r("x", 0.5, 60)], lat: 0, lon: 0, now: now) == nil)

        // AirPods pop-up helpers.
        let map = ["Sam’s AirPods Pro": BluetoothService.BTBattery(main: nil, left: 80, right: 75, caseLevel: 60)]
        check("AirPods matched by name", EarbudsWatcher.match("Sam’s AirPods Pro", in: map)?.left == 80)
        check("short name drops the owner", EarbudsWatcher.shortName("Sam’s AirPods Pro") == "AirPods Pro" && EarbudsWatcher.shortName("Beats Studio") == "Beats Studio")
        check("icons by model", EarbudsWatcher.icon("Sam’s AirPods Max") == "airpodsmax" && EarbudsWatcher.icon("AirPods Pro") == "airpodspro"
              && EarbudsWatcher.icon("Beats Flex") == "beats.headphones")
        note("Bluetooth audio outputs now: \(EarbudsWatcher.bluetoothOutputs().map(\.name))")

        // Spoken answers.
        check("speakable text drops markdown and says symbols", Speaker.speakable("**m∠A** = 35°") == "the measure of angle A = 35°")
        let voice = Speaker.bestVoice()
        note("Speaking voice: \(voice?.name ?? "none") (\(voice?.language ?? "")), quality \(voice?.quality.rawValue ?? 0)")
        check("a voice is available", voice != nil)

        // Settings sync between two pretend Macs, in a throwaway folder and throwaway defaults.
        let folder = URL(fileURLWithPath: dir).appendingPathComponent("sync", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        func mac(_ name: String) -> SettingsSync {
            let s = SettingsSync(); let suite = "onyx.selftest.\(name)"
            UserDefaults().removePersistentDomain(forName: suite)
            s.defaults = UserDefaults(suiteName: suite)!; s.domain = suite; s.folder = folder
            s.stateFile = URL(fileURLWithPath: dir + "/state-\(name).plist"); try? FileManager.default.removeItem(at: s.stateFile)
            return s
        }
        let a = mac("A"), b = mac("B")
        a.defaults.set("glass", forKey: "ap.style"); a.defaults.set(true, forKey: "didOnboard"); a.defaults.set("x", forKey: "notes.selected")
        a.defaults.set(true, forKey: SettingsSync.key); a.pushNow()
        check("only settings are exported (not per-Mac state)", a.current()["ap.style"] as? String == "glass" && a.current()["didOnboard"] == nil && a.current()["notes.selected"] == nil)
        b.defaults.set(true, forKey: SettingsSync.key); b.defaults.set("solid", forKey: "ap.style")
        b.pull(first: true)
        check("first sync on a second Mac asks which settings win", b.conflict?.settings["ap.style"] as? String == "glass")
        b.resolve(useICloud: true)
        check("choosing iCloud applies Mac A's settings", b.defaults.string(forKey: "ap.style") == "glass")
        b.defaults.set("blur", forKey: "ap.style"); b.defaults.set(1.5, forKey: "ap.earScale"); b.pushNow()
        try? await Task.sleep(for: .milliseconds(1100))
        a.pull()
        check("a change on Mac B reaches Mac A", a.defaults.string(forKey: "ap.style") == "blur" && a.defaults.double(forKey: "ap.earScale") == 1.5)
        check("Mac A's own state is untouched", a.defaults.bool(forKey: "didOnboard") && a.defaults.string(forKey: "notes.selected") == "x")
        b.defaults.removeObject(forKey: "ap.earScale"); b.pushNow()
        try? await Task.sleep(for: .milliseconds(1100))
        a.pull()
        check("a setting reset on Mac B resets on Mac A", a.current()["ap.earScale"] == nil && a.current()["ap.style"] as? String == "blur")
        if let data = a.snapshotData() {
            let f = URL(fileURLWithPath: dir + "/export.plist"); try? data.write(to: f)
            check("export file reads back", SettingsSync.read(f)?.settings["ap.style"] as? String == "blur")
        }
        for n in ["A", "B"] { UserDefaults().removePersistentDomain(forName: "onyx.selftest.\(n)") }

        // Live: the closest weather station to downtown Seattle (public data).
        let station = await WeatherSources.nearest(lat: 47.61, lon: -122.33)
        note("Nearest station to downtown Seattle: \(station.map { "\($0.name) (\($0.id), \($0.source)) \(String(format: "%.1f", $0.distanceKm)) km, \($0.tempC)°C, code \($0.code.map(String.init) ?? "–")" } ?? "none")")
        check("a Seattle station is found within 20 km", station != nil)
        let metar = await WeatherSources.metar(lat: 51.47, lon: -0.45)
        check("airport reports work outside the US (London Heathrow)", metar.contains { $0.id == "EGLL" })

        // Live: speech-to-text on a sentence spoken by macOS's own voice, through the same converter the mic uses.
        await voiceTest(dir, note: note, check: check)

        // The AirPods pop-up, captured (debug builds show the notch in screenshots).
        NotchModel.shared.flash(.earbuds(name: "Sam’s AirPods Pro", left: 80, right: 75, caseLevel: 18, main: nil), for: 4)
        try? await Task.sleep(for: .seconds(1))
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let f = NotchModel.shared.geometry.screenFrame
        p.arguments = ["-x", "-R", "\(Int(f.midX - 400)),0,800,120", dir + "/airpods.png"]; try? p.run(); p.waitUntilExit()
        NotchModel.shared.flash(.message(icon: "cloud.rain.fill", text: "Rain in ~15 min", tint: .cyan), for: 3)
        try? await Task.sleep(for: .seconds(1))
        let q = Process(); q.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        q.arguments = ["-x", "-R", "\(Int(f.midX - 400)),0,800,120", dir + "/rain.png"]; try? q.run(); q.waitUntilExit()

        note(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
        exit(0)
    }

    @MainActor static func voiceTest(_ dir: String, note: (String) -> Void, check: (String, Bool) -> Void) async {
        let aiff = dir + "/voice.aiff"
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff, "What is twelve times twelve"]; try? say.run(); say.waitUntilExit()
        do {
            let probe = SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .progressiveTranscription)
            let status = await AssetInventory.status(forModules: [probe])
            note("Speech model status: \(status)")
            if status != .installed && ProcessInfo.processInfo.environment["ONYX_VOICETEST_DOWNLOAD"] == nil {
                note("SKIP voice: Apple's speech model isn't installed (it downloads the first time you use the mic)."); return
            }
            let transcriber = try await VoiceInput.transcriber()
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { check("voice format", false); return }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: aiff))
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            guard let tap = VoiceInput.converterTap(from: file.processingFormat, to: format, into: feed) else { check("converter", false); return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let reader = Task { () -> String in
                var t = ""
                for try await r in transcriber.results where r.isFinal { t += String(r.text.characters) }
                return t
            }
            try await analyzer.start(inputSequence: stream)
            while file.framePosition < file.length {   // feed the clip in mic-sized chunks
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                try file.read(into: buf)
                tap(buf, AVAudioTime(sampleTime: file.framePosition, atRate: file.processingFormat.sampleRate))
            }
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = (try? await reader.value) ?? ""
            note("Heard: \"\(text.trimmingCharacters(in: .whitespaces))\"")
            let words = text.lowercased()
            check("speech recognized on this Mac", words.contains("12") || words.contains("twelve"))
        } catch {
            note("Voice error: \(error)")
            check("speech recognition runs", false)
        }
    }
}

// MARK: - Enhance self-test (debug): ONYX_ENHANCE_TEST=<dir> makes a short test clip, runs it through the AI enhancer
// (60 fps; plus 2× when ONYX_ENHANCE_TEST_SR=1, which downloads Apple's model once), and checks the result.

enum EnhanceSelfTest {
    static func run(_ dir: String) async {
        var log: [String] = []
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/enhance.log", atomically: true, encoding: .utf8) }
        let src = URL(fileURLWithPath: dir + "/test-24fps.mov"), out = URL(fileURLWithPath: dir + "/test-enhanced.mov")
        try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out)
        note("interpolation supported: \(VideoEnhancer.canInterpolate), upscaling supported: \(VideoEnhancer.canUpscale)")
        note("scale factors for 640×360: \(VideoEnhancer.scaleFactors(width: 640, height: 360)); rates from 24 fps: \(VideoEnhancer.frameRates(from: 24))")
        do {
            try await makeClip(src, width: 640, height: 360, fps: 24, seconds: 2)
            let sr = ProcessInfo.processInfo.environment["ONYX_ENHANCE_TEST_SR"] != nil
            let start = Date()
            let factor = sr ? (VideoEnhancer.scaleFactors(width: 640, height: 360).first ?? 1) : 1
            try await VideoEnhancer.enhance(input: src, output: out, scale: factor, fps: 60, progress: { _ in }, modelProgress: { p in
                if p == 0 { note("downloading Apple's upscaling model…") }
            })
            let info = try await WallpaperLibrary.info(out)
            let asset = AVURLAsset(url: out)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let reader = try AVAssetReader(asset: asset)
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil); reader.add(o); reader.startReading()
            var frames = 0; while o.copyNextSampleBuffer() != nil { frames += 1 }
            note(String(format: "took %.1fs → %d×%d, %.1f fps, %.2fs, %d frames", Date().timeIntervalSince(start), info.width, info.height, info.fps, info.duration, frames))
            let wantW = 640 * factor
            note(info.width == wantW && frames >= 110 && frames <= 125 ? "PASS enhanced video has the right size and ~60 fps" : "FAIL unexpected result")
        } catch {
            note("FAIL \(error)")
        }
        exit(0)
    }

    /// A white ball moving across a gradient, so interpolated frames are easy to check by eye.
    static func makeClip(_ url: URL, width: Int, height: Int, fps: Int, seconds: Int) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        for i in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = ad.pixelBufferPool else { break }
            var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1), CGColor(red: 0.6, green: 0.1, blue: 0.4, alpha: 1)] as CFArray, locations: nil)!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
            let x = CGFloat(i) / CGFloat(fps * seconds) * CGFloat(width - 80)
            ctx.setFillColor(.white); ctx.fillEllipse(in: CGRect(x: x, y: CGFloat(height) / 2 - 40, width: 80, height: 80))
            CVPixelBufferUnlockBaseAddress(pb, [])
            ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished(); await w.finishWriting()
    }
}

// MARK: - Wallpapers & launcher self-test (debug): ONYX_WALLTEST=<dir>. Shows each scene and a test video in a
// wallpaper window, opens the launcher and the Live Wallpapers window, screenshots them, checks sunrise/sunset and search.
// Uses its own windows and a temporary file, so your real wallpaper settings aren't touched.

enum WallpaperSelfTest {
    @MainActor static func run(_ dir: String) async {
        var log: [String] = [], fails = 0
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/wall.log", atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool) { note((ok ? "PASS " : "FAIL ") + name); if !ok { fails += 1 } }
        func shot(_ window: NSWindow, _ name: String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(window.windowNumber)", dir + "/" + name]; try? p.run(); p.waitUntilExit()
        }

        // Sunrise/sunset in Seattle on Sep 27 2026: about 7:02 and 18:57 local time.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!
        if let sun = WallpaperEngine.sunTimes(lat: 47.61, lon: -122.33, date: noon) {
            let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "HH:mm"
            note("Seattle sunrise \(f.string(from: sun.rise)), sunset \(f.string(from: sun.set))")
            let rise = cal.date(bySettingHour: 7, minute: 2, second: 0, of: noon)!, set = cal.date(bySettingHour: 18, minute: 57, second: 0, of: noon)!
            check("sunrise/sunset within 10 minutes", abs(sun.rise.timeIntervalSince(rise)) < 600 && abs(sun.set.timeIntervalSince(set)) < 600)
        } else { check("sun times", false) }

        // Scenes and a video in a real desktop-level window.
        guard let screen = NSScreen.main else { exit(1) }
        let win = WallpaperWindow(screen: screen)
        win.setFrame(screen.frame, display: true); win.orderBack(nil)
        for s in WallpaperScene.allCases {
            win.show(s.wallpaper, sound: false); win.play()
            try? await Task.sleep(for: .seconds(2.5))
            shot(win, "scene-\(s.title.replacingOccurrences(of: " ", with: "")).png")
            if s == .glass {   // also as it looks on screen (glass samples what's behind it, which a one-window capture leaves out)
                let lvl = win.level
                win.level = .floating; win.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-R", "0,0,\(Int(screen.frame.width)),\(Int(screen.frame.height))", dir + "/scene-glass-onscreen.png"]; try? p.run(); p.waitUntilExit()
                win.level = lvl; win.orderBack(nil)
            }
        }
        let clip = URL(fileURLWithPath: dir + "/clip.mov")
        try? await EnhanceSelfTest.makeClip(clip, width: 1280, height: 720, fps: 30, seconds: 3)
        let libFile = WallpaperLibrary.shared.folder.appendingPathComponent("onyx-selftest.mov")
        try? FileManager.default.removeItem(at: libFile); try? FileManager.default.copyItem(at: clip, to: libFile)
        win.show(Wallpaper(id: "selftest", name: "Test", file: "onyx-selftest.mov"), sound: false); win.play()
        try? await Task.sleep(for: .seconds(1.2)); shot(win, "video-a.png")
        try? await Task.sleep(for: .seconds(0.8)); shot(win, "video-b.png")
        let a = try? Data(contentsOf: URL(fileURLWithPath: dir + "/video-a.png")), b = try? Data(contentsOf: URL(fileURLWithPath: dir + "/video-b.png"))
        check("video wallpaper is playing (frames change)", a != nil && b != nil && a != b)
        win.stop(); win.orderOut(nil)
        try? FileManager.default.removeItem(at: libFile)

        // Launcher.
        await LauncherStore.shared.refresh()
        let count = LauncherStore.shared.apps.count
        note("Launcher found \(count) apps")
        check("launcher finds apps", count > 20)
        check("search \"saf\" → Safari first", LauncherStore.shared.search("saf").first?.name == "Safari")
        check("search \"sys set\" finds System Settings", LauncherStore.shared.search("system set").first?.name == "System Settings")
        AppLauncher.shared.open()
        try? await Task.sleep(for: .seconds(2))
        let lp = Process(); lp.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        lp.arguments = ["-x", "-R", "0,0,\(Int(screen.frame.width)),\(Int(screen.frame.height))", dir + "/launcher.png"]; try? lp.run(); lp.waitUntilExit()
        AppLauncher.shared.nav.step(1)   // next page
        try? await Task.sleep(for: .seconds(1))
        let lp2 = Process(); lp2.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        lp2.arguments = ["-x", "-R", "0,0,\(Int(screen.frame.width)),\(Int(screen.frame.height))", dir + "/launcher-page2.png"]; try? lp2.run(); lp2.waitUntilExit()
        AppLauncher.shared.close()

        // The Live Wallpapers window.
        (NSApp.delegate as? AppDelegate)?.openWallpapers()
        try? await Task.sleep(for: .seconds(3))
        if let w = (NSApp.delegate as? AppDelegate)?.wallpapersWindow { shot(w, "wallpapers-window.png") }

        note(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
        exit(0)
    }
}

// MARK: - Self-test (debug): ONYX_SPOTLIGHTTEST=<dir> turns "⌘Space opens the App Launcher" on, presses ⌘Space,
// turns it off, presses ⌘Space again (Spotlight should open), and checks macOS's shortcuts end up exactly as before.
// With ONYX_SPOTLIGHTTEST_KEEP=1 it finishes by turning the switch back on.

enum SpotlightSelfTest {
    @MainActor static func run(_ dir: String) async {
        var log: [String] = [], fails = 0
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/spotlight.log", atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool) { note((ok ? "PASS " : "FAIL ") + name); if !ok { fails += 1 } }
        func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                e?.flags = flags; e?.post(tap: .cghidEventTap)
            }
        }
        func spotlightWindows() -> Int {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return info.filter { ($0[kCGWindowOwnerName as String] as? String) == "Spotlight" && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }.count
        }
        // What the window server is using right now (not just what's saved), for Spotlight (64).
        func live() -> String {
            typealias Get = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt64>) -> Int32
            guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
                  let f = dlsym(h, "SLSGetSymbolicHotKeyValue") else { return "?" }
            var ch: UInt16 = 0, kc: UInt16 = 0, m: UInt64 = 0
            _ = unsafeBitCast(f, to: Get.self)(64, &ch, &kc, &m)
            return kc == 49 && Int(m) & 0x1E0000 == SpotlightKey.cmd ? "⌘Space" : kc == 49 && Int(m) & 0x1E0000 == SpotlightKey.cmd | SpotlightKey.opt ? "⌥⌘Space" : "other"
        }
        let S = SpotlightKey.self
        note("Accessibility (needed to press keys): \(AXIsProcessTrusted())")
        if S.isOn { await S.set(false) }
        let before = S.read()
        note("before: Spotlight ⌘Space \(S.uses(before, S.spotlight, mods: S.cmd)), Finder search ⌥⌘Space \(S.uses(before, S.finderSearch, mods: S.cmd | S.opt)), live \(live())")

        await S.set(true)
        let on = S.read()
        check("Spotlight moved to ⌥⌘Space", S.uses(on, S.spotlight, mods: S.cmd | S.opt))
        check("Finder search window no longer on ⌥⌘Space", !S.uses(on, S.finderSearch, mods: S.cmd | S.opt))
        check("Open App Launcher is ⌘Space", Shortcuts.get(.openLauncher) == S.cmdSpace)
        check("macOS is using ⌥⌘Space for Spotlight now", live() == "⌥⌘Space")
        try? await Task.sleep(for: .seconds(1))
        let s0 = spotlightWindows()
        press(49, .maskCommand)
        try? await Task.sleep(for: .seconds(1.5))
        check("⌘Space opened the App Launcher", AppLauncher.shared.isOpen)
        check("⌘Space didn't open Spotlight", spotlightWindows() <= s0)
        AppLauncher.shared.close()
        press(49, [.maskCommand, .maskAlternate])
        try? await Task.sleep(for: .seconds(1.5))
        let s1 = spotlightWindows()
        note("Spotlight windows after ⌥⌘Space: \(s1) (were \(s0))")
        check("⌥⌘Space opens Spotlight", s1 > s0)
        press(53, []); try? await Task.sleep(for: .seconds(1))

        await S.set(false)
        let off = S.read()
        check("Spotlight entry back to what it was", (off[S.spotlight] as? NSDictionary) == (before[S.spotlight] as? NSDictionary))
        check("Finder search entry back to what it was", (off[S.finderSearch] as? NSDictionary) == (before[S.finderSearch] as? NSDictionary))
        check("Open App Launcher no longer on ⌘Space", Shortcuts.get(.openLauncher) != S.cmdSpace)
        check("macOS is using ⌘Space for Spotlight again", live() == "⌘Space")
        try? await Task.sleep(for: .seconds(1))
        let s2 = spotlightWindows()
        press(49, .maskCommand)
        try? await Task.sleep(for: .seconds(1.5))
        check("⌘Space opens Spotlight again", spotlightWindows() > s2)
        check("…and not the App Launcher", !AppLauncher.shared.isOpen)
        press(53, []); try? await Task.sleep(for: .seconds(1))

        if ProcessInfo.processInfo.environment["ONYX_SPOTLIGHTTEST_KEEP"] != nil {
            await S.set(true)
            note("left on: Spotlight on ⌥⌘Space \(S.uses(S.read(), S.spotlight, mods: S.cmd | S.opt))")
        }
        note(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
        exit(0)
    }
}

// MARK: - Self-test (debug): ONYX_LAUNCHERFOCUS=<file> opens the App Launcher while another app is in front,
// then types "saf" and checks it landed in the search field without clicking.

enum LauncherFocusTest {
    @MainActor static func run(_ file: String) async {
        var log: [String] = []
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        try? await Task.sleep(for: .seconds(1))
        note("Onyx active before opening: \(NSApp.isActive)")
        AppLauncher.shared.open()
        try? await Task.sleep(for: .seconds(0.3))
        let w = NSApp.windows.first { $0 is LauncherPanel }
        func state() -> String { "active \(NSApp.isActive), key \(w?.isKeyWindow == true), first responder \(w?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")" }
        note("0.3 s after opening: " + state())
        for k: CGKeyCode in [1, 0, 3] {   // s a f
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: down)?.post(tap: .cghidEventTap) }
            try? await Task.sleep(for: .seconds(0.05))
        }
        try? await Task.sleep(for: .seconds(0.7))
        let typed = (w?.firstResponder as? NSTextView)?.string ?? "(not in a text field)"
        note("after typing: " + state() + ", field has \"\(typed)\"")
        note(typed == "saf" ? "PASS" : "FAIL")
        AppLauncher.shared.close()
        exit(0)
    }
}

// MARK: - Debug: ONYX_SCENESHOT=<dir> renders each GPU scene to PNGs (two moments each), times a frame, then quits.

enum SceneShots {
    static func run(_ dir: String) {
        var log: [String] = []
        for s in WallpaperScene.allCases where s.shader != nil {
            for t: Float in [14, 21] {
                let start = CACurrentMediaTime()
                let img = GPU.snapshot(s, size: CGSize(width: 1806, height: 1130), time: t)
                let ms = (CACurrentMediaTime() - start) * 1000
                if let img, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(s.shader!)-\(Int(t)).png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                    log.append("\(s.title) t=\(Int(t)): \(Int(ms)) ms")
                } else { log.append("\(s.title): FAILED \(GPU.compileError ?? "")") }
            }
        }
        // GPU time per frame at the size the desktop actually draws (screen pixels × the scene's render scale), 30 frames each.
        if let device = GPU.device, let queue = GPU.queue, let screen = NSScreen.main {
            for s in WallpaperScene.allCases where s.shader != nil {
                let k = screen.backingScaleFactor * s.renderScale
                let w = Int(screen.frame.width * k), h = Int(screen.frame.height * k)
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                d.usage = .renderTarget; d.storageMode = .private
                guard let tex = device.makeTexture(descriptor: d) else { continue }
                var total = 0.0
                for f in 0..<30 {
                    guard let cmd = queue.makeCommandBuffer() else { continue }
                    var u = SceneUniforms(res: SIMD2(Float(w), Float(h)), time: 10 + Float(f) / 30, seed: 0)
                    _ = GPU.encode(cmd, into: tex, fragment: s.shader!, bytes: &u, length: MemoryLayout<SceneUniforms>.stride, textures: s == .codeRain ? [GPU.glyphs] : [])
                    cmd.commit(); cmd.waitUntilCompleted()
                    total += cmd.gpuEndTime - cmd.gpuStartTime
                }
                let ms = total / 30 * 1000
                log.append(String(format: "%@ at %d×%d: %.2f ms of GPU per frame → about %.0f%% of the GPU at 30 fps", s.title, w, h, ms, ms * 30 / 10))
            }
        }
        try? log.joined(separator: "\n").write(toFile: dir + "/scenes.log", atomically: true, encoding: .utf8)
        exit(0)
    }
}

// MARK: - Self-test (debug): ONYX_LOOPTEST=<dir> plans an idea, paints it with Image Playground, builds the AI loop,
// saves stills from it, and checks the loop point is seamless. Runs before any other services start, then quits.

enum LoopSelfTest {
    @MainActor static func run(_ dir: String) async {
        var log: [String] = [], fails = 0
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/loop.log", atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool) { note((ok ? "PASS " : "FAIL ") + name); if !ok { fails += 1 } }
        func png(_ img: CGImage, _ name: String) {
            guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name)") as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        }
        let idea = ProcessInfo.processInfo.environment["ONYX_LOOPTEST_IDEA"] ?? "minecraft sunset over the mountains"
        check("offline guess: cyberpunk → rain", LoopEffect.guess("cyberpunk alley").contains(.rain))
        check("offline guess: nothing matched → gentle defaults", LoopEffect.guess("xyz") == [.dust, .wind])

        var t = CACurrentMediaTime()
        let plan = await LoopMaker.plan(idea)
        note(String(format: "plan (%.1f s): %@ | %@ | %@", CACurrentMediaTime() - t, plan.name, plan.scene, plan.effects.map(\.rawValue).joined(separator: ", ")))
        check("plan has a name, a scene and effects", !plan.name.isEmpty && plan.scene.count > 10 && !plan.effects.isEmpty)

        var art: CGImage?
        t = CACurrentMediaTime()
        // Image Playground only paints for the app in front, so show a window and come forward first.
        let front = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        front.title = "Onyx loop test"; front.center(); front.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try? await Task.sleep(for: .seconds(1))
        note("Onyx in front: \(NSApp.isActive)")
        do {
            let c = try await ImageCreator()
            note("Image Playground styles: \(c.availableStyles.map(\.title).joined(separator: ", "))")
            for try await m in c.images(for: [.text(plan.scene)], style: .animation, limit: 1) { art = m.cgImage }
        } catch { note("Image Playground: \(error)") }
        if let art {
            note(String(format: "painted %d×%d in %.1f s", art.width, art.height, CACurrentMediaTime() - t)); png(art, "art.png")
        } else {
            note("no painting; using a Pixel Dusk still instead to test the rest")
            art = GPU.snapshot(.pixelDusk, size: CGSize(width: 1024, height: 1024))
        }
        guard let art else { note("FAIL nothing to animate"); exit(1) }

        t = CACurrentMediaTime()
        var stages: [String] = []
        do {
            let fx = plan.effects.reduce(UInt32(0)) { $0 | $1.bit }
            let url = try await LoopMaker.build(art, fx: fx, motion: 0.02) { stage, _ in
                Task { @MainActor in if stages.last != stage { stages.append(stage) } }
            }
            let secs = CACurrentMediaTime() - t
            let dest = URL(fileURLWithPath: dir + "/loop.mov")
            try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: url, to: dest)
            let info = try await WallpaperLibrary.info(dest)
            let mb = Double((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1e6
            note(String(format: "built in %.1f s: %d×%d, %.0f fps, %.2f s, %.1f MB", secs, info.width, info.height, info.fps, info.duration, mb))
            note("stages: " + stages.joined(separator: " → "))
            check("loop is 12 s at 30 fps", abs(info.duration - 12) < 0.1 && abs(info.fps - 30) < 0.5)
            check("loop is at least 1440p", info.width >= 2560)

            // Stills, and the seam: the last frame should lead into the first like any two neighbouring frames.
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: dest))
            g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            g.maximumSize = CGSize(width: 960, height: 600)
            func frame(_ i: Int) async -> CGImage? { try? await g.image(at: CMTime(value: CMTimeValue(i), timescale: 30)).image }
            for (i, name) in [(0, "frame-0s.png"), (120, "frame-4s.png"), (240, "frame-8s.png")] { if let f = await frame(i) { png(f, name) } }
            func diff(_ a: CGImage?, _ b: CGImage?) -> Double {
                guard let a, let b else { return .infinity }
                func px(_ i: CGImage) -> [UInt8] {
                    var buf = [UInt8](repeating: 0, count: 160 * 100 * 4)
                    let ctx = CGContext(data: &buf, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                    ctx?.draw(i, in: CGRect(x: 0, y: 0, width: 160, height: 100))
                    return buf
                }
                let x = px(a), y = px(b)
                return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
            }
            let first = await frame(0), second = await frame(1), last = await frame(359), middle = await frame(180)
            let seam = diff(last, first), step = diff(first, second), far = diff(first, middle)
            note(String(format: "difference: last→first %.2f, first→second %.2f, first→middle %.2f", seam, step, far))
            check("seamless: last→first is like any other step", seam < max(step * 2.5, 1.5))
            check("it moves: the middle differs from the start", far > step * 2)
        } catch {
            note("stages: " + stages.joined(separator: " → "))
            note("FAIL build: \((error as? VoiceError)?.message ?? "\(error)")"); fails += 1
        }
        note(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
        exit(0)
    }
}

// MARK: - Self-test (debug): ONYX_SCENETEST=<dir> plays each GPU scene in a real desktop wallpaper window for a few
// seconds, screenshots it, and measures Onyx's CPU use and the GPU's busy time. Runs before other services start.

enum ScenePerfTest {
    @MainActor static func run(_ dir: String) async {
        var log: [String] = [], fails = 0
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/scenes-live.log", atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool) { note((ok ? "PASS " : "FAIL ") + name); if !ok { fails += 1 } }
        func cpuSeconds() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        func gpuBusy() -> Int? {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"]
            p.standardOutput = pipe
            try? p.run(); let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
            guard let r = out.range(of: "\"Device Utilization %\"=") else { return nil }
            return Int(out[r.upperBound...].prefix { $0.isNumber })
        }
        // WindowServer does the compositing, so its CPU time counts too (cumulative time from ps, sampled twice).
        func serverSeconds() -> Double {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "time=,comm="]
            p.standardOutput = pipe
            try? p.run(); let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
            guard let line = out.split(separator: "\n").first(where: { $0.hasSuffix("/WindowServer") }),
                  let t = line.split(separator: " ").first else { return 0 }
            return t.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        guard let screen = NSScreen.main else { exit(1) }
        let win = WallpaperWindow(screen: screen)
        win.setFrame(screen.frame, display: true)
        win.orderBack(nil)
        do {
            let w0 = serverSeconds(), t0 = CACurrentMediaTime()
            var gpu: [Int] = []
            for _ in 0..<6 { try? await Task.sleep(for: .seconds(1)); if let g = gpuBusy() { gpu.append(g) } }
            note(String(format: "baseline (no wallpaper): WindowServer %.1f%%, GPU busy %@", (serverSeconds() - w0) / (CACurrentMediaTime() - t0) * 100,
                        gpu.map(String.init).joined(separator: "/")))
        }
        for s in WallpaperScene.allCases {
            win.show(s.wallpaper, sound: false); win.play()
            try? await Task.sleep(for: .seconds(2))
            let c0 = cpuSeconds(), w0 = serverSeconds(), t0 = CACurrentMediaTime()
            var gpu: [Int] = []
            for _ in 0..<6 { try? await Task.sleep(for: .seconds(1)); if let g = gpuBusy() { gpu.append(g) } }
            let cpu = (cpuSeconds() - c0) / (CACurrentMediaTime() - t0) * 100
            let server = (serverSeconds() - w0) / (CACurrentMediaTime() - t0) * 100
            let shot = "\(dir)/live-\(s.rawValue).png"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", shot]; try? p.run(); p.waitUntilExit()
            let drawn = (win.contentView?.subviews.first?.subviews.contains { $0 is ShaderView }) == true
            note(String(format: "%@: Onyx CPU %.1f%%, WindowServer %.1f%%, GPU busy %@ (whole Mac)", s.title, cpu, server, gpu.map(String.init).joined(separator: "/")))
            guard s.shader != nil else { continue }
            check("\(s.title) uses its GPU view", drawn)
            check("\(s.title) keeps Onyx's CPU under 5%", cpu < 5)
        }
        // Paused: no drawing at all.
        win.pause()
        try? await Task.sleep(for: .seconds(1))
        let c0 = cpuSeconds(), t0 = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(4))
        let idle = (cpuSeconds() - c0) / (CACurrentMediaTime() - t0) * 100
        note(String(format: "paused: Onyx CPU %.2f%%", idle))
        check("paused scene costs next to nothing", idle < 1)
        win.stop(); win.orderOut(nil)
        note(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
        exit(0)
    }
}

// MARK: - Self-test (debug): ONYX_SDTEST=<dir> unpacks and runs each Stable Diffusion style (ONYX_SDTEST_STYLES,
// default realistic,anime) on one scene, and builds a loop from ONYX_SDTEST_STILL to check the parallax. Runs before
// other services start, then quits.

enum SDSelfTest {
    @MainActor static func run(_ dir: String) async {
        let env = ProcessInfo.processInfo.environment
        var log: [String] = []
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/sd.log", atomically: true, encoding: .utf8) }
        func png(_ img: CGImage, _ name: String) {
            guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name)") as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        }
        let scene = env["ONYX_SDTEST_SCENE"] ?? "misty castle ruins beside a colossal glowing golden tree at dusk, purple sky, lantern light"
        var made: [(DiffusionStyle, CGImage)] = []
        for sd in (env["ONYX_SDTEST_STYLES"] ?? "realistic,anime").split(separator: ",").compactMap({ DiffusionStyle(rawValue: String($0)) }) {
            var t = CACurrentMediaTime()
            do { try await sd.download { _ in } } catch { note("FAIL \(sd.rawValue) download/unpack: \(error)"); continue }
            note(String(format: "%@ ready in %.1f s", sd.rawValue, CACurrentMediaTime() - t))
            t = CACurrentMediaTime()
            do {
                let imgs = try await Task.detached(priority: .userInitiated) { () -> [CGImage] in
                    var out: [CGImage] = []
                    try Diffusion(sd).paint(scene, count: 1, seed: 7, progress: { _, _ in }, each: { out.append($0) })
                    return out
                }.value
                note(String(format: "%@ painted %d in %.1f s (%@)", sd.rawValue, imgs.count, CACurrentMediaTime() - t, imgs.first.map { "\($0.width)×\($0.height)" } ?? "-"))
                if let i = imgs.first { png(i, "sd-\(sd.rawValue).png"); made.append((sd, i)) }
            } catch { note("FAIL \(sd.rawValue) paint: \(error)") }
        }
        // The parallax, on a still (by default the first painting), with fog and lights.
        var still: CGImage? = made.first?.1
        if let path = env["ONYX_SDTEST_STILL"], let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) { still = CGImageSourceCreateImageAtIndex(src, 0, nil) }
        if let still {
            let t = CACurrentMediaTime()
            do {
                let url = try await LoopMaker.build(still, fx: LoopEffect.fog.bit | LoopEffect.lights.bit | LoopMaker.grain, motion: 0.007) { _, _ in }
                note(String(format: "loop built in %.1f s", CACurrentMediaTime() - t))
                let dest = URL(fileURLWithPath: dir + "/loop.mov")
                try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: url, to: dest)
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: dest))
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                for s in [0, 3, 6, 9] { if let f = try? await g.image(at: CMTime(value: CMTimeValue(s * 30), timescale: 30)).image { png(f, "loop-\(s)s.png") } }
            } catch { note("FAIL loop: \(error)") }
        }
        note("done")
        exit(0)
    }
}
