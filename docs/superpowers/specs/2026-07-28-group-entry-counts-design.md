# Group Entry Counts — Design

**Status:** Approved
**Date:** 2026-07-28
**Repo:** mypass (MyPass, macOS SwiftUI password manager, KDBX4-backed)

## Context

Sidebar smart categories already show trailing entry counts via `SmartCategorySidebarRow` (`.font(.caption)`, `.foregroundStyle(.secondary)`). Group rows in `GroupSidebarView` show only emoji/folder icon and name. The user wants the same per-group password counts on every group row in the sidebar.

## Goals

- Show the direct entry count on each sidebar group row (root group and flattened subgroups).
- Match `SmartCategorySidebarRow` trailing count style (`.caption`, `.secondary`).
- Empty groups show `0`.
- Count is `group.entries.count` only — not a recursive subtree total.

## Non-goals

- Recycle Bin row count (the Deleted smart category already covers the bin).
- Group picker or menu bar entry counts.
- Recursive subtree totals.
- Shared count component refactor.
- New unit tests (display of an existing `Int`).

## Design

### Change: `GroupSidebarView.groupRow`

Update the row layout to an `HStack` with:

1. Emoji or folder icon (unchanged).
2. Group name (unchanged).
3. `Spacer(minLength: 0)`.
4. `Text("\(group.entries.count)")` with `.font(.caption)` and `.foregroundStyle(.secondary)`.

This applies to:

- The root group row.
- Each row in `flattenedGroups`.

The Recycle Bin section is unchanged (no count badge).

Counts update live via existing `KdbxGroup` reference reactivity — no new observation layer.

## Manual verification

- An empty group shows `0`.
- Adding, moving, or deleting an entry updates the affected group’s count without restarting the app.
- The Recycle Bin row has no count badge.
