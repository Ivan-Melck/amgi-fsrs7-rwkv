//
//  DynamicDesiredRetentionPlotTests.swift
//  AnkiKitTests
//
//  The first suite ports the desktop's `dynamic-desired-retention.test.ts`.
//  The `DynamicDesiredRetentionReference` values were produced by running
//  the desktop's `dynamic-desired-retention.ts` and the `renderPlot`
//  geometry of `DynamicDesiredRetentionPlotModal.svelte` (with d3) in Node
//  on the fixtures below.
//

import Testing
@testable import AnkiKit

private typealias Policy = DynamicDesiredRetentionPolicy
private typealias Plot = DynamicDesiredRetentionPlot
private typealias Reference = DynamicDesiredRetentionReference

private func d(_ values: [Float]) -> [Double] { values.map(Double.init) }

private func close(_ lhs: Double?, _ rhs: Double?, _ tolerance: Double = 1e-9) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case let (l?, r?): abs(l - r) <= tolerance * max(1, abs(r))
    default: false
    }
}

private func close(_ lhs: Plot.ProjectedPoint, _ rhs: Plot.ProjectedPoint) -> Bool {
    close(lhs.x, rhs.x) && close(lhs.y, rhs.y) && close(lhs.depth, rhs.depth)
}

private func hex(_ rgb: Plot.RGB) -> String {
    "#" + [rgb.red, rgb.green, rgb.blue].map { byte in
        let text = String(byte, radix: 16)
        return text.count == 1 ? "0" + text : text
    }.joined()
}

/// The fixture the reference values were computed from (f32 values, as
/// the preset stores them).
private let fixture = FsrsDynamicDesiredRetention(
    params: [1.5, 2.0, -1.0, 0.5, -0.5, 0.2, 0.5, 0.3, -0.1, 0.2, -0.5, 0.3, 0.1, 0.2, -0.3],
    weights: [0, 4, 16, 64],
    avgDrs: [0.93, 0.9, 0.86, 0.8],
    minimum: 0.75,
    maximum: 0.95,
    fsrsEqWeights: [0, 4, 16, 64],
    fsrsEqDrs: [0.94, 0.91, 0.87, 0.82]
)

private let wideFixture = FsrsDynamicDesiredRetention(
    params: [0.5, 4.0, -3.0, 1.5, -2.0, 0.8, 1.0, 0.6, -0.4, 0.5, -1.0, 0.6, 0.3, 0.4, -0.6],
    weights: [0, 4, 16, 64],
    avgDrs: [0.93, 0.9, 0.86, 0.8],
    minimum: 0.3,
    maximum: 0.995,
    fsrsEqWeights: [0, 4, 16, 64],
    fsrsEqDrs: [0.94, 0.91, 0.87, 0.82]
)

// MARK: - dynamic-desired-retention.test.ts

@Suite struct DynamicDesiredRetentionPolicyTests {
    @Test func dynamic_desired_retention_requires_params_and_calibration() {
        let model = FsrsDynamicDesiredRetention(
            params: [], weights: [0, 15], avgDrs: [0.9, 0.8], minimum: 0.75, maximum: 0.95
        )
        #expect(!Policy.isEnabled(true, model: model))
    }

    @Test func cost_weight_interpolation_uses_log_weight() {
        let weight = Policy.costWeight(forTarget: 0.85, weights: [0, 15], drs: [0.9, 0.8])
        #expect(close(weight, 3, 1e-2))
    }

