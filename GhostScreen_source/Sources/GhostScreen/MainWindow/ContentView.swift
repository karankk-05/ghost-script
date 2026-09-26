import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var state

    let appDelegate: AppDelegate

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 14) {
            if !state.isBundled {
                Label("Running unbundled (`swift run`) — no stable permission identity, no Dock drops. Use `make run`.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            GroupBox("Notes file") {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(state.notesURL?.lastPathComponent ?? "No file open — drop a .md here")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Open…") { appDelegate.documents.openPanel() }
                }
                .padding(4)
            }

            GroupBox("Notes overlay") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show overlay  (⌘⇧N)", isOn: $state.overlayVisible)
                    HStack {
                        Text("Opacity")
                        Slider(value: $state.overlayOpacity, in: 0.25...1.0)
                    }
                    Text("The overlay is invisible to screen sharing, recordings and screenshots — only you can see it. Move it with ⌘-drag (or the grip strip at its top); select text to copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            if state.restoreOfferPairCount > 0, state.mirrorStatus == .off {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("A previous session changed your display arrangement and didn't restore it.",
                              systemImage: "display.trianglebadge.exclamationmark")
                            .font(.caption)
                        HStack {
                            Button("Restore mirroring") { appDelegate.acceptRestoreOffer() }
                            Button("Keep as is") { appDelegate.dismissRestoreOffer() }
                        }
                    }
                    .padding(4)
                }
            }

            GroupBox("Displays") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.topology.displays) { display in
                        HStack(spacing: 8) {
                            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                                .foregroundStyle(.secondary)
                            Text(display.name)
                            if display.isMirrorSecondary {
                                Text("mirroring")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.orange.opacity(0.3), in: Capsule())
                            }
                            if !display.isActive {
                                Text("inactive")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.secondary.opacity(0.3), in: Capsule())
                            }
                            Spacer()
                            Text(verbatim: "\(display.pixelWidth)×\(display.pixelHeight)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if state.topology.externals.count > 1 {
                        Picker("Beamer target", selection: $state.selectedExternalUUID) {
                            ForEach(state.topology.externals.filter { $0.uuid != nil }) { display in
                                Text(display.name).tag(display.uuid)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .padding(4)
            }

            GroupBox("Beamer mirror") {
                VStack(alignment: .leading, spacing: 8) {
                    if state.topology.isMirroring, state.mirrorStatus == .off {
                        Label("macOS mirroring is on — your notes are visible on the external display right now. Start Mirror replaces it with a notes-free mirror.",
                              systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    switch state.mirrorStatus {
                    case .off:
                        HStack {
                            Button("Start Mirror") {
                                Task { await appDelegate.mirrorController.start() }
                            }
                            .disabled(state.topology.externals.isEmpty)
                            if state.topology.externals.isEmpty {
                                Text("Connect an external display first.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .starting(let phase):
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(phase).font(.caption)
                        }
                    case .active(let fps):
                        HStack(spacing: 8) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(verbatim: String(format: "Mirroring — %.0f fps", fps))
                            if state.mirrorDegraded {
                                Text("no frames — stalled?")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Stop") {
                                Task { await appDelegate.mirrorController.stop() }
                            }
                        }
                    case .suspended(let message):
                        VStack(alignment: .leading, spacing: 6) {
                            Label(message, systemImage: "cable.connector.slash")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Stop Mirror") {
                                Task { await appDelegate.mirrorController.stop() }
                            }
                        }
                    case .stoppedBySystem(let message):
                        VStack(alignment: .leading, spacing: 6) {
                            Label(message, systemImage: "pause.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            HStack {
                                Button("Resume Mirror") {
                                    Task { await appDelegate.mirrorController.resumeCapture() }
                                }
                                Button("Stop") {
                                    Task { await appDelegate.mirrorController.stop() }
                                }
                            }
                        }
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 6) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Try Again") {
                                Task { await appDelegate.mirrorController.start() }
                            }
                        }
                    }

                    if state.permissionState == .denied {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Screen Recording permission needed", systemImage: "lock.shield")
                                    .font(.caption)
                                Button("Request") { appDelegate.capturePermission.request() }
                                    .controlSize(.small)
                                Button("Open Settings") { appDelegate.capturePermission.openSystemSettings() }
                                    .controlSize(.small)
                            }
                            Text("After granting, relaunch GhostScreen.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Native-resolution capture (sharper, more bandwidth)",
                           isOn: $state.nativeSourceCapture)
                        .font(.caption)

                    Text("Mirrors your built-in display to the beamer — without the notes overlay. Start the mirror before putting your presentation in fullscreen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            if let error = state.fileError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = state.mirrorError {
                Label(error, systemImage: "display.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        let delegate = appDelegate
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            Task { @MainActor in
                delegate.documents.open(url: url)
            }
        }
        return true
    }
}
