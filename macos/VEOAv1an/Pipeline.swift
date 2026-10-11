//
//  Pipeline.swift — runs the VEO -> zones -> Av1an pipeline via Process
//

import Foundation

enum Phase: String {
    case idle = "Hazır"
    case probing = "Video inceleniyor"
    case analyzing = "VEO analizi çalışıyor"
    case converting = "Zones üretiliyor"
    case encoding = "Av1an encode ediyor"
    case verifying = "VMAF ölçülüyor"
    case done = "Tamamlandı"
    case failed = "Hata"
    case cancelled = "İptal edildi"
}

struct RunConfig {
    var veoMode = "per-segment"       // per-segment | per-shot
    var encoder = "svt-av1"
    var targetVMAF = 93.0
    var targetBitrate = 2000.0        // kbps (per-shot Trellis)
    var shotThreshold = 10.0
    var veoPreset = "medium"
    var workers = 0                   // 0 = Av1an decides
    var encoderParams = "--preset 6"
    var extraZoneParams = ""
    var defaultCRF = 30.0
    var minSceneLen = 24
    var audioParams = "-c:a copy"
    var verifyVMAF = false
    var fallbackNoZones = false
    var keepWorkdir = false
}

@MainActor
final class Pipeline: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var progress: Double? = nil     // 0-1 when parseable
    @Published var logLines: [String] = []

    private var process: Process?
    private var cancelled = false

    var isRunning: Bool { phase != .idle && phase != .done && phase != .failed && phase != .cancelled }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
        // progress heuristic: last "NN.N%" pattern wins
        if let m = line.range(of: #"(\d{1,3}(?:\.\d+)?)%"#,
                              options: .regularExpression) {
            let v = Double(line[m].dropLast()) ?? 0
            progress = min(1, max(0, v / 100))
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    // MARK: - Process runner

    private struct CmdResult { let code: Int32 }

    private func run(_ executable: String, _ args: [String],
                     tag: String) async throws -> CmdResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.standardOutput = pipe
            p.standardError = pipe
            var buffer = ""
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                buffer += String(decoding: data, as: UTF8.self)
                var lines = buffer.split(separator: "\n",
                                         omittingEmptySubsequences: false)
                if buffer.hasSuffix("\n") || buffer.hasSuffix("\r") {
                    buffer = ""
                } else {
                    buffer = lines.isEmpty ? buffer : String(lines.removeLast())
                }
                let ready = lines.map { String($0).trimmingCharacters(
                    in: .init(charactersIn: "\r")) }.filter { !$0.isEmpty }
                if !ready.isEmpty {
                    Task { @MainActor in
                        for l in ready { self.appendLog("[\(tag)] \(l)") }
                    }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: CmdResult(code: proc.terminationStatus))
            }
            do {
                self.process = p
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Steps

    private func probe(_ input: URL) async throws -> (fps: Double, frames: Int) {
        guard let ffprobe = ToolLocator.find("ffprobe") else {
            throw NSError(domain: "bridge", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "ffprobe bulunamadı"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-select_streams", "v:0",
                       "-show_entries", "stream=avg_frame_rate,nb_frames,duration",
                       "-show_entries", "format=duration",
                       "-of", "json", input.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (json["streams"] as? [[String: Any]])?.first
        else {
            throw NSError(domain: "bridge", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "ffprobe başarısız"])
        }
        let rate = (stream["avg_frame_rate"] as? String) ?? "0/1"
        let parts = rate.split(separator: "/").map { Double($0) ?? 0 }
        let fps = parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : 0
        var frames = (stream["nb_frames"] as? NSString)?.intValue ?? 0
        if frames <= 0 {
            let dur = (stream["duration"] as? NSString)?.doubleValue
                ?? ((json["format"] as? [String: Any])?["duration"] as? NSString)?.doubleValue
                ?? 0
            frames = Int((dur * fps).rounded(.up))
        }
        guard fps > 0, frames > 0 else {
            throw NSError(domain: "bridge", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "fps/kare sayısı belirlenemedi"])
        }
        return (fps, frames)
    }

    private func veoCommand(_ cfg: RunConfig, input: URL) -> [String] {
        let codec = Encoders.veoCodec(for: cfg.encoder)
        if cfg.veoMode == "per-shot" {
            return ["per-shot", "analyze", "-i", input.path,
                    "--threshold", String(cfg.shotThreshold),
                    "--target-bitrate", String(Int(cfg.targetBitrate)),
                    "--codecs", codec]
        }
        return ["per-segment", "analyze", "-i", input.path,
                "--codec", codec, "--preset", cfg.veoPreset,
                "--target-vmaf", String(cfg.targetVMAF)]
    }

    private func av1anCommand(_ cfg: RunConfig, input: URL, output: URL,
                              zones: URL?) -> [String] {
        var args = ["-i", input.path, "-o", output.path,
                    "-e", cfg.encoder,
                    "-v", cfg.encoderParams,
                    "-a", cfg.audioParams,
                    "-y"]
        if cfg.workers > 0 { args += ["-w", String(cfg.workers)] }
        if let zones { args += ["--zones", zones.path] }
        return args
    }

    private func verify(_ cfg: RunConfig, input: URL, output: URL,
                        workdir: URL) async {
        guard let ffmpeg = ToolLocator.find("ffmpeg") else { return }
        let logPath = workdir.appendingPathComponent("vmaf.json")
        _ = try? await run(ffmpeg,
            ["-i", output.path, "-i", input.path, "-lavfi",
             "libvmaf=log_path=\(logPath.path):log_fmt=json",
             "-f", "null", "-"], tag: "vmaf")
        if let data = try? Data(contentsOf: logPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pooled = json["pooled_metrics"] as? [String: Any],
           let vmaf = pooled["vmaf"] as? [String: Any],
           let mean = (vmaf["mean"] as? NSNumber)?.doubleValue {
            let delta = mean - cfg.targetVMAF
            appendLog(String(format:
                "VMAF sonuç: %.2f (hedef %.1f, fark %+.2f)", mean, cfg.targetVMAF, delta))
        }
    }

    // MARK: - Pipeline entry

    func run(input: URL, output: URL, cfg: RunConfig) async {
        phase = .probing
        progress = nil
        logLines = []
        cancelled = false
        appendLog("girdi: \(input.path)")
        appendLog("çıktı: \(output.path)")

        let missing = ToolLocator.missing(
            ["veo", "av1an", "ffprobe"] + (cfg.verifyVMAF ? ["ffmpeg"] : []))
        if !missing.isEmpty {
            appendLog("eksik araçlar: \(missing.joined(separator: ", "))")
            appendLog("brew/cargo ile kurun veya PATH'e ekleyin.")
            phase = .failed
            return
        }

        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("veo-av1an-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workdir,
                                                 withIntermediateDirectories: true)
        defer {
            if !cfg.keepWorkdir {
                try? FileManager.default.removeItem(at: workdir)
            } else {
                appendLog("workdir saklandı: \(workdir.path)")
            }
        }

        do {
            // 1) probe
            let (fps, frames) = try await probe(input)
            appendLog(String(format: "video: %.4f fps, %d kare", fps, frames))

            // 2) VEO
            phase = .analyzing
            let veoResult = try await run(ToolLocator.find("veo")!,
                                          veoCommand(cfg, input: input),
                                          tag: "veo")
            if cancelled { phase = .cancelled; return }
            if veoResult.code != 0 {
                appendLog("VEO hata verdi (çıkış \(veoResult.code))")
                phase = .failed
                return
            }
            // VEO stdout was streamed to the log; re-collect for parsing.
            // We re-read captured lines tagged [veo].
            let veoText = logLines.filter { $0.hasPrefix("[veo] ") }
                .map { String($0.dropFirst(6)) }.joined(separator: "\n")

            // 3) convert
            phase = .converting
            var report = ConvertReport()
            let segments = parseVeoStdout(veoText)
            let zones = try toZones(
                segments: segments, fps: fps, totalFrames: frames,
                encoder: cfg.encoder, defaultCRF: cfg.defaultCRF,
                minSceneFrames: cfg.minSceneLen,
                extraZoneParams: cfg.extraZoneParams, report: &report)
            appendLog(String(format:
                "dönüşüm: %d segment -> %d zone (kısa birleşti: %d, çakışma kırpıldı: %d, crf kenetlendi: %d)",
                report.inputSegments, report.outputZones, report.droppedShort,
                report.clippedOverlaps, report.clampedCRF))
            for w in report.warnings { appendLog("uyarı: \(w)") }
            guard !zones.isEmpty else {
                appendLog("zone üretilemedi")
                phase = .failed
                return
            }
            let zonesURL = workdir.appendingPathComponent("zones.txt")
            let zonesText = renderZones(zones)
            try zonesText.write(to: zonesURL, atomically: true, encoding: .utf8)
            appendLog("zones.txt:\n\(zonesText)")

            // 4) Av1an
            phase = .encoding
            var result = try await run(ToolLocator.find("av1an")!,
                                       av1anCommand(cfg, input: input,
                                                    output: output, zones: zonesURL),
                                       tag: "av1an")
            if cancelled { phase = .cancelled; return }
            if result.code != 0 && cfg.fallbackNoZones {
                appendLog("zones reddedildi; zones'suz tekrar deneniyor")
                result = try await run(ToolLocator.find("av1an")!,
                                       av1anCommand(cfg, input: input,
                                                    output: output, zones: nil),
                                       tag: "av1an")
            }
            if cancelled { phase = .cancelled; return }
            guard result.code == 0,
                  FileManager.default.fileExists(atPath: output.path) else {
                appendLog("Av1an başarısız (çıkış \(result.code))")
                phase = .failed
                return
            }

            // 5) optional VMAF
            if cfg.verifyVMAF {
                phase = .verifying
                await verify(cfg, input: input, output: output, workdir: workdir)
            }
            phase = .done
            progress = 1
            appendLog("bitti: \(output.path)")
        } catch {
            appendLog("hata: \(error.localizedDescription)")
            phase = .failed
        }
    }
}
