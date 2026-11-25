import Foundation

/// Heights above sea level on a regular latitude/longitude grid, for rough line-of-sight checks: the highest roof or
/// ground in each cell (0 on the water) and the ground under it.
public struct SurfaceGrid: Sendable {
    /// Latitude of the southern edge and longitude of the western edge.
    public let south: Double
    public let west: Double
    public let latitudeStep: Double
    public let longitudeStep: Double
    public let rows: Int
    public let columns: Int
    /// Row by row from the south-west corner, meters above sea level.
    private let tops: [Float]
    private let grounds: [Float]

    public init(south: Double, west: Double, latitudeStep: Double, longitudeStep: Double, rows: Int, columns: Int,
                tops: [Float], grounds: [Float]) {
        let count = rows * columns
        precondition(tops.count == count && grounds.count == count, "grid size mismatch")
        self.south = south
        self.west = west
        self.latitudeStep = latitudeStep
        self.longitudeStep = longitudeStep
        self.rows = rows
        self.columns = columns
        self.tops = tops
        self.grounds = grounds
    }

    /// Decodes one byte per cell, base64 (line breaks ignored): tops in `topUnit`-meter steps, grounds in
    /// `groundUnit`-meter steps. Nil when the data doesn't match the grid's size.
    public init?(south: Double, west: Double, latitudeStep: Double, longitudeStep: Double, rows: Int, columns: Int,
                 topsBase64: String, topUnit: Double, groundsBase64: String, groundUnit: Double) {
        guard let tops = Data(base64Encoded: topsBase64, options: .ignoreUnknownCharacters),
              let grounds = Data(base64Encoded: groundsBase64, options: .ignoreUnknownCharacters),
              tops.count == rows * columns, grounds.count == rows * columns
        else { return nil }
        self.init(south: south, west: west, latitudeStep: latitudeStep, longitudeStep: longitudeStep,
                  rows: rows, columns: columns,
                  tops: tops.map { Float(Double($0) * topUnit) },
                  grounds: grounds.map { Float(Double($0) * groundUnit) })
    }

    /// New York Harbor around the dev area (`HarborSurface`).
    public static let harbor = SurfaceGrid(
        south: HarborSurface.south, west: HarborSurface.west,
        latitudeStep: HarborSurface.latitudeStep, longitudeStep: HarborSurface.longitudeStep,
        rows: HarborSurface.rows, columns: HarborSurface.columns,
        topsBase64: HarborSurface.tops, topUnit: HarborSurface.topUnitMeters,
        groundsBase64: HarborSurface.grounds, groundUnit: HarborSurface.groundUnitMeters) ?? .flat

    /// No data anywhere: nothing is ever in the way.
    public static let flat = SurfaceGrid(south: 0, west: 0, latitudeStep: 1, longitudeStep: 1, rows: 0, columns: 0,
                                         tops: [], grounds: [])

    /// Row (from the south) and column (from the west) of the cell holding the point; nil outside the grid.
    public func cell(latitude: Double, longitude: Double) -> (row: Int, column: Int)? {
        let row = ((latitude - south) / latitudeStep).rounded(.down)
        let column = ((longitude - west) / longitudeStep).rounded(.down)
        guard row >= 0, row < Double(rows), column >= 0, column < Double(columns) else { return nil }
        return (Int(row), Int(column))
    }

    private func index(latitude: Double, longitude: Double) -> Int? {
        cell(latitude: latitude, longitude: longitude).map { $0.row * columns + $0.column }
    }

    /// Highest roof or ground in the cell, meters above sea level; nil outside the grid.
    public func top(latitude: Double, longitude: Double) -> Double? {
        index(latitude: latitude, longitude: longitude).map { Double(tops[$0]) }
    }

    /// The ground in the cell, meters above sea level (0 on the water); nil outside the grid.
    public func ground(latitude: Double, longitude: Double) -> Double? {
        index(latitude: latitude, longitude: longitude).map { Double(grounds[$0]) }
    }
}
