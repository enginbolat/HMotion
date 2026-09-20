import SwiftUI

/// The popover shown when the menu bar icon is clicked.
struct ControlPanelView: View {
    @Bindable var controller: HeadTrackingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            readout
            AngleChartView(
                samples: controller.samples,
                thresholdDegrees: controller.thresholdDegrees,
                window: HeadTrackingController.chartWindow,
                showsThreshold: controller.isAutoPauseEnabled
            )
            .frame(height: 70)
            Divider()
            autoPauseControls
            Divider()
            eventLog
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Label("HMotion", systemImage: controller.statusSymbolName)
                .font(.headline)
            Spacer()
            Button(controller.isRunning ? "Stop Session" : "Start Session") {
                if controller.isRunning {
                    controller.stopSession()
                } else {
                    controller.startSession()
                }
            }
            .disabled(!controller.isRunning && !controller.availability.isReady)
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(angleText)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isRunning {
                Button("Recalibrate", systemImage: "scope") {
                    controller.recalibrate()
                }
                .labelStyle(.iconOnly)
                .help("Capture a new baseline from the current head position")
            }
        }
    }

    private var angleText: String {
        guard let angle = controller.angleDegrees else { return "—" }
        return String(format: "Δ %.1f°", angle)
    }

    @ViewBuilder
    private var autoPauseControls: some View {
        Toggle("Auto-pause when removed", isOn: $controller.isAutoPauseEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Threshold")
                Spacer()
                Text("\(Int(controller.thresholdDegrees))°")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Slider(value: $controller.thresholdDegrees, in: 5...120, step: 1)
                .controlSize(.small)
        }
        .disabled(!controller.isAutoPauseEnabled)
        .opacity(controller.isAutoPauseEnabled ? 1 : 0.5)
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Events")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.log.suffix(20).reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            Text(entry.message)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 84)
        }
    }

    private var footer: some View {
        HStack {
            if !controller.availability.isReady {
                Text(controller.availability.description)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if controller.isAutoPauseEnabled && !MediaRemote.isPrivateFrameworkAvailable {
                Text("MediaRemote unavailable — falling back to the media key")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

// MARK: - Presentation helpers

extension HeadTrackingController {
    /// Menu bar glyph, so the current state is readable without opening the panel.
    var statusSymbolName: String {
        guard availability.isReady else { return "exclamationmark.triangle" }
        guard isRunning else { return "headphones" }
        switch phase {
        case .calibrating: return "circle.dotted"
        case .monitoring: return "headphones.circle.fill"
        case .pendingPause: return "exclamationmark.circle.fill"
        case .paused, .recovering: return "pause.circle.fill"
        }
    }

    var statusText: String {
        guard availability.isReady else { return availability.description }
        guard isRunning else { return "Idle" }
        switch phase {
        case .calibrating: return "Calibrating — hold still"
        case .monitoring: return isAutoPauseEnabled ? "Monitoring" : "Logging only"
        case .pendingPause: return "Above threshold — waiting to pause"
        case .paused: return "Paused"
        case .recovering: return "Back in place — waiting to resume"
        }
    }
}
