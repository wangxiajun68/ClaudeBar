import SwiftUI

/// The 清理 confirmation for a stalled Codex session, shared by the sessions
/// page and the popup.
///
/// Cleanup is a Codex-wide action (thread delete plus its forks), so it is
/// described once instead of in every tile; the surface only owns *which*
/// session was asked for and what confirming does. Both surfaces used to carry
/// a byte-identical copy of this dialog, which is how a wording fix on one
/// would have missed the other.
private struct CodexCleanupDialog: ViewModifier {
    @Binding var pending: ExternalSessionInfo?
    let onConfirm: (ExternalSessionInfo) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(pending.map { "清理「\($0.displayName)」？" } ?? "清理卡住的会话",
                                isPresented: Binding(
                                    get: { pending != nil },
                                    set: { if !$0 { pending = nil } }
                                ),
                                titleVisibility: .visible) {
                Button("清理", role: .destructive) {
                    if let session = pending { onConfirm(session) }
                    pending = nil
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个会话的回合已经停止推进（多半是卡在审批上或写到一半就退出了）。\n"
                     + "会先在 Codex 里删掉它的续写分支，再删除它本身；Codex 若拒绝删除，则改为归档。")
            }
    }
}

extension View {
    /// One dialog per surface, driven by whichever card asked. `pending` is the
    /// page's own state; `onConfirm` is the store call it runs on 清理.
    func codexCleanupDialog(pending: Binding<ExternalSessionInfo?>,
                            onConfirm: @escaping (ExternalSessionInfo) -> Void) -> some View {
        modifier(CodexCleanupDialog(pending: pending, onConfirm: onConfirm))
    }
}
