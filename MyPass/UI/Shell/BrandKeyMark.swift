import SwiftUI

struct BrandKeyShape: Shape {
    var teethOnLeft: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        let headCenterX = w * (teethOnLeft ? 0.54 : 0.46)
        let headCenterY = h * 0.21
        let outerRadius = min(w, h) * 0.21
        let innerRadius = outerRadius * 0.36

        path.addEllipse(in: CGRect(
            x: headCenterX - outerRadius,
            y: headCenterY - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))

        path.addEllipse(in: CGRect(
            x: headCenterX - innerRadius,
            y: headCenterY - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))

        let shaftWidth = w * 0.17
        let shaftX = headCenterX - shaftWidth / 2
        let shaftTop = headCenterY + outerRadius * 0.55
        let shaftBottom = h * 0.88
        let tipRadius = shaftWidth * 0.25

        path.addRoundedRect(
            in: CGRect(x: shaftX, y: shaftTop, width: shaftWidth, height: shaftBottom - shaftTop),
            cornerSize: CGSize(width: tipRadius, height: tipRadius),
            style: .continuous
        )

        let toothHeight = shaftWidth * 0.32
        let toothWidth = w * 0.14
        let toothGap = toothHeight * 0.28
        let shaftLength = shaftBottom - shaftTop
        let firstToothY = shaftTop + shaftLength * 0.38

        for index in 0..<3 {
            let toothY = firstToothY + CGFloat(index) * (toothHeight + toothGap)
            path.addPath(blockyTooth(
                x: teethOnLeft ? shaftX - toothWidth : shaftX + shaftWidth,
                y: toothY,
                width: toothWidth,
                height: toothHeight,
                pointingRight: !teethOnLeft
            ))
        }

        return path
    }

    private func blockyTooth(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        pointingRight: Bool
    ) -> Path {
        var tooth = Path()
        if pointingRight {
            tooth.move(to: CGPoint(x: x, y: y))
            tooth.addLine(to: CGPoint(x: x + width, y: y + height * 0.12))
            tooth.addLine(to: CGPoint(x: x + width, y: y + height * 0.88))
            tooth.addLine(to: CGPoint(x: x, y: y + height))
            tooth.closeSubpath()
        } else {
            tooth.move(to: CGPoint(x: x + width, y: y))
            tooth.addLine(to: CGPoint(x: x, y: y + height * 0.12))
            tooth.addLine(to: CGPoint(x: x, y: y + height * 0.88))
            tooth.addLine(to: CGPoint(x: x + width, y: y + height))
            tooth.closeSubpath()
        }
        return tooth
    }
}

enum BrandKeyStyle {
    case monochrome
    case brandGreen
}

struct BrandKeyMark: View {
    var size: CGFloat = 40
    var teethOnLeft: Bool = false
    var style: BrandKeyStyle = .monochrome

    /// Green sampled from AppIcon key (~ muted grass).
    static let brandGreen = Color(red: 0.45, green: 0.70, blue: 0.35)

    var body: some View {
        Group {
            switch style {
            case .monochrome:
                BrandKeyShape(teethOnLeft: teethOnLeft)
                    .fill(.foreground, style: FillStyle(eoFill: true))
            case .brandGreen:
                BrandKeyShape(teethOnLeft: teethOnLeft)
                    .fill(Self.brandGreen, style: FillStyle(eoFill: true))
            }
        }
        .frame(width: size * 0.55, height: size)
        .frame(width: size, height: size)
    }
}
