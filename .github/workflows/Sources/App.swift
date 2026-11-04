import SwiftUI
import AVFoundation

// MARK: - Темп (BPM растёт по ходу игры) — общий для музыки и нот
enum Tempo {
    static func bpm(_ n: Int) -> Double { min(100 + Double(n / 16) * 3, 170) }
    static func len(_ n: Int) -> Double { 60 / bpm(n) }
    private static var cache: [Double] = [0]
    static func time(_ n: Int) -> Double {
        while cache.count <= n { let k = cache.count - 1; cache.append(cache[k] + len(k)) }
        return cache[n]
    }
}

struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / 9007199254740992.0 }
}

// MARK: - Синтезатор: бесконечная музыка, время игры = счётчик сэмплов
final class Synth {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let sr = 44100.0
    var samples: Int64 = 0
    var hitCounter = 0
    private var lastHit = 0
    private var hitT = 10.0
    private var beatIdx = 0
    private var beatStart = 0.0
    private var beatLen = Tempo.len(0)
    private var kickPh = 0.0
    private var noise: UInt32 = 1
    private var latency = 0.0
    private let arp = [0, 1, 2, 3, 2, 1, 2, 3]
    private let roots: [Double] = [55, 43.65, 65.41, 49]
    private let chords: [[Double]] = [
        [220, 261.63, 329.63, 440], [174.61, 220, 261.63, 349.23],
        [261.63, 329.63, 392, 523.25], [196, 246.94, 293.66, 392]
    ]

    var time: Double { Double(samples) / sr - latency }

    func start() throws {
        if engine.isRunning { engine.pause() }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback)
        try s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
        latency = s.outputLatency + s.ioBufferDuration
        samples = 0; beatIdx = 0; beatStart = 0; beatLen = Tempo.len(0)
        hitT = 10; lastHit = hitCounter
        if node == nil {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
            let n = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl in
                self.render(Int(frames), abl)
                return noErr
            }
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: fmt)
            node = n
        }
        try engine.start()
    }

    func stop() { engine.pause() }

    private func render(_ frames: Int, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let L = bufs[0].mData!.assumingMemoryBound(to: Float.self)
        let R = bufs[1].mData!.assumingMemoryBound(to: Float.self)
        let twoPi = 2 * Double.pi
        for i in 0..<frames {
            let t = Double(samples + Int64(i)) / sr
            if t >= beatStart + beatLen {
                beatStart += beatLen; beatIdx += 1; beatLen = Tempo.len(beatIdx)
            }
            let tb = t - beatStart
            if hitCounter != lastHit { lastHit = hitCounter; hitT = 0 }
            var v = 0.0
            // кик
            kickPh += twoPi * (45 + 110 * exp(-tb * 30)) / sr
            v += sin(kickPh) * exp(-tb * 12) * 0.8
            // хэт на доле «и»
            let x = tb - beatLen / 2
            if x >= 0 {
                noise = noise &* 1664525 &+ 1013904223
                let nz = Double(Int32(bitPattern: noise)) / 2147483648.0
                v += nz * exp(-x * 70) * 0.18
            }
            let chord = (beatIdx / 4) % 4
            // бас
            v += sin(twoPi * roots[chord] * tb) * exp(-tb * 2.5) * 0.35
            // арпеджио (после 16-й доли)
            if beatIdx >= 16 {
                let half = beatLen / 2
                let step = tb >= half ? 1 : 0
                let te = tb - Double(step) * half
                let f = chords[chord][arp[(beatIdx * 2 + step) % 8]]
                let ph = twoPi * f * te
                v += (sin(ph) + 0.3 * sin(2 * ph)) * exp(-te * 7) * 0.16
            }
            // звук попадания
            if hitT < 0.15 {
                v += sin(twoPi * 1500 * hitT) * exp(-hitT * 45) * 0.35
                hitT += 1 / sr
            }
            let o = Float(tanh(v * 0.9))
            L[i] = o; R[i] = o
        }
        samples += Int64(frames)
    }
}

// MARK: - Игровая логика
struct Note { var t: Double; var x: CGFloat; var y: CGFloat; var appr: Double; var done = false }
struct FX { var x: CGFloat; var y: CGFloat; var born: Double; var kind: Int }

final class Game: ObservableObject {
    enum Phase { case menu, playing, over }
    @Published var phase = Phase.menu
    @Published var best = UserDefaults.standard.integer(forKey: "nb_best")
    @Published var record = false

    let synth = Synth()
    var notes: [Note] = []
    var fx: [FX] = []
    var slot = 16
    var rng = RNG(s: 1)
    var lx = 0.5, ly = 0.5
    var score = 0, combo = 0, maxCombo = 0, total = 0
    var accSum = 0.0, hp = 100.0
    var ending = false
    var size = CGSize(width: 390, height: 844)