    @Test func target_calibration_prefers_fsrs_equivalent_values() {
        #expect(Policy.targetCalibration(
            avgWeights: [1, 2], avgDrs: [0.7, 0.8], fsrsEqWeights: [3, 4], fsrsEqDrs: [0.9, 0.95]
        ) == .init(weights: [3, 4], drs: [0.9, 0.95], label: "FSRS7 Eq. DR", fixedTarget: false))
    }

    @Test func target_calibration_prefers_fixed_target_values() {
        #expect(Policy.targetCalibration(
            avgWeights: [1, 2], avgDrs: [0.7, 0.8], fsrsEqWeights: [3, 4], fsrsEqDrs: [0.9, 0.95],
            fixedTargetWeights: [16, 4], fixedTargetDrs: [0.8, 0.9]
        ) == .init(weights: [16, 4], drs: [0.8, 0.9], label: "Fixed target DR", fixedTarget: true))
    }

    @Test func target_calibration_uses_average_adr_values_without_fsrs_equivalents() {
        #expect(Policy.targetCalibration(
            avgWeights: [1, 2], avgDrs: [0.7, 0.8], fsrsEqWeights: [], fsrsEqDrs: []
        ) == .init(weights: [1, 2], drs: [0.7, 0.8], label: "Avg ADR DR", fixedTarget: false))
    }

    @Test func fixed_target_cost_weight_uses_next_covered_point() {
        #expect(Policy.costWeight(forTarget: 0.79, weights: [64, 16], drs: [0.8, 0.9], fixedTarget: true) == 64)
        #expect(Policy.costWeight(forTarget: 0.85, weights: [64, 16], drs: [0.8, 0.9], fixedTarget: true) == 16)
        #expect(Policy.costWeight(forTarget: 0.91, weights: [64, 16], drs: [0.8, 0.9], fixedTarget: true) == nil)
    }

    @Test func scheduling_target_clamps_to_calibrated_range_when_enabled() {
        #expect(Policy.schedulingTarget(0.7, weights: [0, 15], drs: [0.9, 0.8], clampTarget: true) == 0.8)
        #expect(Policy.schedulingTarget(0.95, weights: [0, 15], drs: [0.9, 0.8], clampTarget: true) == 0.9)
        #expect(Policy.schedulingTarget(0.7, weights: [0, 15], drs: [0.9, 0.8], clampTarget: false) == 0.7)
        #expect(Policy.schedulingTarget(
            0.95, weights: [64, 16], drs: [0.8, 0.9], clampTarget: true, fixedTarget: true, retentionMin: 0.75
        ) == 0.9)
        #expect(Policy.schedulingTarget(
            0.7, weights: [64, 16], drs: [0.8, 0.9], clampTarget: true, fixedTarget: true, retentionMin: 0.75
        ) == 0.75)
    }

    @Test func policy_evaluation_stays_in_retention_range() {
        let value = Policy.evaluate(
            params: Array(repeating: 0, count: 15), stability: 10, difficulty: 5, costWeight: 64,
            retentionMin: 0.75, retentionMax: 0.95
        )
        #expect(value >= 0.75)
        #expect(value <= 0.95)
    }

    // MARK: Desktop reference values

    @Test func evaluate_matches_desktop() {
        let params = d(fixture.params)
        for row in Reference.evaluate {
            for (weight, expected) in zip([0.0, 3, 64, 2000], row.drs) {
                let value = Policy.evaluate(
                    params: params, stability: row.stability, difficulty: row.difficulty, costWeight: weight,
                    retentionMin: Double(fixture.minimum), retentionMax: Double(fixture.maximum)
                )
                #expect(close(value, expected), "S=\(row.stability) D=\(row.difficulty) w=\(weight)")
            }
        }
        #expect(close(Policy.evaluate(params: params, stability: 10, difficulty: 5, costWeight: 8), Reference.evaluateDefaultBounds))
    }

    @Test func cost_weight_matches_desktop() {
        for row in Reference.costWeight {
            let weight = Policy.costWeight(forTarget: row.target, weights: d(fixture.weights), drs: d(fixture.avgDrs))
            #expect(close(weight, row.weight), "target \(row.target)")
        }
        for row in Reference.costWeightFixed {
            let weight = Policy.costWeight(
                forTarget: row.target, weights: d([64, 16]), drs: d([0.8, 0.9]), fixedTarget: true, retentionMin: 0.75
            )
            #expect(weight == row.weight, "target \(row.target)")
        }
        #expect(Policy.costWeight(forTarget: .nan, weights: [0, 15], drs: [0.9, 0.8]) == nil)
    }

    @Test func ranges_and_scheduling_match_desktop() {
        let ranges = [
            Policy.supportedTargetRange(weights: d(fixture.weights), drs: d(fixture.avgDrs)),
            Policy.supportedTargetRange(weights: d([64, 16]), drs: d([0.8, 0.9]), fixedTarget: true, retentionMin: 0.75),
            Policy.supportedTargetRange(weights: d([64, 16]), drs: d([0.8, 0.9]), fixedTarget: true),
        ]
        for (range, expected) in zip(ranges, Reference.ranges) {
            #expect(range == .init(min: expected.min, max: expected.max))
        }
        for row in Reference.scheduling {
            #expect(Policy.schedulingTarget(
                row.target, weights: d(fixture.weights), drs: d(fixture.avgDrs), clampTarget: true
            ) == row.average)
            #expect(Policy.schedulingTarget(
                row.target, weights: d([64, 16]), drs: d([0.8, 0.9]), clampTarget: true, fixedTarget: true, retentionMin: 0.75
            ) == row.fixed)
        }
    }

    @Test func enabled_requires_a_valid_optional_calibration() {
        #expect(Policy.isEnabled(true, model: FsrsDynamicDesiredRetention(
            params: fixture.params, weights: fixture.weights, avgDrs: fixture.avgDrs,
            minimum: fixture.minimum, maximum: fixture.maximum
        )))
        #expect(!Policy.isEnabled(false, model: fixture))
        // A single FSRS-equivalent point is not a calibration.
        #expect(!Policy.isEnabled(true, model: FsrsDynamicDesiredRetention(
            params: fixture.params, weights: fixture.weights, avgDrs: fixture.avgDrs,
            minimum: fixture.minimum, maximum: fixture.maximum, fsrsEqWeights: [1], fsrsEqDrs: [0.9]
        )))
    }

    @Test func status_mirrors_fsrs_options() {
        let ready = Policy.status(enabled: true, clamp: false, model: fixture, effectiveDesiredRetention: 0.88)
        #expect(ready.ready)
        #expect(ready.warning.isEmpty)
        #expect(close(ready.weight, Reference.weightAt088))
        #expect(Policy.Status.formatBound(ready.retentionMin) == "75.0%")
        #expect(Policy.Status.formatBound(.nan) == "n/a")

        let outside = Policy.status(enabled: true, clamp: false, model: fixture, effectiveDesiredRetention: 0.97)
        #expect(!outside.ready)
        #expect(outside.weight == nil)
        #expect(outside.warning == "Dynamic DR target is outside the calibrated target range.")

        // Clamping moves the target to the calibrated maximum.
        let clamped = Policy.status(enabled: true, clamp: true, model: fixture, effectiveDesiredRetention: 0.97)
        #expect(clamped.ready)
        #expect(close(clamped.weight, Policy.costWeight(forTarget: Double(Float(0.94)), weights: d(fixture.fsrsEqWeights), drs: d(fixture.fsrsEqDrs))))

        let unfitted = Policy.status(enabled: true, clamp: false, model: .init(), effectiveDesiredRetention: 0.9)
        #expect(!unfitted.ready)
        #expect(unfitted.warning == "Dynamic DR requires 15 ADR policy parameters and matching calibration arrays.")

        var badBounds = fixture
        badBounds.minimum = 0.96
        #expect(Policy.status(enabled: true, clamp: false, model: badBounds, effectiveDesiredRetention: 0.9).warning
            == "Dynamic DR requires valid retention bounds.")

        #expect(Policy.status(enabled: false, clamp: false, model: .init(), effectiveDesiredRetention: 0.9).warning.isEmpty)

        // An unusable FSRS-equivalent calibration disables Dynamic DR
        // without the "outside the range" warning.
        var badEquivalents = fixture
        badEquivalents.fsrsEqWeights = [1]
        badEquivalents.fsrsEqDrs = [0.9]
        let disabled = Policy.status(enabled: true, clamp: false, model: badEquivalents, effectiveDesiredRetention: 0.97)
        #expect(!disabled.ready)
        #expect(disabled.weight == nil)
        #expect(disabled.warning.isEmpty)
    }

    @Test func sorting_is_stable_like_array_sort() {
        let sorted = Policy.stableSorted([(1, "a"), (0, "b"), (1, "c"), (0, "d")]) { $0.0 < $1.0 }
        #expect(sorted.map(\.1) == ["b", "d", "a", "c"])
        // Equal weights keep their order, so the first pair brackets 0.85.
        #expect(close(Policy.costWeight(forTarget: 0.85, weights: [4, 4, 16], drs: [0.9, 0.8, 0.7]), 4))
        #expect(close(Policy.costWeight(forTarget: 0.85, weights: [4, 4, 16], drs: [0.8, 0.9, 0.7]), 4))
        #expect(close(Policy.costWeight(forTarget: 0.75, weights: [16, 4, 4], drs: [0.7, 0.9, 0.8]), 8.219544457292889))
    }

    @Test func to_fixed_matches_javascript() {
        for row in Reference.toFixed {
            #expect(Policy.toFixed(row.value, row.digits) == row.text, "\(row.value).toFixed(\(row.digits))")
        }
    }
}

