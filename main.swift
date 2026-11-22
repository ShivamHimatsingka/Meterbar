// Meterbar — a lightweight menu bar system monitor (AppKit + Core Graphics, no SwiftUI).
import Cocoa
import IOKit
import IOKit.ps
import SystemConfiguration
import ServiceManagement
import Darwin

// MARK: - Utilities

let hostPort = mach_host_self()
// VM statistics are counted in kernel pages. Use the kernel's page size (16 KB on Apple Silicon), not
// hw.pagesize, which reports 4 KB to an Intel binary running under Rosetta.
let pageSize = Double(vm_kernel_page_size)

func sysctlInt(_ name: String) -> Int {
    var v: Int64 = 0; var s = MemoryLayout<Int64>.size
    return sysctlbyname(name, &v, &s, nil, 0) == 0 ? Int(v) : 0
}
func sysctlString(_ name: String) -> String {
    var s = 0
    guard sysctlbyname(name, nil, &s, nil, 0) == 0, s > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: s)
    sysctlbyname(name, &buf, &s, nil, 0)
    return String(cString: buf)
}
func fmtBytes(_ b: Double, base: Double = 1024) -> String {
    let u = ["B", "KB", "MB", "GB", "TB", "PB"]; var v = max(0, b); var i = 0
    while v >= base && i < u.count - 1 { v /= base; i += 1 }
    if i == 0 { return "\(Int(v)) B" }
    return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, u[i])
}
func fmtSpeed(_ b: Double) -> String { fmtBytes(b, base: 1000) + "/s" }
func pct(_ v: Double) -> String { "\(Int((max(0, v) * 100).rounded()))%" }
func fmtDuration(_ secs: Int) -> String {
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    return d > 0 ? "\(d)d \(h)h \(m)m" : "\(h)h \(m)m"
}
func regProp(_ e: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

struct Ring {
    private(set) var buf: [Double]
    private var head = 0
    private(set) var count = 0
    var capacity: Int { buf.count }
    init(_ cap: Int) { buf = .init(repeating: 0, count: cap) }
    mutating func push(_ v: Double) {
        buf[head] = v; head = (head + 1) % buf.count
        if count < buf.count { count += 1 }
    }
    func tail(_ n: Int) -> [Double] {
        let k = min(n, count); var r = [Double](); r.reserveCapacity(k)
        for i in 0..<k { r.append(buf[(head - k + i + buf.count * 2) % buf.count]) }
        return r
    }
    var maxValue: Double { buf.max() ?? 0 }
}

// MARK: - Drawing

enum Draw {
    static func font(_ size: CGFloat, _ w: NSFont.Weight, _ mono: Bool) -> NSFont {
        mono ? .monospacedDigitSystemFont(ofSize: size, weight: w) : .systemFont(ofSize: size, weight: w)
    }
    private static var widthCache: [String: CGFloat] = [:]
    /// Cached text measurement (widget widths are measured from constant strings).
    static func width(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
        let k = "\(s)|\(size)|\(w.rawValue)|\(mono)"
        if let v = widthCache[k] { return v }
        let v = (s as NSString).size(withAttributes: [.font: font(size, w, mono)]).width
        if widthCache.count > 512 { widthCache.removeAll() }
        widthCache[k] = v
        return v
    }
    static func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor, mono: Bool = false, align: NSTextAlignment = .left, maxWidth: CGFloat = 0) {
        var str = s
        let attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight, mono), .foregroundColor: color]
        var sz = (str as NSString).size(withAttributes: attrs)
        if maxWidth > 0 && sz.width > maxWidth {
            while str.count > 1 && sz.width > maxWidth { str.removeLast(); sz = ((str + "…") as NSString).size(withAttributes: attrs) }
            str += "…"
        }
        var px = x
        if align == .right { px -= sz.width } else if align == .center { px -= sz.width / 2 }
        (str as NSString).draw(at: NSPoint(x: px, y: y), withAttributes: attrs)
    }
    static var flipped: Bool { NSGraphicsContext.current?.isFlipped ?? false }

    static func lineChart(_ v: [Double], in r: NSRect, max m: Double, color: NSColor, cap: Int, fill: Bool = true, lw: CGFloat = 1) {
        guard v.count > 1, m > 0 else { return }
        let fl = flipped
        let step = r.width / CGFloat(max(cap - 1, 1))
        let x0 = r.maxX - CGFloat(v.count - 1) * step
        func yv(_ x: Double) -> CGFloat {
            let f = CGFloat(min(max(x / m, 0), 1)) * r.height
            return fl ? r.maxY - f : r.minY + f
        }
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x0, y: yv(v[0])))
        for i in 1..<v.count { p.line(to: NSPoint(x: x0 + CGFloat(i) * step, y: yv(v[i]))) }
        if fill {
            let f = p.copy() as! NSBezierPath
            let by = fl ? r.maxY : r.minY
            f.line(to: NSPoint(x: r.maxX, y: by)); f.line(to: NSPoint(x: x0, y: by)); f.close()
            color.withAlphaComponent(0.3).setFill(); f.fill()
        }
        color.setStroke(); p.lineWidth = lw; p.stroke()
    }

    static func donut(_ c: NSPoint, r: CGFloat, w: CGFloat, parts: [(Double, NSColor)]) {
        let bg = NSBezierPath(); bg.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        bg.lineWidth = w; NSColor.labelColor.withAlphaComponent(0.1).setStroke(); bg.stroke()
        let fl = flipped
        var a: CGFloat = fl ? -90 : 90
        for (v, col) in parts where v > 0.002 {
            let d = CGFloat(min(v, 1)) * 360
            let e = fl ? a + d : a - d
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: a, endAngle: e, clockwise: !fl)
            p.lineWidth = w; col.setStroke(); p.stroke(); a = e
        }
    }
}

// MARK: - Menu bar widgets

enum W {
    /// Sized to what is shown: room for two digits ("99%"), growing only while a reading needs more
    /// (e.g. "100%"). macOS adds the user's NSStatusItemSpacing around every item, so no margins here.
    static func miniWidth(_ label: String, _ value: String = "", reserve: String = "99%") -> CGFloat {
        ceil(max(Draw.width(label, 7, .semibold), Draw.width(reserve, 11, .medium, mono: true),
                 Draw.width(value, 11, .medium, mono: true)))
    }
    static func mini(_ r: NSRect, _ label: String, _ value: String, color: NSColor = .labelColor) {
        Draw.text(label, x: 0, y: r.midY + 1.5, size: 7, weight: .semibold)
        Draw.text(value, x: 0, y: r.midY - 10.5, size: 11, weight: .medium, color: color, mono: true)
    }
    static func vlabel(_ r: NSRect, _ s: String) {
        let chars = Array(s); let lh: CGFloat = 6.4
        let top = r.midY + CGFloat(chars.count) * lh / 2
        for (i, ch) in chars.enumerated() {
            Draw.text(String(ch), x: 3.5, y: top - CGFloat(i + 1) * lh - 0.8, size: 6, weight: .bold, align: .center)
        }
    }
    static let lineWidth: CGFloat = 38
    static func line(_ r: NSRect, _ label: String, _ series: [([Double], NSColor)], max m: Double = 1) {
        vlabel(r, label)
        let box = NSRect(x: 8.5, y: r.midY - 8.5, width: r.width - 9.5, height: 17)
        let b = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2); b.lineWidth = 0.75
        NSColor.labelColor.withAlphaComponent(0.4).setStroke(); b.stroke()
        for (v, c) in series { Draw.lineChart(v, in: box.insetBy(dx: 1, dy: 1), max: m, color: c, cap: 30) }
    }
    static func barsWidth(_ n: Int) -> CGFloat { 9 + CGFloat(n) * 3 }
    static func bars(_ r: NSRect, _ label: String, _ vals: [Double], _ color: NSColor) {
        vlabel(r, label)
        let h: CGFloat = 17, y0 = r.midY - 8.5
        for (i, v) in vals.enumerated() {
            let x = 8.5 + CGFloat(i) * 3
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSRect(x: x, y: y0, width: 2, height: h).fill()
            color.setFill(); NSRect(x: x, y: y0, width: 2, height: max(1, h * CGFloat(min(max(v, 0), 1)))).fill()
        }
    }
    static let pieWidth: CGFloat = 20
    static func pie(_ r: NSRect, _ v: Double, _ color: NSColor) {
        let d: CGFloat = 16, c = NSPoint(x: r.midX, y: r.midY)
        let circle = NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        NSColor.labelColor.withAlphaComponent(0.15).setFill(); circle.fill()
        let p = NSBezierPath(); p.move(to: c)
        p.appendArc(withCenter: c, radius: d / 2, startAngle: 90, endAngle: 90 - CGFloat(min(max(v, 0), 1)) * 360, clockwise: true)
        p.close(); color.setFill(); p.fill()
    }
    static let speedWidth: CGFloat = ceil(Draw.width("↓ 999 KB/s", 9, .regular, mono: true))
    static func speed(_ r: NSRect, top: Double, bottom: Double, topSym: String = "↑", botSym: String = "↓",
                      topColor: NSColor = .systemRed, botColor: NSColor = .systemBlue) {
        let yt = r.midY - 0.5, yb = r.midY - 11
        Draw.text(topSym, x: 0, y: yt, size: 9, weight: .bold, color: top > 1000 ? topColor : .labelColor)
        Draw.text(botSym, x: 0, y: yb, size: 9, weight: .bold, color: bottom > 1000 ? botColor : .labelColor)
        Draw.text(fmtSpeed(top), x: r.width, y: yt, size: 9, mono: true, align: .right)
        Draw.text(fmtSpeed(bottom), x: r.width, y: yb, size: 9, mono: true, align: .right)
    }
    static func stack(_ r: NSRect, _ a: String, _ b: String) {
        Draw.text(a, x: r.width, y: r.midY - 0.5, size: 9, weight: .medium, mono: true, align: .right)
        Draw.text(b, x: r.width, y: r.midY - 11, size: 9, weight: .medium, mono: true, align: .right)
    }
    static func battery(_ r: NSRect, level: Double, charging: Bool, onAC: Bool, showPct: Bool) {
        var x: CGFloat = 0
        if showPct {
            let s = pct(level)
            Draw.text(s, x: x, y: r.midY - 7.5, size: 11, weight: .medium, mono: true)
            x += Draw.width(s, 11, .medium, mono: true) + 3
        }
        let body = NSRect(x: x + 0.5, y: r.midY - 5.5, width: 22, height: 11)
        let o = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3); o.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.55).setStroke(); o.stroke()
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: r.midY - 2, width: 1.5, height: 4), xRadius: 0.7, yRadius: 0.7).fill()
        var inner = body.insetBy(dx: 2, dy: 2)
        inner.size.width = max(1.5, inner.width * CGFloat(min(max(level, 0), 1)))
        (level < 0.2 && !onAC ? NSColor.systemRed : (charging ? NSColor.systemGreen : NSColor.labelColor)).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5).fill()
        if charging || onAC {
            let c = NSPoint(x: body.midX, y: body.midY)
            let p = NSBezierPath()
            for (dx, dy) in [(1.5, 6.5), (-3.5, -0.5), (-0.3, -0.5), (-1.5, -6.5), (3.5, 0.5), (0.3, 0.5)] as [(CGFloat, CGFloat)] {
                let pt = NSPoint(x: c.x + dx, y: c.y + dy)
                p.elementCount == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            p.close()
            NSColor.black.withAlphaComponent(0.6).setStroke(); p.lineWidth = 1.2; p.stroke()
            NSColor.white.setFill(); p.fill()
        }
    }
    static func batteryWidth(showPct: Bool, _ value: String = "") -> CGFloat {
        ceil(25 + (showPct ? max(Draw.width("99%", 11, .medium, mono: true), Draw.width(value, 11, .medium, mono: true)) + 3 : 0))
    }
}

