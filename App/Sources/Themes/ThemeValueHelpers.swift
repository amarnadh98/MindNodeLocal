import MapCore
import MapRender
import SwiftUI

// MARK: display names + with-helpers

extension NodeShape {
    var displayName: String {
        switch self {
        case .roundedRect: "Rounded Rect"
        case .pill: "Pill"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .square: "Square"
        case .hexagon: "Hexagon"
        case .octagon: "Octagon"
        case .cloud: "Cloud"
        case .diamond: "Diamond"
        case .underline: "Underline"
        case .none: "None"
        }
    }
}

extension BranchLineStyle {
    var displayName: String {
        switch self {
        case .curved: "Curved"
        case .tapered: "Tapered"
        case .straight: "Straight"
        case .elbow: "Elbow"
        case .none: "None"
        }
    }
}

extension ThemeLevelStyle {
    func with(
        shape: NodeShape? = nil, fill: ThemeFill? = nil, cornerRadius: Double? = nil,
        font: ThemeFont? = nil, textColor: String? = nil
    ) -> ThemeLevelStyle {
        ThemeLevelStyle(
            shape: shape ?? self.shape,
            fill: fill ?? self.fill,
            border: border,
            cornerRadius: cornerRadius ?? self.cornerRadius,
            paddingWidth: paddingWidth,
            paddingHeight: paddingHeight,
            shadow: shadow,
            font: font ?? self.font,
            textColor: textColor ?? self.textColor,
            maxWidth: maxWidth)
    }
}

extension ThemeFont {
    func with(size: Double? = nil, weight: Double? = nil) -> ThemeFont {
        var copy = self
        if let size { copy.size = size }
        if let weight { copy.weight = weight }
        return copy
    }
}

extension ThemeFill {
    enum FillKind {
        case none
        case solid
        case palette
    }

    var kind: FillKind {
        switch self {
        case .none: .none
        case .solid: .solid
        case .palette: .palette
        }
    }

    /// A `with` that preserves the previous fill's payload: switching
    /// Solid → Palette keeps a sensible alpha (0.16, Paper's level-1),
    /// Palette → Solid carries the first palette color in.
    init(kind: FillKind, previous: ThemeFill) {
        switch kind {
        case .none: self = .none
        case .solid:
            switch previous {
            case .solid(let hex): self = .solid(hex)
            default: self = .solid("#12A594")
            }
        case .palette:
            switch previous {
            case .palette(let alpha): self = .palette(alpha: alpha)
            default: self = .palette(alpha: 0.16)
            }
        }
    }
}

extension ThemeBranchStyle {
    func with(
        lineStyle: BranchLineStyle? = nil,
        startWidth: Double? = nil,
        endWidth: Double? = nil
    ) -> ThemeBranchStyle {
        var copy = self
        if let lineStyle { copy.lineStyle = lineStyle }
        if let startWidth { copy.startWidth = startWidth }
        if let endWidth { copy.endWidth = endWidth }
        return copy
    }
}

extension ThemeConnectionStyle {
    func with(
        color: String? = nil,
        width: Double? = nil,
        dash: Bool? = nil,
        arrowEnd: Bool? = nil
    ) -> ThemeConnectionStyle {
        var copy = self
        if let color { copy.color = color }
        if let width { copy.width = width }
        if let dash { copy.dash = dash }
        if let arrowEnd { copy.arrowEnd = arrowEnd }
        return copy
    }
}

extension ThemeBoundaryStyle {
    func with(
        strokeColor: String? = nil,
        fillColor: String? = nil,
        cornerRadius: Double? = nil,
        padding: Double? = nil
    ) -> ThemeBoundaryStyle {
        var copy = self
        if let strokeColor { copy.strokeColor = strokeColor }
        if let fillColor { copy.fillColor = fillColor }
        if let cornerRadius { copy.cornerRadius = cornerRadius }
        if let padding { copy.padding = padding }
        return copy
    }
}

extension ThemeLevelKey {
    var level: Int {
        switch self {
        case .root: 0
        case .level1: 1
        case .level2: 2
        case .level3Plus: 3
        }
    }
}

// MARK: property-form groups (F-STY-5: Canvas / Palette / Levels / Branches / Connections / Boundaries)

extension ThemeEditorView {
    var canvasGroup: some View {
        GroupBox("Canvas") {
            ColorField(
                label: "Canvas color",
                hex: model.scheme.canvasColor,
                onHex: { model.setCanvasColor($0) }
            )
            .padding(.vertical, 4)
        }
    }

