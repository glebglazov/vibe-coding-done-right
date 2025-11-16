//
//  AppContextProvider.swift
//  vcdr
//
//  Created by Claude Code
//

import Foundation
import ApplicationServices
import Cocoa

/// Provides context from the currently active application using macOS Accessibility APIs
@MainActor
class AppContextProvider {

    /// Captures all readable text content from the frontmost application
    /// - Returns: The extracted text content, or nil if unable to access
    static func captureActiveAppContext() async -> String? {
        // Get the frontmost application
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let pid = frontmostApp.processIdentifier as pid_t? else {
            return nil
        }

        let appName = frontmostApp.localizedName ?? "Unknown App"

        // Create AX element for the app
        let appElement = AXUIElementCreateApplication(pid)

        // Try to get focused window first
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        var extractedText = ""

        if windowResult == .success, let window = focusedWindow {
            // Extract text from focused window
            extractedText = extractAllText(from: window as! AXUIElement)
        } else {
            // Fallback: try to extract from the entire app
            extractedText = extractAllText(from: appElement)
        }

        // Clean up the text
        let cleanedText = cleanText(extractedText)

        if cleanedText.isEmpty {
            return nil
        }

        // Format with app name for context
        return "Context from \(appName):\n\n\(cleanedText)"
    }

    /// Recursively extracts all text content from an accessibility element
    private static func extractAllText(from element: AXUIElement, depth: Int = 0) -> String {
        // Prevent infinite recursion
        guard depth < 50 else { return "" }

        var text = ""

        // Try to get the role to optimize for certain element types
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleString = role as? String

        // For web content, prioritize AXWebArea
        if roleString == "AXWebArea" || roleString == "AXScrollArea" {
            // This is likely the main content area
            text += extractTextContent(from: element)
        } else {
            // Try to get text value
            text += extractTextContent(from: element)
        }

        // Get children and recurse
        var children: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &children
        )

        if childrenResult == .success, let childArray = children as? [AXUIElement] {
            for child in childArray {
                text += extractAllText(from: child, depth: depth + 1)
            }
        }

        return text
    }

    /// Extracts text content from a single element
    private static func extractTextContent(from element: AXUIElement) -> String {
        var text = ""

        // Try AXValue (main text content)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
            if let stringValue = value as? String, !stringValue.isEmpty {
                text += stringValue + "\n"
            }
        }

        // Try AXTitle (headings, labels, links)
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success {
            if let titleString = title as? String, !titleString.isEmpty {
                text += titleString + "\n"
            }
        }

        // Try AXDescription
        var description: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description) == .success {
            if let descString = description as? String, !descString.isEmpty {
                text += descString + "\n"
            }
        }

        return text
    }

    /// Cleans up extracted text by removing duplicates and excess whitespace
    private static func cleanText(_ text: String) -> String {
        // Split into lines
        let lines = text.components(separatedBy: .newlines)

        // Remove empty lines and trim whitespace
        var cleanedLines: [String] = []
        var seenLines = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            guard !trimmed.isEmpty else { continue }

            // Skip very short noise (single characters, unless they're meaningful)
            guard trimmed.count > 1 || trimmed.rangeOfCharacter(from: .letters) != nil else {
                continue
            }

            // Deduplicate consecutive identical lines
            if seenLines.contains(trimmed) {
                continue
            }

            cleanedLines.append(trimmed)
            seenLines.insert(trimmed)

            // Clear seen lines occasionally to allow some repetition
            if cleanedLines.count % 50 == 0 {
                seenLines.removeAll()
            }
        }

        return cleanedLines.joined(separator: "\n")
    }

    /// Checks if the app has accessibility permissions
    static func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Requests accessibility permissions with prompt
    static func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
