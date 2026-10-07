import Foundation

/// Which transcript books a Claude `message.id`.
///
/// `message.id` is unique per *conversation*, not per file. When a session is
/// resumed into a fresh transcript — `--resume`, a fork, a workflow agent that
/// inherits its parent's context — Claude Code copies the parent's assistant
/// records verbatim into the new file: same id, same `message.uuid`, same
/// usage, in two live transcripts. Measured on this machine: 417 ids appear in
/// more than one transcript and 103M tokens were booked twice, all on the two
/// days the forks ran. `UsageIndex.parseClaude`'s per-file last-wins dedupe
/// exists for the partial→final rewrite of a *single* stream and cannot see
/// across files, so both copies used to be booked.
///
/// One owner per id: the first transcript to be indexed. A later transcript
/// that prints the same id books nothing — a Claude file's rollup is replaced
/// in full on every parse, so dropping the entry is all it takes. An owner
/// that no longer prints an id gives it back.
///
/// The ledger is append-only JSONL beside the other usage logs, so nothing
/// here is load-bearing for money: a lost, unreadable or half-written file
/// only means the next parse finds no owner and claims the id, which is the
/// behaviour before this existed. A line with an empty `owner` is a tombstone
/// that frees an id.
///
/// Reclaim lag: when a transcript is deleted its ids are freed at the top of
/// the next pass, but the copy that still prints them is only re-parsed when
/// it next changes (mtime/size) or when a rebuild re-parses the corpus. Until
/// then those tokens are missing rather than doubled. Deleting a transcript
/// while a resumed copy of it lives on is the one shape that reaches this, and
/// it is the shape the previous code got *wrong in the other direction*: the
/// duplicate stayed booked twice.
enum UsageClaims {
    struct Claim: Codable {
        var id: String
        var owner: String
    }

    /// id → owner, plus the owner index that makes "what does this file book?"
    /// a lookup rather than a scan of every id in the corpus.
    private static var ledger: [String: String] = [:]
    private static var owners: [String: Set<String>] = [:]
    private static var loaded = false

    /// `UsageIndex`'s SQLite path holds its own lock across a whole pass, and
    /// this ledger is read/reclaimed from more than one call site inside it
    /// (`begin` at the top, `flush` at the end, `owned(by:)` during the walk),
    /// so it needs one of its own.
    private static let lock = NSLock()

    /// Written by the next `flush()`.
    private static var appended: [Claim] = []
    private static var tombstones: [String] = []
    private static var lines = 0