// MARK: - Popup layout (flipped coordinates, also used for measuring)

final class Layout {
    var y: CGFloat = 10
    let w: CGFloat, dry: Bool, pad: CGFloat = 12
    init(w: CGFloat, dry: Bool) { self.w = w; self.dry = dry }
    var inner: CGFloat { w - pad * 2 }

    func title(_ s: String, _ sub: String? = nil) {
        if !dry {
            Draw.text(s, x: w / 2, y: y, size: 13, weight: .semibold, align: .center)
            if let sub { Draw.text(sub, x: w / 2, y: y + 17, size: 10, color: .secondaryLabelColor, align: .center, maxWidth: inner) }
        }
        y += sub == nil ? 24 : 36
    }
    func section(_ s: String) {
        y += 6
        if !dry {
            Draw.text(s, x: pad, y: y, size: 11, weight: .semibold, color: .secondaryLabelColor)
            NSColor.separatorColor.setFill(); NSRect(x: pad, y: y + 17, width: inner, height: 1).fill()
        }
        y += 23
    }
    func row(_ k: String, _ v: String, dot: NSColor? = nil, color: NSColor = .labelColor) {
        if !dry {
            var x = pad
            if let dot { dot.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y + 4.5, width: 7, height: 7)).fill(); x += 13 }
            let vw = Draw.width(v, 11.5, .medium, mono: true)
            Draw.text(k, x: x, y: y, size: 11.5, maxWidth: w - pad - x - vw - 8)
            Draw.text(v, x: w - pad, y: y, size: 11.5, weight: .medium, color: color, mono: true, align: .right)
        }
        y += 17
    }
    func chart(_ series: [(Ring, NSColor)], max m: Double? = nil, stacked: Bool = false, h: CGFloat = 64, legend: String? = nil) {
        if !dry {
            let r = NSRect(x: pad, y: y, width: inner, height: h)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            var data: [([Double], NSColor)] = []
            var acc: [Double]? = nil
            for (ring, c) in series {
                var v = ring.tail(ring.capacity)
                if stacked, let a = acc, a.count == v.count { v = zip(v, a).map(+) }
                acc = v; data.append((v, c))
            }
            let mx = m ?? max(data.flatMap { $0.0 }.max() ?? 0, 1)
            let cr = r.insetBy(dx: 1, dy: 3)
            for (v, c) in (stacked ? data.reversed() : data) {
                Draw.lineChart(v, in: cr, max: mx, color: c, cap: series.first?.0.capacity ?? 120)
            }
            if let legend { Draw.text(legend, x: r.maxX - 5, y: r.minY + 3, size: 9, color: .secondaryLabelColor, mono: true, align: .right) }
        }
        y += h + 4
    }
    /// Small secondary text that wraps within the popup width.
    func note(_ s: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let r = (s as NSString).boundingRect(with: NSSize(width: inner, height: 200), options: [.usesLineFragmentOrigin], attributes: attrs)
        if !dry { (s as NSString).draw(with: NSRect(x: pad, y: y, width: inner, height: ceil(r.height)), options: [.usesLineFragmentOrigin], attributes: attrs) }
        y += ceil(r.height) + 4
    }
    func custom(_ h: CGFloat, _ f: (NSRect) -> Void) {
        if !dry { f(NSRect(x: pad, y: y, width: inner, height: h)) }
        y += h
    }
    // Donut "dashboard" with a center value and optional side gauges.
    func dashboard(_ parts: [(Double, NSColor)], center: String, left: (String, String)? = nil, right: (String, String)? = nil) {
        custom(92) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            Draw.donut(c, r: 36, w: 8, parts: parts)
            Draw.text(center, x: c.x, y: c.y - 9, size: 15, weight: .semibold, mono: true, align: .center)
            for (side, x) in [(left, r.minX + 38), (right, r.maxX - 38)] {
                guard let side else { continue }
                Draw.text(side.1, x: x, y: c.y - 14, size: 13, weight: .medium, mono: true, align: .center)
                Draw.text(side.0, x: x, y: c.y + 3, size: 9.5, color: .secondaryLabelColor, align: .center)
            }
        }
    }
}

// MARK: - Module base

class Module {
    let id: String, title: String, label: String, styles: [String]
    weak var host: AppDelegate?
    var item: NSStatusItem?
    var widget: WidgetView?
    init(id: String, title: String, label: String, styles: [String]) {
        self.id = id; self.title = title; self.label = label; self.styles = styles
    }
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: id + ".on") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: id + ".on") }
    }
    var styleOverride: String?          // used by --screenshots; never saved
    var style: String {
        get {
            if let o = styleOverride { return o }
            let s = UserDefaults.standard.string(forKey: id + ".style") ?? styles[0]; return styles.contains(s) ? s : styles[0]
        }
        set { UserDefaults.standard.set(newValue, forKey: id + ".style") }
    }
    var available: Bool { true }
    var wantsProcesses: Bool { false }
    func update() {}
    func widgetWidth() -> CGFloat { W.miniWidth(label) }
    /// What the widget currently shows; the widget is only redrawn when this changes. nil = always redraw (charts).
    func widgetKey() -> String? { nil }
    func drawWidget(_ r: NSRect) {}
    func drawPopup(_ L: Layout) {}
    func dump() -> String { "" }
}

final class WidgetView: NSView {
    unowned let module: Module
    var lastKey: String?
    init(_ m: Module) { module = m; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) { module.drawWidget(bounds) }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    func refresh() {
        // Skip items macOS has hidden (e.g. behind the notch).
        if let w = window, !w.occlusionState.contains(.visible) { lastKey = nil; return }
        let k = module.widgetKey()
        if k == nil || k != lastKey { lastKey = k; needsDisplay = true }
    }
    // The meter takes the click itself (instead of the status bar button) so the button never runs its
    // own press tracking, which would clear the highlight when the mouse is released. The popup opens on
    // press, like system menu bar items, and the highlight stays until the popup closes.
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { module.host?.toggle(module) }
    override func rightMouseDown(with e: NSEvent) { module.host?.toggle(module) }
    override func mouseUp(with e: NSEvent) {}
    override func rightMouseUp(with e: NSEvent) {}
}

// MARK: - Process list (only runs while a CPU/RAM popup is open)
// macOS blocks normal apps from reading CPU usage of root/system processes (WindowServer, kernel_task).
// /usr/bin/top is setuid root, so — like Stats — we read the list from top. One long-running top
// process streams samples while the popup is open and is terminated when it closes.

final class ProcSampler {
    struct Proc { let name: String; let cpu: Double; let mem: Double }
    var byCPU: [Proc] = [], byMem: [Proc] = []
    private var proc: Process?
    private var sort = "cpu"
    private var pending = ""
    private var rows: [(Int32, Double, Double, String)] = []
    private var inTable = false, samples = 0
    private var names: [Int32: String] = [:]
    private let rowCount = 6

    func start(sortBy: String, interval: Double) {
        stop()
        sort = sortBy
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "0", "-s", "\(max(1, Int(interval)))", "-o", sortBy, "-n", "\(rowCount)",
                       "-stats", "pid,cpu,mem,command"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s) }
        }
        do { try p.run(); proc = p } catch { proc = nil }
    }
    func stop() {
        if let p = proc {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        proc = nil; pending = ""; rows = []; inTable = false; samples = 0
        byCPU = []; byMem = []; names = [:]
    }
    private func consume(_ s: String) {
        guard proc != nil else { return }
        pending += s
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl]); pending.removeSubrange(...nl)
            parse(line)
        }
    }
    private func parse(_ line: String) {
        if line.hasPrefix("PID") { inTable = true; rows = []; return }
        guard inTable else { return }
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { return }
        rows.append((pid, cpu, ProcSampler.bytes(String(parts[2])), String(parts[3])))
        if rows.count == rowCount {
            inTable = false; samples += 1
            // top's first sample has no CPU delta yet, so skip it for the CPU list.
            if sort == "mem" || samples > 1 { publish() }
        }
    }
    private func publish() {
        let list = rows.filter { $0.0 != proc?.processIdentifier }.prefix(5).map {
            Proc(name: name($0.0, fallback: $0.3), cpu: $0.1, mem: $0.2)
        }
        if sort == "mem" { byMem = Array(list) } else { byCPU = Array(list) }
    }
    static func bytes(_ s: String) -> Double {
        var t = s; while let c = t.last, c == "+" || c == "-" { t.removeLast() }
        guard let u = t.last, let v = Double(t.dropLast()) else { return Double(t) ?? 0 }
        switch u { case "K": return v * 1024; case "M": return v * 1048576; case "G": return v * 1073741824; case "B": return v; default: return Double(t) ?? 0 }
    }
    private func name(_ pid: Int32, fallback: String) -> String {
        if let n = names[pid] { return n }
        var s = NSRunningApplication(processIdentifier: pid)?.localizedName
        if s == nil {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { s = (String(cString: buf) as NSString).lastPathComponent }
        }
        let r = s ?? fallback.trimmingCharacters(in: .whitespaces)
        names[pid] = r; return r
    }
}

