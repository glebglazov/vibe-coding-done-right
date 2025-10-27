//
//  CustomModeEditorView.swift
//  vcdr
//
//  Custom mode editor for creating and editing AI processing modes
//

import SwiftUI

struct CustomModeEditorView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var modeManager = ModeManager.shared

    let editingMode: CustomMode?
    let onSave: () -> Void

    @State private var modeName: String
    @State private var modeDescription: String
    @State private var systemPrompt: String
    @State private var showingError = false
    @State private var errorMessage = ""

    init(editingMode: CustomMode? = nil, onSave: @escaping () -> Void) {
        self.editingMode = editingMode
        self.onSave = onSave

        // Initialize with existing mode data or empty
        _modeName = State(initialValue: editingMode?.name ?? "")
        _modeDescription = State(initialValue: editingMode?.description ?? "")
        _systemPrompt = State(initialValue: editingMode?.systemPrompt ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editingMode == nil ? "Create Custom Mode" : "Edit Custom Mode")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Define how AI should process your voice input")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Mode Name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mode Name")
                            .font(.headline)

                        TextField("e.g., Code Reviewer", text: $modeName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Text("A short, descriptive name for your mode")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Mode Description
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)

                        TextField("e.g., Reviews code and suggests improvements", text: $modeDescription)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Text("Brief explanation of what this mode does")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // System Prompt
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Prompt")
                            .font(.headline)

                        TextEditor(text: $systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 200)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Instructions for the AI model. Be specific about:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("• The role the AI should play")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• How it should transform or respond to input")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Output format and style")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Any constraints or guidelines")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 8)
                    }

                    // Example
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                            Text("Example System Prompt")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }

                        Text("""
                        You are a code reviewer. Analyze the user's code and provide constructive feedback.

                        Guidelines:
                        - Point out potential bugs or issues
                        - Suggest improvements for readability
                        - Recommend best practices
                        - Keep feedback concise and actionable
                        - Use a friendly, helpful tone

                        Output your review as a bulleted list.
                        """)
                        .font(.caption)
                        .padding(12)
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(editingMode == nil ? "Create Mode" : "Save Changes") {
                    saveMode()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(modeName.isEmpty || modeDescription.isEmpty || systemPrompt.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 600, height: 700)
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func saveMode() {
        // Validate input
        guard !modeName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a mode name"
            showingError = true
            return
        }

        guard !modeDescription.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a description"
            showingError = true
            return
        }

        guard !systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a system prompt"
            showingError = true
            return
        }

        // Create or update mode
        if let existingMode = editingMode {
            // Update existing mode
            let updatedMode = CustomMode(
                id: existingMode.id,
                name: modeName.trimmingCharacters(in: .whitespaces),
                description: modeDescription.trimmingCharacters(in: .whitespaces),
                systemPrompt: systemPrompt.trimmingCharacters(in: .whitespaces)
            )
            modeManager.updateCustomMode(updatedMode)
        } else {
            // Create new mode
            let newMode = CustomMode(
                name: modeName.trimmingCharacters(in: .whitespaces),
                description: modeDescription.trimmingCharacters(in: .whitespaces),
                systemPrompt: systemPrompt.trimmingCharacters(in: .whitespaces)
            )
            modeManager.addCustomMode(newMode)
        }

        onSave()
        dismiss()
    }
}

#Preview {
    CustomModeEditorView(onSave: {})
}
