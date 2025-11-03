//
//  ResultsOverlay.swift
//  vcdr
//
//  Created by Gleb Glazov on 24/9/25.
//

import SwiftUI
import Combine
import AppKit

struct ResultsOverlay: View {
    let onStopAndPaste: () -> Void
    let onStopAndCopyToClipboard: () -> Void
    let onStopAndSendToTmux: () -> Void
    let onStopAndPreview: () -> Void
    let onCancel: () -> Void
    @ObservedObject var controller: MenuBarController
    let previousActiveApp: NSRunningApplication?

    @ObservedObject var modeManager = ModeManager.shared

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Capture Complete")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select mode and destination")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("X: Disabled • A: Assistant • C: Custom")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var hasCapturedText: Bool {
        !controller.capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var capturedTextView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.bubble")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("Captured Text:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
            }

            VStack(alignment: .leading) {
                ScrollView {
                    if hasCapturedText {
                        Text(controller.capturedText)
                            .font(.system(size: 11))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(4)
                    } else {
                        Text("No text captured")
                            .font(.system(size: 11))
                            .italic()
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
                .frame(minHeight: 60, maxHeight: 80)
            }
            .padding(8)
            .background(Color.white.opacity(0.8))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var modeSelectionView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                    .font(.caption)
                Text("AI Processing:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                // Disabled mode (X)
                if let disabledMode = modeManager.builtInModes.first(where: { $0.name == "Disabled" }) {
                    ModeButton(
                        mode: disabledMode,
                        isActive: modeManager.activeMode?.id == disabledMode.id,
                        onTap: {
                            modeManager.setMode(disabledMode)
                            let settings = AppSettings.shared
                            settings.activeModeName = disabledMode.name
                            settings.saveSettings()
                        }
                    )
                }

                // Assistant mode (A)
                if let assistantMode = modeManager.builtInModes.first(where: { $0.name == "Assistant" }) {
                    ModeButton(
                        mode: assistantMode,
                        isActive: modeManager.activeMode?.id == assistantMode.id,
                        onTap: {
                            modeManager.setMode(assistantMode)
                            let settings = AppSettings.shared
                            settings.activeModeName = assistantMode.name
                            settings.saveSettings()
                        }
                    )
                }

                // Custom mode slot (C)
                CustomModeSlot(
                    modeManager: modeManager,
                    currentCustomMode: modeManager.activeMode as? CustomMode ?? modeManager.lastUsedCustomMode ?? modeManager.customModes.first,
                    isActive: modeManager.activeMode is CustomMode
                )

                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.05))
        .cornerRadius(8)
    }

    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 20) {
            headerView

            capturedTextView

            modeSelectionView

            destinationButtonsView
        }
        .padding(24)
        .frame(width: 350)
        .background(.regularMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
        .onAppear {
            // Set up local event monitor for keyboard events
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Handle key events using keyCode (works across keyboard layouts)
                let keyCode = event.keyCode
                let hasCommand = event.modifierFlags.contains(.command)

                if keyCode == 53 { // Escape key
                    onCancel()
                    return nil // Event handled
                } else if keyCode == 7 && !hasCommand { // X key (Disabled mode)
                    controller.switchToDisabledMode()
                    return nil
                } else if keyCode == 0 && !hasCommand { // A key (Assistant mode)
                    controller.switchToAssistantMode()
                    return nil
                } else if keyCode == 8 && !hasCommand { // C key (Cycle custom modes)
                    controller.cycleCustomModes()
                    return nil
                } else if keyCode == 9 && hasCommand { // V key (Paste)
                    onStopAndPaste()
                    return nil
                } else if keyCode == 8 && hasCommand { // C key (Copy)
                    onStopAndCopyToClipboard()
                    return nil
                } else if keyCode == 17 && hasCommand { // T key (Tmux)
                    onStopAndSendToTmux()
                    return nil
                } else if keyCode == 35 && hasCommand { // P key (Preview)
                    onStopAndPreview()
                    return nil
                }

                return event // Let other events pass through
            }
        }
        .onDisappear {
            // Clean up event monitor
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }

    private var destinationButtonsView: some View {
        VStack(spacing: 12) {
            // Destination buttons
            VStack(spacing: 8) {
                Text("Send to:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    // Copy button
                    Button(action: onStopAndCopyToClipboard) {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                            Text("Copy")
                            Spacer()
                            Text("⌘C")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Paste button
                    Button(action: onStopAndPaste) {
                        HStack {
                            Image(systemName: "doc.on.clipboard.fill")
                            Text("Paste")
                            Spacer()
                            Text("⌘V")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                HStack(spacing: 8) {
                    // Tmux button
                    Button(action: onStopAndSendToTmux) {
                        HStack {
                            Image(systemName: "terminal.fill")
                            Text("Tmux")
                            Spacer()
                            Text("⌘T")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Preview button
                    Button(action: onStopAndPreview) {
                        HStack {
                            Image(systemName: "eye.fill")
                            Text("Preview")
                            Spacer()
                            Text("⌘P")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                HStack(spacing: 8) {
                    // Cancel button
                    Button(action: onCancel) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Cancel")
                            Spacer()
                            Text("ESC")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Helper Views

struct ModeButton: View {
    let mode: any Mode
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(mode.name)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isActive ? Color.purple : Color.gray.opacity(0.2)
                )
                .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CustomModeSlot: View {
    @ObservedObject var modeManager: ModeManager
    let currentCustomMode: CustomMode?
    let isActive: Bool

    var body: some View {
        Button(action: {
            // Cycle through custom modes when clicked
            modeManager.cycleCustomMode()
            if let activeMode = modeManager.activeMode {
                let settings = AppSettings.shared
                settings.activeModeName = activeMode.name
                settings.saveSettings()
            }
        }) {
            Text(currentCustomMode?.name ?? "No Custom")
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive ? .white : (currentCustomMode == nil ? .secondary : .primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isActive ? Color.purple : Color.gray.opacity(0.2)
                )
                .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(modeManager.customModes.isEmpty)
    }
}

#Preview {
    ResultsOverlay(
        onStopAndPaste: { },
        onStopAndCopyToClipboard: { },
        onStopAndSendToTmux: { },
        onStopAndPreview: { },
        onCancel: { },
        controller: MenuBarController(),
        previousActiveApp: nil
    )
}
