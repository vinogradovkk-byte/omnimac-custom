import SwiftUI

/// Контур «тануки» GitLab (лисья голова) для иконки вкладки: рисуется линией, как в боковой панели VS Code.
struct GitLabLogo: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0.5, 0.96), (0.02, 0.50), (0.15, 0.06), (0.32, 0.46), (0.68, 0.46), (0.85, 0.06), (0.98, 0.50)]
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

struct GitLabLogoView: View {
    var lineWidth: CGFloat = 1.5
    var body: some View {
        GitLabLogo().stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)).aspectRatio(1, contentMode: .fit)
    }
}
