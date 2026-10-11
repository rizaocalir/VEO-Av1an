//
//  ZoneConverter.swift
//  VEOAv1an — Swift port of ../veo_to_av1an.py
//
//  Converts VEO (Video Encoding Optimizer) output into an Av1an --zones file.
//  Supports: per-segment stdout table, per-shot stdout table (+Trellis),
//  per-shot detect table, and VEO JSON dumps (Go time.Duration = nanoseconds,
//  auto-detected). Pure logic, no I/O — fully unit-testable.
//

import Foundation

// MARK: - Types

struct Segment: Equatable {
    var start: Double   // seconds
    var end: Double     // seconds (exclusive)
    var crf: Double?    // nil = VEO gave no CRF for this range
}

struct Zone: Equatable {
    var startFrame: Int
    var endFrame: Int   // exclusive; -1 = end of video
    var encoder: String
    var videoParams: String
}

struct ConvertReport {
    var inputSegments = 0
    var outputZones = 0
    var droppedShort = 0
    var mergedAdjacent = 0
    var clippedOverlaps = 0
    var clampedCRF = 0
    var uncoveredLead = 0.0   // seconds before the first zone
    var uncoveredTail = 0.0   // seconds after the last zone
    var warnings: [String] = []
}

enum ConvertError: Error {
    case unsupportedEncoder(String)
    case noSegments
}

struct EncoderSpec {
    let crfFlag: String      // printf-style with %d for the CRF value
    let minCRF: Int
    let maxCRF: Int
}

// Av1an encoder name -> spec. VEO's FFmpeg codec names are mapped first.
enum Encoders {
    static let specs: [String: EncoderSpec] = [
        "svt-av1": EncoderSpec(crfFlag: "--crf %d", minCRF: 0, maxCRF: 63),
        "x264":    EncoderSpec(crfFlag: "--crf %d", minCRF: 0, maxCRF: 51),
        "x265":    EncoderSpec(crfFlag: "--crf %d", minCRF: 0, maxCRF: 51),
        "aom":     EncoderSpec(crfFlag: "--cq-level=%d", minCRF: 0, maxCRF: 63),
    ]
    // VEO FFmpeg codec name -> Av1an encoder name
    static let codecToAv1an: [String: String] = [
        "libsvtav1": "svt-av1", "svt-av1": "svt-av1",
        "libx264": "x264", "x264": "x264",
        "libx265": "x265", "x265": "x265",
        "libaom-av1": "aom", "aom": "aom",
    ]
    // Av1an encoder name -> canonical VEO (FFmpeg) codec name.
    // A reverse lookup over codecToAv1an would be nondeterministic
    // (several keys share a value and dictionary order is not stable).
    static let av1anToVeo: [String: String] = [
        "svt-av1": "libsvtav1",
        "x264": "libx264",
        "x265": "libx265",
        "aom": "libaom-av1",
    ]
    // Sensible `av1an -v` (encoder params) defaults per encoder — the
    // flag syntax differs (x264/x265 named presets, svt-av1 numeric,
    // aom -cpu-used).
    static let defaultParams: [String: String] = [
        "svt-av1": "--preset 6",
        "x264": "--preset medium",
        "x265": "--preset medium",
        "aom": "--cpu-used 6",
    ]
    static let names = ["svt-av1", "x264", "x265", "aom"]
    static func veoCodec(for av1anName: String) -> String {
        av1anToVeo[av1anName] ?? "libsvtav1"
    }
}

private let nsThreshold = 1_000_000.0   // > ~11 days in "seconds" must be ns

// MARK: - Stdout parsing

private func tokens(of line: String) -> [String] {
    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
}

private func parseRange(_ tok: String) -> (Double, Double)? {
    // "0.0-2.0s"
    guard tok.hasSuffix("s") else { return nil }
    let parts = tok.dropLast().split(separator: "-")
    guard parts.count == 2,
          let a = Double(parts[0]), let b = Double(parts[1]) else { return nil }
    return (a, b)
}

private func parseSeconds(_ tok: String) -> Double? {
    guard tok.hasSuffix("s") else { return nil }
    return Double(tok.dropLast())
}