// MARK: - DynamicDesiredRetentionPlotModal.svelte

@Suite struct DynamicDesiredRetentionPlotTests {
    @Test func selector_and_inferred_weight_match_desktop() {
        let plot = Plot(model: fixture)
        #expect(plot.targetCalibration.label == Reference.selector.2)
        #expect(plot.selectorRange == .init(min: Reference.selector.0, max: Reference.selector.1))
        #expect(close(plot.inferredWeight(target: 0.88), Reference.weightAt088))
        #expect(plot.canPlot(weight: plot.inferredWeight(target: 0.88)))
        #expect(!plot.canPlot(weight: plot.inferredWeight(target: 0.97)))
        #expect(plot.draftTarget(0.99) == Reference.selector.1)
        #expect(plot.draftTarget(0.5) == Reference.selector.0)
        #expect(plot.draftTarget(.nan) == nil)
    }

    @Test func selector_without_target_calibration_is_disabled() {
        let plot = Plot(params: d(fixture.params), calibrationWeights: [1], calibrationAvgDrs: [0.9])
        #expect(!plot.hasTargetCalibration)
        #expect(plot.selectorRange == .init(min: 0, max: 1))
        #expect(plot.scene(width: 600, height: 600, yaw: -42, pitch: 24, weight: 1) == nil)
    }

