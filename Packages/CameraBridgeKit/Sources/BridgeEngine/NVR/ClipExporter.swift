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
}