// MARK: - CPU

final class CPUModule: Module {
    private var prev: [UInt32] = []
    var cores: [Double] = []
    var coreType: [Character] = []
    var user = 0.0, system = 0.0, total = 0.0
    var hUser = Ring(120), hSys = Ring(120), hTotal = Ring(120)
    var load: [Double] = [0, 0, 0]
    let ncpu = sysctlInt("hw.logicalcpu")
    let pCount = sysctlInt("hw.perflevel0.logicalcpu"), eCount = sysctlInt("hw.perflevel1.logicalcpu")
    let brand = sysctlString("machdep.cpu.brand_string")
    let boot: Int = {
        var tv = timeval(); var s = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &s, nil, 0); return tv.tv_sec
    }()

    init() {
        super.init(id: "cpu", title: "CPU", label: "CPU", styles: ["mini", "line", "bars", "pie"])
        coreType = CPUModule.readCoreTypes(ncpu, p: pCount, e: eCount)
    }
    static func readCoreTypes(_ n: Int, p: Int, e: Int) -> [Character] {
        var types = [Character](repeating: "P", count: n)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        var found = 0
        if cpus != 0 {
            var it: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &it) == KERN_SUCCESS {
                var c = IOIteratorNext(it)
                while c != 0 {
                    if let ct = regProp(c, "cluster-type") as? Data, let ch = ct.first,
                       let idd = regProp(c, "logical-cpu-id") as? Data, idd.count >= 4 {
                        let id = Int(idd.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                        if id < n { types[id] = Character(UnicodeScalar(ch)); found += 1 }
                    }
                    IOObjectRelease(c); c = IOIteratorNext(it)
                }
                IOObjectRelease(it)
            }
            IOObjectRelease(cpus)
        }
        if found < n && e > 0 { for i in 0..<min(e, n) { types[i] = "E" } }
        return types
    }
    override var wantsProcesses: Bool { true }
    override func update() {
        var n: natural_t = 0; var info: processor_info_array_t?; var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let info else { return }
        let N = Int(n)
        var cur = [UInt32](repeating: 0, count: N * 4)
        for i in 0..<N * 4 { cur[i] = UInt32(bitPattern: info[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(cnt) * MemoryLayout<integer_t>.stride))
        if prev.count == cur.count {
            var tu = 0.0, ts = 0.0, tt = 0.0
            var cs = [Double](repeating: 0, count: N)
            for c in 0..<N {
                let u = Double(cur[c * 4] &- prev[c * 4]), s = Double(cur[c * 4 + 1] &- prev[c * 4 + 1])
                let i = Double(cur[c * 4 + 2] &- prev[c * 4 + 2]), ni = Double(cur[c * 4 + 3] &- prev[c * 4 + 3])
                let t = u + s + i + ni
                tu += u + ni; ts += s; tt += t
                cs[c] = t > 0 ? (u + s + ni) / t : 0
            }
            cores = cs
            user = tt > 0 ? tu / tt : 0; system = tt > 0 ? ts / tt : 0; total = user + system
            hUser.push(user); hSys.push(system); hTotal.push(total)
        }
        prev = cur
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); load = l
    }
    private func avg(_ t: Character) -> Double {
        let v = cores.enumerated().filter { $0.offset < coreType.count && coreType[$0.offset] == t }.map { $0.element }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
    override func widgetWidth() -> CGFloat {
        switch style {
        case "line": return W.lineWidth
        case "bars": return W.barsWidth(ncpu)
        case "pie": return W.pieWidth
        default: return W.miniWidth(label, pct(total))
        }
    }
    override func drawWidget(_ r: NSRect) {
        switch style {
        case "line": W.line(r, label, [(hTotal.tail(30), .systemBlue)])
        case "bars": W.bars(r, label, cores, .systemBlue)
        case "pie": W.pie(r, total, .systemBlue)
        default: W.mini(r, label, pct(total))
        }
    }
    override func widgetKey() -> String? {
        switch style {
        case "line": return nil
        case "bars": return cores.map { String(Int($0 * 17)) }.joined(separator: ",")
        default: return pct(total)
        }
    }
    override func drawPopup(_ L: Layout) {
        L.title("CPU", brand)
        let temp = host?.sensors.cpuTemp
        L.dashboard([(system, .systemRed), (user, .systemBlue)], center: pct(total),
                    left: ("Temperature", temp.map { String(format: "%.0f°C", $0) } ?? "—"),
                    right: ("Load 1m", String(format: "%.2f", load[0])))
        L.section("Usage history")
        L.chart([(hSys, .systemRed), (hUser, .systemBlue)], max: 1, stacked: true, legend: pct(total))
        L.section("Details")
        L.row("System", pct(system), dot: .systemRed)
        L.row("User", pct(user), dot: .systemBlue)
        L.row("Idle", pct(1 - total), dot: .tertiaryLabelColor)
        if eCount > 0 {
            L.row("Efficiency cores (\(eCount))", pct(avg("E")), dot: .systemTeal)
            L.row("Performance cores (\(pCount))", pct(avg("P")), dot: .systemIndigo)
        }
        L.row("Load average", String(format: "%.2f  %.2f  %.2f", load[0], load[1], load[2]))
        L.row("Uptime", fmtDuration(Int(Date().timeIntervalSince1970) - boot))
        L.section("Cores")
        L.custom(44) { r in
            let n = max(cores.count, 1)
            let bw = (r.width - CGFloat(n - 1) * 3) / CGFloat(n)
            for (i, v) in cores.enumerated() {
                let x = r.minX + CGFloat(i) * (bw + 3)
                let bg = NSRect(x: x, y: r.minY, width: bw, height: 32)
                NSColor.labelColor.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: bg, xRadius: 2, yRadius: 2).fill()
                let h = max(1, 32 * CGFloat(min(v, 1)))
                (i < coreType.count && coreType[i] == "E" ? NSColor.systemTeal : NSColor.systemIndigo).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: r.minY + 32 - h, width: bw, height: h), xRadius: 2, yRadius: 2).fill()
                Draw.text(i < coreType.count ? String(coreType[i]) : "", x: x + bw / 2, y: r.minY + 33, size: 8, color: .secondaryLabelColor, align: .center)
            }
        }
        L.section("Top processes")
        let ps = host?.procs.byCPU ?? []
        for i in 0..<5 {
            if i < ps.count { L.row(ps[i].name, String(format: "%.1f%%", ps[i].cpu)) } else { L.row("", "") }
        }
    }
    override func dump() -> String {
        "CPU total=\(pct(total)) user=\(pct(user)) sys=\(pct(system)) cores=\(cores.map { pct($0) }) types=\(String(coreType)) load=\(load)"
    }
}

// MARK: - GPU