    @Test func fixed_target_selector_starts_at_retention_min() {
        var model = fixture
        model.fixedTargetWeights = [64, 16]
        model.fixedTargetDrs = [0.8, 0.9]
        let plot = Plot(model: model)
        #expect(plot.targetCalibration.label == "Fixed target DR")
        #expect(plot.selectorRange == .init(min: Double(Float(0.75)), max: Double(Float(0.9))))
        #expect(plot.inferredWeight(target: 0.76) == 64)
    }

    @Test func scene_matches_desktop() {
        let plot = Plot(model: fixture)
        let weight = plot.inferredWeight(target: 0.88)
        let scene = try! #require(plot.scene(width: 600, height: 600, yaw: Plot.defaultYaw, pitch: Plot.defaultPitch, weight: weight))
        expect(scene, plot: plot, matches: Reference.scene600)
    }

    @Test func rotated_scene_matches_desktop() {
        let rotated = Plot.rotated(yaw: Plot.defaultYaw, pitch: Plot.defaultPitch, dx: 120, dy: -200)
        #expect(close(rotated.yaw, Reference.rotated.0))
        #expect(rotated.pitch == Reference.rotated.1)
        let plot = Plot(model: fixture)
        let scene = try! #require(plot.scene(
            width: 390, height: 500, yaw: rotated.yaw, pitch: rotated.pitch, weight: plot.inferredWeight(target: 0.88)
        ))
        expect(scene, plot: plot, matches: Reference.sceneRotated390x500)
    }

    @Test func wide_scene_matches_desktop() {
        let plot = Plot(model: wideFixture)
        let scene = try! #require(plot.scene(width: 860, height: 560, yaw: Plot.defaultYaw, pitch: Plot.defaultPitch, weight: 2.5))
        expect(scene, plot: plot, matches: Reference.sceneWide860x560)
    }

    @Test func contour_levels_match_desktop() {
        for row in Reference.levels {
            var model = fixture
            model.minimum = row.min
            model.maximum = row.max
            #expect(Plot(model: model).contourLevels() == row.levels)
        }
    }

    @Test func contour_through_a_corner_is_deduplicated() {
        func corner(_ x: Double, _ y: Double, _ dr: Double) -> Plot.SurfacePoint {
            .init(x: x, y: y, z: 0, stability: 1, difficulty: 1, dr: dr)
        }
        let corners = [corner(0, 0, 0.8), corner(1, 0, 0.9), corner(1, 1, 0.9), corner(0, 1, 0.7)]
        let points = Plot.contourIntersections(corners, level: 0.8)
        #expect(points.count == 2)
        #expect(points[0].x == 0 && points[0].y == 0)
        #expect(close(points[1].x, 0.5) && points[1].y == 1)
        #expect(points.allSatisfy { $0.dr == 0.8 })
    }

    @Test func percent_input_parses_like_number() {
        for row in Reference.parse {
            let value = Plot.parsePercentInput(row.text)
            if let expected = row.value {
                #expect(close(value, expected), "\(row.text)")
            } else {
                #expect(value.isNaN, "\(row.text)")
            }
        }
    }

    @Test func formatting_matches_modal() {
        #expect(Plot.formatWeight(nil) == "n/a")
        #expect(Plot.formatWeight(8.219543112294772) == "8.22")
        #expect(Plot.formatPercent(0.8725, digits: 2) == "87.25%")
        #expect(Plot.formatStability(99.996) == "100.0 d")
        #expect(Plot.formatStability(9.999) == "10.00 d")
    }

    @Test func hit_test_picks_topmost_cell_and_tooltip_is_clamped() {
        let plot = Plot(model: fixture)
        let scene = try! #require(plot.scene(width: 600, height: 600, yaw: -42, pitch: 24, weight: 8))
        let top = try! #require(scene.cells.last)
        let cx = top.points.map(\.x).reduce(0, +) / 4 + scene.offsetX
        let cy = top.points.map(\.y).reduce(0, +) / 4 + scene.offsetY
        #expect(scene.cell(atX: cx, y: cy) == top)
        #expect(scene.cell(atX: -50, y: -50) == nil)
        let origin = scene.tooltipOrigin(pointerX: 590, pointerY: 0)
        #expect(origin.x == 600 - 188 - 6)
        #expect(origin.y == 14)
        #expect(scene.tooltipOrigin(pointerX: -100, pointerY: -100) == (6, 6))
    }

    @Test func hit_test_prefers_the_cell_drawn_last() {
        func square(_ row: Int, _ origin: Double, depth: Double) -> Plot.Cell {
            let points = [(0.0, 0.0), (10, 0), (10, 10), (0, 10)].map {
                Plot.ProjectedPoint(x: origin + $0.0, y: origin + $0.1, depth: depth)
            }
            return Plot.Cell(row: row, column: 0, points: points, depth: depth, dr: 0.9, stability: 1, difficulty: 1)
        }
        let scene = Plot.Scene(
            width: 100, height: 100, scale: 1, weight: 1, offsetX: 20, offsetY: 20,
            cells: [square(0, 0, depth: 0), square(1, 5, depth: 1)],
            contours: [], axes: [], ticks: []
        )
        #expect(scene.cell(atX: 28, y: 28)?.row == 1)
        #expect(scene.cell(atX: 22, y: 22)?.row == 0)
        #expect(scene.cell(atX: 2, y: 2) == nil)
    }

    private func expect(_ scene: Plot.Scene, plot: Plot, matches reference: Reference.SceneReference) {
        #expect(close(scene.scale, reference.scale))
        #expect(close(scene.offsetX, reference.offsetX))
        #expect(close(scene.offsetY, reference.offsetY))
        #expect(scene.cells.count == reference.cellCount)
        #expect(scene.contours.count == reference.contourCount)
        let levels = plot.contourLevels()
        #expect(levels.map { level in scene.contours.filter { $0.level == level }.count } == reference.contourLevelCounts)

        // The drawing order (depth sort) of the 33 x 23 grid cells.
        let order = scene.cells.map { $0.row * 33 + $0.column }
        #expect(Array(order.prefix(8)) == reference.orderHead)
        #expect(Array(order.suffix(8)) == reference.orderTail)
        #expect(order.enumerated().reduce(0) { $0 + ($1.offset + 1) * $1.element } == reference.orderHash)

        let surface = plot.surface(weight: scene.weight)
        for (point, expected) in zip([surface[0][0], surface[11][17], surface[23][33]], reference.surface) {
            #expect(close(point.stability, expected.stability) && close(point.difficulty, expected.difficulty))
            #expect(close(point.dr, expected.dr) && close(point.z, expected.z))
        }
        for sample in reference.cells {
            let cell = scene.cells[sample.index]
            #expect(close(cell.points[0], sample.first), "cell \(sample.index)")
            #expect(close(cell.depth, sample.depth))
            #expect(close(cell.dr, sample.dr))
            #expect(close(cell.stability, sample.stability))
            #expect(close(cell.difficulty, sample.difficulty))
            #expect(hex(plot.color(cell.dr)) == sample.color)
            #expect(Plot.tooltipRows(cell) == sample.rows)
        }
        for sample in reference.contours {
            let contour = scene.contours[sample.index]
            #expect(close(contour.start, sample.start), "contour \(sample.index)")
            #expect(close(contour.end, sample.end))
            #expect(close(contour.depth, sample.depth))
            #expect(contour.level == sample.level)
        }
        #expect(scene.axes.count == reference.axes.count)
        for (axis, expected) in zip(scene.axes, reference.axes) {
            #expect(close(axis.start, expected.start) && close(axis.end, expected.end) && axis.label == expected.label)
        }
        #expect(scene.ticks.count == reference.ticks.count)
        for (tick, expected) in zip(scene.ticks, reference.ticks) {
            #expect(close(tick.point, expected.point), "tick \(expected.label)")
            #expect(tick.label == expected.label && tick.dx == expected.dx && tick.dy == expected.dy)
        }
        let legend = plot.legendStops()
        #expect(legend.map(\.location) == reference.legend.map(\.location))
        #expect(legend.map { hex($0.color) } == reference.legend.map(\.color))
    }
}
