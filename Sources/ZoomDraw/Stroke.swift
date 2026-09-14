import AppKit
import CoreGraphics

enum DrawTool { case pen, rect, ellipse, arrow, mosaic, text }

struct Stroke {
    var tool: DrawTool
    var color: NSColor
    var width: CGFloat
    var points: [NSPoint]   // pen / mosaic 用
    var start: NSPoint      // rect/ellipse/arrow/text 用
    var end: NSPoint
    var text: String = ""   // text 用

    /// 文字工具的字号（随笔触联动）
    var fontSize: CGFloat { max(13, width * 4.5) }
}

enum StrokeRenderer {
    static func draw(_ s: Stroke, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(s.color.cgColor)
        ctx.setFillColor(s.color.cgColor)
        ctx.setLineWidth(s.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch s.tool {
        case .pen:
            if s.points.count > 1 {
                ctx.move(to: s.points[0])
                for p in s.points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            } else if s.points.count == 1 {
                let p = s.points[0]
                let r = max(1, s.width / 2)
                ctx.fillEllipse(in: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        case .rect:
            let r = NSRect(x: min(s.start.x, s.end.x), y: min(s.start.y, s.end.y),
                           width: abs(s.end.x - s.start.x), height: abs(s.end.y - s.start.y))
            ctx.stroke(r)
        case .ellipse:
            let r = NSRect(x: min(s.start.x, s.end.x), y: min(s.start.y, s.end.y),
                           width: abs(s.end.x - s.start.x), height: abs(s.end.y - s.start.y))
            ctx.strokeEllipse(in: r)
        case .arrow:
            drawArrow(from: s.start, to: s.end, width: s.width, ctx: ctx)
        case .mosaic:
            break   // 由持有原图的视图单独渲染
        case .text:
            drawText(s)
        }
        ctx.restoreGState()
    }

    /// 文字渲染（需要当前存在 NSGraphicsContext）
    static func drawText(_ s: Stroke) {
        guard !s.text.isEmpty else { return }
        let attrs = textAttributes(color: s.color, size: s.fontSize)
        (s.text as NSString).draw(at: s.start, withAttributes: attrs)
    }

    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
            .shadow: shadow
        ]
    }

    static func textSize(_ s: Stroke) -> NSSize {
        let str = s.text.isEmpty ? " " : s.text
        return (str as NSString).size(withAttributes: textAttributes(color: s.color, size: s.fontSize))
    }

    private static func drawArrow(from p1: NSPoint, to p2: NSPoint, width: CGFloat, ctx: CGContext) {
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let head = max(12, width * 3)
        let angle = atan2(dy, dx)
        let a1 = angle + .pi - .pi / 7
        let a2 = angle + .pi + .pi / 7
        let h1 = NSPoint(x: p2.x + cos(a1) * head, y: p2.y + sin(a1) * head)
        let h2 = NSPoint(x: p2.x + cos(a2) * head, y: p2.y + sin(a2) * head)
        ctx.move(to: p2); ctx.addLine(to: h1)
        ctx.move(to: p2); ctx.addLine(to: h2)
        ctx.strokePath()
    }
}

/// 工具状态容器 —— 让 ZoomView 与 DrawView 共享同一份"当前工具/颜色/笔触"
final class DrawToolState {
    var tool: DrawTool = .pen
    private(set) var colorIndex: Int = 0
    var lineWidth: CGFloat = 4.0

    static let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    private static let names: [String] = ["红", "黄", "绿", "蓝", "白", "黑"]

    var color: NSColor { Self.palette[colorIndex] }
    var colorName: String { Self.names[colorIndex] }

    func setColorIndex(_ i: Int) {
        colorIndex = max(0, min(Self.palette.count - 1, i))
    }

    /// 处理快捷键，返回是否已消费
    func handleKey(chars: String) -> Bool {
        switch chars {
        case "1": colorIndex = 0
        case "2": colorIndex = 1
        case "3": colorIndex = 2
        case "4": colorIndex = 3
        case "5": colorIndex = 4
        case "a": tool = .pen
        case "b": tool = .rect
        case "c": tool = .ellipse
        case "d": tool = .arrow
        case "[": lineWidth = max(1, lineWidth - 1)
        case "]": lineWidth = min(40, lineWidth + 1)
        default: return false
        }
        return true
    }

    /// 带按键提示的名称（用于独立画笔工具栏）
    var toolName: String {
        switch tool {
        case .pen: return "自由(A)"
        case .rect: return "矩形(B)"
        case .ellipse: return "椭圆(C)"
        case .arrow: return "箭头(D)"
        case .mosaic: return "马赛克(M)"
        case .text: return "文字(T)"
        }
    }

    /// 不带按键提示的名称（用于放大 HUD 头部）
    var toolShortName: String {
        switch tool {
        case .pen: return "自由画笔"
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        }
    }
}
