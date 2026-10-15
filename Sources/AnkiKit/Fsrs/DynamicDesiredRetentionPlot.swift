//
//  DynamicDesiredRetentionPlot.swift
//  AnkiKit
//

import Foundation

/// Port of the desktop's `DynamicDesiredRetentionPlotModal.svelte`: the
/// ADR policy's DR surface over stability x difficulty for the cost weight
/// of a target DR, projected with the modal's yaw/pitch rotation, plus its
/// contours, axes, ticks, colour scale and readouts. Pure geometry, so the
/// SwiftUI view only draws what this computes.
public struct DynamicDesiredRetentionPlot: Sendable, Equatable {
    public var params: [Double]
    public var calibrationWeights: [Double]
    public var calibrationAvgDrs: [Double]
    public var fsrsEquivalentWeights: [Double]
    public var fsrsEquivalentDrs: [Double]
    public var fixedTargetWeights: [Double]
    public var fixedTargetDrs: [Double]
    public var retentionMin: Double
    public var retentionMax: Double

    public init(
        params: [Double],
        calibrationWeights: [Double],
        calibrationAvgDrs: [Double],
        fsrsEquivalentWeights: [Double] = [],
        fsrsEquivalentDrs: [Double] = [],
        fixedTargetWeights: [Double] = [],
        fixedTargetDrs: [Double] = [],
        retentionMin: Double = DynamicDesiredRetentionPolicy.defaultRetentionMin,
        retentionMax: Double = DynamicDesiredRetentionPolicy.defaultRetentionMax
    ) {
        self.params = params
        self.calibrationWeights = calibrationWeights
        self.calibrationAvgDrs = calibrationAvgDrs
        self.fsrsEquivalentWeights = fsrsEquivalentWeights
        self.fsrsEquivalentDrs = fsrsEquivalentDrs
        self.fixedTargetWeights = fixedTargetWeights
        self.fixedTargetDrs = fixedTargetDrs
        self.retentionMin = retentionMin
        self.retentionMax = retentionMax
    }

    /// The props `FsrsOptions.svelte` passes from the edited preset.
    public init(model: FsrsDynamicDesiredRetention) {
        let m = model.doubles
        self.init(
            params: m.params,
            calibrationWeights: m.weights,
            calibrationAvgDrs: m.avgDrs,
            fsrsEquivalentWeights: m.fsrsEqWeights,
            fsrsEquivalentDrs: m.fsrsEqDrs,
            fixedTargetWeights: m.fixedTargetWeights,
            fixedTargetDrs: m.fixedTargetDrs,
            retentionMin: m.minimum,
            retentionMax: m.maximum
        )
    }

    // MARK: - Target selector

    public var targetCalibration: DynamicDesiredRetentionPolicy.TargetCalibration {
        DynamicDesiredRetentionPolicy.targetCalibration(
            avgWeights: calibrationWeights,
            avgDrs: calibrationAvgDrs,
            fsrsEqWeights: fsrsEquivalentWeights,
            fsrsEqDrs: fsrsEquivalentDrs,
            fixedTargetWeights: fixedTargetWeights,
            fixedTargetDrs: fixedTargetDrs
        )
    }

    public var hasTargetCalibration: Bool { targetCalibration.isValid }

    /// The slider's `selectorMin`/`selectorMax`.
    public var selectorRange: DynamicDesiredRetentionPolicy.ClosedRangeValues {
        let calibration = targetCalibration
        guard calibration.isValid else { return .init(min: 0, max: 1) }
        return .init(
            min: calibration.fixedTarget ? retentionMin : DynamicDesiredRetentionPolicy.jsMin(calibration.drs),
            max: DynamicDesiredRetentionPolicy.jsMax(calibration.drs)
        )
    }

    /// `inferredWeight`: the cost weight plotted for a target DR.
    public func inferredWeight(target: Double) -> Double? {
        let calibration = targetCalibration
        return DynamicDesiredRetentionPolicy.costWeight(
            forTarget: target,
            weights: calibration.weights,
            drs: calibration.drs,
            fixedTarget: calibration.fixedTarget,
            retentionMin: retentionMin
        )
    }

