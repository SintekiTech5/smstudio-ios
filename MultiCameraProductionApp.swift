import SwiftUI

@main
struct MultiCameraProductionApp: App {
    var body: some Scene {
        WindowGroup {
            ProductionLauncherView()
        }
    }
}

private struct ProductionLauncherView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Spacer()
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .accessibilityLabel("Multi-Camera Live Production logo")
                Text("Multi-Camera Live Production")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Choose the role for this device.")
                    .foregroundColor(.secondary)
                NavigationLink(destination: IOSHubRoleView()) {
                    Label("Master Production Hub", systemImage: "rectangle.3.group")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                NavigationLink(destination: RemoteCameraNodeView()) {
                    Label("Remote Camera Node", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}

private struct IOSHubRoleView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 144, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityLabel("Multi-Camera Live Production logo")
            Text("Master Production Hub")
                .font(.title2.bold())
            Text("The live switcher, SRT listener, OpenGL compositor, and dual RTMP publisher run on the Android Hub. Use this iPhone as a Remote Camera Node and connect it to the Hub over local Wi-Fi.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            NavigationLink(destination: RemoteCameraNodeView()) {
                Text("Use this iPhone as a Camera Node")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .navigationTitle("Production Hub")
    }
}

private struct RemoteCameraNodeView: View {
    @StateObject private var model = RemoteCameraNodeViewModel()
    @State private var pairingCode = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "video.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.accentColor)
                Text(model.stateText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                TextField("Six-digit Master pairing code", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pairingCode) { value in
                        pairingCode = String(value.filter(\.isNumber).prefix(6))
                    }
                if let error = model.errorText {
                    Text(error)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
                Button(model.isActive ? "Stop Camera Node" : "Start Camera Node") {
                    model.toggle(pairingCode: pairingCode)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isActive ? .red : .accentColor)
                .disabled(!model.isActive && pairingCode.count != 6)

                GroupBox("Video effects") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Automatic low-light enhancement", isOn: $model.effects.automaticLowLight)
                        effectSlider("Brightness", value: $model.effects.brightness, range: -1...1)
                        effectSlider("Contrast", value: $model.effects.contrast, range: 0...2)
                        effectSlider("Highlights", value: $model.effects.highlights, range: -1...1)
                        effectSlider("Shadows", value: $model.effects.shadows, range: -1...1)
                        effectSlider("Whites", value: $model.effects.whites, range: -1...1)
                        effectSlider("Blacks", value: $model.effects.blacks, range: -1...1)
                        effectSlider("Temperature", value: $model.effects.temperature, range: -1...1)
                        effectSlider("Tint", value: $model.effects.tint, range: -1...1)
                        effectSlider("Saturation", value: $model.effects.saturation, range: -1...1)
                        effectSlider("Vibrance", value: $model.effects.vibrance, range: -1...1)
                        effectSlider("Film grain", value: $model.effects.filmGrain, range: 0...1)
                        effectSlider("Chromatic aberration", value: $model.effects.chromaticAberration, range: 0...0.02)
                        effectSlider("Vignette", value: $model.effects.vignette, range: 0...1)
                        Toggle("Monochrome", isOn: $model.effects.monochrome)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Remote Camera Node")
        .onDisappear { model.stop() }
        .onChange(of: model.effects) { _ in model.applyEffects() }
    }

    private func effectSlider(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        let sliderRange = Double(range.lowerBound)...Double(range.upperBound)
        let sliderValue = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Float($0) }
        )
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: sliderValue, in: sliderRange)
        }
    }
}

private final class RemoteCameraNodeViewModel: NSObject, ObservableObject {
    @Published private(set) var stateText = "Stopped"
    @Published private(set) var errorText: String?
    @Published private(set) var isActive = false
    @Published var effects = RemoteCameraEffectsSettings()
    private var node: RemoteCameraNode?

    func toggle(pairingCode: String) {
        if isActive {
            stop()
            return
        }
        let cameraNode = RemoteCameraNode()
        cameraNode.delegate = self
        cameraNode.updateEffects(effects)
        node = cameraNode
        isActive = true
        errorText = nil
        stateText = "Starting camera and searching for the Master Hub"
        cameraNode.start(pairingCode: pairingCode)
    }

    func stop() {
        guard let node else { return }
        self.node = nil
        node.stop()
        isActive = false
        stateText = "Stopped"
    }

    func applyEffects() {
        node?.updateEffects(effects)
    }
}

extension RemoteCameraNodeViewModel: RemoteCameraNodeDelegate {
    func remoteCameraNode(_ node: RemoteCameraNode, didChangeState state: RemoteCameraNode.State) {
        stateText = String(describing: state).capitalized
        if state == .stopped {
            isActive = false
        }
    }

    func remoteCameraNode(_ node: RemoteCameraNode, didFail error: Error) {
        errorText = error.localizedDescription
    }
}
