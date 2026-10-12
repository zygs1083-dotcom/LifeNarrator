import ApplicationServices
import CoreGraphics
import SwiftUI

public struct OnboardingView: View {
    @ObservedObject var store: AppStore
    @State private var step = 0
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    public init(store: AppStore) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(store.text("onboarding.title")).font(.largeTitle.bold())
            Text("\(step + 1) / 3").foregroundStyle(.secondary)
            Group {
                switch step {
                case 0:
                    Text(store.text("onboarding.model")).font(.title2)
                    Form { ProviderSettingsView(store: store) }.formStyle(.grouped)
                case 1:
                    Text(store.text("onboarding.accessibility")).font(.title2)
                    Text(store.text("onboarding.accessibility.hint"))
                    Button(store.text("onboarding.accessibility.request")) {
                        accessibilityGranted = AXIsProcessTrustedWithOptions([
                            "AXTrustedCheckOptionPrompt": true
                        ] as CFDictionary)
                    }
                    permissionStatus(accessibilityGranted)
                default:
                    Text(store.text("onboarding.screen")).font(.title2)
                    Text(store.text("onboarding.screen.hint"))
                    Button(store.text("onboarding.screen.request")) { screenGranted = CGRequestScreenCaptureAccess() }
                    permissionStatus(screenGranted)
                }
            }
            Spacer()
            HStack {
                if step > 0 { Button(store.text("back")) { step -= 1 } }
                Spacer()
                Button(store.text(step == 2 ? "finish" : "continue")) {
                    store.perform {
                        if step == 0 {
                            if store.settings.provider == .builtin, case .notDownloaded = store.downloader.state {
                                try store.downloader.start(source: .huggingFace)
                            }
                            if store.settings.provider == .openAICompatible {
                                _ = try store.settings.generationAPI.validatedURL()
                                guard !store.settings.generationAPI.model.isEmpty else { throw AppInputError.missingModel }
                            }
                        }
                        if step == 2 {
                            var settings = store.settings
                            settings.onboardingCompleted = true
                            try store.directory.saveSettings(settings)
                            store.settings = settings
                            store.closeOnboarding()
                        } else { step += 1 }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(32).frame(width: 620, height: 500)
        .onChange(of: store.settings.provider) { _, provider in
            if provider == .builtin, case .notDownloaded = store.downloader.state {
                store.perform { try store.downloader.start(source: .huggingFace) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            screenGranted = CGPreflightScreenCaptureAccess()
        }
        .alert(store.text("error"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(store.text("ok")) { store.error = nil }
        } message: { Text(verbatim: store.error ?? "") }
    }

    private func permissionStatus(_ granted: Bool) -> some View {
        Label(store.text(granted ? "permission.granted" : "permission.notGranted"),
              systemImage: granted ? "checkmark.circle" : "circle")
        .foregroundStyle(.secondary)
    }
}