    /// `canPlotWithWeight`; also gates "Save DR".
    public func canPlot(weight: Double?) -> Bool {
        DynamicDesiredRetentionPolicy.validPolicyParams(params)
            && DynamicDesiredRetentionPolicy.validCalibration(calibrationWeights, calibrationAvgDrs)
            && hasTargetCalibration
            && DynamicDesiredRetentionPolicy.validRetentionBounds(retentionMin, retentionMax)
            && weight != nil
    }

    /// `setDraftTargetDr`: clamps into the selector range; nil (ignored)
    /// when not finite.
    public func draftTarget(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let range = selectorRange
        return Swift.min(range.max, Swift.max(range.min, value))
    }

    /// `parsePercentInput`: `Number(text.trim().replace("%", "")) / 100`.
    public static func parsePercentInput(_ text: String) -> Double {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let percent = normalized.range(of: "%") {
            normalized.removeSubrange(percent)
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return 0 }
        // `Number` rejects Swift's "inf"/"nan" spellings and hex floats.
        let lowered = normalized.lowercased()
        if lowered.contains("inf") || lowered.contains("nan") || lowered.contains("p") {
            return .nan
        }
        return (Double(normalized) ?? .nan) / 100
    }

    // MARK: - Surface

    public static let stabilityCount = 34
    public static let difficultyCount = 24

    /// `renderPlot`'s grid: rows by difficulty 1...10, columns by log
    /// stability 0.1...1000 days.
    public func surface(weight: Double) -> [[SurfacePoint]] {
        let logSMin = log(0.1)
        let logSMax = log(1000.0)
        let sCount = Self.stabilityCount
        let dCount = Self.difficultyCount
        return (0..<dCount).map { y in
            let difficulty = 1 + (9 * Double(y)) / Double(dCount - 1)
            return (0..<sCount).map { x in
                let stability = exp(logSMin + ((logSMax - logSMin) * Double(x)) / Double(sCount - 1))
                let dr = DynamicDesiredRetentionPolicy.evaluate(
                    params: params,
                    stability: stability,
                    difficulty: difficulty,
                    costWeight: weight,
                    retentionMin: retentionMin,
                    retentionMax: retentionMax
                )
                return SurfacePoint(
                    x: (Double(x) / Double(sCount - 1) - 0.5) * 2,
                    y: (Double(y) / Double(dCount - 1) - 0.5) * 2,
                    z: retentionToAxis(dr),
                    stability: stability,
                    difficulty: difficulty,
                    dr: dr
                )
            }
        }
    }

    public func retentionToAxis(_ value: Double) -> Double {
        ((value - retentionMin) / (retentionMax - retentionMin)) * 1.6
    }

    public static func stabilityToAxis(_ value: Double) -> Double {
        ((log(value) - log(0.1)) / (log(1000.0) - log(0.1)) - 0.5) * 2
    }

    public static func difficultyToAxis(_ value: Double) -> Double {
        ((value - 1) / 9 - 0.5) * 2
    }

    // MARK: - Axes and ticks

    /// `axisDefinitions`.
    public static let axes: [Axis] = [
        Axis(start: .init(x: -1.08, y: 1.08, z: 0), end: .init(x: 1.08, y: 1.08, z: 0), label: "S"),
        Axis(start: .init(x: -1.08, y: -1.08, z: 0), end: .init(x: -1.08, y: 1.08, z: 0), label: "D"),
        Axis(start: .init(x: -1.08, y: 1.08, z: 0), end: .init(x: -1.08, y: 1.08, z: 1.75), label: "DR"),
    ]