final class GPUModule: Module {
    var util = 0.0, renderer = 0.0, tiler = 0.0, memUsed = 0.0
    var model = "GPU", cores = 0
    var h = Ring(120)
    private var entry: io_object_t = 0
    init() {
        super.init(id: "gpu", title: "GPU", label: "GPU", styles: ["mini", "line", "bars", "pie"])
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS {
            var e = IOIteratorNext(it)
            while e != 0 {
                if entry == 0, regProp(e, "PerformanceStatistics") != nil { entry = e } else { IOObjectRelease(e) }
                e = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        if entry != 0 {
            let m = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "model" as CFString, kCFAllocatorDefault,
                                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            if let s = m as? String { model = s }
            else if let d = m as? Data { model = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self) }
            cores = (regProp(entry, "gpu-core-count") as? Int) ?? 0
        }
    }
    override var available: Bool { entry != 0 }
    override func update() {
        guard entry != 0, let s = regProp(entry, "PerformanceStatistics") as? [String: Any] else { return }
        func n(_ k: String) -> Double { (s[k] as? NSNumber)?.doubleValue ?? 0 }
        util = n("Device Utilization %") / 100
        renderer = n("Renderer Utilization %") / 100
        tiler = n("Tiler Utilization %") / 100
        memUsed = n("In use system memory")
        h.push(util)
    }
    override func widgetWidth() -> CGFloat {
        switch style { case "line": return W.lineWidth; case "bars": return W.barsWidth(1); case "pie": return W.pieWidth; default: return W.miniWidth(label, pct(util)) }
    }
    override func drawWidget(_ r: NSRect) {
        switch style {
        case "line": W.line(r, label, [(h.tail(30), .systemPurple)])
        case "bars": W.bars(r, label, [util], .systemPurple)
        case "pie": W.pie(r, util, .systemPurple)
        default: W.mini(r, label, pct(util))
        }
    }
    override func widgetKey() -> String? { style == "line" ? nil : pct(util) }
    override func drawPopup(_ L: Layout) {
        L.title("GPU", model)
        let temp = host?.sensors.gpuTemp
        L.dashboard([(util, .systemPurple)], center: pct(util),
                    left: ("Temperature", temp.map { String(format: "%.0f°C", $0) } ?? "—"),
                    right: ("Renderer", pct(renderer)))
        L.section("Usage history")
        L.chart([(h, .systemPurple)], max: 1, legend: pct(util))
        L.section("Details")
        L.row("Model", model)
        if cores > 0 { L.row("Cores", "\(cores)") }
        L.row("Utilization", pct(util), dot: .systemPurple)
        L.row("Renderer", pct(renderer))
        L.row("Tiler", pct(tiler))
        L.row("Memory in use", fmtBytes(memUsed))
    }
    override func dump() -> String { "GPU \(model) cores=\(cores) util=\(pct(util)) mem=\(fmtBytes(memUsed))" }
}

// MARK: - RAM

final class RAMModule: Module {
    let total = Double(sysctlInt("hw.memsize"))
    var used = 0.0, app = 0.0, wired = 0.0, compressed = 0.0, free = 0.0, cached = 0.0
    var swapUsed = 0.0, swapTotal = 0.0, pressure = 1
    var h = Ring(120)
    init() { super.init(id: "ram", title: "Memory", label: "RAM", styles: ["mini", "line", "bars", "pie"]) }
    override var wantsProcesses: Bool { true }
    var frac: Double { total > 0 ? used / total : 0 }
    override func update() {
        var st = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &st) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &cnt) } }
        guard r == KERN_SUCCESS else { return }
        let active = Double(st.active_count) * pageSize, inactive = Double(st.inactive_count) * pageSize
        let spec = Double(st.speculative_count) * pageSize, purge = Double(st.purgeable_count) * pageSize
        let ext = Double(st.external_page_count) * pageSize
        wired = Double(st.wire_count) * pageSize
        compressed = Double(st.compressor_page_count) * pageSize
        used = active + inactive + spec + wired + compressed - purge - ext
        app = max(0, used - wired - compressed)
        cached = purge + ext
        free = max(0, total - used)
        var xsw = xsw_usage(); var s = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &s, nil, 0) == 0 { swapUsed = Double(xsw.xsu_used); swapTotal = Double(xsw.xsu_total) }
        pressure = sysctlInt("kern.memorystatus_vm_pressure_level")
        h.push(frac)
    }
    var pressureColor: NSColor { pressure >= 4 ? .systemRed : (pressure == 2 ? .systemYellow : .systemGreen) }
    var pressureName: String { pressure >= 4 ? "Critical" : (pressure == 2 ? "Warning" : "Normal") }
    override func widgetWidth() -> CGFloat {
        switch style { case "line": return W.lineWidth; case "bars": return W.barsWidth(1); case "pie": return W.pieWidth; default: return W.miniWidth(label, pct(frac)) }
    }
    override func drawWidget(_ r: NSRect) {
        switch style {
        case "line": W.line(r, label, [(h.tail(30), .systemGreen)])
        case "bars": W.bars(r, label, [frac], pressureColor)
        case "pie": W.pie(r, frac, pressureColor)
        default: W.mini(r, label, pct(frac))
        }
    }
    override func widgetKey() -> String? { style == "line" ? nil : pct(frac) + "\(pressure)" }
    override func drawPopup(_ L: Layout) {
        L.title("Memory", fmtBytes(total) + " total")
        L.dashboard([(app / total, .systemBlue), (wired / total, .systemOrange), (compressed / total, .systemPink)],
                    center: pct(frac), left: ("Pressure", pressureName), right: ("Swap", fmtBytes(swapUsed)))
        L.section("Usage history")
        L.chart([(h, .systemGreen)], max: 1, legend: pct(frac))
        L.section("Details")
        L.row("Used", fmtBytes(used))
        L.row("App", fmtBytes(app), dot: .systemBlue)
        L.row("Wired", fmtBytes(wired), dot: .systemOrange)
        L.row("Compressed", fmtBytes(compressed), dot: .systemPink)
        L.row("Free", fmtBytes(free), dot: .tertiaryLabelColor)
        L.row("Cached files", fmtBytes(cached))
        L.row("Swap", "\(fmtBytes(swapUsed)) / \(fmtBytes(swapTotal))")
        L.row("Pressure", pressureName, dot: pressureColor)
        L.section("Top processes")
        let ps = host?.procs.byMem ?? []
        for i in 0..<5 {
            if i < ps.count { L.row(ps[i].name, fmtBytes(ps[i].mem)) } else { L.row("", "") }
        }
    }
    override func dump() -> String { "RAM used=\(fmtBytes(used))/\(fmtBytes(total)) app=\(fmtBytes(app)) wired=\(fmtBytes(wired)) comp=\(fmtBytes(compressed)) pressure=\(pressure)" }
}

// MARK: - Disk

final class DiskModule: Module {
    var total = 0.0, free = 0.0, volName = "Macintosh HD"
    var rBps = 0.0, wBps = 0.0, totR: UInt64 = 0, totW: UInt64 = 0
    var hR = Ring(120), hW = Ring(120)
    private var drivers: [io_object_t] = []
    private var n = 0, lastR: UInt64 = 0, lastW: UInt64 = 0, lastT = 0.0
    init() { super.init(id: "disk", title: "Disk", label: "SSD", styles: ["mini", "speed", "bars", "pie"]) }
    var frac: Double { total > 0 ? (total - free) / total : 0 }
    override func update() {
        if n % 30 == 0 { space() }
        if n % 120 == 0 { rescan() }
        n += 1
        var r: UInt64 = 0, w: UInt64 = 0
        for d in drivers {
            if let s = regProp(d, "Statistics") as? [String: Any] {
                r += (s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        let t = ProcessInfo.processInfo.systemUptime
        if lastT > 0, t > lastT, r >= lastR, w >= lastW {
            rBps = Double(r - lastR) / (t - lastT); wBps = Double(w - lastW) / (t - lastT)
        } else { rBps = 0; wBps = 0 }
        lastR = r; lastW = w; lastT = t; totR = r; totW = w
        hR.push(rBps); hW.push(wBps)
    }
    private func space() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            total = Double(v.volumeTotalCapacity ?? 0)
            free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            volName = v.volumeLocalizedName ?? volName
        }
    }
    private func rescan() {
        drivers.forEach { IOObjectRelease($0) }; drivers = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return }
        var e = IOIteratorNext(it)
        while e != 0 { drivers.append(e); e = IOIteratorNext(it) }
        IOObjectRelease(it)
    }
    override func widgetWidth() -> CGFloat {
        switch style { case "speed": return W.speedWidth; case "bars": return W.barsWidth(1); case "pie": return W.pieWidth; default: return W.miniWidth(label, pct(frac)) }
    }
    override func drawWidget(_ r: NSRect) {
        switch style {
        case "speed": W.speed(r, top: wBps, bottom: rBps, topSym: "W", botSym: "R")
        case "bars": W.bars(r, label, [frac], .systemOrange)
        case "pie": W.pie(r, frac, .systemOrange)
        default: W.mini(r, label, pct(frac))
        }
    }
    override func widgetKey() -> String? { style == "speed" ? fmtSpeed(rBps) + fmtSpeed(wBps) : pct(frac) }
    override func drawPopup(_ L: Layout) {
        L.title("Disk", volName)
        L.dashboard([(frac, .systemOrange)], center: pct(frac), left: ("Read", fmtSpeed(rBps)), right: ("Write", fmtSpeed(wBps)))
        L.section("Activity")
        L.chart([(hR, .systemBlue), (hW, .systemRed)], legend: "R \(fmtSpeed(rBps))  W \(fmtSpeed(wBps))")
        L.section("Details")
        L.row("Total", fmtBytes(total, base: 1000))
        L.row("Used", fmtBytes(total - free, base: 1000), dot: .systemOrange)
        L.row("Free", fmtBytes(free, base: 1000), dot: .tertiaryLabelColor)
        L.row("Read", fmtSpeed(rBps), dot: .systemBlue)
        L.row("Write", fmtSpeed(wBps), dot: .systemRed)
        L.row("Total read", fmtBytes(Double(totR), base: 1000))
        L.row("Total written", fmtBytes(Double(totW), base: 1000))
    }
    override func dump() -> String { "Disk \(volName) used=\(pct(frac)) free=\(fmtBytes(free, base: 1000)) R=\(fmtSpeed(rBps)) W=\(fmtSpeed(wBps)) drivers=\(drivers.count)" }
}

// MARK: - Network

final class NetworkModule: Module {
    var iface = "", ip = "—", down = 0.0, up = 0.0, totDown: UInt64 = 0, totUp: UInt64 = 0
    var hD = Ring(120), hU = Ring(120)
    private var lastD: UInt64 = 0, lastU: UInt64 = 0, lastT = 0.0, n = 0
    private let store = SCDynamicStoreCreate(nil, "meterbar" as CFString, nil, nil)
    init() { super.init(id: "net", title: "Network", label: "NET", styles: ["speed", "line"]) }
    override func update() {
        if n % 10 == 0 {
            let i = primaryIface()
            if i != iface { iface = i; lastT = 0 }
            ip = ipv4(iface)
        }
        n += 1
        let (d, u) = counters(iface)
        let t = ProcessInfo.processInfo.systemUptime
        if lastT > 0, t > lastT, d >= lastD, u >= lastU {
            down = Double(d - lastD) / (t - lastT); up = Double(u - lastU) / (t - lastT)
        } else { down = 0; up = 0 }
        lastD = d; lastU = u; lastT = t; totDown = d; totUp = u
        hD.push(down); hU.push(up)
    }
    private func primaryIface() -> String {
        guard let store, let d = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let i = d["PrimaryInterface"] as? String else { return "en0" }
        return i
    }
    private func ipv4(_ name: String) -> String {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "—" }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), String(cString: a.pointee.ifa_name) == name {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            p = a.pointee.ifa_next
        }
        return "—"
    }
    private func counters(_ name: String) -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var ib: UInt64 = 0, ob: UInt64 = 0
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil, String(cString: nameBuf) == name {
                        ib += h2.ifm_data.ifi_ibytes; ob += h2.ifm_data.ifi_obytes
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return (ib, ob)
    }
    override func widgetWidth() -> CGFloat { style == "line" ? W.lineWidth : W.speedWidth }
    override func drawWidget(_ r: NSRect) {
        if style == "line" {
            let m = max(hD.tail(30).max() ?? 0, hU.tail(30).max() ?? 0, 1024)
            W.line(r, label, [(hD.tail(30), .systemBlue), (hU.tail(30), .systemRed)], max: m)
        } else {
            W.speed(r, top: up, bottom: down)
        }
    }
    override func widgetKey() -> String? { style == "line" ? nil : fmtSpeed(up) + fmtSpeed(down) + "\(up > 1000)\(down > 1000)" }
    override func drawPopup(_ L: Layout) {
        L.title("Network", iface.isEmpty ? nil : iface)
        L.section("Activity")
        L.chart([(hD, .systemBlue), (hU, .systemRed)], h: 80, legend: "↓ \(fmtSpeed(down))  ↑ \(fmtSpeed(up))")
        L.section("Details")
        L.row("Download", fmtSpeed(down), dot: .systemBlue)
        L.row("Upload", fmtSpeed(up), dot: .systemRed)
        L.row("Interface", iface)
        L.row("Local IP", Screenshots.active ? "192.168.x.x" : ip)
        L.row("Total downloaded", fmtBytes(Double(totDown), base: 1000))
        L.row("Total uploaded", fmtBytes(Double(totUp), base: 1000))
    }
    override func dump() -> String { "Net \(iface) ip=\(ip) down=\(fmtSpeed(down)) up=\(fmtSpeed(up)) tot=\(totDown)/\(totUp)" }
}

