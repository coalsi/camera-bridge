import Foundation

/// The correction as ffmpeg's `remap` filter applies it (Camera Bridge OS: the transcoder for Apple Home, snapshots, saved clips).
///
/// `remap` takes every output pixel from the source pixel two map images name, the nearest one (it has no interpolation), so a
/// plain warp at the output size shows stair-steps on thin slanted lines (power lines on the owner's Backyard frame). The warp is
/// therefore done on a picture `remapSupersample` times taller and then shrunk with `area`, which came out close to an exact
/// bilinear warp. `remap` takes no subsampled pixel format, so each plane of the 4:2:0 picture is warped as a grey picture of its
/// own (`extractplanes`, three `remap`s, `mergeplanes`): on the box's N150 that adds about 18 ms per 1920 × 852 picture, half of
/// what a 4:4:4 warp costs, at the same quality (ruling R6, 2026-10-18). The maps are 16-bit grey pictures, hence the `gray16` steps.
extension PictureCorrection {
    /// How many times taller than the output the picture is warped.
    public static let remapSupersample = 2

    /// The four maps for a `width × height` picture (`width` even), as 16-bit binary PGM images (`P5\n<w> <h>\n65535\n`,
    /// big-endian samples): `x` and `y` for the luma plane of the supersampled picture (`width × remapSupersample · height`),
    /// `chromaX` and `chromaY` for its two colour planes (half as wide and half as tall as that picture: `width/2 × height`). An x map holds every
    /// pixel's own column; a y map the row of its plane that the pixel takes its colour from,
    /// `floor(sourceFraction(across: (x + 0.5) / columns, down: (r + 0.5) / rows) · rows)` kept inside `0…rows − 1`.
    public func remapMaps(width: Int, height: Int) -> (x: Data, y: Data, chromaX: Data, chromaY: Data) {
        let columns = min(65_536, max(1, width))
        let rows = min(65_536, max(1, height * Self.remapSupersample))
        // 4:2:0 planes are rounded up, as ffmpeg's are (the sizes used are even, so these are exact halves).
        let chromaColumns = (columns + 1) / 2, chromaRows = (rows + 1) / 2
        let luma = maps(columns: columns, rows: rows)
        let chroma = maps(columns: chromaColumns, rows: chromaRows)
        return (luma.x, luma.y, chroma.x, chroma.y)
    }

    /// An x map and a y map for one plane of `columns × rows`.
    private func maps(columns: Int, rows: Int) -> (x: Data, y: Data) {
        let header = Array("P5\n\(columns) \(rows)\n65535\n".utf8)
        var row = [UInt8](repeating: 0, count: columns * 2)
        for column in 0..<columns {
            row[column * 2] = UInt8(column >> 8)
            row[column * 2 + 1] = UInt8(column & 0xFF)
        }
        var x = header
        x.reserveCapacity(header.count + columns * rows * 2)
        for _ in 0..<rows { x += row }
        var y = header + [UInt8](repeating: 0, count: columns * rows * 2)
        let scale = Double(rows)
        for column in 0..<columns {
            let across = (Double(column) + 0.5) / Double(columns)
            for r in 0..<rows {
                let source = sourceFraction(across: across, down: (Double(r) + 0.5) / scale) * scale
                let value = min(rows - 1, max(0, Int(source.rounded(.down))))
                let offset = header.count + (r * columns + column) * 2
                y[offset] = UInt8(value >> 8)
                y[offset + 1] = UInt8(value & 0xFF)
            }
        }
        return (Data(x), Data(y))
    }

    /// The filter-graph piece that warps the picture on pad `input` (a `width × height` picture, `width` even) with the maps on
    /// pads `xMap`, `yMap`, `chromaXMap` and `chromaYMap` (made by `remapMaps(width:height:)`) and puts the straightened
    /// `width × height` 4:2:0 picture on pad `output`. Pad names are given without brackets; the piece uses pads named `cb…` inside
    /// (`cbpy`, `cbx`, `cbcx1`, `cbry` and the like).
    public static func ffmpegRemapChain(input: String, width: Int, height: Int, xMap: String, yMap: String, chromaXMap: String, chromaYMap: String,
                                        output: String) -> String {
        "[\(input)]scale=\(width):\(height * remapSupersample):flags=bicubic,format=yuv420p,extractplanes=y+u+v[cbpy][cbpu][cbpv];"
            + "[\(xMap)]format=gray16[cbx];[\(yMap)]format=gray16[cby];"
            + "[\(chromaXMap)]format=gray16,split[cbcx1][cbcx2];[\(chromaYMap)]format=gray16,split[cbcy1][cbcy2];"
            + "[cbpy][cbx][cby]remap=format=gray[cbry];[cbpu][cbcx1][cbcy1]remap=format=gray[cbru];[cbpv][cbcx2][cbcy2]remap=format=gray[cbrv];"
            + "[cbry][cbru][cbrv]mergeplanes=map0s=0:map0p=0:map1s=1:map1p=0:map2s=2:map2p=0:format=yuv420p,scale=\(width):\(height):flags=area[\(output)]"
    }
}