    /// `axisTickPoints`.
    public func axisTicks() -> [AxisTick] {
        let stability: [(Double, String)] = [(0.1, "0.1"), (1, "1"), (10, "10"), (100, "100"), (1000, "1000")]
        let difficulty: [(Double, String)] = [(1, "1"), (5, "5"), (10, "10")]
        let retention = [retentionMin, (retentionMin + retentionMax) / 2, retentionMax]
        return stability.map { value, label in
            AxisTick(point: .init(x: Self.stabilityToAxis(value), y: 1.16, z: 0), label: label, dx: 0, dy: 12)
        } + difficulty.map { value, label in
            AxisTick(point: .init(x: -1.2, y: Self.difficultyToAxis(value), z: 0), label: label, dx: -8, dy: 3)
        } + retention.map { value in
            AxisTick(
                point: .init(x: -1.2, y: 1.2, z: retentionToAxis(value)),
                label: Self.formatPercent(value),
                dx: -10,
                dy: 3
            )
        }
    }

    // MARK: - Contours

    /// `contourLevels`: every 10% strictly inside the bounds.
    public func contourLevels() -> [Double] {
        let first = ceil((retentionMin + 0.000001) * 10) / 10
        let last = floor((retentionMax - 0.000001) * 10) / 10
        return Self.d3Range(first, last + 0.001, 0.1)
    }

    /// `d3.range(start, stop, step)`.
    static func d3Range(_ start: Double, _ stop: Double, _ step: Double) -> [Double] {
        let steps = ((stop - start) / step).rounded(.up)
        guard steps.isFinite, steps > 0 else { return [] }
        let count = Int(steps)
        return (0..<count).map { start + Double($0) * step }
    }