    var paletteGroup: some View {
        GroupBox("Palette (\(model.scheme.palette.count) colors)") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.scheme.palette.indices, id: \.self) { index in
                    HStack {
                        Text("\(index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        ColorField(
                            label: "Palette color \(index + 1)",
                            hex: model.scheme.palette[index],
                            onHex: { model.setPaletteColor(at: index, hex: $0) }
                        )
                        Button(role: .destructive) {
                            model.removePaletteColor(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.scheme.palette.count <= 1)
                        .accessibilityLabel("Remove palette color \(index + 1)")
                    }
                }
                HStack {
                    Button("Add Color") { model.addPaletteColor() }
                        .disabled(model.scheme.palette.count >= 12)
                }
            }
            .padding(.vertical, 4)
        }
    }

    var levelsGroup: some View {
        GroupBox("Levels") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ThemeLevelKey.allCases) { key in
                    LevelStyleForm(
                        title: key.title,
                        style: model.scheme.levels.style(forLevel: key.level),
                        onStyle: { model.setLevel(key, $0) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    var branchGroup: some View {
        GroupBox("Branches") {
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "Line style",
                    selection: Binding(
                        get: { model.draft.branch.lineStyle },
                        set: { model.setBranch(model.draft.branch.with(lineStyle: $0)) }
                    )
                ) {
                    ForEach(BranchLineStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Stepper(
                    value: Binding(
                        get: { model.draft.branch.startWidth },
                        set: { model.setBranch(model.draft.branch.with(startWidth: $0)) }
                    ),
                    in: 1...12,
                    step: 0.5
                ) {
                    LabeledContent("Width at root", value: model.draft.branch.startWidth.formatted())
                }
                Stepper(
                    value: Binding(
                        get: { model.draft.branch.endWidth },
                        set: { model.setBranch(model.draft.branch.with(endWidth: $0)) }
                    ),
                    in: 0.5...8,
                    step: 0.5
                ) {
                    LabeledContent("Width at leaves", value: model.draft.branch.endWidth.formatted())
                }
                Toggle(
                    "Rainbow branches",
                    isOn: Binding(
                        get: { model.draft.rainbowBranches },
                        set: { model.setRainbowBranches($0) }
                    )
                )
                .help("Each level-1 branch takes the next palette color; off means every branch uses the first color.")
            }
            .padding(.vertical, 4)
        }
    }

    var connectionGroup: some View {
        GroupBox("Connections") {
            VStack(alignment: .leading, spacing: 8) {
                ColorField(
                    label: "Color",
                    hex: model.draft.connection.color,
                    onHex: {
                        model.setConnection(model.draft.connection.with(color: $0))
                    })
                Stepper(
                    value: Binding(
                        get: { model.draft.connection.width },
                        set: { model.setConnection(model.draft.connection.with(width: $0)) }
                    ),
                    in: 0.5...6,
                    step: 0.5
                ) {
                    LabeledContent("Width", value: model.draft.connection.width.formatted())
                }
                Toggle(
                    "Dashed",
                    isOn: Binding(
                        get: { model.draft.connection.dash },
                        set: { model.setConnection(model.draft.connection.with(dash: $0)) }
                    ))
                Toggle(
                    "Arrow at end",
                    isOn: Binding(
                        get: { model.draft.connection.arrowEnd },
                        set: { model.setConnection(model.draft.connection.with(arrowEnd: $0)) }
                    ))
            }
            .padding(.vertical, 4)
        }
    }

    var boundaryGroup: some View {
        GroupBox("Boundaries") {
            VStack(alignment: .leading, spacing: 8) {
                ColorField(
                    label: "Stroke",
                    hex: model.draft.boundary.strokeColor,
                    onHex: { model.setBoundary(model.draft.boundary.with(strokeColor: $0)) })
                ColorField(
                    label: "Fill",
                    hex: model.draft.boundary.fillColor,
                    onHex: { model.setBoundary(model.draft.boundary.with(fillColor: $0)) })
                Stepper(
                    value: Binding(
                        get: { model.draft.boundary.cornerRadius },
                        set: { model.setBoundary(model.draft.boundary.with(cornerRadius: $0)) }
                    ),
                    in: 0...40,
                    step: 1
                ) {
                    LabeledContent("Corner radius", value: Int(model.draft.boundary.cornerRadius).formatted())
                }
                Stepper(
                    value: Binding(
                        get: { model.draft.boundary.padding },
                        set: { model.setBoundary(model.draft.boundary.with(padding: $0)) }
                    ),
                    in: 0...48,
                    step: 1
                ) {
                    LabeledContent("Padding", value: Int(model.draft.boundary.padding).formatted())
                }
            }
            .padding(.vertical, 4)
        }
    }
}
