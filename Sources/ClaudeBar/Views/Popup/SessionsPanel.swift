import SwiftUI

/// Popup sessions area: Claude Code cards + Cursor cards, both in a 2-column
/// grid with section headers and standby empty states.
struct SessionsPanelView: View {
    @EnvironmentObject var providerStore: ProviderStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sessionsSection
                HairlineDivider()
                cursorSessionsSection
                HairlineDivider()
                externalSessionsSection
            }
        }
    }

    /// Grid layout for session cards: two columns → a 2×N "four-grid".
    private var sessionGridColumns: [GridItem] {
        Theme.GridLayout.columns(.popupSession)
    }

    // MARK: Claude Code

    private var sessionsSection: some View {
        let alive = providerStore.aliveSessions
        let busyCount = providerStore.busySessionCount

        return VStack(alignment: .leading, spacing: Theme.Space.s4) {
            SectionHeader(
                icon: "rectangle.connected.to.line.below",
                title: "CLAUDE CODE",
                tint: Theme.claude,
                count: alive.count,
                activeCount: busyCount,
                activeSymbol: "B"
            )
            .padding(.horizontal, Theme.Space.s16)

            if alive.isEmpty {
                StandbyEmptyState(label: "no signals")
                    .padding(.horizontal, Theme.Space.s16).padding(.bottom, Theme.Space.s4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: Theme.Space.s4) {
                    ForEach(alive) { session in
                        SessionCardView(session: session, heartbeat: providerStore.heartbeats[session.pid]) {
                            resumeInTerminal(session)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s8).padding(.bottom, Theme.Space.s4)
            }
        }
        .padding(.vertical, Theme.Space.s6)
    }

    // MARK: Cursor

    private var cursorSessionsSection: some View {
        let alive = providerStore.aliveCursorSessions
        let activeCount = providerStore.activeCursorCount

        return VStack(alignment: .leading, spacing: Theme.Space.s4) {
            SectionHeader(
                icon: "cursorarrow.rays",
                title: "CURSOR",
                tint: Theme.cursor,
                count: alive.count,
                activeCount: activeCount,
                activeSymbol: "A"
            )
            .padding(.horizontal, Theme.Space.s16)

            if alive.isEmpty {
                StandbyEmptyState(label: "no cursor signals")
                    .padding(.horizontal, Theme.Space.s16).padding(.bottom, Theme.Space.s4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: Theme.Space.s4) {
                    ForEach(alive) { session in
                        CursorSessionCardView(session: session) { openInCursor(session) }
                    }
                }
                .padding(.horizontal, Theme.Space.s8).padding(.bottom, Theme.Space.s4)
            }
        }
        .padding(.vertical, Theme.Space.s6)
    }

    // MARK: External tools (Codex / WorkBuddy / OpenClaw)

    private var externalSessionsSection: some View {
        let alive = providerStore.aliveExternalSessions
        let activeCount = providerStore.activeExternalCount

        return VStack(alignment: .leading, spacing: Theme.Space.s4) {
            SectionHeader(
                icon: "rectangle.stack.person.crop",
                title: "CODEX · WORKBUDDY · OPENCLAW",
                tint: Theme.external,
                count: alive.count,
                activeCount: activeCount,
                activeSymbol: "A"
            )
            .padding(.horizontal, Theme.Space.s16)

            if alive.isEmpty {
                StandbyEmptyState(label: "no external signals")
                    .padding(.horizontal, Theme.Space.s16).padding(.bottom, Theme.Space.s4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: Theme.Space.s4) {
                    ForEach(alive) { session in
                        ExternalSessionCardView(session: session) { revealInFinder(session) }
                    }
                }
                .padding(.horizontal, Theme.Space.s8).padding(.bottom, Theme.Space.s4)
            }
        }
        .padding(.vertical, Theme.Space.s6)
    }

    // MARK: Actions

    /// Double-click a Claude Code session: open a terminal in the session's
    /// project directory and auto-run `claude --resume <sessionId>`.
    private func resumeInTerminal(_ session: SessionInfo) {
        TerminalLauncher.resumeClaudeSession(cwd: session.cwd, sessionId: session.sessionId)
    }

    /// Double-click a Cursor session: open the workspace folder in Cursor.app.
    private func openInCursor(_ session: CursorSessionInfo) {
        TerminalLauncher.openInCursor(cwd: session.cwd)
    }

    /// External sessions have no resume affordance — reveal the project.
    private func revealInFinder(_ session: ExternalSessionInfo) {
        guard !session.cwd.isEmpty,
              FileManager.default.fileExists(atPath: session.cwd) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }
}
