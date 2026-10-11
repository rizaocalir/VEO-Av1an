//
//  ContentView.swift — VEO Av1an Bridge main window
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var pipeline = Pipeline()

    @AppStorage("veoMode") private var veoMode = "per-segment"
    @AppStorage("encoder") private var encoder = "svt-av1"
    @AppStorage("targetVMAF") private var targetVMAF = 93.0
    @AppStorage("targetBitrate") private var targetBitrate = 2000.0
    @AppStorage("workers") private var workers = 0
    @AppStorage("encoderParams") private var encoderParams = "--preset 6"
    @AppStorage("extraZoneParams") private var extraZoneParams = ""
    @AppStorage("defaultCRF") private var defaultCRF = 30.0
    @AppStorage("minSceneLen") private var minSceneLen = 24
    @AppStorage("verifyVMAF") private var verifyVMAF = false
    @AppStorage("fallbackNoZones") private var fallbackNoZones = false
    @AppStorage("keepWorkdir") private var keepWorkdir = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @State private var inputPath = ""
    @State private var outputPath = ""
    @State private var dropTargeted = false
    @State private var showAdvanced = false
    @State private var showOnboarding = false

    private var canRun: Bool {
        !inputPath.isEmpty && !outputPath.isEmpty && !pipeline.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filesSection
            settingsSection
            controlsSection
            logSection
        }
        .padding()
        .onAppear {
            guard !hasSeenOnboarding else { return }
            hasSeenOnboarding = true
            // Present only after the window is up — during the first
            // onAppear a sheet can be swallowed silently.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        GroupBox("Dosyalar") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "film")
                    TextField("Girdi videosu (sürükle-bırak)", text: $inputPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Seç…") { pickInput() }
                }
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    TextField("Çıktı dosyası", text: $outputPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Seç…") { pickOutput() }
                }
            }
            .padding(4)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                                      options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in
                        inputPath = url.path
                        if outputPath.isEmpty {
                            outputPath = url.deletingPathExtension().path
                                + "-encoded.mkv"
                        }
                    }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        GroupBox("Ayarlar") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Picker("Analiz", selection: $veoMode) {
                        Text("Per-segment").tag("per-segment")
                        Text("Per-shot").tag("per-shot")
                    }
                    .frame(width: 220)
                    Picker("Encoder", selection: $encoder) {
                        ForEach(Encoders.names, id: \.self) { Text($0) }
                    }
                    .frame(width: 160)
                    .onChange(of: encoder) { newEncoder in
                        // keep a still-default params field valid for
                        // the newly selected encoder; leave custom
                        // strings untouched
                        if Encoders.defaultParams.values
                            .contains(encoderParams) || encoderParams.isEmpty {
                            encoderParams = Encoders.defaultParams[newEncoder]
                                ?? encoderParams
                        }
                    }
                    Stepper("İşçi: \(workers == 0 ? "auto" : "\(workers)")",
                            value: $workers, in: 0...32)
                }
                GridRow {
                    HStack {
                        Text("Hedef VMAF")
                        Slider(value: $targetVMAF, in: 85...99, step: 0.5)
                        Text(String(format: "%.1f", targetVMAF))
                            .monospacedDigit()
                    }
                    .frame(width: 280)
                    if veoMode == "per-shot" {
                        HStack {
                            Text("Bit hızı")
                            TextField("kbps", value: $targetBitrate,
                                      format: .number)
                                .frame(width: 70)
                            Text("kbps")
                        }
                    }
                    Toggle("VMAF doğrula", isOn: $verifyVMAF)
                }
            }
            .padding(4)
            DisclosureGroup("Gelişmiş", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        HStack {
                            Text("Encoder parametreleri").fixedSize()
                            TextField("--preset 6", text: $encoderParams)
                                .frame(width: 180)
                        }
                        HStack {
                            Text("Zone ek parametre").fixedSize()
                            TextField("", text: $extraZoneParams)
                                .frame(width: 160)
                        }
                    }
                    HStack(spacing: 16) {
                        Stepper("Varsayılan CRF: \(Int(defaultCRF))",
                                value: $defaultCRF, in: 0...63)
                        Stepper("Min sahne: \(minSceneLen) kare",
                                value: $minSceneLen, in: 1...240)
                        Toggle("Zones reddedilirse zones'suz dene",
                               isOn: $fallbackNoZones)
                    }
                    Toggle("Çalışma klasörünü sakla", isOn: $keepWorkdir)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        HStack {
            Button(pipeline.isRunning ? "Çalışıyor…" : "Başlat") {
                Task { await start() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun)

            Button("İptal") { pipeline.cancel() }
                .disabled(!pipeline.isRunning)

            Spacer()

            Button {
                showOnboarding = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("Kullanım notları")
            .buttonStyle(.borderless)
            Text(pipeline.phase.rawValue).foregroundStyle(.secondary)
            if let p = pipeline.progress {
                ProgressView(value: p).frame(width: 160)
            } else if pipeline.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        GroupBox("Günlük") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(pipeline.logLines.enumerated()),
                                id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: pipeline.logLines.count) { _ in
                    proxy.scrollTo(pipeline.logLines.count - 1,
                                   anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Actions

    private func pickInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            inputPath = url.path
            if outputPath.isEmpty {
                outputPath = url.deletingPathExtension().path + "-encoded.mkv"
            }
        }
    }

    private func pickOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie]
        panel.nameFieldStringValue = "output.mkv"
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
        }
    }

    private func start() async {
        let cfg = RunConfig(
            veoMode: veoMode, encoder: encoder, targetVMAF: targetVMAF,
            targetBitrate: targetBitrate, workers: workers,
            encoderParams: encoderParams, extraZoneParams: extraZoneParams,
            defaultCRF: defaultCRF, minSceneLen: minSceneLen,
            verifyVMAF: verifyVMAF, fallbackNoZones: fallbackNoZones,
            keepWorkdir: keepWorkdir)
        await pipeline.run(input: URL(fileURLWithPath: inputPath),
                           output: URL(fileURLWithPath: outputPath),
                           cfg: cfg)
    }
}

// MARK: - First-run info sheet

private struct OnboardingView: View {
    let onClose: () -> Void

    private let tips: [(String, String)] = [
        ("film", "Girdi: mp4, mkv, mov, avi, webm — ffprobe'nin okuduğu her format."),
        ("checkmark.seal", "En sorunsuz girdi: yuv420p piksel formatı ve çift sayılı en/boy (örn. 1920x1080)."),
        ("shippingbox", "Çıktı olarak .mkv önerilir; Av1an parçaları en güvenli bu kapta birleştirir."),
        ("timer", "Analiz süresi video uzadıkça artar — VEO her segmenti birkaç kez deneme kodlaması yapar."),
        ("internaldrive", "Diskte kaynak boyutunun birkaç katı boş alan bırak (geçici parça dosyaları için)."),
        ("wrench.and.screwdriver", "veo ve av1an uygulamanın içinde gömülü; ayrıca kurulum gerekmez. ffprobe sistemde kurulu olmalı (brew install ffmpeg)."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kullanım Notları")
                .font(.title2).bold()
            ForEach(tips, id: \.1) { symbol, text in
                Label(text, systemImage: symbol)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Anladım") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
