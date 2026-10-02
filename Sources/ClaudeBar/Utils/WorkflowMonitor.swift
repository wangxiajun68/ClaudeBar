import Foundation

/// Native workflow journals carry agent lifecycle; the parent transcript carries
/// the run's launch and terminal notification. Neither tool activity nor an
/// empty running-agent set proves that the script has finished.
enum WorkflowStatus: String {
    case unknown, running, paused, completed, failed, cancelled

    var label: String {
        switch self {
        case .unknown: return "状态未知"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    static func parse(_ raw: String) -> Self {
        switch raw {
        case "async_launched", "running": return .running
        case "paused": return .paused
        case "completed": return .completed
        case "failed": return .failed
        case "cancelled", "stopped": return .cancelled
        default: return .unknown
        }
    }
}

final class WorkflowMonitor: @unchecked Sendable {
    static let shared = WorkflowMonitor()
    private let lock = NSLock()
    private var cache: [String: Records] = [:]
    private static let activityWindow: TimeInterval = 90

    private struct Run {
        var name: String
        var taskID: String
        var status: WorkflowStatus
        var total: Int? = nil
        var done: Int? = nil
        var errors: Int? = nil
    }

    private struct Agent {
        var phase: String
        var done: Bool
        var order: Int
    }

    private struct Records {
        var offset: UInt64 = 0
        var modified: Date = .distantPast
        var inode: UInt64 = 0
        var partial = Data()
        var droppingLine = false
        var runs: [String: Run] = [:]
        var taskRuns: [String: String] = [:]
        var agents: [String: Agent] = [:]
        var sequence = 0
    }

    func enrich(_ workflows: [WorkflowInfo], transcript: URL, directory: URL,
                sessionAlive: Bool, now: Date = Date()) -> [WorkflowInfo] {
        lock.lock()
        defer { lock.unlock() }
        let parent = read(transcript)
        var byID = Dictionary(uniqueKeysWithValues: workflows.map { ($0.workflowId, $0) })
        for id in parent.runs.keys where byID[id] == nil {
            // Never follow paths supplied by transcript content.
            byID[id] = WorkflowInfo(workflowId: id)
        }
        return byID.values.map { original in
            var workflow = original
            let run = parent.runs[workflow.workflowId]
            workflow.name = run?.name ?? ""
            // Only native directory names may be used to construct a path.
            let validID = workflow.workflowId.range(of: #"^wf_[a-zA-Z0-9-]+$"#,
                                                    options: .regularExpression) != nil
            let journal = validID
                ? read(directory.appendingPathComponent(workflow.workflowId).appendingPathComponent("journal.jsonl"))
                : Records()
            let pending = journal.agents.filter { !$0.value.done }
            workflow.phase = pending.values.max(by: { $0.order < $1.order })?.phase
                ?? journal.agents.values.max(by: { $0.order < $1.order })?.phase ?? ""
            workflow.totalCount = max(workflow.agents.count, journal.agents.count, run?.total ?? 0)
            workflow.completedCount = run?.done ?? journal.agents.values.filter(\.done).count
            workflow.failedCount = run?.errors ?? 0
            let newestAgent = pending.keys.compactMap { id -> Date? in
                guard validID, id.range(of: #"^agent-[a-zA-Z0-9_-]+$"#,
                                                  options: .regularExpression) != nil else { return nil }
                let file = directory.appendingPathComponent(workflow.workflowId)
                    .appendingPathComponent("\(id).jsonl")
                return try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max() ?? .distantPast
            let recent = now.timeIntervalSince(max(journal.modified, newestAgent)) <= Self.activityWindow
            workflow.status = run?.status ?? .unknown
            if workflow.status == .running, !sessionAlive || !recent {
                workflow.status = .unknown
            } else if workflow.status == .unknown, sessionAlive, recent, !pending.isEmpty {
                workflow.status = .running
            }
            // Journal start/result events cover model inference too; a tool
            // result only says the tool returned, not that the agent ended.
            workflow.runningCount = workflow.status == .running ? pending.count : 0
            for index in workflow.agents.indices {
                let id = workflow.agents[index].agentId
                if journal.agents[id]?.done == true {
                    workflow.agents[index].status = .done
                } else if workflow.status == .running, pending[id] != nil {
                    workflow.agents[index].status = .running
                } else {
                    workflow.agents[index].status = .unknown
                }
            }
            return workflow
        }.sorted {
            if ($0.status == .running) != ($1.status == .running) { return $0.status == .running }
            return $0.workflowId < $1.workflowId
        }
    }

    /// Incremental, newline-delimited reads. Cache only lifecycle fields, never
    /// prompts/results. Bound both the cache and an incomplete/corrupt line.
    private func read(_ url: URL) -> Records {
        let key = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: key),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url) else {
            cache.removeValue(forKey: key)
            return Records()
        }
        defer { try? handle.close() }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var records = cache[key] ?? Records()
        if inode != records.inode || size < records.offset
            || (size == records.offset && modified != records.modified) {
            records = Records()
        }
        if size == records.offset, modified == records.modified { return records }
        do {
            try handle.seek(toOffset: records.offset)
            var remaining = size - records.offset
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(65_536, remaining))), !chunk.isEmpty else { break }
                remaining -= UInt64(chunk.count)
                records.offset += UInt64(chunk.count)
                for byte in chunk {
                    if byte == 10 {
                        if !records.droppingLine,
                           let json = try? JSONSerialization.jsonObject(with: records.partial) as? [String: Any] {
                            apply(json, to: &records)
                        }
                        records.partial.removeAll(keepingCapacity: true)
                        records.droppingLine = false
                    } else if !records.droppingLine {
                        if records.partial.count < 4_000_000 { records.partial.append(byte) }
                        else { records.partial.removeAll(keepingCapacity: false); records.droppingLine = true }
                    }
                }
            }
        } catch { return Records() }
        records.modified = modified
        records.inode = inode
        if cache.count >= 64, cache[key] == nil { cache.removeAll(keepingCapacity: true) }
        cache[key] = records
        return records
    }

    private func apply(_ json: [String: Any], to records: inout Records) {
        if let type = json["type"] as? String, type == "started" || type == "result",
           let rawID = json["agentId"] as? String {
            let id = rawID.hasPrefix("agent-") ? rawID : "agent-" + rawID
            records.sequence += 1
            let phase = json["phase"] as? String ?? records.agents[id]?.phase ?? ""
            records.agents[id] = Agent(phase: phase, done: type == "result", order: records.sequence)
        }
        guard let result = json["toolUseResult"] as? [String: Any] else {
            applyNotification(json, to: &records)
            return
        }
        if let id = result["runId"] as? String, let taskID = result["taskId"] as? String {
            records.runs[id] = Run(name: result["workflowName"] as? String ?? "", taskID: taskID,
                                   status: WorkflowStatus.parse(result["status"] as? String ?? ""))
            records.taskRuns[taskID] = id
        } else if let task = result["task"] as? [String: Any],
                  let taskID = task["id"] as? String, let id = records.taskRuns[taskID],
                  records.runs[id]?.taskID == taskID {
            records.runs[id]?.status = WorkflowStatus.parse(task["status"] as? String ?? "")
        }
    }

    /// Terminal records only. A quoted `<task-id>` in an ordinary message, and
    /// the same XML sitting in a `queue-operation` before it is delivered, are
    /// not status events. Claude Code 2.1.287 delivers the record as an
    /// `attachment` whose `origin` lives under `attachment`, with the XML in
    /// `prompt` rather than `message.content`.
    private func applyNotification(_ json: [String: Any], to records: inout Records) {
        for text in notificationTexts(json) {
            guard let taskID = tag("task-id", in: text), let id = records.taskRuns[taskID],
                  records.runs[id]?.taskID == taskID, let status = tag("status", in: text) else { continue }
            records.runs[id]?.status = WorkflowStatus.parse(status)
            records.runs[id]?.total = tag("agent_count", in: text).flatMap(Int.init)
            records.runs[id]?.done = tag("agents_done", in: text).flatMap(Int.init)
            records.runs[id]?.errors = tag("agents_error", in: text).flatMap(Int.init)
        }
    }

    private func notificationTexts(_ json: [String: Any]) -> [String] {
        var texts: [String] = []
        if (json["origin"] as? [String: Any])?["kind"] as? String == "task-notification",
           let message = json["message"] as? [String: Any] {
            texts.append(contentsOf: contentTexts(message["content"]))
        }
        if let attachment = json["attachment"] as? [String: Any],
           (attachment["origin"] as? [String: Any])?["kind"] as? String == "task-notification" {
            texts.append(contentsOf: contentTexts(attachment["prompt"]))
        }
        return texts
    }

    private func contentTexts(_ content: Any?) -> [String] {
        if let content = content as? String { return [content] }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    private func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
