import AppKit
import SwiftUI

/// Search mode (⌘K): a large search field over a list of every meeting, active and archived,
/// each previewing where the query matched. ↑/↓ or ⌃N/⌃P move the selection, Return opens it,
/// Escape clears the query and then leaves search mode.
struct MeetingSearchView: View {
    let search: SidebarSearchModel
    /// Every meeting, newest first.
    let sessions: [MeetingSession]
    /// Bumped by ⌘K so pressing it again refocuses (and selects) the field.
    let focusRequest: Int
    /// False while the title-bar pill is still morphing into the field; the field and results fade in after.
    let isRevealed: Bool
    let fieldAnchor: LiquidAnchor
    /// Called once the field has its frame, so the pill can morph into it.
    let onFieldLaidOut: () -> Void
    let actions: (MeetingSession) -> MeetingItemActions
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool
    /// A shared object, not `@State` values: the key monitor's closure outlives this view value,
    /// and writes through a stale copy's state never reached the list.
    @State private var selection = SearchSelection()
    @State private var keyMonitor = SearchKeyMonitor()
    @State private var didReportLayout = false

    private static let recentLimit = 8

    private var results: [MeetingSession] {
        search.isSearching ? sessions.filter(search.matches) : Array(sessions.filter { !$0.isArchivedValue }.prefix(Self.recentLimit))
    }

    var body: some View {
        let results = results

        VStack(alignment: .leading, spacing: 0) {
            searchField(results: results)
                .background(LiquidAnchorView(anchor: fieldAnchor))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                    guard !didReportLayout else { return }
                    didReportLayout = true
                    // After this layout pass lands in AppKit, so the anchor has its frame
                    // and the field is in the window and can take focus.
                    DispatchQueue.main.async {
                        isFieldFocused = true
                        onFieldLaidOut()
                    }
                }
                .padding(.bottom, 22)

            resultsSection(results: results)
                .opacity(isRevealed ? 1 : 0)
                .offset(y: isRevealed ? 0 : -6)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .appPanelBackground(AppTheme.bgPrimary)
        // Focus set while the view is still being inserted is dropped, so it's also set once
        // the field is laid out (above) and again when the morph reveals it.
        .task { isFieldFocused = true }
        .onChange(of: isRevealed) { _, revealed in
            if revealed { isFieldFocused = true }
        }
        .onAppear {
            let selection = selection
            keyMonitor.start(moveSelection: { selection.move(by: $0) }, escape: handleEscape)
        }
        .onDisappear { keyMonitor.stop() }
        .onChange(of: focusRequest) { _, _ in isFieldFocused = true }
        // Keep the selection on the first result as the results change.
        .onChange(of: results.map(\.id), initial: true) { _, ids in
            selection.resultIDs = ids
            if selection.selectedID.map({ !ids.contains($0) }) ?? true {
                selection.selectedID = ids.first
            }
        }
        .onChange(of: search.needle) { _, _ in
            selection.selectedID = results.first?.id
        }
    }

    private func resultsSection(results: [MeetingSession]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AppSectionHeader(title: header(count: results.count))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if results.isEmpty {
                MeetingActivityEmptyState(
                    systemImage: "magnifyingglass",
                    title: search.isSearching ? "No matches" : "No meetings yet",
                    message: search.isSearching
                        ? "Try a different search term."
                        : "Start a meeting to capture transcripts and summaries."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(results) { session in
                                SearchResultRowView(
                                    session: session,
                                    query: search.needle,
                                    isSelected: session.id == selection.selectedID,
                                    actions: actions(session)
                                )
                                .id(session.id)
                            }
                        }
                        .padding(.bottom, 32)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: selection.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    /// The morph hands over to this field: its background appears at once (the same color
    /// and shape as the morph), and its contents fade in.
    private func searchField(results: [MeetingSession]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)

            TextField("Search meetings, transcripts and summaries", text: Bindable(search).text)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .foregroundStyle(AppTheme.textPrimary)
                .focused($isFieldFocused)
                .onSubmit { open(results: results) }

            if !search.text.isEmpty {
                Button {
                    search.text = ""
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            Text("esc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
                .help(search.text.isEmpty ? "Close search" : "Clear search")
        }
        .padding(.horizontal, 18)
        .opacity(isRevealed ? 1 : 0)
        .frame(height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: SearchMorphDriver.fieldCorner, style: .continuous)
                .stroke(isFieldFocused ? AppTheme.focusRing : AppTheme.border, lineWidth: 1)
                .opacity(isRevealed ? 1 : 0)
        )
        .background(
            RoundedRectangle(cornerRadius: SearchMorphDriver.fieldCorner, style: .continuous)
                .fill(AppTheme.bgInput)
                .opacity(isRevealed ? 1 : 0)
                .transaction { $0.animation = nil }
        )
        .contentShape(Rectangle())
        .onTapGesture { isFieldFocused = true }
    }

    private func header(count: Int) -> String {
        guard search.isSearching else { return "Recent meetings" }
        return count == 1 ? "1 meeting" : "\(count) meetings"
    }

    /// Esc clears the query; with nothing typed it leaves search mode.
    private func handleEscape() {
        if search.text.isEmpty {
            onClose()
        } else {
            search.text = ""
            isFieldFocused = true
        }
    }

    private func open(results: [MeetingSession]) {
        guard let session = results.first(where: { $0.id == selection.selectedID }) ?? results.first else { return }
        actions(session).onOpen()
    }
}

/// The highlighted search result, moved by the arrow keys and ⌃N/⌃P.
@MainActor
@Observable
private final class SearchSelection {
    var selectedID: UUID?
    var resultIDs: [UUID] = []

    func move(by offset: Int) {
        guard !resultIDs.isEmpty else { return }
        let current = resultIDs.firstIndex { $0 == selectedID } ?? -1
        let next = min(max(current + offset, 0), resultIDs.count - 1)
        selectedID = resultIDs[next]
    }
}

/// Catches ↑/↓, ⌃N/⌃P and Esc in the main window before the search field's editor does, which would
/// otherwise move the caret (⌃N/⌃P are its Emacs bindings) or open word completion (Esc).
@MainActor
private final class SearchKeyMonitor {
    private var monitor: Any?

    func start(moveSelection: @escaping (Int) -> Void, escape: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard MainWindowController.shared.isMainWindow(event.window) else { return event }
            // Leave keys alone while an input method is composing text.
            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event
            }
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                escape()
                return nil
            }
            guard let offset = Self.offset(for: event) else { return event }
            moveSelection(offset)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static func offset(for event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 125 where modifiers.isEmpty: return 1   // ↓
        case 126 where modifiers.isEmpty: return -1  // ↑
        default: break
        }
        guard modifiers == .control else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "n": return 1
        case "p": return -1
        default: return nil
        }
    }
}

