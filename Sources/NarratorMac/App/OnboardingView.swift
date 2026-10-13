import ApplicationServices
import CoreGraphics
import SwiftUI

public struct OnboardingView: View {
    @ObservedObject var store: AppStore
    @State private var step = 0
    @State private var goingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    public init(store: AppStore) { self.store = store }

    init(store: AppStore, step: Int) {
        self.store = store
        _step = State(initialValue: step)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: "text.bubble.fill").font(.system(size: 28))
                    .foregroundStyle(AppTheme.accent).frame(width: 56, height: 56)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(AppTheme.accent)
                    }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.text("onboarding.title")).font(AppTheme.font(.hero))
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            Capsule().fill(step == index ? AppTheme.accent : AppTheme.cardStroke)
                                .frame(width: step == index ? 20 : 6, height: 6)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(format: store.text("onboarding.step"), step + 1))
                }
            }
            Group {
                switch step {
                case 0:
                    Text(store.text("onboarding.model")).font(AppTheme.font(.pageTitle))
                    GroupBox { ProviderSettingsView(store: store) } label: { EmptyView() }
                case 1:
                    Text(store.text("onboarding.accessibility")).font(AppTheme.font(.pageTitle))
                    Text(store.text("onboarding.accessibility.hint"))
                    Button(store.text("onboarding.accessibility.request")) {
                        accessibilityGranted = AXIsProcessTrustedWithOptions([
                            "AXTrustedCheckOptionPrompt": true
                        ] as CFDictionary)
                    }
                    .buttonStyle(AppTheme.CapsuleButton())
                    permissionStatus(accessibilityGranted)
                default:
                    Text(store.text("onboarding.screen")).font(AppTheme.font(.pageTitle))
                    Text(store.text("onboarding.screen.hint"))
                    Button(store.text("onboarding.screen.request")) { screenGranted = CGRequestScreenCaptureAccess() }
                        .buttonStyle(AppTheme.CapsuleButton())
                    permissionStatus(screenGranted)
                }
            }
            .id(step)
            .transition(stepTransition)
            Spacer()
            HStack {
                if step > 0 {
                    Button(store.text("back")) {
                        goingForward = false
                        withAnimation(stepAnimation) { step -= 1 }
                    }.buttonStyle(AppTheme.CapsuleButton(filled: false))
                }
                Spacer()
                Button(store.text(step == 2 ? "finish" : "continue")) {
                    goingForward = true
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
                        } else { withAnimation(stepAnimation) { step += 1 } }
                    }
                }.buttonStyle(AppTheme.CapsuleButton()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).padding(.top, 20).frame(width: 620, height: 500)
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .groupBoxStyle(.card).toggleStyle(.switch).tint(AppTheme.accent)
        .background(AppTheme.windowBackground).ignoresSafeArea()
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

    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.25)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity))
    }

    private func permissionStatus(_ granted: Bool) -> some View {
        let hue = AppTheme.hue(granted ? 150 : 42)
        return Label(store.text(granted ? "permission.granted" : "permission.notGranted"),
              systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
            .font(AppTheme.font(.badge)).foregroundStyle(hue.text)
            .padding(.horizontal, 8).padding(.vertical, 3).background(hue.soft, in: Capsule())
    }
}