    /// Forget the in-memory state so the next pass re-reads the file. Called
    /// from `UsageIndex.reloadPersistence` (the regression harness's reset
    /// between scenarios) and from the claims-ledger phase of the same suite.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        ledger = [:]
        owners = [:]
        loaded = false
        appended = []
        tombstones = []
        lines = 0
    }

    /// Seed a pass: read the file once, then hand every claim whose owner is
    /// not one of this pass's candidate transcripts back to the pool. That is
    /// what lets a surviving copy take the ids of a transcript that vanished.
    ///
    /// Iterates the owners, not the ids: with nothing gone the whole step is a
    /// filter over the corpus's file count, and only a vanished owner's ids
    /// are walked at all.
    static func begin(owners live: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        guard owners.keys.contains(where: { !live.contains($0) }) else { return }
        for (owner, ids) in owners where !live.contains(owner) {
            for id in ids {
                ledger.removeValue(forKey: id)
                tombstones.append(id)
            }
        }
        owners = owners.filter { live.contains($0.key) }
    }

    static func owner(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return ledger[id]
    }

    /// The ids `owner` books right now — the set a re-parse diffs against, so
    /// an id the file no longer prints stops being owned.
    static func owned(by owner: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return owners[owner] ?? []
    }

    /// Book `id` for `owner`. Appends a ledger line only when the owner
    /// actually changes, so a steady corpus does not grow the file per pass.
    static func record(_ id: String, owner: String) {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        guard ledger[id] != owner else { return }
        if let previous = ledger[id] { owners[previous]?.remove(id) }
        ledger[id] = owner
        owners[owner, default: []].insert(id)
        appended.append(Claim(id: id, owner: owner))
    }

    static func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        guard let owner = ledger.removeValue(forKey: id) else { return }
        owners[owner]?.remove(id)
        tombstones.append(id)
    }

    /// Append this pass's changes. Rewrites the file in full once the dead
    /// lines outnumber the live ones, so a long-lived corpus does not grow
    /// without bound.
    static func flush() {
        lock.lock(); defer { lock.unlock() }
        flushLocked()
    }

    private static func flushLocked() {
        guard !appended.isEmpty || !tombstones.isEmpty else { return }
        let fresh = appended, dead = tombstones
        appended = []; tombstones = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func encode(_ claims: [Claim], _ freed: [String]) -> String {
            var body = ""
            for claim in claims {
                guard let data = try? encoder.encode(claim),
                      let line = String(data: data, encoding: .utf8) else { continue }
                body += line + "\n"
            }
            for id in freed {
                guard let data = try? encoder.encode(Claim(id: id, owner: "")),
                      let line = String(data: data, encoding: .utf8) else { continue }
                body += line + "\n"
            }
            return body
        }

        let additions = encode(fresh, dead)
        guard !additions.isEmpty else { return }
        // Compact when the *dead* lines outnumber the live ones. Written the
        // other way round (`lines * 2 > ledger.count + 4096`) this fires for
        // every ledger above ~4,096 live ids — a tombstone-free corpus has
        // lines ≈ count, so 2·lines beats count + 4096 on every flush and each
        // pass rewrote the whole file instead of appending the few lines that
        // changed.
        if lines > ledger.count * 2 + 4096 {
            let compacted = encode(ledger.keys.sorted().map { Claim(id: $0, owner: ledger[$0]!) }, [])
            if (try? Data(compacted.utf8).write(to: FilePaths.usageClaimsJSONL, options: .atomic)) != nil {
                lines = ledger.count
                return
            }
            // The rewrite failed — fall through to appending this pass's
            // additions rather than returning with them dropped. `lines` is
            // advanced only by a write that verified.
        }
        guard let handle = try? FileHandle(forWritingTo: FilePaths.usageClaimsJSONL) else {
            // First write: create the file. A failure here costs nothing — the
            // next parse finds no owner and claims the id, which is exactly
            // the pre-ledger behaviour rather than a new double booking.
            // `lines` counts lines *on disk*, so it is advanced only by a
            // write that actually landed — advancing it after a failed write
            // would make the compaction test believe a shorter file exists.
            if (try? Data(additions.utf8).write(to: FilePaths.usageClaimsJSONL, options: .atomic)) != nil {
                lines = fresh.count + dead.count
            }
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        do {
            try handle.write(contentsOf: Data(additions.utf8))
            lines += fresh.count + dead.count
        } catch {
            // Left for the next flush; the claims are also still in memory
            // (`ledger`), so a re-parse reproduces them.
        }
    }

    private static func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: FilePaths.usageClaimsJSONL) else { return }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            lines += 1
            guard let claim = fastClaim(line) ?? (try? decoder.decode(Claim.self, from: Data(line))) else { continue }
            guard !claim.owner.isEmpty else {
                if let previous = ledger.removeValue(forKey: claim.id) {
                    owners[previous]?.remove(claim.id)
                }
                continue
            }
            // Later lines win, so a re-claim under a new owner moves the id.
            if let previous = ledger[claim.id] { owners[previous]?.remove(claim.id) }
            ledger[claim.id] = claim.owner
            owners[claim.owner, default: []].insert(claim.id)
        }
    }

    /// Fast path for exactly the line shape `flushLocked` writes: an object
    /// whose first key is `id` and second is `owner` (`.sortedKeys`), with
    /// Foundation's `\/` escaping of path separators and nothing else.
    /// Returns nil for any other shape — different key order, whitespace, a
    /// `\"` or `\uXXXX` escape, invalid UTF-8, a missing brace — and the
    /// caller re-decodes with `JSONDecoder`, so this can only ever be a faster
    /// route to the same answer, never a different one.
    ///
    /// This load is once per process (`loaded` above; only the regression
    /// harness resets it), but it grows with the corpus's lifetime: measured
    /// here, the ledger is 37 MB / 178,883 lines, and the full load takes
    /// 558–584 ms old vs 362–376 ms with this path (five runs each, old path
    /// reconstructed beside the new one), all of it under the claims lock on
    /// the index pass. `usage-index-regressions.py` diffs the two routes line
    /// by line on generated and adversarial ledgers.
    private static func fastClaim(_ line: Data) -> Claim? {
        let length = line.count
        // `{"id":"x","owner":""}` is the shortest line this shape can be.
        guard length >= 20 else { return nil }
        return line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Claim? in
            let byte = raw.bindMemory(to: UInt8.self)
            // `{"id":"`
            let idHead: [UInt8] = [0x7B, 0x22, 0x69, 0x64, 0x22, 0x3A, 0x22]
            guard !(idHead.indices.contains { byte[$0] != idHead[$0] }) else { return nil }
            var i = idHead.count
            let idStart = i
            while i < length, byte[i] != 0x22 {
                if byte[i] == 0x5C { return nil }   // any escape in an id → untrusted
                i += 1
            }
            guard i > idStart, i < length else { return nil }
            let idBytes = byte[idStart..<i]
            i += 1
            // `,"owner":"`
            let ownerHead: [UInt8] = [0x2C, 0x22, 0x6F, 0x77, 0x6E, 0x65, 0x72, 0x22, 0x3A, 0x22]
            guard i + ownerHead.count <= length,
                  !(ownerHead.indices.contains { byte[i + $0] != ownerHead[$0] }) else { return nil }
            i += ownerHead.count
            let ownerStart = i
            while i < length, byte[i] != 0x22 {
                // `\/` is the only escape Foundation writes for a path; every
                // other one (a literal quote, \uXXXX, a control character)
                // hands the line to the decoder.
                if byte[i] == 0x5C, !(i + 1 < length && byte[i + 1] == 0x2F) { return nil }
                i += 1
            }
            // The line ends `"}` — anything longer or shorter is not this shape.
            guard i + 2 == length, byte[i + 1] == 0x7D else { return nil }
            guard let id = String(bytes: idBytes, encoding: .utf8) else { return nil }
            let ownerBytes = byte[ownerStart..<i]
            var owner: [UInt8] = []
            owner.reserveCapacity(ownerBytes.count)
            for b in ownerBytes {
                // Only `\/` can still be present, and only its backslash goes.
                if b == 0x5C { continue }
                owner.append(b)
            }
            guard let owner = String(bytes: owner, encoding: .utf8) else { return nil }
            return Claim(id: id, owner: owner)
        }
    }
}
