// PortalTouch: turns touches on a Wormhole Display (Meta Portal) into mouse input on the Mac display
// that is being shown on it. Discovers _wormholetouch._tcp via Bonjour; acts only while an attached
// display has the same name as the Portal (i.e. only while this Mac is extending/mirroring to it).
import AppKit
import ApplicationServices
import Network

let log = { (s: String) in FileHandle.standardError.write(("PortalTouch: " + s + "\n").data(using: .utf8)!) }

final class Gesture {
    enum State { case idle, pending, dragging, scrolling, consumed }
    var state = State.idle
    var start = CGPoint.zero
    var last = CGPoint.zero
    var lastCentroid = CGPoint.zero
    var longPress: DispatchWorkItem?
    var lastTapTime = Date.distantPast
    var lastTapPoint = CGPoint.zero
    var clickState: Int64 = 1
    let slop: CGFloat = 10          // points before a touch becomes a drag
    let longPressDelay = 0.55       // seconds held still = right click

    func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
    }
    func click(_ p: CGPoint, right: Bool = false) {
        if right {
            post(.rightMouseDown, p, button: .right); post(.rightMouseUp, p, button: .right)
            return
        }
        let now = Date()
        let dbl = now.timeIntervalSince(lastTapTime) < 0.4 && hypot(p.x - lastTapPoint.x, p.y - lastTapPoint.y) < 24
        clickState = dbl ? min(clickState + 1, 3) : 1
        lastTapTime = now; lastTapPoint = p
        post(.leftMouseDown, p, clicks: clickState); post(.leftMouseUp, p, clicks: clickState)
    }
    func scroll(dx: CGFloat, dy: CGFloat) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }
    func cancelLongPress() { longPress?.cancel(); longPress = nil }

    func handle(count: Int, points: [CGPoint]) {
        guard let p = points.first else { return }
        switch state {
        case .idle:
            if count == 1 {
                state = .pending; start = p; last = p
                post(.mouseMoved, p)
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.state == .pending else { return }
                    self.click(self.start, right: true); self.state = .consumed
                }
                longPress = work
                DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
            } else if count >= 2 {
                state = .scrolling; lastCentroid = centroid(points)
            }
        case .pending:
            if count == 0 { cancelLongPress(); click(start); state = .idle }
            else if count >= 2 { cancelLongPress(); state = .scrolling; lastCentroid = centroid(points) }
            else if hypot(p.x - start.x, p.y - start.y) > slop {
                cancelLongPress()
                post(.leftMouseDown, start); post(.leftMouseDragged, p); last = p; state = .dragging
            }
        case .dragging:
            if count == 0 { post(.leftMouseUp, p); state = .idle }
            else { post(.leftMouseDragged, p); last = p }
        case .scrolling:
            if count >= 2 {
                let c = centroid(points)
                scroll(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y)
                lastCentroid = c
            } else if count == 0 { state = .idle }
        case .consumed:
            if count == 0 { state = .idle }
        }
    }
    func cancel() {
        cancelLongPress()
        if state == .dragging { post(.leftMouseUp, last) }
        state = .idle
    }
    func centroid(_ pts: [CGPoint]) -> CGPoint {
        CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }
}

/// Global CG bounds (top-left origin) of the attached display named `name`, if any.
func displayBounds(named name: String) -> CGRect? {
    // macOS names AirPlay displays "<receiver name> (AirPlay)".
    let wanted = name.lowercased()
    for screen in NSScreen.screens {
        let n = screen.localizedName.lowercased()
        guard n == wanted || n.hasPrefix(wanted + " (") else { continue }
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return CGDisplayBounds(id)
        }
    }
    return nil
}

final class PortalLink {
    let endpoint: NWEndpoint
    let display: String
    var conn: NWConnection?
    var buffer = Data()
    let gesture = Gesture()
    var retry: DispatchWorkItem?
    var stopped = false
    var warnedNoDisplay = false
    var loggedFirst = false

    init(endpoint: NWEndpoint, display: String) { self.endpoint = endpoint; self.display = display }

    func connect() {
        guard !stopped else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        conn = c
        // Bonjour resolution occasionally stalls in "preparing"; start over rather than wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak c] in
            guard let self, let c, self.conn === c, c.state != .ready else { return }
            log("connect timed out; retrying"); c.cancel()
        }
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: log("connected to \(self.display)"); self.receive()
            case .failed, .cancelled: self.scheduleRetry()
            default: log("connection state \(st)")
            }
        }
        c.start(queue: .main)
    }
    func scheduleRetry() {
        guard !stopped, retry == nil else { return }
        gesture.cancel()
        let w = DispatchWorkItem { [weak self] in self?.retry = nil; self?.connect() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
    func stop() { stopped = true; retry?.cancel(); conn?.cancel(); gesture.cancel() }

    func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if done || err != nil { self.conn?.cancel(); return }
            self.receive()
        }
    }
    func drain() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
        if buffer.count > 65536 { buffer.removeAll() }
    }
    func handle(_ line: String) {
        let f = line.split(separator: " ")
        guard let kind = f.first else { return }
        if kind == "C" { gesture.cancel(); return }
        guard kind == "P", f.count >= 4, let count = Int(f[1]) else { return }
        // Only act while this Mac has the Portal attached as a display.
        guard let b = displayBounds(named: display) else {
            if !warnedNoDisplay { log("touch ignored: no display named \(display) attached"); warnedNoDisplay = true }
            gesture.cancel(); return
        }
        if warnedNoDisplay || !loggedFirst { log("touch -> \(display) at \(b)"); warnedNoDisplay = false; loggedFirst = true }
        var pts: [CGPoint] = []
        var i = 2
        while i + 1 < f.count, let x = Double(f[i]), let y = Double(f[i + 1]) {
            let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
            pts.append(CGPoint(x: b.minX + CGFloat(cx) * (b.width - 1), y: b.minY + CGFloat(cy) * (b.height - 1)))
            i += 2
        }
        gesture.handle(count: count, points: pts)
    }
}

final class Discovery {
    var browser: NWBrowser?
    var links: [String: PortalLink] = [:]

    func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_wormholetouch._tcp", domain: nil), using: .tcp)
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        b.stateUpdateHandler = { st in if case .failed(let e) = st { log("browse failed: \(e)") } }
        b.start(queue: .main)
    }
    func update(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            var display = name
            if case let .bonjour(txt) = r.metadata, let d = txt["display"], !d.isEmpty { display = d }
            seen.insert(name)
            if links[name] == nil {
                log("found \(display)")
                let l = PortalLink(endpoint: r.endpoint, display: display)
                links[name] = l
                l.connect()
            }
        }
        for (name, l) in links where !seen.contains(name) { l.stop(); links[name] = nil }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) {
    log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
}
let discovery = Discovery()
discovery.start()
log("running")
app.run()
