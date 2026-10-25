import Foundation

/// How well a sky camera's aim is known, as the card says it ("Aim: rough → good → precise"):
/// - `rough`: the card's facing and tilt, or a fit that is not good yet (flight matching is loose meanwhile);
/// - `good`: fitted (stage 1 or more) to within 0.8° RMS;
/// - `precise`: fitted with at least 25 star matches, whose RMS is within 0.15°.
///
/// A dual camera's is its least aimed lens's, as each lens is fitted on its own.
public enum SkyAimQuality: String, Codable, Sendable {
    case rough, good, precise
}

extension SkyAimQuality {
    /// rough 0, good 1, precise 2.
    var rank: Int {
        switch self {
        case .rough: 0
        case .good: 1
        case .precise: 2
        }
    }

    /// The lowest of `qualities` (rough when there are none).
    static func lowest(_ qualities: [SkyAimQuality]) -> SkyAimQuality {
        qualities.min { $0.rank < $1.rank } ?? .rough
    }
}

/// One lens's aim, for the card ("Left lens: precise …, right lens: good …").
public struct SkyLensAimStatus: Codable, Sendable, Equatable {
    public var quality: SkyAimQuality
    /// The aircraft and the stars (each counted once) whose matches the lens's fit agrees with.
    public var planes: Int
    public var stars: Int
    /// The lens's residual: the RMS of its inliers' errors in pixels of the camera's original picture; nil before the lens has a fit.
    public var residualPixels: Double?

    public init(quality: SkyAimQuality, planes: Int, stars: Int, residualPixels: Double?) {
        self.quality = quality
        self.planes = planes
        self.stars = stars
        self.residualPixels = residualPixels
    }
}

/// A sky camera's aim, as the card and the log show it ("Aim: precise, 214 stars matched, 1.8 px").
public struct SkyAimStatus: Codable, Sendable, Equatable {
    public var quality: SkyAimQuality
    /// The aircraft and the stars (each counted once) whose matches the fit agrees with.
    public var planes: Int
    public var stars: Int
    /// The fit's residual: the RMS of its inliers' errors in pixels of the camera's original picture; nil before there is a fit.
    public var residualPixels: Double?
    /// When the fit was made; nil before there is one.
    public var updated: Date?
    /// Each lens's own (one for a single lens; left, then right, for a dual camera); empty before there is a fit.
    public var lenses: [SkyLensAimStatus]
    /// What the card says about the aim beyond that, such as "The camera seems to have moved; aiming again."; nil when there is nothing.
    public var note: String?

    public init(quality: SkyAimQuality, planes: Int, stars: Int, residualPixels: Double?, updated: Date?, lenses: [SkyLensAimStatus] = [],
                note: String? = nil) {
        self.quality = quality
        self.planes = planes
        self.stars = stars
        self.residualPixels = residualPixels
        self.updated = updated
        self.lenses = lenses
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case quality, planes, stars, residualPixels, updated, lenses, note
    }

    /// A status written without `lenses` or `note` (or without a residual or a date) reads with none.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(quality: try values.decode(SkyAimQuality.self, forKey: .quality), planes: try values.decode(Int.self, forKey: .planes),
                  stars: try values.decode(Int.self, forKey: .stars),
                  residualPixels: try values.decodeIfPresent(Double.self, forKey: .residualPixels),
                  updated: try values.decodeIfPresent(Date.self, forKey: .updated),
                  lenses: try values.decodeIfPresent([SkyLensAimStatus].self, forKey: .lenses) ?? [],
                  note: try values.decodeIfPresent(String.self, forKey: .note))
    }

    /// Before any fit: rough, with nothing matched.
    static func unaimed(note: String? = nil) -> SkyAimStatus {
        SkyAimStatus(quality: .rough, planes: 0, stars: 0, residualPixels: nil, updated: nil, note: note)
    }
}

/// A match the aim is fitted to: where in the camera's original picture (never the straightened one) something was seen, and the sky
/// direction it was really in at that moment: an aircraft's from the flight feed, or a star's from the catalogue.
struct AimCorrespondence: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case plane, star
    }

    var point: PixelPoint
    var direction: SkyDirection
    var source: Source
    /// When it was seen.
    var at: Date
    /// What was seen: an aircraft's hex, a star's HR number.
    var object: String
}

/// A fit of a camera's aim to its matches (`AimFitter`), each lens on its own.
struct AimFit: Codable, Sendable, Equatable {
    /// One lens's part of the fit.
    struct LensFit: Codable, Sendable, Equatable {
        /// 0 (not fitted: too few matches) to 4; the terms each stage frees are in `AimFitter`.
        var stage: Int
        var quality: SkyAimQuality
        /// The RMS of the inliers' angular errors (degrees): how far the sky direction of each match's pixel through the lens is from the
        /// match's own. 0 when the lens is not fitted.
        var residualDegrees: Double
        /// The RMS of the inliers' errors in pixels of the original picture: where the lens puts each match's direction, against where it
        /// was seen. 0 when the lens is not fitted.
        var residualPixels: Double
        /// The matches the fit agrees with: within the tolerance it reached (`AimFitter.matchTolerance`), of those the lens owns outside the
        /// seam band.
        var inliers: Int
        /// The aircraft and the stars among them, each counted once.
        var planes: Int
        var stars: Int
        /// The star matches among them (precise needs 25).
        var starMatches: Int
        /// The plane matches among them, and their RMS (degrees; nil without any).
        var planeMatches: Int
        var planeResidualDegrees: Double?
        /// The star matches' RMS (degrees; nil without any), what precise is judged on.
        var starResidualDegrees: Double?

        /// A lens with no fit.
        static let unfitted = LensFit(stage: 0, quality: .rough, residualDegrees: 0, residualPixels: 0, inliers: 0, planes: 0, stars: 0,
                                      starMatches: 0, planeMatches: 0, planeResidualDegrees: nil, starResidualDegrees: nil)
    }

    var model: SkyCameraModel
    /// The lowest of the lenses' stages, as the quality is the lowest of their qualities: the camera is as aimed as its least aimed lens.
    var stage: Int
    var quality: SkyAimQuality
    /// The lenses' residuals together: the RMS over all their inliers, in degrees and in pixels of the original picture.
    var residualDegrees: Double
    var residualPixels: Double
    var inliers: Int
    /// The aircraft and the stars (each counted once, in whichever lens) among the inliers.
    var planes: Int
    var stars: Int
    /// Each lens's own: one for a single lens, left then right for a dual camera.
    var lenses: [LensFit]
    /// The RMS of the plane inliers alone (degrees), what a new plane match is held to (a moved camera, `SkyAimStore`); nil without any.
    var planeResidualDegrees: Double?

    /// What the card shows of it. A lens (or a camera) that is not fitted has no residual to show.
    func status(updated: Date?, note: String?) -> SkyAimStatus {
        let each = lenses.map { lens in
            SkyLensAimStatus(quality: lens.quality, planes: lens.planes, stars: lens.stars, residualPixels: lens.stage > 0 ? lens.residualPixels : nil)
        }
        let fitted = lenses.contains { $0.stage > 0 }
        return SkyAimStatus(quality: quality, planes: planes, stars: stars, residualPixels: fitted ? residualPixels : nil,
                            updated: fitted ? updated : nil, lenses: fitted ? each : [], note: note)
    }
}