// MARK: - Sensors (SMC temperatures, fans and power — the same source Stats uses)

final class SMC {
    private var conn: io_connect_t = 0
    private var info: [UInt32: (UInt32, UInt32)] = [:]
    private var inBuf = [UInt8](repeating: 0, count: 80)
    private var outBuf = [UInt8](repeating: 0, count: 80)
    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }
    static func cc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func str(_ v: UInt32) -> String { String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "" }
    // SMCKeyData_t is 80 bytes: key@0, keyInfo.dataSize@28, keyInfo.dataType@32, result@40, data8@42, data32@44, bytes@48
    private func call(key: UInt32, cmd: UInt8, size: UInt32 = 0, index: UInt32 = 0) -> Bool {
        for i in 0..<80 { inBuf[i] = 0 }
        put(0, key); put(28, size); put(44, index); inBuf[42] = cmd
        var outSize = 80
        let r = IOConnectCallStructMethod(conn, 2, &inBuf, 80, &outBuf, &outSize)
        return r == kIOReturnSuccess && outBuf[40] == 0
    }
    private func put(_ off: Int, _ v: UInt32) { for k in 0..<4 { inBuf[off + k] = UInt8((v >> (8 * k)) & 0xff) } }
    private func get(_ off: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(outBuf[off + $1]) << (8 * $1) } }
    func type(_ key: String) -> String? {
        let k = SMC.cc(key)
        if info[k] == nil { info[k] = call(key: k, cmd: 9) ? (get(28), get(32)) : (0, 0) }
        guard let (size, t) = info[k], size > 0 else { return nil }
        return SMC.str(t)
    }
    func read(_ key: String) -> Double? {
        let k = SMC.cc(key)
        if info[k] == nil { info[k] = call(key: k, cmd: 9) ? (get(28), get(32)) : (0, 0) }
        guard let (size, type) = info[k], size > 0, call(key: k, cmd: 5, size: size) else { return nil }
        let b0 = UInt16(outBuf[48]), b1 = UInt16(outBuf[49])
        switch type {
        case SMC.cc("flt "): return size >= 4 ? Double(Float(bitPattern: get(48))) : nil
        case SMC.cc("ui8 "): return Double(outBuf[48])
        case SMC.cc("ui16"): return Double(b0 << 8 | b1)
        case SMC.cc("ui32"): return Double((0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(outBuf[48 + $1]) })
        case SMC.cc("fpe2"): return Double(b0 << 8 | b1) / 4
        case SMC.cc("sp78"): return Double(Int16(bitPattern: b0 << 8 | b1)) / 256
        default: return nil
        }
    }
    /// All SMC key names (used once at launch to discover sensors).
    func allKeys() -> [String] {
        guard let n = read("#KEY"), n > 0 else { return [] }
        var keys: [String] = []; keys.reserveCapacity(Int(n))
        for i in 0..<UInt32(n) where call(key: 0, cmd: 8, index: i) { keys.append(SMC.str(get(0))) }
        return keys
    }
}

final class SensorsModule: Module {
    struct Sensor { let key: String; let group: String; let name: String; var value: Double = 0 }
    enum G { static let cpu = "CPU", gpu = "GPU", sys = "System" }

    private let smc = SMC()
    private(set) var sensors: [Sensor] = []
    private var lightIdx: [Int] = []          // small evenly-spaced subset read while the popup is closed
    private lazy var fanCount: Int = Int(smc?.read("FNum") ?? 0)
    private var lastRead = 0.0, lastFull = false
    var forceFull = false
    var fans: [(cur: Double, min: Double, max: Double)] = []
    var power: Double?, batteryPower: Double?
    var cpuTemp: Double?, cpuMax: Double?, eTemp: Double?, pTemp: Double?, gpuTemp: Double?, gpuMax: Double?
    var hTemp = Ring(120)
    let eCores = sysctlInt("hw.perflevel1.logicalcpu"), pCores = sysctlInt("hw.perflevel0.logicalcpu")
    var gpuCores: Int { host?.modules.lazy.compactMap { $0 as? GPUModule }.first?.cores ?? 0 }

    init() {
        super.init(id: "sensors", title: "Sensors", label: "TMP", styles: ["stack", "stackPower", "mini", "line"])
        discover()
    }
    var showAll: Bool {
        get { !Screenshots.active && UserDefaults.standard.bool(forKey: "sensors.all") }
        set { UserDefaults.standard.set(newValue, forKey: "sensors.all") }
    }

    // Stats-style friendly names. Numbered families get "… 1", "… 2" in key order.
    private static let fixed: [String: (String, String)] = [
        "Tm0P": (G.sys, "Memory"), "Tm0p": (G.sys, "Memory"), "Tm0B": (G.sys, "Memory"),
        "TH0x": (G.sys, "SSD (NAND)"), "TH0a": (G.sys, "SSD (NAND)"),
        "TB0T": (G.sys, "Battery"), "TB1T": (G.sys, "Battery cell 1"), "TB2T": (G.sys, "Battery cell 2"),
        "TW0P": (G.sys, "Wi-Fi / Bluetooth module"), "TCHP": (G.sys, "Charger proximity"),
        "Ts0P": (G.sys, "Palm rest 1"), "Ts1P": (G.sys, "Palm rest 2"),
        "TaLP": (G.sys, "Airflow left"), "TaRP": (G.sys, "Airflow right"),
        "TC0P": (G.cpu, "CPU proximity"), "TG0P": (G.gpu, "GPU proximity"),
    ]
    private func discover() {
        guard let smc else { return }
        var counters: [String: Int] = [:]
        for key in smc.allKeys().sorted() where key.hasPrefix("T") {
            let pre = String(key.prefix(2))
            let fam: (String, String)?
            if let f = SensorsModule.fixed[key] { fam = f }
            // Each cluster has several thermal sensors spread over the die — not one per core.
            else if pre == "Te" { fam = (G.cpu, "E-cluster sensor") }
            else if pre == "Tp" { fam = (G.cpu, "P-cluster sensor") }
            else if pre == "Tg" { fam = (G.gpu, "GPU sensor") }
            else { fam = nil }
            guard let fam, smc.type(key) == "flt ", let v = smc.read(key), v > 5, v < 130 else { continue }
            var name = fam.1
            if SensorsModule.fixed[key] == nil { let n = (counters[fam.1] ?? 0) + 1; counters[fam.1] = n; name += " \(n)" }
            sensors.append(Sensor(key: key, group: fam.0, name: name, value: v))
        }
        // Light set: up to 4 sensors each from E-cores, P-cores and GPU.
        for prefix in ["Te", "Tp", "Tg"] {
            let idx = sensors.indices.filter { sensors[$0].key.hasPrefix(prefix) }
            let step = max(1, idx.count / 4)
            lightIdx += stride(from: 0, to: idx.count, by: step).prefix(4).map { idx[$0] }
        }
    }
    override func update() {
        guard let smc else { return }
        let full = forceFull || host?.popup.module === self
        let now = ProcessInfo.processInfo.systemUptime
        // Temperatures change slowly: refresh at most every 2 s unless the popup just opened.
        guard now - lastRead >= 1.95 || (full && !lastFull) else { return }
        lastRead = now; lastFull = full
        for i in (full ? Array(sensors.indices) : lightIdx) {
            if let v = smc.read(sensors[i].key), v > 5, v < 130 { sensors[i].value = v }
        }
        func stats(_ f: (Sensor) -> Bool) -> (Double, Double)? {
            let v = (full ? sensors.indices.map { $0 } : lightIdx).map { sensors[$0] }.filter(f).map(\.value)
            return v.isEmpty ? nil : (v.reduce(0, +) / Double(v.count), v.max()!)
        }
        let cpu = stats { $0.group == G.cpu }, gpu = stats { $0.group == G.gpu }
        cpuTemp = cpu?.0; cpuMax = cpu?.1; gpuTemp = gpu?.0; gpuMax = gpu?.1
        eTemp = stats { $0.key.hasPrefix("Te") }?.0; pTemp = stats { $0.key.hasPrefix("Tp") }?.0
        if full || fanCount > 0 && style != "stack" {
            fans = (0..<fanCount).map { i in (smc.read("F\(i)Ac") ?? 0, smc.read("F\(i)Mn") ?? 0, smc.read("F\(i)Mx") ?? 0) }
        }
        if full || style == "stackPower" { power = smc.read("PSTR") }
        if full { batteryPower = smc.read("PPBR") }
        hTemp.push(cpuTemp ?? 0)
    }
    private func t(_ v: Double?) -> String { v.map { String(format: "%.0f°C", $0) } ?? "—" }
    private var secondLine: String {
        if style == "stackPower" {
            if let f = fans.first, f.cur > 0 { return "\(Int(f.cur))rpm" }
            return power.map { String(format: "%.1fW", $0) } ?? ""
        }
        return t(gpuTemp)
    }
    override func widgetKey() -> String? { style == "line" ? nil : t(cpuTemp) + secondLine }
    override func widgetWidth() -> CGFloat {
        switch style {
        case "line": return W.lineWidth
        case "mini": return W.miniWidth("CPU", t(cpuTemp), reserve: "99°C")
        default:
            // label column + 4 pt + values (room for "99°C", growing only if a reading needs more)
            let lw = max(Draw.width("CPU", 9, .semibold), Draw.width(style == "stackPower" ? "PWR" : "GPU", 9, .semibold))
            let vw = max(Draw.width("99°C", 9, .medium, mono: true), Draw.width(t(cpuTemp), 9, .medium, mono: true),
                         Draw.width(secondLine, 9, .medium, mono: true))
            return ceil(lw + 4 + vw)
        }
    }
    override func drawWidget(_ r: NSRect) {
        switch style {
        case "line": W.line(r, label, [(hTemp.tail(30), .systemOrange)], max: 110)
        case "mini": W.mini(r, "CPU", t(cpuTemp))
        default:
            W.stack(r, t(cpuTemp), secondLine)
            Draw.text("CPU", x: 0, y: r.midY - 0.5, size: 9, weight: .semibold, color: .secondaryLabelColor)
            Draw.text(style == "stackPower" ? "PWR" : "GPU", x: 0, y: r.midY - 11, size: 9, weight: .semibold, color: .secondaryLabelColor)
        }
    }
    override func drawPopup(_ L: Layout) {
        L.title("Sensors")
        L.section("CPU temperature")
        L.chart([(hTemp, .systemOrange)], max: 110, h: 50, legend: t(cpuTemp))
        L.section("CPU")
        L.row("CPU average", t(cpuTemp), dot: .systemOrange)
        L.row("CPU hottest", t(cpuMax))
        if eTemp != nil { L.row("Efficiency cores (\(eCores))", t(eTemp), dot: .systemTeal) }
        if pTemp != nil { L.row("Performance cores (\(pCores))", t(pTemp), dot: .systemIndigo) }
        if showAll {
            L.note("Sensors are spread across each core cluster; there are more sensors than cores.")
            for s in sensors where s.group == G.cpu { L.row("   " + s.name, String(format: "%.1f°C", s.value)) }
        }
        if gpuTemp != nil {
            L.section(gpuCores > 0 ? "GPU (\(gpuCores) cores)" : "GPU")
            L.row("GPU average", t(gpuTemp), dot: .systemPurple)
            L.row("GPU hottest", t(gpuMax))
            if showAll { for s in sensors where s.group == G.gpu { L.row("   " + s.name, String(format: "%.1f°C", s.value)) } }
        }
        let sys = sensors.filter { $0.group == G.sys }
        if !sys.isEmpty {
            L.section("System")
            for s in sys { L.row(s.name, String(format: "%.1f°C", s.value)) }
        }
        if !fans.isEmpty {
            L.section("Fans")
            for (i, f) in fans.enumerated() { L.row("Fan \(i + 1)", "\(Int(f.cur)) rpm  (\(Int(f.min))–\(Int(f.max)))") }
        }
        if power != nil || batteryPower != nil {
            L.section("Power")
            if let p = power { L.row("Total system power", String(format: "%.2f W", p)) }
            if let p = batteryPower { L.row("Battery power", String(format: "%.2f W", p)) }
        }
    }
    override func dump() -> String {
        "Sensors cpu=\(t(cpuTemp)) max=\(t(cpuMax)) E=\(t(eTemp)) P=\(t(pTemp)) gpu=\(t(gpuTemp)) gpuMax=\(t(gpuMax)) power=\(power ?? -1)\n  "
            + sensors.map { "\($0.key)→\($0.name)=\(String(format: "%.1f", $0.value))" }.joined(separator: ", ")
    }
}