    /// `contourIntersections`: where a level crosses a cell's edges.
    static func contourIntersections(_ corners: [SurfacePoint], level: Double) -> [SurfacePoint] {
        var intersections: [SurfacePoint] = []
        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            if (level - start.dr) * (level - end.dr) > 0 || start.dr == end.dr {
                continue
            }
            let t = (level - start.dr) / (end.dr - start.dr)
            if t < 0 || t > 1 {
                continue
            }
            intersections.append(SurfacePoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t,
                z: start.z + (end.z - start.z) * t,
                stability: start.stability + (end.stability - start.stability) * t,
                difficulty: start.difficulty + (end.difficulty - start.difficulty) * t,
                dr: level
            ))
        }
        // `uniquePoints`, keyed on x/y/z to 5 decimals.
        var seen = Set<String>()
        return intersections.filter { point in
            let key = [point.x, point.y, point.z]
                .map { DynamicDesiredRetentionPolicy.toFixed($0, 5) }
                .joined(separator: ",")
            return seen.insert(key).inserted
        }
    }

    // MARK: - Scene

    public static let defaultYaw: Double = -42
    public static let defaultPitch: Double = 24

    /// The drag handler: yaw follows x, pitch follows y within ±70°.
    public static func rotated(yaw: Double, pitch: Double, dx: Double, dy: Double) -> (yaw: Double, pitch: Double) {
        (yaw + dx * 0.45, Swift.max(-70, Swift.min(70, pitch - dy * 0.35)))
    }

    /// `renderPlot` for a `width` x `height` canvas: nil when the modal
    /// shows "Dynamic DR policy and calibration are required." instead.
    public func scene(width: Double, height: Double, yaw: Double, pitch: Double, weight: Double?) -> Scene? {
        guard canPlot(weight: weight), let weight else { return nil }
        let surface = surface(weight: weight)
        let ticks = axisTicks()
        let horizontalPadding = 24.0
        let topPadding = 70.0
        let bottomPadding = 12.0

        let unit = Projection(yaw: yaw, pitch: pitch, scale: 1)
        let unitBounds = Self.projectedBounds(surface, ticks: ticks, projection: unit)
        let scale = Swift.min(
            (width - horizontalPadding * 2) / Swift.max(1, unitBounds.maxX - unitBounds.minX),
            (height - topPadding - bottomPadding) / Swift.max(1, unitBounds.maxY - unitBounds.minY)
        )
        let projection = Projection(yaw: yaw, pitch: pitch, scale: scale)
        let projected = surface.map { $0.map(projection.project) }

        var cells: [Cell] = []
        for y in 0..<(surface.count - 1) {
            for x in 0..<(surface[y].count - 1) {
                let points = [projected[y][x], projected[y][x + 1], projected[y + 1][x + 1], projected[y + 1][x]]
                let corners = [surface[y][x], surface[y][x + 1], surface[y + 1][x + 1], surface[y + 1][x]]
                cells.append(Cell(
                    row: y,
                    column: x,
                    points: points,
                    depth: Self.mean(points.map(\.depth)),
                    dr: surface[y][x].dr,
                    stability: exp(Self.mean(corners.map { log($0.stability) })),
                    difficulty: Self.mean(corners.map(\.difficulty))
                ))
            }
        }
        cells = DynamicDesiredRetentionPolicy.stableSorted(cells) { $0.depth < $1.depth }

        var contours: [ContourSegment] = []
        let levels = contourLevels()
        for y in 0..<(surface.count - 1) {
            for x in 0..<(surface[y].count - 1) {
                let corners = [surface[y][x], surface[y][x + 1], surface[y + 1][x + 1], surface[y + 1][x]]
                for level in levels {
                    let intersections = Self.contourIntersections(corners, level: level)
                    var index = 0
                    while index + 1 < intersections.count {
                        let start = projection.project(intersections[index].point)
                        let end = projection.project(intersections[index + 1].point)
                        contours.append(ContourSegment(
                            start: start, end: end, depth: (start.depth + end.depth) / 2, level: level
                        ))
                        index += 2
                    }
                }
            }
        }
        contours = DynamicDesiredRetentionPolicy.stableSorted(contours) { $0.depth < $1.depth }

        let bounds = Self.projectedBounds(surface, ticks: ticks, projection: projection)
        return Scene(
            width: width,
            height: height,
            scale: scale,
            weight: weight,
            offsetX: width / 2 - (bounds.minX + bounds.maxX) / 2,
            offsetY: height - bottomPadding - bounds.maxY,
            cells: cells,
            contours: contours,
            axes: Self.axes.map { ProjectedAxis(start: projection.project($0.start), end: projection.project($0.end), label: $0.label) },
            ticks: ticks.map { ProjectedTick(point: projection.project($0.point), label: $0.label, dx: $0.dx, dy: $0.dy) }
        )
    }

    /// `projectedBounds`: the surface, axis ends and tick anchors.
    static func projectedBounds(_ surface: [[SurfacePoint]], ticks: [AxisTick], projection: Projection) -> Bounds {
        let points = surface.flatMap { $0.map { projection.project($0.point) } }
            + axes.flatMap { [projection.project($0.start), projection.project($0.end)] }
            + ticks.map { projection.project($0.point) }
        // `d3.min`/`d3.max` skip NaN; `?? 0` when nothing is left.
        func extent(_ values: [Double]) -> (min: Double, max: Double) {
            let finite = values.filter { !$0.isNaN }
            return (finite.min() ?? 0, finite.max() ?? 0)
        }
        let xs = extent(points.map(\.x))
        let ys = extent(points.map(\.y))
        return Bounds(minX: xs.min, maxX: xs.max, minY: ys.min, maxY: ys.max)
    }

    /// `d3.mean(...) ?? 0`: NaN values are skipped.
    static func mean(_ values: [Double]) -> Double {
        let numbers = values.filter { !$0.isNaN }
        return numbers.isEmpty ? 0 : numbers.reduce(0, +) / Double(numbers.count)
    }

    // MARK: - Colour scale and legend

    /// `d3.scaleSequential(d3.interpolateViridis).domain([min, max])`.
    public func color(_ dr: Double) -> RGB {
        let t = (dr - retentionMin) / (retentionMax - retentionMin)
        guard !t.isNaN else { return RGB(red: 0, green: 0, blue: 0) }
        let n = Self.viridis.count
        let index = Swift.max(0, Swift.min(n - 1, Int((t * Double(n)).rounded(.down).clamped(to: -1...Double(n)))))
        return Self.viridis[index]
    }

    /// The legend's gradient stops: `d3.range(0, 1.01, 0.1)` across the
    /// bounds.
    public func legendStops() -> [(location: Double, color: RGB)] {
        Self.d3Range(0, 1.01, 0.1).map { step in
            (step, color(retentionMin + step * (retentionMax - retentionMin)))
        }
    }

    // MARK: - Formatting

    /// `formatPercent`.
    public static func formatPercent(_ value: Double, digits: Int = 1) -> String {
        "\(DynamicDesiredRetentionPolicy.toFixed(value * 100, digits))%"
    }

    /// `formatStability`.
    public static func formatStability(_ value: Double) -> String {
        if value >= 100 {
            return "\(DynamicDesiredRetentionPolicy.toFixed(value, 0)) d"
        } else if value >= 10 {
            return "\(DynamicDesiredRetentionPolicy.toFixed(value, 1)) d"
        }
        return "\(DynamicDesiredRetentionPolicy.toFixed(value, 2)) d"
    }

    /// `surfaceTooltipRows`.
    public static func tooltipRows(_ cell: Cell) -> [String] {
        [
            "Stability: \(formatStability(cell.stability))",
            "Difficulty: \(DynamicDesiredRetentionPolicy.toFixed(cell.difficulty, 2)) / 10",
            "DR: \(formatPercent(cell.dr, digits: 2))",
        ]
    }

    /// The "Weight:" readout.
    public static func formatWeight(_ weight: Double?) -> String {
        weight.map { DynamicDesiredRetentionPolicy.toFixed($0, 2) } ?? "n/a"
    }
}

