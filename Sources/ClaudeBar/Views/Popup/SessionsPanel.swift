import SwiftUI

/// Popup sessions: one full-width column so project / activity text can
/// breathe. Empty tool families are omitted instead of occupying a blank row.
struct SessionsPanelView: View {
    @EnvironmentObject var providerStore: ProviderStore

    var body: some View {
        let claude = providerStore.aliveSessions
        let cursor = providerStore.aliveCursorSessions
        let externalKinds = ExternalAgentKind.allCases.filter {
            !providerStore.externalSessionTree(kind: $0).isEmpty
        }
        let empty = claude.isEmpty && cursor.isEmpty && externalKinds.isEmpty

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                if empty {
                    StandbyEmptyState(label: "暂无会话")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    if !claude.isEmpty {
                        section(title: "Claude Code", icon: "rectangle.connected.to.line.below",
                                tint: Theme.claude, ink: Theme.Ink.claude) {
                            ForEach(claude) { session in
                                SessionCardView(session: session, heartbeat: providerStore.heartbeats[session.pid]) {
                                    resumeInTerminal(session)
                                }
                            }
                        }
                    }
                    if !cursor.isEmpty {
                        section(title: "Cursor", icon: "cursorarrow.rays",
                                tint: Theme.cursor, ink: Theme.Ink.cursor) {
                            ForEach(cursor) { session in
                                CursorSessionCardView(session: session) { openInCursor(session) }
                            }
                        }
                    }
                    ForEach(externalKinds, id: \.self) { kind in
                        externalBlock(kind: kind)
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.vertical, 7)
    }

    private func section<Content: View>(title: String, icon: String, tint: Color,
                                        ink: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
                .padding(.horizontal, 10)
        } header: {
            SectionHeader(icon: icon, title: title, tint: tint, ink: ink)
                .padding(.horizontal, 10)
        }
    }

    private func externalBlock(kind: ExternalAgentKind) -> some View {
        let tree = providerStore.externalSessionTree(kind: kind)
        return section(title: kind.displayName, icon: kind.icon,
                       tint: Theme.external, ink: Theme.Ink.success) {
            ForEach(tree) { node in
                ExternalSessionCardView(session: node.session,
                                        descendantCount: node.descendantCount,
                                        childAgents: node.children.flatMap(\.flattened).map(\.session)) {
                    resumeCodex(node.session)
                }
            }
        }
    }

    private func resumeInTerminal(_ session: SessionInfo) {
        TerminalLauncher.resumeClaudeSession(cwd: session.cwd, sessionId: session.sessionId)
    }

    private func openInCursor(_ session: CursorSessionInfo) {
        TerminalLauncher.openInCursor(cwd: session.cwd)
    }

    private func resumeCodex(_ session: ExternalSessionInfo) {
        TerminalLauncher.resumeCodexSession(cwd: session.cwd, sessionId: session.sessionId)
    }
}