// MARK: - Battery

final class BatteryModule: Module {
    var level = 0.0, charging = false, onAC = false, charged = false, minutes = -1
    var cycles = 0, maxCap = 0, designCap = 0, tempC = 0.0, volts = 0.0, amps = 0.0, adapterW = 0
    var h = Ring(120)
    private var n = 0
    private let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    init() { super.init(id: "battery", title: "Battery", label: "BAT", styles: ["battery", "icon", "mini"]) }
    override var available: Bool { battery != 0 }
    override func update() {
        let open = host?.popup.module === self
        // Battery state changes slowly: poll powerd every 5 ticks (every tick while the popup is open).
        if n % 5 == 0 || open, let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
                level = mx > 0 ? Double(cur) / Double(mx) : 0
                charging = d[kIOPSIsChargingKey] as? Bool ?? false
                charged = d[kIOPSIsChargedKey] as? Bool ?? false
                onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
            }
        }
        if (n % 30 == 0 || (open && n % 5 == 0)) && battery != 0 {
            func num(_ k: String) -> NSNumber? { regProp(battery, k) as? NSNumber }
            cycles = num("CycleCount")?.intValue ?? 0
            maxCap = num("AppleRawMaxCapacity")?.intValue ?? 0
            designCap = num("DesignCapacity")?.intValue ?? 0
            tempC = (num("Temperature")?.doubleValue ?? 0) / 100
            volts = (num("Voltage")?.doubleValue ?? 0) / 1000
            amps = Double(Int16(truncatingIfNeeded: num("Amperage")?.int64Value ?? 0)) / 1000
            adapterW = ((regProp(battery, "AdapterDetails") as? [String: Any])?["Watts"] as? Int) ?? 0
        }
        n += 1
        h.push(level)
    }
    override func widgetWidth() -> CGFloat {
        switch style { case "icon": return W.batteryWidth(showPct: false); case "mini": return W.miniWidth(label, pct(level)); default: return W.batteryWidth(showPct: true, pct(level)) }
    }
    override func drawWidget(_ r: NSRect) {
        switch style {
        case "mini": W.mini(r, label, pct(level))
        default: W.battery(r, level: level, charging: charging, onAC: onAC, showPct: style == "battery")
        }
    }
    override func widgetKey() -> String? { pct(level) + "\(charging)\(onAC)" }
    private var stateName: String { charged ? "Fully charged" : (charging ? "Charging" : (onAC ? "Not charging" : "Discharging")) }
    override func drawPopup(_ L: Layout) {
        L.title("Battery", onAC ? "Power adapter" : "Battery power")
        let health = designCap > 0 ? Double(maxCap) / Double(designCap) : 0
        L.dashboard([(level, level < 0.2 ? .systemRed : .systemGreen)], center: pct(level),
                    left: ("Health", health > 0 ? pct(health) : "—"), right: ("Cycles", "\(cycles)"))
        L.section("Level history")
        L.chart([(h, .systemGreen)], max: 1, h: 50, legend: pct(level))
        L.section("Details")
        L.row("Level", pct(level))
        L.row("State", stateName)
        L.row(charging ? "Time to full" : "Time remaining", minutes > 0 ? fmtDuration(minutes * 60) : "Calculating…")
        L.row("Health", health > 0 ? pct(health) : "—")
        L.row("Capacity", "\(maxCap) / \(designCap) mAh")
        L.row("Cycle count", "\(cycles)")
        L.row("Temperature", String(format: "%.1f°C", tempC))
        L.row("Power", String(format: "%.2f W", abs(volts * amps)))
        L.row("Voltage", String(format: "%.2f V", volts))
        L.row("Amperage", String(format: "%.0f mA", amps * 1000))
        if adapterW > 0 { L.row("Adapter", "\(adapterW) W") }
    }
    override func dump() -> String { "Battery \(pct(level)) \(stateName) cycles=\(cycles) temp=\(tempC) \(volts)V \(amps)A adapter=\(adapterW)W" }
}

// MARK: - Popup window

/// The whole popup is one view: background, scrolling content, scroll indicator and footer buttons.
/// It is painted on the CPU into a bitmap that is handed straight to the layer. When a window redraws
/// rich content every second through normal view drawing, macOS 26 moves it onto GPU-accelerated
/// rendering (~31-45 MB extra); setting the layer's contents to a CPU-rendered image avoids that.
final class PopupView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)   // flipped, like the view
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
        NSGraphicsContext.restoreGraphicsState()
        layer.contentsScale = scale
        layer.contents = ctx.makeImage()
    }
    weak var module: Module?
    var footer: CGFloat = 36
    var contentHeight: CGFloat = 0 { didSet { scroll = min(scroll, maxScroll) } }
    var onButton: ((Int) -> Void)?
    static let titles = ["Activity Monitor", "Settings…", "Quit"]
    private var scroll: CGFloat = 0
    private var buttonRects: [NSRect] = []
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    private var viewport: CGFloat { bounds.height - footer }
    private var maxScroll: CGFloat { max(0, contentHeight - viewport) }

    override func draw(_ r: NSRect) { paint() }   // used for offscreen renders (--render)
    func paint() {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill(); bg.fill()
        NSColor.separatorColor.setStroke(); bg.lineWidth = 1; bg.stroke()
        if let m = module, let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            NSBezierPath.clip(NSRect(x: 0, y: 0, width: bounds.width, height: viewport))
            let t = NSAffineTransform(); t.translateX(by: 0, yBy: -scroll); t.concat()
            m.drawPopup(Layout(w: bounds.width, dry: false))
            ctx.restoreGraphicsState()
        }
        if maxScroll > 0 {
            let h = max(30, viewport * viewport / contentHeight)
            let y = (viewport - h) * scroll / maxScroll
            NSColor.labelColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - 7, y: y + 4, width: 4, height: h - 8), xRadius: 2, yRadius: 2).fill()
        }
        NSColor.separatorColor.setFill(); NSRect(x: 0, y: viewport, width: bounds.width, height: 1).fill()
        var x: CGFloat = 10
        buttonRects = []
        for t in PopupView.titles {
            let w = Draw.width(t, 11) + 18
            let rect = NSRect(x: x, y: viewport + (footer - 22) / 2, width: w, height: 22)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            Draw.text(t, x: rect.midX, y: rect.minY + 4, size: 11, align: .center)
            buttonRects.append(rect); x += w + 6
        }
    }
    override func scrollWheel(with e: NSEvent) {
        guard maxScroll > 0 else { return }
        let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12
        scroll = min(max(scroll - d, 0), maxScroll)
        needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = buttonRects.firstIndex(where: { $0.contains(p) }) { onButton?(i) }
    }
}

