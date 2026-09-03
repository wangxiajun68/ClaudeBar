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
            }        }
    }

    /// Grid layout for session cards: two columns → a 2×N "four-grid".
    private var sessionGridColumns: [GridItem] {
        Theme.GridLayout.columns(.popupSession)
    }

    // MARK: Claude Code

    private var sessionsSection: some View {
        let alive = providerStore.aliveSessions

        return VStack(alignment: .leading, spacing: Theme.Space.s4) {
            SectionHeader(
                icon: "rectangle.connected.to.line.below",
                title: "Claude Code",
                tint: Theme.claude
            )
            .padding(.horizontal, Theme.Space.s16)

            if alive.isEmpty {
                StandbyEmptyState(label: "暂无会话")
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

        return VStack(alignment: .leading, spacing: Theme.Space.s4) {
            SectionHeader(
                icon: "cursorarrow.rays",
                title: "Cursor",
                tint: Theme.cursor
            )
            .padding(.horizontal, Theme.Space.s16)

            if alive.isEmpty {
                StandbyEmptyState(label: "暂无 Cursor 会话")
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

    // MARK: External tools — one header per tool

    private var externalSessionsSection: some View {
        ForEach(ExternalAgentKind.allCases, id: \.self) { kind in
            externalSessionsSection(kind: kind)
        }
    }

    private func externalSessionsSection(kind: ExternalAgentKind) -> some View {
        let alive = providerStore.externalSessions.filter { $0.kind == kind && $0.isAlive }

        return VStack(alignment: .leading, spacing: Theme.Space.s4) {
            SectionHeader(
                icon: kind.icon,
                title: kind.displayName,
                tint: Theme.external
            )
            .padding(.horizontal, Theme.Space.s16)

            if alive.isEmpty {
                StandbyEmptyState(label: "暂无 \(kind.displayName) 会话")
                    .padding(.horizontal, Theme.Space.s16).padding(.bottom, Theme.Space.s4)
            } else {
                LazyVGrid(columns: sessionGridColumns, spacing: Theme.Space.s4) {
                    ForEach(alive) { session in
                        ExternalSessionCardView(session: session) { resumeCodex(session) }
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

    /// Double-click a Codex session: open it in Codex Desktop or resume in the CLI.
    private func resumeCodex(_ session: ExternalSessionInfo) {
        TerminalLauncher.resumeCodexSession(cwd: session.cwd, sessionId: session.sessionId)
    }
}
