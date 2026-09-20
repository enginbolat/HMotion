import SwiftUI
import UniformTypeIdentifiers

struct SessionView: View {
    @State private var model = HeadTrackingModel()
    @State private var isShowingImporter = false
    @State private var urlText = ""

    var body: some View {
        NavigationStack {
            Form {
                readoutSection
                audioModeSection
                if model.mode == .builtInPlayer { builtInPlayerSection }
                thresholdSection
                logSection
            }
            .navigationTitle("EarGuard")
            .safeAreaInset(edge: .bottom) { sessionButton }
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.builtInPlayer.load(url)
            }
        }
    }

    // MARK: - Sections

    private var readoutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(angleText)
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(model.statusText)
                    .font(.subheadline)
                    .foregroundStyle(model.availability.isReady ? Color.secondary : Color.red)

                DeviationChartView(
                    samples: model.samples,
                    thresholdDegrees: model.thresholdDegrees,
                    window: HeadTrackingModel.chartWindow
                )
                .frame(height: 100)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            if model.isRunning {
                Button("Recalibrate", systemImage: "scope") { model.recalibrate() }
            }
        }
    }

    private var angleText: String {
        guard let angle = model.angleDegrees else { return "—" }
        return String(format: "Δ %.1f°", angle)
    }

    private var audioModeSection: some View {
        Section {
            Picker("Control", selection: $model.mode) {
                ForEach(AudioControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(model.mode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Now", value: model.activeController.statusDescription)
                .font(.caption)
        } header: {
            Text("Audio control")
        } footer: {
            if model.didLoseBackgroundTracking {
                Label(
                    "Tracking stopped while the app was in the background. Reopen EarGuard and start a new session.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private var builtInPlayerSection: some View {
        Section("Audio source") {
            Button("Choose file…", systemImage: "folder") { isShowingImporter = true }

            HStack {
                TextField("or paste a stream URL", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Load") {
                    guard let url = URL(string: urlText) else { return }
                    model.builtInPlayer.load(url)
                }
                .disabled(URL(string: urlText) == nil || urlText.isEmpty)
            }

            Button(
                model.builtInPlayer.isPlaying ? "Pause" : "Play",
                systemImage: model.builtInPlayer.isPlaying ? "pause.fill" : "play.fill"
            ) {
                model.builtInPlayer.togglePlayPause()
            }
            .disabled(model.builtInPlayer.sourceURL == nil)
        }
    }

    private var thresholdSection: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text("Threshold")
                    Spacer()
                    Text("\(Int(model.thresholdDegrees))°")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.thresholdDegrees, in: 5...120, step: 1)
            }
        } footer: {
            Text("Deviation from the calibrated baseline that counts as taking the headphones off. Pause fires after 1.5 s above this line; resume after 0.5 s back below it.")
        }
    }

    private var logSection: some View {
        Section("Events") {
            if model.log.isEmpty {
                Text("No events yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(model.log.suffix(20).reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Text(entry.message)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var sessionButton: some View {
        Button {
            if model.isRunning { model.stopSession() } else { model.startSession() }
        } label: {
            Text(model.isRunning ? "Stop Session" : "Start Session")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(model.isRunning ? .red : .accentColor)
        .disabled(!model.isRunning && !model.availability.isReady)
        .padding()
        .background(.bar)
    }
}

#Preview {
    SessionView()
}
