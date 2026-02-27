# Swipe-to-Delete Transcription History Entries

## Overview

Add the ability to delete individual transcription history entries via swipe-left gesture (showing a "Delete" button) and via right-click context menu.

## Current State Analysis

- `TranscriptionHistory` (`vcdr/History/TranscriptionHistory.swift`) has `addRecord(_:)` and `clearAll()` but no single-record deletion method.
- `HistoryTabView` (`vcdr/UI/HistoryTabView.swift:15`) uses `List(history.records) { record in ... }` shorthand, which doesn't allow attaching `ForEach` modifiers like `.swipeActions`.
- The existing context menu (line 103) only has "Copy" actions, no "Delete".

### Key Discoveries:
- `ModesTabView.swift:13-43` already implements swipe-to-delete using `ForEach` + `.onDelete` + context menu pattern — we'll follow the same approach.
- `TranscriptionHistory.save()` handles atomic disk writes, so deleting a record and calling `save()` is safe.

## Desired End State

- Users can swipe left on any history row to reveal a red "Delete" button.
- Users can right-click any history row and select "Delete" from the context menu.
- Deleting a record removes it from memory and persists the change to disk immediately.

### Verification:
- Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`
- Manual: Swipe left on a history entry → red "Delete" button appears → clicking it removes the entry.
- Manual: Right-click a history entry → "Delete" option appears → clicking it removes the entry.
- Manual: After deleting, quit and relaunch → deleted entry stays gone (persisted).

## What We're NOT Doing

- No confirmation dialog for single-entry deletion (swipe-delete is already intentional enough).
- No multi-select deletion.
- No undo support.

## Implementation Approach

Single phase — two files, minimal changes.

## Phase 1: Add Single-Record Deletion

### Changes Required:

#### 1. TranscriptionHistory — add `removeRecord(_:)`
**File**: `vcdr/History/TranscriptionHistory.swift`
**Changes**: Add a method to remove a single record by identity, then persist.

```swift
func removeRecord(_ record: TranscriptionRecord) {
    records.removeAll { $0.id == record.id }
    save()
}
```

Place this between `addRecord(_:)` (line 26) and `clearAll()` (line 28).

#### 2. HistoryTabView — add swipe action and context menu delete
**File**: `vcdr/UI/HistoryTabView.swift`
**Changes**:

Replace the `List(history.records)` shorthand (line 15-17) with explicit `ForEach` inside `List` to enable per-row modifiers:

```swift
List {
    ForEach(history.records) { record in
        HistoryRowView(record: record)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("Delete", role: .destructive) {
                    history.removeRecord(record)
                }
            }
    }
}
```

Add a "Delete" option to the existing `.contextMenu` on `HistoryRowView` (after the copy actions, line 111):

```swift
Divider()

Button("Delete", role: .destructive) {
    onDelete()
}
```

Since `HistoryRowView` is a private struct that doesn't have access to `history`, add an `onDelete` closure parameter:

```swift
private struct HistoryRowView: View {
    let record: TranscriptionRecord
    let onDelete: () -> Void
    // ...
}
```

Update the call site to pass the closure:

```swift
HistoryRowView(record: record, onDelete: { history.removeRecord(record) })
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `xcodebuild -scheme vcdr -destination 'platform=macOS' build`

#### Manual Verification:
- [ ] Swipe left on a history entry reveals a red "Delete" button
- [ ] Clicking "Delete" removes the entry from the list
- [ ] Right-click on a history entry shows "Delete" in the context menu
- [ ] Clicking "Delete" in context menu removes the entry
- [ ] After deleting, quit and relaunch — deleted entry does not reappear
- [ ] "Clear All" toolbar button still works as before