final class Popup: NSObject {
    private(set) var module: Module?
    private var panel: NSPanel?
    private var view: PopupView?
    private var monitor: Any?
    let width: CGFloat = 280, footer: CGFloat = 36
    private var maxHeight: CGFloat = 800
    weak var host: AppDelegate?

    /// `anchor` (screen coordinates): open under this rectangle instead of the item's own
    /// button — used when NotchOverflow shows the item next to the notch.
    func toggle(_ m: Module, anchor: NSRect? = nil) {
        if module === m { close(); return }
        close(); open(m, anchor: anchor)
    }
    private func height(_ m: Module) -> CGFloat {
        let L = Layout(w: width, dry: true); m.drawPopup(L); return ceil(L.y + 8) + footer
    }
    private func open(_ m: Module, anchor: NSRect? = nil) {
        guard let btn = m.item?.button, let bw = btn.window else { return }
        let ref = anchor ?? bw.frame
        let h = height(m)
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.contains(NSPoint(x: a.midX, y: a.midY)) } } ?? bw.screen ?? NSScreen.main
        maxHeight = (screen?.visibleFrame.height ?? 800) - 12
        let ph = min(h, maxHeight)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: ph),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isReleasedWhenClosed = false; p.level = .popUpMenu; p.isOpaque = false
        p.backgroundColor = .clear; p.hasShadow = true; p.hidesOnDeactivate = false
        let v = PopupView(frame: NSRect(x: 0, y: 0, width: width, height: ph))
        v.autoresizingMask = [.width, .height]
        v.module = m; v.footer = footer; v.contentHeight = h - footer
        v.onButton = { [weak self] i in
            switch i { case 0: self?.activityMonitor(); case 1: self?.settings(); default: self?.quit() }
        }
        p.contentView = v
        var ox = ref.midX - width / 2
        if let vf = screen?.visibleFrame { ox = min(max(ox, vf.minX + 6), vf.maxX - width - 6) }
        var oy = ref.minY - ph - 4
        if let vf = screen?.visibleFrame { oy = min(max(oy, vf.minY + 6), vf.maxY - ph - 4) }  // keep on screen
        p.setFrame(NSRect(x: ox, y: oy, width: width, height: ph), display: true)
        v.updateLayer()                 // contents ready before the window appears (no blank first frame)
        p.orderFrontRegardless()
        panel = p; view = v; module = m
        btn.highlight(true)   // stays on until close(); nothing else changes it
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        if m.wantsProcesses {
            // top scans every process on each sample (~3% of a core at 2 s), so sample at most every 2 s.
            host?.procs.start(sortBy: m is RAMModule ? "mem" : "cpu", interval: max(2, host?.interval ?? 1))
        }
    }
    func refresh() {
        guard let m = module, let p = panel, let v = view else { return }
        let h = height(m)
        if abs(v.contentHeight - (h - footer)) > 0.5 { v.contentHeight = h - footer }
        let ph = min(h, maxHeight)
        if abs(p.frame.height - ph) > 0.5 {
            var f = p.frame; f.origin.y += f.height - ph; f.size.height = ph; p.setFrame(f, display: false)
            v.needsDisplay = true; return
        }
        v.needsDisplay = true
    }
    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        module?.item?.button?.highlight(false)
        host?.procs.stop()
        if let p = panel {
            // Fade out like system menus. The panel is released when the animation finishes.
            p.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        panel = nil; view = nil; module = nil
    }
    @objc private func activityMonitor() {
        close()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                           configuration: .init(), completionHandler: nil)
    }
    @objc private func settings() { close(); host?.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Settings window (built on demand, released on close)

final class SettingsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    unowned let host: AppDelegate
    static let styleNames = ["mini": "Mini", "line": "Line chart", "bars": "Bar chart", "pie": "Pie chart", "speed": "Speed",
                             "stack": "CPU + GPU temperature", "stackPower": "CPU temperature + power",
                             "battery": "Battery + percentage", "icon": "Battery icon"]
    static let intervals: [Double] = [1, 2, 3, 5, 10]

    init(host: AppDelegate) {
        self.host = host
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Meterbar Settings"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8; grid.columnSpacing = 16
        for (i, m) in host.modules.enumerated() {
            let cb = NSButton(checkboxWithTitle: m.title + (m.available ? "" : " (not available)"), target: self, action: #selector(toggle(_:)))
            cb.tag = i; cb.state = m.enabled && m.available ? .on : .off; cb.isEnabled = m.available
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            pop.addItems(withTitles: m.styles.map { SettingsWindow.styleNames[$0] ?? $0 })
            pop.selectItem(at: m.styles.firstIndex(of: m.style) ?? 0)
            pop.tag = i; pop.target = self; pop.action = #selector(style(_:)); pop.isEnabled = m.available
            grid.addRow(with: [cb, pop])
        }
        let iv = NSPopUpButton(frame: .zero, pullsDown: false)
        iv.addItems(withTitles: SettingsWindow.intervals.map { "\(Int($0)) s" })
        iv.selectItem(at: SettingsWindow.intervals.firstIndex(of: host.interval) ?? 0)
        iv.target = self; iv.action = #selector(interval(_:))
        grid.addRow(with: [NSTextField(labelWithString: "Update interval"), iv])
        let login = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(login(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        grid.addRow(with: [login, NSGridCell.emptyContentView])
        let all = NSButton(checkboxWithTitle: "Sensors: list every individual core and GPU sensor", target: self, action: #selector(allSensors(_:)))
        all.state = host.sensors.showAll ? .on : .off
        grid.addRow(with: [all, NSGridCell.emptyContentView])
        grid.cell(for: all)?.row?.mergeCells(in: NSRange(location: 0, length: 2))
        let note = NSTextField(wrappingLabelWithString: "Tip: ⌘-drag menu bar items to reorder them.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }
    @objc func toggle(_ s: NSButton) { host.setEnabled(host.modules[s.tag], s.state == .on) }
    @objc func style(_ s: NSPopUpButton) {
        let m = host.modules[s.tag]; m.style = m.styles[s.indexOfSelectedItem]; host.relayout(m)
    }
    @objc func interval(_ s: NSPopUpButton) {
        UserDefaults.standard.set(SettingsWindow.intervals[s.indexOfSelectedItem], forKey: "interval"); host.startTimer()
    }
    @objc func login(_ s: NSButton) {
        do { if s.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { s.state = SMAppService.mainApp.status == .enabled ? .on : .off; NSSound.beep() }
    }
    @objc func allSensors(_ s: NSButton) { host.sensors.showAll = s.state == .on }
    func windowWillClose(_ n: Notification) { DispatchQueue.main.async { self.host.settings = nil } }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var modules: [Module] = []
    let sensors = SensorsModule()
    let procs = ProcSampler()
    let popup = Popup()
    var timer: Timer?
    var settings: SettingsWindow?
    var interval: Double { let v = UserDefaults.standard.double(forKey: "interval"); return v > 0 ? v : 1 }

    func applicationDidFinishLaunching(_ n: Notification) {
        modules = [CPUModule(), GPUModule(), RAMModule(), DiskModule(), sensors, NetworkModule(), BatteryModule()]
        modules.forEach { $0.host = self }
        popup.host = self
        if CommandLine.arguments.contains("--enable-login") {
            do { try SMAppService.mainApp.register(); print("login item: enabled") } catch { print("login item failed: \(error)") }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots"), i + 1 < CommandLine.arguments.count {
            let secs = i + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 2]) ?? 45 : 45
            Screenshots.run(self, dir: CommandLine.arguments[i + 1], seconds: secs)
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") {
            sensors.forceFull = true
            for _ in 0..<3 { modules.forEach { $0.update() }; Thread.sleep(forTimeInterval: 1) }
            procs.start(sortBy: "cpu", interval: 1); RunLoop.main.run(until: Date().addingTimeInterval(3.5)); let cpuList = procs.byCPU
            procs.start(sortBy: "mem", interval: 1); RunLoop.main.run(until: Date().addingTimeInterval(2)); let memList = procs.byMem; procs.stop()
            modules.forEach { print($0.dump()) }
            print("Top CPU:", cpuList.map { "\($0.name) \(String(format: "%.1f", $0.cpu))%" })
            print("Top MEM:", memList.map { "\($0.name) \(fmtBytes($0.mem))" })
            exit(0)
        }
        // Status items are inserted to the left of existing ones, so install in reverse.
        for m in modules.reversed() where m.enabled && m.available { install(m) }
        tick()
        startTimer()
        // Test hook: --open <module id> opens that popup (used for measuring popup cost).
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count,
           let m = modules.first(where: { $0.id == CommandLine.arguments[i + 1] && $0.item != nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.popup.toggle(m) }
        }
        // NotchOverflow: when this item is hidden behind the notch, NotchOverflow shows it to the
        // left of the notch and asks us to open its popup right there (opt-in via the
        // NotchOverflowOpensAtAnchor Info.plist key), so the popup never appears out of place.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("NotchOverflow.openItem"), object: Bundle.main.bundleIdentifier, queue: .main
        ) { [weak self] n in
            guard let self, let u = n.userInfo, let name = u["item"] as? String,
                  let x = u["x"] as? Double, let y = u["y"] as? Double, let w = u["w"] as? Double, let h = u["h"] as? Double,
                  let m = self.modules.first(where: { "meterbar." + $0.id == name && $0.item != nil }) else { return }
            self.popup.toggle(m, anchor: NSRect(x: x, y: y, width: w, height: h))
        }
        // NotchOverflow also asks for live images of the meters it is showing for us (opt-in via
        // the NotchOverflowSendsItemImages Info.plist key). The request lists autosave names and
        // must be renewed within 10 s, so we stop sending if NotchOverflow goes away.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("NotchOverflow.wantImages"), object: Bundle.main.bundleIdentifier, queue: .main
        ) { [weak self] n in
            guard let self else { return }
            let names = (n.userInfo?["items"] as? [String]) ?? []
            let ids = Set(names.compactMap { $0.hasPrefix("meterbar.") ? String($0.dropFirst(9)) : nil })
            if ids != self.liveWanted { self.liveSent = [:] }          // send the new ones straight away
            self.liveWanted = ids
            self.liveUntil = Date().addingTimeInterval(10)
            self.sendLiveImages()
        }
        // Stop all sampling while the display sleeps or the session is locked / switched away.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.pause() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.startTimer(); self?.tick() }
        }
    }
    func pause() { popup.close(); timer?.invalidate(); timer = nil }

    // MARK: Live images for NotchOverflow
    var liveWanted: Set<String> = []                 // module ids NotchOverflow is showing
    var liveUntil = Date.distantPast
    var liveSent: [String: String] = [:]             // module id → widget key last sent

    func sendLiveImages() {
        guard Date() < liveUntil, !liveWanted.isEmpty else { return }
        for m in modules where liveWanted.contains(m.id) && m.item != nil {
            let k = m.widgetKey()
            if let k, liveSent[m.id] == k { continue }              // unchanged since last time
            guard let (png, size) = renderWidget(m) else { continue }
            liveSent[m.id] = k ?? UUID().uuidString
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("NotchOverflow.itemImage"), object: Bundle.main.bundleIdentifier,
                userInfo: ["item": "meterbar." + m.id, "png": png, "w": Double(size.width), "h": Double(size.height)],
                deliverImmediately: true)
        }
    }

    /// The widget exactly as it would appear in the menu bar, as a 2× PNG.
    func renderWidget(_ m: Module) -> (Data, NSSize)? {
        let h = (m.widget?.bounds.height).flatMap { $0 > 0 ? $0 : nil } ?? 24
        let size = NSSize(width: m.item?.length ?? m.widgetWidth(), height: h)
        guard size.width > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (m.widget?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            m.drawWidget(NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { ($0, size) }
    }
    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func install(_ m: Module) {
        let item = NSStatusBar.system.statusItem(withLength: m.widgetWidth())
        item.autosaveName = "meterbar." + m.id
        if let b = item.button {
            let v = WidgetView(m)
            v.frame = b.bounds; v.autoresizingMask = [.width, .height]
            b.addSubview(v)
            m.widget = v
        }
        m.item = item
    }
    func uninstall(_ m: Module) {
        if popup.module === m { popup.close() }
        if let i = m.item { NSStatusBar.system.removeStatusItem(i) }
        m.item = nil; m.widget = nil
    }
    func setEnabled(_ m: Module, _ on: Bool) {
        m.enabled = on
        if on && m.item == nil && m.available { m.update(); install(m) } else if !on { uninstall(m) }
    }
    func relayout(_ m: Module) { m.item?.length = m.widgetWidth(); m.widget?.needsDisplay = true }
    func toggle(_ m: Module) { popup.toggle(m) }
    func showSettings() {
        if settings == nil { settings = SettingsWindow(host: self) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.window.makeKeyAndOrderFront(nil)
    }
    func tick() {
        autoreleasepool {
            let open = popup.module
            if sensors.item == nil && (open is CPUModule || open is GPUModule) { sensors.update() }
            for m in modules where m.item != nil {
                m.update()
                let w = m.widgetWidth()
                if let item = m.item, abs(item.length - w) > 0.5 { item.length = w; m.widget?.lastKey = nil }
                m.widget?.refresh()
            }
            if let open {
                popup.refresh()
            }
            sendLiveImages()
        }
    }
}

// MARK: - Screenshot renderer (--screenshots <dir> [seconds]) — produces the README popup and widget images
// (the README's top image is a real screen capture, not rendered here)

enum Screenshots {
    static var active = false
    static let looks: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

    static func run(_ host: AppDelegate, dir: String, seconds: Int) {
        active = true
        host.sensors.forceFull = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Sample real data for a while so the history charts fill in; top runs alongside.
        host.procs.start(sortBy: "cpu", interval: 2)
        for _ in 0..<max(seconds, 3) {
            host.modules.forEach { $0.update() }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        let cpuList = host.procs.byCPU
        host.procs.start(sortBy: "mem", interval: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let memList = host.procs.byMem
        host.procs.stop()
        host.procs.byCPU = cpuList; host.procs.byMem = memList

        let mods = host.modules.filter { $0.available }
        for (look, name) in looks {
            guard let ap = NSAppearance(named: name) else { continue }
            mods.forEach { $0.styleOverride = $0.styles[0] }
            for m in mods { save(shadowed(popup(m, ap)), "\(dir)/popup-\(m.id)-\(look).png") }
            save(menuBar(mods, ap, dark: look == "dark"), "\(dir)/menubar-\(look).png")
            save(gallery(mods, ap, dark: look == "dark"), "\(dir)/widgets-\(look).png")
        }
        print("Saved screenshots to \(dir)")
    }

    // A 2× bitmap of the given point size; `draw` runs with it as the current (unflipped) context.
    static func canvas(_ size: NSSize, _ ap: NSAppearance, _ draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ap.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func save(_ rep: NSBitmapImageRep, _ path: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    // The popup exactly as the app draws it (content + footer, rounded corners).
    static func popup(_ m: Module, _ ap: NSAppearance) -> NSBitmapImageRep {
        let L = Layout(w: 280, dry: true); m.drawPopup(L)
        let content = ceil(L.y + 8), h = content + 36
        let v = PopupView(frame: NSRect(x: 0, y: 0, width: 280, height: h))
        v.module = m; v.footer = 36; v.contentHeight = content; v.appearance = ap
        // Draw exactly like the live popup does: into a transparent, flipped 2× bitmap.
        let w = 560, hp = Int(h * 2)
        let ctx = CGContext(data: nil, width: w, height: hp, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: 2, y: 2); ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ap.performAsCurrentDrawingAppearance { v.paint() }
        NSGraphicsContext.restoreGraphicsState()
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        rep.size = NSSize(width: 280, height: h)
        rep.isOpaque = false   // keep the transparent rounded corners when composited
        return rep
    }
    static func withShadow(_ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 16; sh.shadowOffset = NSSize(width: 0, height: -5)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }
    static func shadowed(_ p: NSBitmapImageRep) -> NSBitmapImageRep {
        let pad: CGFloat = 24
        return canvas(NSSize(width: p.size.width + pad * 2, height: p.size.height + pad * 2), NSApp.effectiveAppearance) {
            withShadow { p.draw(in: NSRect(x: pad, y: pad, width: p.size.width, height: p.size.height)) }
        }
    }
    // Widgets side by side, the way they sit in the menu bar.
    static let itemGap: CGFloat = 15   // matches a typical NSStatusItemSpacing
    static func drawWidgets(_ mods: [Module], at origin: NSPoint, height h: CGFloat) {
        var x = origin.x
        for m in mods {
            let w = m.widgetWidth()
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform(); t.translateX(by: x, yBy: origin.y); t.concat()
            m.drawWidget(NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            x += w + itemGap
        }
    }
    static func stripWidth(_ mods: [Module]) -> CGFloat { mods.map { $0.widgetWidth() }.reduce(0, +) + itemGap * CGFloat(mods.count - 1) }
    static func barColor(_ dark: Bool) -> NSColor { dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1) }
    static func menuBar(_ mods: [Module], _ ap: NSAppearance, dark: Bool) -> NSBitmapImageRep {
        let h: CGFloat = 28, pad: CGFloat = 14
        return canvas(NSSize(width: stripWidth(mods) + pad * 2, height: h), ap) {
            barColor(dark).setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: stripWidth(mods) + pad * 2, height: h), xRadius: 8, yRadius: 8).fill()
            drawWidgets(mods, at: NSPoint(x: pad, y: 2), height: 24)
        }
    }
    // Every widget style of every module, with captions.
    static func gallery(_ mods: [Module], _ ap: NSAppearance, dark: Bool) -> NSBitmapImageRep {
        let rowH: CGFloat = 50, labelW: CGFloat = 86, pad: CGFloat = 18, gap: CGFloat = 26
        var widest: CGFloat = 0
        for m in mods {
            var w: CGFloat = 0
            for st in m.styles {
                m.styleOverride = st
                w += max(m.widgetWidth(), Draw.width(SettingsWindow.styleNames[st] ?? st, 9)) + gap
            }
            widest = max(widest, w)
        }
        let size = NSSize(width: pad * 2 + labelW + widest - gap, height: pad * 2 + rowH * CGFloat(mods.count))
        let rep = canvas(size, ap) {
            barColor(dark).setFill(); NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).fill()
            for (r, m) in mods.enumerated() {
                let y = size.height - pad - rowH * CGFloat(r + 1)
                Draw.text(m.title, x: pad, y: y + 22, size: 12, weight: .semibold)
                var x = pad + labelW
                for st in m.styles {
                    m.styleOverride = st
                    let caption = SettingsWindow.styleNames[st] ?? st
                    let cw = max(m.widgetWidth(), Draw.width(caption, 9))
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform(); t.translateX(by: x + (cw - m.widgetWidth()) / 2, yBy: y + 18); t.concat()
                    m.drawWidget(NSRect(x: 0, y: 0, width: m.widgetWidth(), height: 24))
                    NSGraphicsContext.restoreGraphicsState()
                    Draw.text(caption, x: x + cw / 2, y: y + 4, size: 9, color: .secondaryLabelColor, align: .center)
                    x += cw + gap
                }
            }
        }
        mods.forEach { $0.styleOverride = $0.styles[0] }
        return rep
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
