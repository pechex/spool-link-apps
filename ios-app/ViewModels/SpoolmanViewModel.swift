// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-PackageHomePage: https://github.com/paxx12-snapmaker-u1/spool-link-apps
// SPDX-FileCopyrightText: Copyright (c) 2026 @paxx12

import Foundation
import SwiftUI

@Observable
class SpoolmanViewModel: NFCManagerDelegate {
    var isScanning = false
    var statusMessage = "Ready to scan"
    var scanHistory: [ScanResult] = []
    var lastResult: ScanResult?
    var spools: [SpoolResponse] = []
    var isFetchingSpools = false
    var spoolsErrorMessage: String?
    var hasMoreSpools = false
    var pendingAssignSpool: SpoolResponse?
    /// Outcome of the most recent tag assignment, shown where it was started.
    var lastAssignmentResult: ScanResult?
    /// Set when an assignment would take a tag from another spool; the UI must confirm or decline it.
    var pendingTagMove: PendingTagMove?
    /// An assignment error to present as an alert.
    var assignmentError: TagAssignmentError?
    var isCreatingSpool = false
    var availableFilaments: [SpoolmanAPI.FilamentResponse] = []
    var isLoadingFilaments = false
    var filamentsErrorMessage: String?
    var isMovingTags = false
    var tagMoveLogs: [String] = []
    private var spoolsOffset = 0
    // Large enough to load every spool at once so sort, grouping, search, and filter see the whole collection;
    // "Load More" only appears beyond this.
    private let spoolsPageSize = 1000
    private var lastSpoolsFetch: Date?
    private var spoolsLoadTask: Task<Void, Never>?
    // Bumped whenever `spools` is changed outside a full load, so an in-flight load knows its response is stale.
    private var spoolsGeneration = 0

    private let api: SpoolmanAPI
    let nfcManager: NFCManager

    init(baseURL: String = "http://spoolman.local:7912") {
        self.api = SpoolmanAPI(baseURL: baseURL)
        self.nfcManager = NFCManager()
        self.nfcManager.delegate = self
    }

    func updateBaseURL(_ url: String) {
        Task { @MainActor in
            await api.updateBaseURL(url)
            spoolsGeneration += 1
            spools = []
            spoolsOffset = 0
            hasMoreSpools = false
            spoolsErrorMessage = nil
            lastSpoolsFetch = nil
        }
    }

    private var tagStore: TagStore { TagStore.current }

    @MainActor
    func moveTagsToSelectedStore() async {
        guard !isMovingTags else { return }
        isMovingTags = true
        tagMoveLogs = []
        do {
            tagMoveLogs = try await api.migrateTags(to: tagStore)
        } catch {
            tagMoveLogs = ["✗ \(error.localizedDescription)"]
        }
        isMovingTags = false
        fetchSpools(reset: true)
    }

    // MARK: - Spool list

    @MainActor
    func ensureSpoolsLoaded() {
        guard spools.isEmpty && !isFetchingSpools else { return }
        fetchSpools()
    }

    @MainActor
    func fetchSpools(reset: Bool = true) {
        Task { await loadSpools(reset: reset) }
    }

    /// Reloads unless the last successful load is recent; called on every appearance, so this avoids refetching
    /// the whole collection on each tab switch.
    @MainActor
    func refreshSpoolsIfStale(maxAge: TimeInterval = 15) {
        if let last = lastSpoolsFetch, Date().timeIntervalSince(last) < maxAge { return }
        fetchSpools(reset: true)
    }

    /// Loads spools, or waits for the load already in progress.
    @MainActor
    func loadSpools(reset: Bool = true) async {
        if let inFlight = spoolsLoadTask {
            await inFlight.value
            return
        }
        let task = Task { await performSpoolsLoad(reset: reset) }
        spoolsLoadTask = task
        await task.value
        spoolsLoadTask = nil
    }