// MARK: - Geometry types

extension DynamicDesiredRetentionPlot {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var z: Double
    }

    public struct SurfacePoint: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var z: Double
        public var stability: Double
        public var difficulty: Double
        public var dr: Double

        var point: Point { Point(x: x, y: y, z: z) }
    }

    public struct ProjectedPoint: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var depth: Double
    }

    /// `project`: yaw about the vertical axis, then pitch.
    public struct Projection: Sendable, Equatable {
        public var yaw: Double
        public var pitch: Double
        public var scale: Double

        public func project(_ point: Point) -> ProjectedPoint {
            let yawRad = (yaw * Double.pi) / 180
            let pitchRad = (pitch * Double.pi) / 180
            let cy = cos(yawRad)
            let sy = sin(yawRad)
            let cp = cos(pitchRad)
            let sp = sin(pitchRad)
            let x1 = point.x * cy - point.y * sy
            let y1 = point.x * sy + point.y * cy
            let y2 = y1 * cp - point.z * sp
            let z2 = y1 * sp + point.z * cp
            return ProjectedPoint(x: x1 * scale, y: y2 * scale, depth: z2)
        }

        func project(_ point: SurfacePoint) -> ProjectedPoint { project(point.point) }
    }

    struct Bounds: Equatable {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
    }

    public struct Cell: Sendable, Equatable {
        /// The cell's grid position (difficulty row, stability column).
        public var row: Int
        public var column: Int
        public var points: [ProjectedPoint]
        public var depth: Double
        public var dr: Double
        public var stability: Double
        public var difficulty: Double

        /// Even-odd point-in-polygon, in plot (untranslated) coordinates.
        func contains(x: Double, y: Double) -> Bool {
            var inside = false
            var j = points.count - 1
            for i in points.indices {
                let a = points[i]
                let b = points[j]
                if (a.y > y) != (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }

    public struct ContourSegment: Sendable, Equatable {
        public var start: ProjectedPoint
        public var end: ProjectedPoint
        public var depth: Double
        public var level: Double
    }

    public struct Axis: Sendable, Equatable {
        public var start: Point
        public var end: Point
        public var label: String
    }

    public struct AxisTick: Sendable, Equatable {
        public var point: Point
        public var label: String
        public var dx: Double
        public var dy: Double
    }

    public struct ProjectedAxis: Sendable, Equatable {
        public var start: ProjectedPoint
        public var end: ProjectedPoint
        public var label: String
    }

    public struct ProjectedTick: Sendable, Equatable {
        public var point: ProjectedPoint
        public var label: String
        public var dx: Double
        public var dy: Double
    }

    /// Everything `renderPlot` draws. Cell, contour, axis and tick points
    /// are in the plot group's coordinates; `offsetX`/`offsetY` is its
    /// `translate(...)`. Cells and contours are in drawing order.
    public struct Scene: Sendable, Equatable {
        public var width: Double
        public var height: Double
        /// `projectionScale` after fitting the plot to the canvas.
        public var scale: Double
        /// The cost weight the surface was evaluated at.
        public var weight: Double
        public var offsetX: Double
        public var offsetY: Double
        public var cells: [Cell]
        public var contours: [ContourSegment]
        public var axes: [ProjectedAxis]
        public var ticks: [ProjectedTick]

        /// The cell under a canvas point: the topmost (last drawn) one, as
        /// the SVG's hover picks it.
        public func cell(atX x: Double, y: Double) -> Cell? {
            let px = x - offsetX
            let py = y - offsetY
            return cells.last { $0.contains(x: px, y: py) }
        }

        /// `showSurfaceTooltip`'s placement for a 188 x 64 tooltip.
        public func tooltipOrigin(pointerX: Double, pointerY: Double) -> (x: Double, y: Double) {
            let x = Swift.min(width - 188 - 6, pointerX + 14)
            let y = Swift.min(height - 64 - 6, pointerY + 14)
            return (Swift.max(6, x), Swift.max(6, y))
        }
    }

    public struct RGB: Sendable, Equatable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
    }
}

extension DynamicDesiredRetentionPlot {
    /// d3-scale-chromatic's `interpolateViridis` ramp (256 colours).
    static let viridis: [RGB] = {
        let hex = "44015444025645045745055946075a46085c460a5d460b5e470d60470e6147106347116447136548146748166848176948186a481a6c481b6d481c6e481d6f481f70482071482173482374482475482576482677482878482979472a7a472c7a472d7b472e7c472f7d46307e46327e46337f463480453581453781453882443983443a83443b84433d84433e85423f854240864241864142874144874045884046883f47883f48893e49893e4a893e4c8a3d4d8a3d4e8a3c4f8a3c508b3b518b3b528b3a538b3a548c39558c39568c38588c38598c375a8c375b8d365c8d365d8d355e8d355f8d34608d34618d33628d33638d32648e32658e31668e31678e31688e30698e306a8e2f6b8e2f6c8e2e6d8e2e6e8e2e6f8e2d708e2d718e2c718e2c728e2c738e2b748e2b758e2a768e2a778e2a788e29798e297a8e297b8e287c8e287d8e277e8e277f8e27808e26818e26828e26828e25838e25848e25858e24868e24878e23888e23898e238a8d228b8d228c8d228d8d218e8d218f8d21908d21918c20928c20928c20938c1f948c1f958b1f968b1f978b1f988b1f998a1f9a8a1e9b8a1e9c891e9d891f9e891f9f881fa0881fa1881fa1871fa28720a38620a48621a58521a68522a78522a88423a98324aa8325ab8225ac8226ad8127ad8128ae8029af7f2ab07f2cb17e2db27d2eb37c2fb47c31b57b32b67a34b67935b77937b87838b9773aba763bbb753dbc743fbc7340bd7242be7144bf7046c06f48c16e4ac16d4cc26c4ec36b50c46a52c56954c56856c66758c7655ac8645cc8635ec96260ca6063cb5f65cb5e67cc5c69cd5b6ccd5a6ece5870cf5773d05675d05477d1537ad1517cd2507fd34e81d34d84d44b86d54989d5488bd6468ed64590d74393d74195d84098d83e9bd93c9dd93ba0da39a2da37a5db36a8db34aadc32addc30b0dd2fb2dd2db5de2bb8de29bade28bddf26c0df25c2df23c5e021c8e020cae11fcde11dd0e11cd2e21bd5e21ad8e219dae319dde318dfe318e2e418e5e419e7e419eae51aece51befe51cf1e51df4e61ef6e620f8e621fbe723fde725"
        let bytes = Array(hex.utf8)
        return stride(from: 0, to: bytes.count, by: 6).map { start in
            func byte(_ offset: Int) -> UInt8 {
                UInt8(String(decoding: bytes[(start + offset)..<(start + offset + 2)], as: UTF8.self), radix: 16)!
            }
            return RGB(red: byte(0), green: byte(2), blue: byte(4))
        }
    }()
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