    var now: Double { synth.time }
    var acc: Double { total == 0 ? 1 : accSum / Double(300 * total) }
    func radius() -> CGFloat { max(30, min(size.width * 0.11, 46)) }

    func start() {
        notes = []; fx = []; slot = 16
        rng = RNG(s: UInt64.random(in: 1...UInt64.max))
        lx = 0.5; ly = 0.5
        score = 0; combo = 0; maxCombo = 0; total = 0; accSum = 0; hp = 100
        record = false; ending = false
        UIApplication.shared.isIdleTimerDisabled = true
        try? synth.start()
        phase = .playing
    }

    func end() {
        synth.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        record = score > best
        if record { best = score; UserDefaults.standard.set(best, forKey: "nb_best") }
        phase = .over
    }

    func spawn(_ s: Int) {
        let n = s / 2, half = s % 2 == 1
        let p = half ? (n < 48 ? 0 : min(Double(n - 48) / 400, 0.5)) : min(0.55 + Double(n) / 300, 0.9)
        let r = rng.unit(), a = rng.unit(), d = rng.unit()
        guard r < p else { return }
        let dist = min(0.12 + Double(n) * 0.0015, 0.45) * (0.6 + 0.4 * d)
        lx = min(max(lx + cos(a * 2 * Double.pi) * dist, 0.1), 0.9)
        ly = min(max(ly + sin(a * 2 * Double.pi) * dist * 0.7, 0.2), 0.82)
        let t = Tempo.time(n) + (half ? Tempo.len(n) / 2 : 0)
        notes.append(Note(t: t, x: CGFloat(lx), y: CGFloat(ly), appr: max(0.5, 0.95 - Double(n) / 400)))
    }

    func tick() {
        guard phase == .playing else { return }
        let t = now
        while Tempo.time(slot / 2) + (slot % 2 == 1 ? Tempo.len(slot / 2) / 2 : 0) < t + 3 {
            spawn(slot); slot += 1
        }
        for i in notes.indices where !notes[i].done && t > notes[i].t + 0.16 {
            notes[i].done = true
            combo = 0; hp -= 12; total += 1
            fx.append(FX(x: notes[i].x, y: notes[i].y, born: t, kind: 0))
        }
        notes.removeAll { $0.done }
        fx.removeAll { t - $0.born > 0.5 }
        if hp <= 0 && !ending {
            ending = true
            DispatchQueue.main.async { self.end() }
        }
    }

    func tap(_ p: CGPoint) {
        guard phase == .playing else { return }
        let t = now, r = radius()
        var bi = -1
        for i in notes.indices where !notes[i].done {
            let dt = notes[i].t - t
            if dt > 0.25 || dt < -0.16 { continue }
            let dx = notes[i].x * size.width - p.x
            let dy = notes[i].y * size.height - p.y
            if dx * dx + dy * dy <= r * r * 1.5 {
                if bi < 0 || notes[i].t < notes[bi].t { bi = i }
            }
        }
        guard bi >= 0 else { return }
        let off = abs(t - notes[bi].t)
        let kind = off < 0.06 ? 3 : (off < 0.11 ? 2 : 1)
        let pts = [0, 50, 100, 300][kind]
        notes[bi].done = true
        combo += 1; maxCombo = max(maxCombo, combo); total += 1
        accSum += Double(pts)
        score += pts * (1 + combo / 25)
        hp = min(100, hp + [0, 1, 2, 4][kind])
        synth.hitCounter += 1
        fx.append(FX(x: notes[bi].x, y: notes[bi].y, born: t, kind: kind))
    }
}

// MARK: - Тач с мультитачем (чтобы бить двумя пальцами)
struct TouchPad: UIViewRepresentable {
    var onTouch: (CGPoint) -> Void
    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        v.cb = onTouch
        return v
    }
    func updateUIView(_ v: PadView, context: Context) { v.cb = onTouch }
    final class PadView: UIView {
        var cb: ((CGPoint) -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { cb?(t.location(in: self)) }
        }
    }
}

// MARK: - Экраны
struct PlayView: View {
    @ObservedObject var g: Game

