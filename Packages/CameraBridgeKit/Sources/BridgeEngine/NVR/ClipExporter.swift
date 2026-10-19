import Foundation

/// Exports a stretch of one camera's recordings as an ordinary MP4 (export-clip design, section 3): `plan` is a dry run that reads fragment headers
/// only and says exactly what the files will be, `export` writes one part of a plan to a sink in one pass, without re-encoding. One portable type:
/// the Mac app calls it in process and writes a file, the daemon's routes stream it to a browser.
public struct ClipExporter: ClipExporting {
    private let planner: ClipPlanner
    private let writer: ClipWriter

    public init(archive: any ArchiveReading, limits: ClipLimits = .standard) {
        planner = ClipPlanner(archive: archive, limits: limits, sizing: ClipSizing.totalBytes(of:))
        writer = ClipWriter(archive: archive)
    }

    public func plan(_ request: ClipRequest) async throws -> ClipPlan { try await planner.plan(request) }

    /// Part `part` of `plan`, counted from 1 like `ClipPart.index`. A plan that did not come from `plan(_:)` of a `ClipExporter` throws `notReady`.
    public func export(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws {
        try await writer.write(plan, part: part, to: sink, progress: progress)
    }

    /// The picture size of part `part` of `plan` (counted from 1), as the part's recordings say it (their init segment): what a converter
    /// that re-encodes the part (a straightened clip) is given. Throws `notReady` for a part the plan has no tables for (a fake's plan).
    public func pictureSize(_ plan: ClipPlan, part: Int) async throws -> (width: Int, height: Int) {
        guard plan.tables.indices.contains(part - 1) else { throw ClipError.notReady }
        let tables = plan.tables[part - 1]
        return (tables.width, tables.height)
    }
}
