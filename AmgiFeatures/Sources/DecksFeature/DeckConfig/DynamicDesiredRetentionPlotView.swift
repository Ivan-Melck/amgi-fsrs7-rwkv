//
//  DynamicDesiredRetentionPlotView.swift
//  DecksFeature
//

import AnkiKit
import SwiftUI
import Theme

/// Port of the desktop's `DynamicDesiredRetentionPlotModal.svelte`: the
/// ADR policy's DR surface over stability and difficulty for the cost
/// weight of the chosen target DR, rotated by dragging, with the cell under
/// the pointer (or a tap) read out, and "Save DR" to use the target. The
/// surface is a projected 3D mesh, which Swift Charts can't draw before
/// iOS 26, so it is drawn on a `Canvas` from `DynamicDesiredRetentionPlot`.
struct DynamicDesiredRetentionPlotView: View {
    let plot: DynamicDesiredRetentionPlot
    /// The modal's `targetAverageDr`: the desired retention the page shows.
    let targetAverageDr: Double
    let onSaveTarget: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var draftTargetDr: Double
    @State private var targetText: String
    @State private var yaw = DynamicDesiredRetentionPlot.defaultYaw
    @State private var pitch = DynamicDesiredRetentionPlot.defaultPitch
    @State private var lastDragTranslation: CGSize?
    @State private var selection: Selection?
    @FocusState private var targetFieldFocused: Bool

    /// The tooltip: a cell and where it was picked.
    private struct Selection {
        var cell: DynamicDesiredRetentionPlot.Cell
        var location: CGPoint
    }

    init(plot: DynamicDesiredRetentionPlot, targetAverageDr: Double, onSaveTarget: @escaping (Double) -> Void) {
        self.plot = plot
        self.targetAverageDr = targetAverageDr
        self.onSaveTarget = onSaveTarget
        _draftTargetDr = State(initialValue: targetAverageDr)
        _targetText = State(initialValue: DynamicDesiredRetentionPlot.formatPercent(targetAverageDr, digits: 2))
    }

    private var inferredWeight: Double? { plot.inferredWeight(target: draftTargetDr) }
    private var canPlot: Bool { plot.canPlot(weight: inferredWeight) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                controls
                plotArea
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(palette.background)
            .navigationTitle("Dynamic DR Plot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // `syncedTargetDr`: a saved target becomes the new draft.
        .onChange(of: targetAverageDr) { _, newValue in
            draftTargetDr = newValue
        }
        .onChange(of: draftTargetDr) { _, newValue in
            targetText = DynamicDesiredRetentionPlot.formatPercent(newValue, digits: 2)
            selection = nil
        }
        .onChange(of: targetFieldFocused) { _, focused in
            if !focused { applyTargetText() }
        }
    }

    // MARK: - Controls (`plot-meta`)

    private var controls: some View {
        let range = sliderRange
        let hasCalibration = plot.hasTargetCalibration
        let selector = plot.selectorRange
        let canSlide = hasCalibration && selector.max > selector.min
        return VStack(alignment: .leading, spacing: 8) {
            Text("Target \(plot.targetCalibration.label)")
                .amgiFont(.body)
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { min(range.upperBound, max(range.lowerBound, draftTargetDr)) },
                        set: { setDraftTargetDr($0) }
                    ),
                    in: range,
                    step: 0.001
                )
                .disabled(!canSlide)
                TextField("", text: $targetText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .focused($targetFieldFocused)
                    .onSubmit { applyTargetText() }
                    .disabled(!hasCalibration)
            }
            HStack {
                Text("Weight: \(DynamicDesiredRetentionPlot.formatWeight(inferredWeight))")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Button("Save DR") {
                    if canPlot { onSaveTarget(draftTargetDr) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canPlot)
            }
        }
    }

    /// The range input's `selectorMin`...`selectorMax`, widened when empty
    /// (the slider is then disabled) since `ClosedRange` can't be.
    private var sliderRange: ClosedRange<Double> {
        let range = plot.selectorRange
        guard range.min.isFinite, range.max.isFinite else { return 0...1 }
        return range.min...max(range.max, range.min + 0.001)
    }

    /// `setDraftTargetDr`.
    private func setDraftTargetDr(_ value: Double) {
        if let target = plot.draftTarget(value) {
            draftTargetDr = target
        }
    }

    /// The text field's `on:change`; the field then shows the draft.
    private func applyTargetText() {
        setDraftTargetDr(DynamicDesiredRetentionPlot.parsePercentInput(targetText))
        targetText = DynamicDesiredRetentionPlot.formatPercent(draftTargetDr, digits: 2)
    }

    // MARK: - Plot

