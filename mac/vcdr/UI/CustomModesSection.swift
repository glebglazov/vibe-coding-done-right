//
//  CustomModesSection.swift
//  vcdr
//
//  Custom modes management section for Settings
//

import SwiftUI

struct CustomModesSection: View {
    @ObservedObject var modeManager = ModeManager.shared
    @State private var showingEditor = false
    @State private var editingMode: CustomMode?
    @State private var showingDeleteConfirmation = false
    @State private var modeToDelete: CustomMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Custom Modes")
                    .font(.headline)

                Spacer()

                Button(action: {
                    editingMode = nil
                    showingEditor = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("New Mode")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.blue)
            }

            if modeManager.customModes.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("No Custom Modes Yet")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    Text("Create custom modes to define your own AI behaviors")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // List of custom modes
                VStack(spacing: 8) {
                    ForEach(modeManager.customModes, id: \.id) { mode in
                        CustomModeRow(
                            mode: mode,
                            onEdit: {
                                editingMode = mode
                                showingEditor = true
                            },
                            onDelete: {
                                modeToDelete = mode
                                showingDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showingEditor) {
            CustomModeEditorView(editingMode: editingMode) {
                // Refresh after save
                showingEditor = false
            }
        }
        .alert("Delete Custom Mode?", isPresented: $showingDeleteConfirmation, presenting: modeToDelete) { mode in
            Button("Cancel", role: .cancel) {
                modeToDelete = nil
            }
            Button("Delete", role: .destructive) {
                modeManager.deleteCustomMode(mode)
                modeToDelete = nil
            }
        } message: { mode in
            Text("Are you sure you want to delete '\(mode.name)'? This action cannot be undone.")
        }
    }
}

struct CustomModeRow: View {
    let mode: CustomMode
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Mode icon
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16))
                .foregroundColor(.purple)
                .frame(width: 24)

            // Mode info
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(mode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Action buttons (visible on hover)
            if isHovered {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Edit mode")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Delete mode")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.blue.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

#Preview {
    CustomModesSection()
}