    var body: some View {
        ZStack {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    _ = tl.date
                    g.size = size
                    g.tick()
                    draw(ctx, size)
                }
            }
            TouchPad { g.tap($0) }
        }
        .ignoresSafeArea()
    }

    func draw(_ c: GraphicsContext, _ s: CGSize) {
        let t = g.now, r = g.radius()
        for n in g.notes.reversed() where !n.done {
            let dt = n.t - t
            if dt > n.appr { continue }
            let p = CGPoint(x: n.x * s.width, y: n.y * s.height)
            let a = min(1, (n.appr - dt) / 0.25)
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            c.fill(circle, with: .color(Color.cyan.opacity(0.25 * a)))
            c.stroke(circle, with: .color(Color.white.opacity(a)), lineWidth: 4)
            let k = r * (1 + 2.2 * CGFloat(max(0, dt) / n.appr))
            let ring = Path(ellipseIn: CGRect(x: p.x - k, y: p.y - k, width: 2 * k, height: 2 * k))
            c.stroke(ring, with: .color(Color.pink.opacity(a)), lineWidth: 3)
        }
        let cols: [Color] = [.red, .yellow, .green, .cyan]
        let txt = ["✕", "50", "100", "300"]
        for f in g.fx {
            let age = t - f.born
            c.draw(Text(txt[f.kind]).font(.system(size: 22, weight: .heavy))
                    .foregroundColor(cols[f.kind].opacity(max(0, 1 - age * 2))),
                   at: CGPoint(x: f.x * s.width, y: f.y * s.height - CGFloat(age * 40)))
        }
        // HUD
        let w = s.width - 40
        c.fill(Path(roundedRect: CGRect(x: 20, y: 52, width: w, height: 8), cornerRadius: 4),
               with: .color(Color.white.opacity(0.15)))
        c.fill(Path(roundedRect: CGRect(x: 20, y: 52, width: w * CGFloat(max(0, g.hp) / 100), height: 8), cornerRadius: 4),
               with: .color(g.hp > 30 ? Color.green : Color.red))
        c.draw(Text("\(g.score)").font(.system(size: 30, weight: .black, design: .monospaced)).foregroundColor(.white),
               at: CGPoint(x: s.width - 20, y: 86), anchor: .trailing)
        c.draw(Text(String(format: "%.1f%%", g.acc * 100)).font(.system(size: 16, design: .monospaced)).foregroundColor(.gray),
               at: CGPoint(x: s.width - 20, y: 114), anchor: .trailing)
        c.draw(Text("\(g.combo)x").font(.system(size: 38, weight: .black)).foregroundColor(.cyan),
               at: CGPoint(x: 20, y: s.height - 60), anchor: .leading)
    }
}

struct MenuView: View {
    @ObservedObject var g: Game
    var body: some View {
        VStack(spacing: 24) {
            Text("NEON BEAT ∞")
                .font(.system(size: 38, weight: .black, design: .monospaced))
                .foregroundColor(.cyan).shadow(color: .cyan, radius: 12)
            Text("Рекорд: \(g.best)").foregroundColor(.gray)
            Button { g.start() } label: {
                Text("ИГРАТЬ").font(.system(size: 22, weight: .heavy))
                    .padding(.horizontal, 50).padding(.vertical, 14)
                    .background(Color.cyan).foregroundColor(.black).cornerRadius(16)
            }
            Text("Тапай по кругу, когда розовое кольцо сожмётся до белого. Карта бесконечная: темп растёт, промах отнимает HP. Бей рекорд!")
                .font(.footnote).foregroundColor(.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
        }
    }
}

struct OverView: View {
    @ObservedObject var g: Game
    var body: some View {
        VStack(spacing: 16) {
            Text("ИГРА ОКОНЧЕНА").font(.system(size: 28, weight: .black)).foregroundColor(.white)
            if g.record {
                Text("НОВЫЙ РЕКОРД!").font(.system(size: 20, weight: .heavy)).foregroundColor(.yellow)
            }
            Text("\(g.score)").font(.system(size: 56, weight: .black, design: .monospaced)).foregroundColor(.cyan)
            Text("Макс. комбо: \(g.maxCombo)   Точность: \(String(format: "%.1f", g.acc * 100))%")
                .foregroundColor(.gray)
            Text("Рекорд: \(g.best)").foregroundColor(.gray)
            Button { g.start() } label: {
                Text("ЕЩЁ РАЗ").font(.system(size: 20, weight: .heavy))
                    .padding(.horizontal, 40).padding(.vertical, 12)
                    .background(Color.cyan).foregroundColor(.black).cornerRadius(14)
            }
            Button("В меню") { g.phase = .menu }.foregroundColor(.gray)
        }
    }
}

struct RootView: View {
    @StateObject var g = Game()
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.12), .black],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            switch g.phase {
            case .menu: MenuView(g: g)
            case .playing: PlayView(g: g)
            case .over: OverView(g: g)
            }
        }
    }
}

@main
struct NeonBeatApp: App {
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}