    private var plotArea: some View {
        GeometryReader { geometry in
            let scene = plot.scene(
                width: geometry.size.width,
                height: geometry.size.height,
                yaw: yaw,
                pitch: pitch,
                weight: inferredWeight
            )
            ZStack(alignment: .topLeading) {
                if let scene {
                    let surfacePlot = self.plot
                    let foreground = palette.textPrimary
                    Canvas { context, _ in
                        Self.draw(scene, plot: surfacePlot, foreground: foreground, in: &context)
                    }
                    if let selection {
                        tooltip(for: selection, in: scene)
                    }
                } else {
                    Text("Dynamic DR policy and calibration are required.")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(rotationGesture)
            .onTapGesture { location in
                select(at: location, in: scene)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    select(at: location, in: scene)
                default:
                    selection = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Dynamic DR plot")
            .accessibilityValue("Weight \(DynamicDesiredRetentionPlot.formatWeight(inferredWeight))")
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 680)
    }

    /// The SVG's drag: yaw follows x, pitch follows y.
    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let last = lastDragTranslation ?? CGSize(width: 0, height: 0)
                let rotated = DynamicDesiredRetentionPlot.rotated(
                    yaw: yaw,
                    pitch: pitch,
                    dx: value.translation.width - last.width,
                    dy: value.translation.height - last.height
                )
                yaw = rotated.yaw
                pitch = rotated.pitch
                lastDragTranslation = value.translation
                selection = nil
            }
            .onEnded { _ in
                lastDragTranslation = nil
            }
    }

    private func select(at location: CGPoint, in scene: DynamicDesiredRetentionPlot.Scene?) {
        guard let cell = scene?.cell(atX: location.x, y: location.y) else {
            selection = nil
            return
        }
        selection = Selection(cell: cell, location: location)
    }

    /// `showSurfaceTooltip`.
    private func tooltip(for selection: Selection, in scene: DynamicDesiredRetentionPlot.Scene) -> some View {
        let origin = scene.tooltipOrigin(pointerX: selection.location.x, pointerY: selection.location.y)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(DynamicDesiredRetentionPlot.tooltipRows(selection.cell), id: \.self) { row in
                Text(row)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 188, height: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255).opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.28), lineWidth: 1))
        )
        .offset(x: origin.x, y: origin.y)
        .allowsHitTesting(false)
    }

    // MARK: - Drawing (`renderPlot`)

    private nonisolated static func draw(
        _ scene: DynamicDesiredRetentionPlot.Scene,
        plot: DynamicDesiredRetentionPlot,
        foreground: Color,
        in context: inout GraphicsContext
    ) {
        var plotContext = context
        plotContext.translateBy(x: scene.offsetX, y: scene.offsetY)

        for cell in scene.cells {
            var path = Path()
            path.addLines(cell.points.map { CGPoint(x: $0.x, y: $0.y) })
            path.closeSubpath()
            plotContext.fill(path, with: .color(swiftUIColor(plot.color(cell.dr))))
            plotContext.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 0.35)
        }

        var contours = Path()
        for segment in scene.contours {
            contours.move(to: CGPoint(x: segment.start.x, y: segment.start.y))
            contours.addLine(to: CGPoint(x: segment.end.x, y: segment.end.y))
        }
        plotContext.stroke(
            contours,
            with: .color(.white.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )

        for axis in scene.axes {
            var line = Path()
            line.move(to: CGPoint(x: axis.start.x, y: axis.start.y))
            line.addLine(to: CGPoint(x: axis.end.x, y: axis.end.y))
            plotContext.stroke(line, with: .color(foreground), lineWidth: 1.2)
            plotContext.draw(
                Text(axis.label).font(.system(size: 12)).foregroundStyle(foreground),
                at: CGPoint(x: axis.end.x, y: axis.end.y),
                anchor: .bottomLeading
            )
        }

        for tick in scene.ticks {
            plotContext.draw(
                Text(tick.label).font(.system(size: 10)).foregroundStyle(foreground),
                at: CGPoint(x: tick.point.x + tick.dx, y: tick.point.y + tick.dy),
                anchor: .bottom
            )
        }

        drawLegend(scene, plot: plot, foreground: foreground, in: &context)
    }

    /// `drawLegend`: the colour scale across the retention bounds.
    private nonisolated static func drawLegend(
        _ scene: DynamicDesiredRetentionPlot.Scene,
        plot: DynamicDesiredRetentionPlot,
        foreground: Color,
        in context: inout GraphicsContext
    ) {
        let legendWidth = 180.0
        let legendHeight = 10.0
        let x = scene.width - legendWidth - 28
        let y = 24.0
        let rect = CGRect(x: x, y: y, width: legendWidth, height: legendHeight)
        let stops = plot.legendStops().map { Gradient.Stop(color: swiftUIColor($0.color), location: $0.location) }
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: stops),
                startPoint: CGPoint(x: rect.minX, y: rect.midY),
                endPoint: CGPoint(x: rect.maxX, y: rect.midY)
            )
        )
        context.draw(
            Text(DynamicDesiredRetentionPlot.formatPercent(plot.retentionMin)).font(.system(size: 12)).foregroundStyle(foreground),
            at: CGPoint(x: x, y: y - 6),
            anchor: .bottomLeading
        )
        context.draw(
            Text(DynamicDesiredRetentionPlot.formatPercent(plot.retentionMax)).font(.system(size: 12)).foregroundStyle(foreground),
            at: CGPoint(x: x + legendWidth, y: y - 6),
            anchor: .bottomTrailing
        )
    }

    private nonisolated static func swiftUIColor(_ rgb: DynamicDesiredRetentionPlot.RGB) -> Color {
        Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    DynamicDesiredRetentionPlotView(
        plot: DynamicDesiredRetentionPlot(
            params: [0.5, 4.0, -3.0, 1.5, -2.0, 0.8, 1.0, 0.6, -0.4, 0.5, -1.0, 0.6, 0.3, 0.4, -0.6],
            calibrationWeights: [0, 4, 16, 64],
            calibrationAvgDrs: [0.93, 0.9, 0.86, 0.8],
            retentionMin: 0.3,
            retentionMax: 0.995
        ),
        targetAverageDr: 0.9,
        onSaveTarget: { _ in }
    )
}
#endif