private let shotHeaderRe = try! NSRegularExpression(
    pattern: #"Shot\s+(\d+)\s*\(\s*([\d.]+)s\s*-\s*([\d.]+)s"#)

func parseVeoStdout(_ text: String) -> [Segment] {
    // 1) per-segment analyze rows: idx range complexity crf bitrate kbps vmaf iter
    var segments: [Segment] = []
    for line in text.split(separator: "\n").map(String.init) {
        let t = tokens(of: line)
        guard t.count >= 8, Int(t[0]) != nil,
              let range = parseRange(t[1]),
              let kbps = t.firstIndex(of: "kbps"), kbps >= 4,
              let crf = Int(t[kbps - 2])
        else { continue }
        segments.append(Segment(start: range.0, end: range.1, crf: Double(crf)))
    }
    if !segments.isEmpty { return segments }

    // 2) per-shot analyze: "Shot N (a - b, c):" headers + trellis rows
    var shots: [Int: Segment] = [:]
    var trellis: [Int: Int] = [:]
    let full = text as NSString
    for m in shotHeaderRe.matches(in: text, range: NSRange(location: 0, length: full.length)) {
        let idx = Int(full.substring(with: m.range(at: 1))) ?? 0
        let a = Double(full.substring(with: m.range(at: 2))) ?? 0
        let b = Double(full.substring(with: m.range(at: 3))) ?? 0
        shots[idx] = Segment(start: a, end: b, crf: nil)
    }
    for line in text.split(separator: "\n").map(String.init) {
        let t = tokens(of: line)
        // trellis row: shotIdx res codec crf bitrate kbps vmaf
        guard t.count >= 7, let idx = Int(t[0]),
              t[5] == "kbps", let crf = Int(t[3])
        else { continue }
        trellis[idx] = crf
    }
    if !shots.isEmpty {
        return shots.keys.sorted().map {
            var s = shots[$0]!
            s.crf = trellis[$0].map(Double.init)
            return s
        }
    }

    // 3) per-shot detect rows: idx start s end s duration s
    for line in text.split(separator: "\n").map(String.init) {
        let t = tokens(of: line)
        guard t.count == 4, Int(t[0]) != nil,
              let a = parseSeconds(t[1]), let b = parseSeconds(t[2])
        else { continue }
        segments.append(Segment(start: a, end: b, crf: nil))
    }
    return segments
}

// MARK: - JSON parsing (VEO Result schema; durations may be nanoseconds)

private func asSeconds(_ v: Double, _ maxVal: Double) -> Double {
    maxVal > nsThreshold ? v / 1e9 : v
}

private func crfFromHull(_ hull: [String: Any]?, targetVMAF: Double?) -> Double? {
    guard let hull, let targetVMAF,
          let points = hull["points"] as? [[String: Any]], !points.isEmpty
    else { return nil }
    let best = points.min {
        abs((($0["vmaf"] as? NSNumber)?.doubleValue ?? 0) - targetVMAF) <
        abs((($1["vmaf"] as? NSNumber)?.doubleValue ?? 0) - targetVMAF)
    }
    return (best?["crf"] as? NSNumber)?.doubleValue
}

func parseVeoJSON(data: Data, crfPick: String = "median",
                  targetVMAF: Double? = nil) throws -> [Segment] {
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else { throw ConvertError.noSegments }

    func pickCRF(_ raw: Any?) -> Double? {
        switch raw {
        case let n as NSNumber: return n.doubleValue
        case let list as [NSNumber]:
            let v = list.map(\.doubleValue).sorted()
            if v.isEmpty { return nil }
            switch crfPick {
            case "midpoint": return (v.first! + v.last!) / 2
            case "min": return v.first
            case "max": return v.last
            default: return v[v.count / 2]
            }
        case let range as [String: NSNumber]:
            if let lo = range["min"], let hi = range["max"] {
                return (lo.doubleValue + hi.doubleValue) / 2
            }
            return nil
        default: return nil
        }
    }

    var segments: [Segment] = []

    // per-segment schema
    if let raw = dict["segments"] as? [[String: Any]] {
        let maxEnd = raw.compactMap { ($0["end"] as? NSNumber)?.doubleValue }.max() ?? 0
        for s in raw {
            segments.append(Segment(
                start: asSeconds((s["start"] as? NSNumber)?.doubleValue ?? 0, maxEnd),
                end: asSeconds((s["end"] as? NSNumber)?.doubleValue ?? 0, maxEnd),
                crf: pickCRF(s["crf"] ?? s["crf_range"] ?? s["crf_values"])
            ))
        }
        return segments
    }

    // per-shot schema
    if let raw = dict["shots"] as? [[String: Any]] {
        let maxEnd = raw.compactMap {
            (($0["shot"] as? [String: Any])?["end"] as? NSNumber)?.doubleValue
        }.max() ?? 0
        var assign: [Int: Double] = [:]
        for a in dict["assignments"] as? [[String: Any]] ?? [] {
            if let i = (a["shot_index"] as? NSNumber)?.intValue,
               let c = (a["crf"] as? NSNumber)?.doubleValue {
                assign[i] = c
            }
        }
        for (i, sr) in raw.enumerated() {
            let shot = (sr["shot"] as? [String: Any]) ?? sr
            let crf = assign[i] ?? assign[i + 1]
                ?? crfFromHull(sr["hull"] as? [String: Any], targetVMAF: targetVMAF)
            segments.append(Segment(
                start: asSeconds((shot["start"] as? NSNumber)?.doubleValue ?? 0, maxEnd),
                end: asSeconds((shot["end"] as? NSNumber)?.doubleValue ?? 0, maxEnd),
                crf: crf
            ))
        }
    }
    return segments
}

// MARK: - Segments -> zones

private func crfOf(_ zone: Zone) -> Double {
    // first number in the params is the CRF (handles "--crf 30" and "--cq-level=28")
    if let m = zone.videoParams.range(of: #"\d+(\.\d+)?"#,
                                      options: .regularExpression) {
        return Double(zone.videoParams[m]) ?? 0
    }
    return 0
}

private func enforceMinLength(_ zones: inout [Zone], minFrames: Int,
                              report: inout ConvertReport) {
    var changed = true
    while changed && zones.count > 1 {
        changed = false
        for i in zones.indices {
            guard zones[i].endFrame - zones[i].startFrame < minFrames else { continue }
            var best: (dist: Double, idx: Int)?
            if i > 0 { best = (abs(crfOf(zones[i-1]) - crfOf(zones[i])), i - 1) }
            if i < zones.count - 1 {
                let cand = (dist: abs(crfOf(zones[i+1]) - crfOf(zones[i])), idx: i + 1)
                if best == nil || cand.dist < best!.dist { best = cand }
            }
            guard let target = best else { break }
            if target.idx < i {
                zones[target.idx].endFrame = zones[i].endFrame
            } else {
                zones[target.idx].startFrame = zones[i].startFrame
            }
            zones.remove(at: i)
            report.droppedShort += 1
            changed = true
            break
        }
    }
}

func toZones(
    segments: [Segment], fps: Double, totalFrames: Int, encoder: String,
    defaultCRF: Double? = nil, minSceneFrames: Int = 24,
    extraZoneParams: String = "", report: inout ConvertReport
) throws -> [Zone] {
    guard let spec = Encoders.specs[encoder] else {
        throw ConvertError.unsupportedEncoder(encoder)
    }
    report.inputSegments = segments.count
    var segs = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    if segs.isEmpty {
        report.warnings.append("no usable segments from VEO output")
        return []
    }

    // clip overlaps: next segment's start wins
    for i in 1..<segs.count {
        if segs[i].start < segs[i-1].end {
            segs[i-1].end = segs[i].start
            report.clippedOverlaps += 1
        }
    }
    segs = segs.filter { $0.end > $0.start }

    var zones: [Zone] = []
    for s in segs {
        guard let crf = s.crf ?? defaultCRF else {
            report.warnings.append(
                String(format: "segment %.2f-%.2fs has no CRF; skipped", s.start, s.end))
            continue
        }
        let clamped = min(spec.maxCRF, max(spec.minCRF, Int(crf.rounded())))
        if clamped != Int(crf.rounded()) { report.clampedCRF += 1 }
        var params = String(format: spec.crfFlag, clamped)
        if !extraZoneParams.isEmpty { params += " " + extraZoneParams }
        zones.append(Zone(
            startFrame: Int((s.start * fps).rounded()),
            endFrame: Int((s.end * fps).rounded()),
            encoder: encoder, videoParams: params))
    }
    if zones.isEmpty { return [] }

    // merge adjacent zones with identical params
    var merged: [Zone] = []
    for z in zones {
        if let last = merged.last, z.startFrame <= last.endFrame,
           z.videoParams == last.videoParams, z.encoder == last.encoder {
            merged[merged.count - 1].endFrame = max(last.endFrame, z.endFrame)
            report.mergedAdjacent += 1
        } else {
            merged.append(z)
        }
    }
    zones = merged

    enforceMinLength(&zones, minFrames: minSceneFrames, report: &report)

    zones = zones.filter { $0.endFrame > 0 && $0.startFrame < totalFrames }
    for i in zones.indices {
        zones[i].startFrame = max(0, zones[i].startFrame)
        zones[i].endFrame = min(zones[i].endFrame, totalFrames)
    }
    if let first = zones.first, first.startFrame > 0 {
        report.uncoveredLead = Double(first.startFrame) / fps
    }
    if let last = zones.last {
        if last.endFrame >= totalFrames - 1 {
            zones[zones.count - 1].endFrame = -1
        } else if last.endFrame > 0 {
            report.uncoveredTail = Double(totalFrames - last.endFrame) / fps
        }
    }
    report.outputZones = zones.count
    return zones
}

func renderZones(_ zones: [Zone]) -> String {
    zones.map { "\($0.startFrame) \($0.endFrame) \($0.encoder) \($0.videoParams)" }
        .joined(separator: "\n") + (zones.isEmpty ? "" : "\n")
}