    @MainActor
    private func performSpoolsLoad(reset: Bool) async {
        isFetchingSpools = true
        defer { isFetchingSpools = false }
        // Retry if `spools` changed mid-fetch (tag assigned, server switched); applying the older response would undo it.
        for _ in 0..<3 {
            let generation = spoolsGeneration
            let offset = reset ? 0 : spoolsOffset
            do {
                let page = try await api.fetchSpools(limit: spoolsPageSize, offset: offset)
                guard generation == spoolsGeneration else { continue }
                let active = page.filter { !$0.archived }
                if reset {
                    spools = active
                } else {
                    spools += active
                }
                spoolsOffset = offset + page.count
                hasMoreSpools = page.count == spoolsPageSize
                spoolsErrorMessage = nil
                lastSpoolsFetch = Date()
                return
            } catch {
                guard generation == spoolsGeneration else { continue }
                spoolsErrorMessage = error.localizedDescription
                if spools.isEmpty { hasMoreSpools = false }
                return
            }
        }
    }

    @MainActor
    func loadMoreSpools() {
        guard hasMoreSpools && !isFetchingSpools else { return }
        fetchSpools(reset: false)
    }

    @MainActor
    @discardableResult
    func refreshSpool(id: Int) async -> SpoolResponse? {
        guard let updated = try? await api.getSpool(id: id) else { return nil }
        spoolsGeneration += 1
        if let idx = spools.firstIndex(where: { $0.id == id }) {
            spools[idx] = updated
        }
        for i in scanHistory.indices where scanHistory[i].spoolId == id {
            scanHistory[i] = scanHistory[i].withSpoolResponse(updated)
        }
        if lastResult?.spoolId == id {
            lastResult = lastResult?.withSpoolResponse(updated)
        }
        return updated
    }

    // MARK: - Tag removal

    @MainActor
    func removeAllTags(from spool: SpoolResponse) async {
        try? await api.unlinkAllTags(from: spool, store: tagStore)
        await refreshSpool(id: spool.id)
        if let result = lastResult, result.spoolId == spool.id {
            lastResult = ScanResult(
                id: result.id, timestamp: result.timestamp,
                spoolId: nil, spoolName: result.spoolName,
                cardUid: result.cardUid, success: result.success,
                message: result.message, tagPayload: result.tagPayload,
                spoolResponse: nil
            )
            statusMessage = "Tag unlinked from \(spool.displayName)"
        }
    }

    @MainActor
    func removeTag(uidHex: String, from spool: SpoolResponse) async {
        let freshSpool = (try? await api.getSpool(id: spool.id)) ?? spool
        try? await api.unlinkTag(from: freshSpool, uid: uidHex, store: tagStore)
        await refreshSpool(id: spool.id)
        if let result = lastResult, result.spoolId == spool.id {
            lastResult = ScanResult(
                id: result.id, timestamp: result.timestamp,
                spoolId: nil, spoolName: result.spoolName,
                cardUid: result.cardUid, success: result.success,
                message: result.message, tagPayload: result.tagPayload,
                spoolResponse: nil
            )
            statusMessage = "Tag unlinked from \(spool.displayName)"
        }
    }

    // MARK: - Filament list

    @MainActor
    func loadFilamentsIfNeeded() {
        guard availableFilaments.isEmpty && !isLoadingFilaments else { return }
        loadFilaments()
    }

    @MainActor
    func loadFilaments() {
        guard !isLoadingFilaments else { return }
        isLoadingFilaments = true
        filamentsErrorMessage = nil
        Task {
            do {
                availableFilaments = try await api.fetchFilaments(limit: 1000, offset: 0)
            } catch {
                filamentsErrorMessage = error.localizedDescription
            }
            isLoadingFilaments = false
        }
    }

    // MARK: - Spool creation

