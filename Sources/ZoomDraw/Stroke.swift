import AppKit
import CoreGraphics

enum DrawTool { case pen, rect, ellipse, arrow }

struct Stroke {
    var tool: DrawTool
    var color: NSColor
    var width: CGFloat
    var points: [NSPoint]   // pen 用
    var start: NSPoint      // rect/ellipse/arrow 用
    var end: NSPoint
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
        }
        ctx.restoreGState()
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
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4.0

    /// 处理快捷键，返回是否已消费
    func handleKey(chars: String) -> Bool {
        switch chars {
        case "1": color = .systemRed
        case "2": color = .systemYellow
        case "3": color = .systemGreen
        case "4": color = .systemBlue
        case "5": color = .white
        case "p": tool = .pen
        case "r": tool = .rect
        case "o": tool = .ellipse
        case "a": tool = .arrow
        case "[": lineWidth = max(1, lineWidth - 1)
        case "]": lineWidth = min(40, lineWidth + 1)
        default: return false
        }
        return true
    }

    var toolName: String {
        switch tool {
        case .pen: return "自由(P)"
        case .rect: return "矩形(R)"
        case .ellipse: return "椭圆(O)"
        case .arrow: return "箭头(A)"
        }
    }
}