    @MainActor
    @discardableResult
    func createSpoolFromTag(tagPayload: (any NFCTagPayload)? = nil, uidHex: String = "",
                            overrideMeta: FilamentMetadata? = nil,
                            selectedFilamentId: Int? = nil) async -> SpoolResponse? {
        isCreatingSpool = true
        statusMessage = "Creating spool…"
        defer { isCreatingSpool = false }
        do {
            try await api.requireTagStoreSupport(store: tagStore)
            let newSpool: SpoolResponse
            if let meta = overrideMeta ?? tagPayload?.filamentMetadata {
                let styleRaw = UserDefaults.standard.string(forKey: "filamentNameStyle") ?? ""
                let nameStyle = FilamentNameStyle(rawValue: styleRaw) ?? .brandAndSubtype
                let vendorId: Int?
                if let brand = meta.brand {
                    vendorId = try await api.findOrCreateVendor(name: brand)
                } else {
                    vendorId = nil
                }
                let filamentId: Int
                if let selectedFilamentId {
                    filamentId = selectedFilamentId
                } else {
                    filamentId = try await api.createFilamentFromInfo(
                        name: meta.filamentName(style: nameStyle),
                        vendorId: vendorId,
                        material: meta.material,
                        colorHex: meta.colorHex,
                        diameter: meta.diameter ?? 1.75,
                        weight: meta.weight,
                        nozzleTemp: meta.nozzleTemp,
                        bedTemp: meta.bedTemp,
                        variant: meta.subtype
                    )
                }
                newSpool = try await api.createSpoolFromInfo(
                    filamentId: filamentId,
                    cardUid: uidHex.isEmpty ? nil : uidHex,
                    store: tagStore
                )
            } else {
                statusMessage = "Missing filament details"
                return nil
            }
            statusMessage = "Spool created: \(newSpool.displayName)"
            if let idx = scanHistory.firstIndex(where: { $0.cardUid == uidHex }) {
                let old = scanHistory[idx]
                scanHistory[idx] = ScanResult(
                    id: old.id, timestamp: old.timestamp,
                    spoolId: newSpool.id, spoolName: newSpool.displayName,
                    cardUid: uidHex, success: true, message: "Spool created",
                    tagPayload: old.tagPayload, spoolResponse: newSpool
                )
                lastResult = scanHistory[idx]
            }
            fetchSpools(reset: true)
            return newSpool
        } catch {
            statusMessage = "Error creating spool: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - NFC delegate

    func startScanning() {
        lastResult = nil
        nfcManager.startScanning()
        isScanning = nfcManager.isScanning
        statusMessage = nfcManager.sessionMessage
    }

    func stopScanning() {
        nfcManager.stopScanning()
        isScanning = false
        statusMessage = nfcManager.sessionMessage
    }

    func startTagAssignment(for spool: SpoolResponse) {
        lastResult = nil
    func startTagAssignment(for spool: SpoolResponse) {
        lastResult = nil
        lastAssignmentResult = nil
        // Leaving pendingAssignSpool set without a session would keep the Assign button spinning forever.
        guard nfcManager.startScanning() else {
            statusMessage = nfcManager.sessionMessage
            return
        }
        pendingAssignSpool = spool
        isScanning = true
        statusMessage = "Scan tag to assign to \(spool.displayName)…"
    }

    func cancelTagAssignment() {
        pendingAssignSpool = nil
        nfcManager.stopScanning()
        isScanning = false
        statusMessage = "Ready to scan"
    }

    func nfcManager(_ manager: NFCManager, didReadTag payload: any NFCTagPayload, uidHex: String) {
        let pending = pendingAssignSpool
        pendingAssignSpool = nil
        isScanning = false
        statusMessage = "Tag detected"
        Task { @MainActor in
            if let spool = pending {
                await processAssignment(spool: spool, uidHex: uidHex, tagPayload: payload)
            } else {
                await processTag(payload: payload, uidHex: uidHex)
            }
        }
    }

    func nfcManager(_ manager: NFCManager, didFailWithError error: Error) {
        isScanning = false
        pendingAssignSpool = nil
        statusMessage = "Error: \(error.localizedDescription)"
    }

    func nfcManagerDidInvalidateSession(_ manager: NFCManager, error: Error?) {
        isScanning = false
        pendingAssignSpool = nil
        statusMessage = error.map { "Session ended: \($0.localizedDescription)" } ?? "Scanning stopped"
    }

    // MARK: - Tag processing

    @MainActor
    func processTag(payload: any NFCTagPayload, uidHex: String) async {
        guard let spoolId = payload.spoolId else {
            let foundSpool = try? await api.findSpoolsByCardUid(uidHex, store: tagStore).first
            let result = ScanResult(
                spoolId: foundSpool?.id,
                spoolName: foundSpool?.displayName ?? payload.displayTitle,
                cardUid: uidHex,
                success: true,
                message: "Tag read (no Spoolman link)",
                tagPayload: payload,
                spoolResponse: foundSpool
            )
            statusMessage = "Tag read: \(payload.displayTitle)"
            scanHistory.insert(result, at: 0)
            lastResult = result
            return
        }

        statusMessage = "Fetching spool \(spoolId)…"

        do {
            let spool = try await api.getSpool(id: spoolId)
            let spoolName = spool.displayName

            statusMessage = "Updating spool…"
            if let holder = try await api.linkTag(to: spool, uid: uidHex, store: tagStore) {
                await refreshSpool(id: holder)
            }

            statusMessage = "Cleaning up other spools…"
            let matchingSpools = try await api.findSpoolsByCardUid(uidHex, store: tagStore)
            for otherSpool in matchingSpools where otherSpool.id != spoolId {
                try await api.unlinkTag(from: otherSpool, uid: uidHex, store: tagStore)
                await refreshSpool(id: otherSpool.id)
            }

            let updatedSpool = await refreshSpool(id: spoolId) ?? spool
            statusMessage = "Synced: \(spoolName)"
            let result = ScanResult(
                spoolId: spoolId,
                spoolName: spoolName,
                cardUid: uidHex,
                success: true,
                message: "Synced successfully",
                tagPayload: payload,
                spoolResponse: updatedSpool
            )
            scanHistory.insert(result, at: 0)
            lastResult = result

        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            let result = ScanResult(
                spoolId: spoolId,
                spoolName: payload.displayTitle,
                cardUid: uidHex,
                success: false,
                message: error.localizedDescription,
                tagPayload: payload
            )
            scanHistory.insert(result, at: 0)
            lastResult = result
        }
    }

    /// Assigns a scanned tag to `spool`. Rejects a tag the spool already has. Before taking a tag away from
    /// another spool it asks for confirmation (via `pendingTagMove`), unless `confirmMove` is false because the
    /// user already saw where the tag was when choosing the spool.
    @MainActor
    @discardableResult
    func processAssignment(spool: SpoolResponse, uidHex: String, tagPayload: any NFCTagPayload,
                           confirmMove: Bool = true) async -> TagAssignmentOutcome {
        statusMessage = "Assigning tag to \(spool.displayName)…"

        do {
            // The caller's spool may be a stale snapshot; building on it would drop tags assigned since.
            let freshSpool = try await api.getSpool(id: spool.id)
            let otherOwners = try await api.findSpoolsByCardUid(uidHex, store: tagStore).filter { $0.id != spool.id }

            if !otherOwners.isEmpty {
                let move = PendingTagMove(spool: freshSpool, uidHex: uidHex, tagPayload: tagPayload,
                                          currentOwners: otherOwners)
                guard confirmMove else { return await confirmTagMove(move) }
                pendingTagMove = move
                statusMessage = "Confirm moving tag to \(spool.displayName)"
                return .needsConfirmation
            }

            if freshSpool.tagUIDs.contains(uidHex.uppercased()) {
                recordAssignmentFailure(spool: freshSpool, uidHex: uidHex, tagPayload: tagPayload,
                                        title: "Tag Already Assigned",
                                        message: "This tag is already assigned to \(spool.displayName) (#\(spool.id)).")
                return .alreadyAssigned
            }

            if let holder = try await api.linkTag(to: freshSpool, uid: uidHex, store: tagStore) {
                await refreshSpool(id: holder)
            }
            await recordAssignmentSuccess(spool: freshSpool, uidHex: uidHex, tagPayload: tagPayload, message: "Tag assigned")
            return .assigned
        } catch {
            recordAssignmentFailure(spool: spool, uidHex: uidHex, tagPayload: tagPayload,
                                    title: "Couldn't Assign Tag", message: error.localizedDescription)
            return .failed
        }
    }

    /// Completes a move the user confirmed: adds the tag to the target spool and removes it from all others.
    @MainActor
    @discardableResult
    func confirmTagMove(_ move: PendingTagMove) async -> TagAssignmentOutcome {
        if pendingTagMove?.id == move.id { pendingTagMove = nil }
        statusMessage = "Moving tag to \(move.spool.displayName)…"
        do {
            // Re-read both sides: the confirmation may have been open for a while.
            let target = try await api.getSpool(id: move.spool.id)
            if let holder = try await api.linkTag(to: target, uid: move.uidHex, store: tagStore) {
                await refreshSpool(id: holder)
            }
            for other in try await api.findSpoolsByCardUid(move.uidHex, store: tagStore) where other.id != target.id {
                try await api.unlinkTag(from: other, uid: move.uidHex, store: tagStore)
                await refreshSpool(id: other.id)
            }
            await recordAssignmentSuccess(spool: target, uidHex: move.uidHex, tagPayload: move.tagPayload,
                                          message: "Tag moved from \(move.ownersDescription)")
            return .moved
        } catch {
            recordAssignmentFailure(spool: move.spool, uidHex: move.uidHex, tagPayload: move.tagPayload,
                                    title: "Couldn't Move Tag", message: error.localizedDescription)
            return .failed
        }
    }

    /// The user declined the move; nothing was written.
    @MainActor
    func declineTagMove() {
        guard let move = pendingTagMove else { return }
        pendingTagMove = nil
        statusMessage = "Tag not moved"
        lastAssignmentResult = ScanResult(
            spoolId: move.spool.id,
            spoolName: move.spool.displayName,
            cardUid: move.uidHex,
            success: false,
            message: "Tag not moved — still on \(move.ownersDescription)",
            tagPayload: move.tagPayload,
            spoolResponse: move.spool
        )
    }

    @MainActor
    private func recordAssignmentSuccess(spool: SpoolResponse, uidHex: String, tagPayload: any NFCTagPayload,
                                         message: String) async {
        let updatedSpool = await refreshSpool(id: spool.id) ?? spool
        statusMessage = "\(message) — \(spool.displayName)"
        let result = ScanResult(
            spoolId: spool.id,
            spoolName: spool.displayName,
            cardUid: uidHex,
            success: true,
            message: message,
            tagPayload: tagPayload,
            spoolResponse: updatedSpool
        )
        scanHistory.insert(result, at: 0)
        lastResult = result
        lastAssignmentResult = result
    }

    @MainActor
    private func recordAssignmentFailure(spool: SpoolResponse, uidHex: String, tagPayload: any NFCTagPayload,
                                         title: String, message: String) {
        statusMessage = "\(title): \(message)"
        let result = ScanResult(
            spoolId: spool.id,
            spoolName: spool.displayName,
            cardUid: uidHex,
            success: false,
            message: title,
            tagPayload: tagPayload,
            spoolResponse: spool
        )
        scanHistory.insert(result, at: 0)
        lastResult = result
        lastAssignmentResult = result
        assignmentError = TagAssignmentError(title: title, message: message)
    }
}

/// Lets the caller decide what to do next, e.g. close the picker once the tag is assigned or moved.
enum TagAssignmentOutcome {
    case assigned, moved, alreadyAssigned, needsConfirmation, failed
}

/// A scanned tag that belongs to other spools, awaiting the user's OK to move it to `spool`.
struct PendingTagMove: Identifiable {
    let id = UUID()
    let spool: SpoolResponse
    let uidHex: String
    let tagPayload: any NFCTagPayload
    let currentOwners: [SpoolResponse]

    var ownersDescription: String {
        currentOwners.map { "\($0.displayName) (#\($0.id))" }.joined(separator: ", ")
    }
}

struct TagAssignmentError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
