import SwiftUI
import AVFoundation

// MARK: - Темп (BPM растёт по ходу игры) — общий для музыки и нот
enum Tempo {
    static var speed = 1.0
    static var base = 100.0
    static func bpm(_ n: Int) -> Double { min(base + Double(n / 16) * 3, base * 1.7) * speed }
    static func len(_ n: Int) -> Double { 60 / bpm(n) }
    private static var cache: [Double] = [0]
    static func reset() { cache = [0] }
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
    private let orders: [[Int]] = [[0, 1, 2, 3], [0, 2, 1, 3], [1, 0, 3, 2], [1, 3, 0, 2]]
    var genre = 0
    var trk = Track.all[0], chosen = Track.all[0]
    var forceBase: Double? = nil
    private var isPreview = false, previewing = 0
    private var keepGenre: Int? = nil
    private var curBar = -1, curStep = -1
    private var padF = [110.0, 130.0, 165.0], bassF = 55.0, melF = 0.0
    private let roots: [Double] = [55, 43.65, 65.41, 49]
    private let chords: [[Double]] = [
        [220, 261.63, 329.63, 440], [174.61, 220, 261.63, 349.23],
        [261.63, 329.63, 392, 523.25], [196, 246.94, 293.66, 392]
    ]

    var offset = 0.0
    var musicVol = 1.0, sfxVol = 1.0, pulse = 0.0
    var time: Double { Double(samples) / sr - latency - offset }

    func start() throws {
        if engine.isRunning { engine.pause() }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback)
        try s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
        latency = s.outputLatency + s.ioBufferDuration
        if isPreview { isPreview = false } else { trk = chosen; if let k = keepGenre { genre = k; keepGenre = nil } }
        Tempo.base = forceBase ?? trk.bpm; forceBase = nil; Tempo.reset()
        curBar = -1; curStep = -1
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
    func preview(_ tr: Track) {
        if keepGenre == nil { keepGenre = genre }
        trk = tr; genre = tr.genre; isPreview = true; Tempo.speed = 1
        try? start()
        previewing += 1
        let id = previewing
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if let me = self, me.previewing == id { me.stop() }
        }
    }
    private func fq(_ d: Int) -> Double {
        let oct = Int(floor(Double(d) / 7)), k = ((d % 7) + 7) % 7
        return trk.root * pow(2, Double(trk.scale[k] + 12 * oct) / 12)
    }
    private func hash(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var z = trk.seed &+ UInt64(truncatingIfNeeded: a) &* 0x9E3779B97F4A7C15 &+ UInt64(truncatingIfNeeded: b) &* 0xBF58476D1CE4E5B9 &+ UInt64(truncatingIfNeeded: c) &* 0x94D049BB133111EB
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / 9007199254740992.0
    }
    // мелодия: фразы A A B A, повторяются парами и меняются каждые 8 тактов
    private func melody(_ bar: Int, _ step: Int) -> Int? {
        let cd = trk.prog[bar % trk.prog.count]
        let b = bar % 4
        let sb = (bar / 8) * 10 + (b == 2 ? 1 : 0)
        if step % 2 == 1 && hash(sb, step, 1) < 0.3 { return nil }
        if step == 7 && b == 3 && hash(sb, 9, 3) < 0.5 { return nil }
        let pool = [0, 2, 4, 2, 1, 3, 5, 4]
        var d = cd + pool[Int(hash(sb, step, 2) * 8) % 8] + 7
        if b == 1 && step >= 6 { d += 1 }
        return d
    }
    func resume() { try? engine.start() }

    private func render(_ frames: Int, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let L = bufs[0].mData!.assumingMemoryBound(to: Float.self)
        let R = bufs[1].mData!.assumingMemoryBound(to: Float.self)
        let twoPi = 2 * Double.pi
        var lastTb = 0.0
        for i in 0..<frames {
            let t = Double(samples + Int64(i)) / sr
            if t >= beatStart + beatLen {
                beatStart += beatLen; beatIdx += 1; beatLen = Tempo.len(beatIdx)
            }
            let tb = t - beatStart
            lastTb = tb
            if hitCounter != lastHit { lastHit = hitCounter; hitT = 0 }
            var v = 0.0, h = 0.0
            // кик
            kickPh += twoPi * (45 + 110 * exp(-tb * 30)) / sr
            v += sin(kickPh) * exp(-tb * 12) * (genre == 2 ? 0.95 : (genre == 3 ? 0.5 : 0.8))
            // хэт на доле «и»
            let x = tb - beatLen / 2
            if x >= 0 && genre != 3 {
                noise = noise &* 1664525 &+ 1013904223
                let nz = Double(Int32(bitPattern: noise)) / 2147483648.0
                v += nz * exp(-x * 70) * (genre == 2 ? 0.26 : 0.18)
            }
            let bar = beatIdx / 4, bib = beatIdx % 4
            let half = beatLen / 2
            if bar != curBar {
                curBar = bar
                let cd = trk.prog[bar % trk.prog.count]
                padF = [fq(cd), fq(cd + 2), fq(cd + 4)]
                bassF = fq(cd - 7)
            }
            // снейр на 2 и 4
            if bib == 1 || bib == 3 {
                noise = noise &* 1664525 &+ 1013904223
                v += Double(Int32(bitPattern: noise)) / 2147483648.0 * exp(-tb * (genre == 1 ? 30 : 16)) * (genre == 3 ? 0.14 : 0.3)
            }
            // бас
            let bsin = sin(twoPi * bassF * tb)
            let bw = genre == 1 ? (bsin >= 0 ? 0.5 : -0.5) : bsin
            v += bw * exp(-(genre == 2 && x >= 0 ? x : tb) * (genre == 2 ? 6 : 2.5)) * 0.32
            if bar >= 1 {
                // пэд: аккорд плавно «дышит» в течение такта
                if genre != 1 {
                    let pe = sin(Double.pi * (Double(bib) * beatLen + tb) / (4 * beatLen))
                    v += (sin(twoPi * padF[0] * t) + sin(twoPi * padF[1] * t) + sin(twoPi * padF[2] * t)) * pe * 0.045
                }
                // мелодия по восьмым
                let st = bib * 2 + (tb >= half ? 1 : 0)
                if st != curStep {
                    curStep = st; melF = 0
                    if let d = melody(bar, st) { melF = fq(d) }
                }
                if melF > 0 {
                    let te = tb - (tb >= half ? half : 0)
                    let ph = twoPi * melF * te
                    var w = sin(ph) + 0.5 * sin(2 * ph) + 0.3 * sin(3 * ph)
                    if genre == 1 { w = sin(ph) >= 0 ? 0.6 : -0.6 }
                    else if genre == 3 { w = sin(ph + 0.3 * sin(twoPi * 5 * te)) }
                    v += w * exp(-te * (genre == 3 ? 3 : (genre == 2 ? 10 : 6))) * (genre == 3 ? 0.11 : 0.15)
                }
            }
            // звук попадания
            if hitT < 0.15 {
                h += sin(twoPi * 1500 * hitT) * exp(-hitT * 45) * 0.35 * sfxVol
                hitT += 1 / sr
            }
            let o = Float(tanh((v * musicVol + h) * 0.9))
            L[i] = o; R[i] = o
        }
        samples += Int64(frames)
        pulse = exp(-lastTb * 7)
    }
}

// MARK: - Игровая логика
struct Note {
    var t: Double; var x: CGFloat; var y: CGFloat; var appr: Double
    var kind = 0                       // 0 круг, 1 слайдер, 2 спиннер
    var dur = 0.0; var ex: CGFloat = 0; var ey: CGFloat = 0
    var started = false; var done = false
    var rep = 1; var tk = 0
    var follow = 0.0; var spun = 0.0
}
struct FX { var x: CGFloat; var y: CGFloat; var born: Double; var kind: Int }
final class Touches { var pts: [ObjectIdentifier: CGPoint] = [:] }

final class Game: ObservableObject {
    enum Phase { case menu, playing, over, mania, arcade }
    @Published var phase = Phase.menu
    @Published var paused = false
    @Published var record = false
    @Published var diff = UserDefaults.standard.object(forKey: "nb_diff") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(diff, forKey: "nb_diff") }
    }
    @Published var offsetMs = UserDefaults.standard.double(forKey: "nb_off") {
        didSet { UserDefaults.standard.set(offsetMs, forKey: "nb_off"); synth.offset = offsetMs / 1000 }
    }

    let names = ["Лёгкий", "Обычный", "Сложный"]
    let modNames = ["No Fail", "Easy", "Hard Rock", "Double Time", "Half Time", "Hidden", "Flashlight", "Sudden Death", "Auto"]
    let modInfo = ["не вылетаешь", "проще, ×0.5", "сложнее, ×1.1", "быстрее, ×1.2", "медленнее, ×0.5", "круги тают, ×1.06", "видно возле пальца, ×1.12", "промах = конец", "играет сам, без рекорда"]
    let skinNames = ["Неон", "Закат", "Лёд"]
    let pals: [[Color]] = [[.cyan, .pink, .yellow, .green], [.orange, .red, .yellow, .pink], [.mint, .blue, .white, .purple]]
    @Published var mods: Set<Int> = []
    @Published var orient = UserDefaults.standard.integer(forKey: "nb_orient") {
        didSet { UserDefaults.standard.set(orient, forKey: "nb_orient"); applyOrientation(orient) }
    }
    @Published var seedText = ""
    @Published var mode = 0
    @Published var skin = UserDefaults.standard.integer(forKey: "nb_skin") {
        didSet { UserDefaults.standard.set(skin, forKey: "nb_skin") }
    }
    @Published var vibe = !UserDefaults.standard.bool(forKey: "nb_novibe") {
        didSet { UserDefaults.standard.set(!vibe, forKey: "nb_novibe") }
    }
    @Published var musicVol = UserDefaults.standard.object(forKey: "nb_mv") as? Double ?? 1.0 {
        didSet { synth.musicVol = musicVol; UserDefaults.standard.set(musicVol, forKey: "nb_mv") }
    }
    @Published var sfxVol = UserDefaults.standard.object(forKey: "nb_sv") as? Double ?? 1.0 {
        didSet { synth.sfxVol = sfxVol; UserDefaults.standard.set(sfxVol, forKey: "nb_sv") }
    }
    let apprK = [1.25, 1.0, 0.8], missHP = [8.0, 12.0, 16.0], dens = [0.8, 1.0, 1.15]
    let synth = Synth()
    let touches = Touches()
    var notes: [Note] = [], fx: [FX] = []
    var slot = 16, blockUntil = 0.0, lastT = 0.0
    var rng = RNG(s: 1)
    var lx = 0.5, ly = 0.5
    var score = 0, combo = 0, maxCombo = 0, total = 0
    var accSum = 0.0, hp = 100.0
    var prevAng: Double? = nil
    var ending = false
    var seed: UInt64 = 0, prevCombo = 0, misses = 0
    var rec = Replay(seed: 0, diff: 1, mods: [], taps: [], frames: [])
    var replaying = false, replayNext = false, rpTap = 0, rpFrame = 0, lastRec = 0.0
    var rpPts: [CGPoint] = []
    @Published var practice = false
    @Published var tutorial = false
    @Published var genre = UserDefaults.standard.integer(forKey: "nb_genre") {
        didSet { UserDefaults.standard.set(genre, forKey: "nb_genre"); synth.genre = genre }
    }
    var offs: [(Double, Double)] = []
    var flashP = CGPoint(x: 200, y: 400)
    var trail: [(CGPoint, Double)] = []
    @Published var track = UserDefaults.standard.integer(forKey: "nb_track") {
        didSet {
            let i = min(max(track, 0), Track.all.count - 1)
            UserDefaults.standard.set(i, forKey: "nb_track")
            synth.chosen = Track.all[i]; synth.trk = Track.all[i]; genre = Track.all[i].genre
        }
    }
    @Published var duel = 0
    var duelScore = 0
    let hapticL = UIImpactFeedbackGenerator(style: .light), hapticH = UIImpactFeedbackGenerator(style: .heavy)
    var size = CGSize(width: 390, height: 844)

    init() { let ti = min(max(track, 0), Track.all.count - 1); synth.chosen = Track.all[ti]; synth.trk = Track.all[ti]; synth.genre = genre; synth.offset = offsetMs / 1000; synth.musicVol = musicVol; synth.sfxVol = sfxVol }

    func on(_ i: Int) -> Bool { mods.contains(i) }
    func toggleMod(_ i: Int) {
        if mods.contains(i) { mods.remove(i); return }
        mods.insert(i)
        if i == 3 { mods.remove(4) }; if i == 4 { mods.remove(3) }
        if i == 1 { mods.remove(2) }; if i == 2 { mods.remove(1) }
    }
    var palette: [Color] { pals[min(skin, 2)] }
    var mult: Double {
        if on(8) { return 0 }
        var m = 1.0
        if on(0) { m *= 0.5 }; if on(1) { m *= 0.5 }; if on(2) { m *= 1.1 }
        if on(3) { m *= 1.2 }; if on(4) { m *= 0.5 }; if on(5) { m *= 1.06 }; if on(6) { m *= 1.12 }
        return m
    }
    var hpLoss: Double { (practice || tutorial) ? 0 : missHP[diff] * (on(1) ? 0.5 : (on(2) ? 1.3 : 1)) }
    var apprMul: Double { on(1) ? 1.3 : (on(2) ? 0.7 : 1) }
    var rank: String {
        if acc >= 0.999 && misses == 0 { return "SS" }
        return acc >= 0.95 ? "S" : (acc >= 0.9 ? "A" : (acc >= 0.8 ? "B" : (acc >= 0.7 ? "C" : "D")))
    }

    var best: Int { UserDefaults.standard.integer(forKey: "nb_best_\(diff)") }
    var now: Double { synth.time }
    var acc: Double { total == 0 ? 1 : accSum / Double(300 * total) }
    func radius() -> CGFloat { max(30, min(size.width * 0.11, 46)) * (on(1) ? 1.15 : (on(2) ? 0.85 : 1)) }
    func need(_ n: Note) -> Double { n.dur * 1.4 * 2 * Double.pi }

    func start(daily: Bool = false) {
        replaying = replayNext; replayNext = false; rpTap = 0; rpFrame = 0; lastRec = 0
        notes = []; fx = []; slot = 16; blockUntil = 0; lastT = 0
        if daily { seed = UInt64(Date().timeIntervalSince1970 / 86400) &* 2654435761 }
        else if let v = UInt64(seedText) { seed = v }
        else if practice || tutorial { seed = 1 }
        else { seed = UInt64.random(in: 1...999_999_999) }
        rng = RNG(s: seed)
        Tempo.speed = on(3) ? 1.3 : ((on(4) || practice || tutorial) ? 0.75 : 1.0)
        if !replaying { rec = Replay(seed: seed, diff: diff, mods: Array(mods), taps: [], frames: []) }
        Tempo.reset()
        prevCombo = 0; misses = 0; offs = []
        lx = 0.5; ly = 0.5; prevAng = nil
        score = 0; combo = 0; maxCombo = 0; total = 0; accSum = 0; hp = 100
        record = false; ending = false; paused = false
        UIApplication.shared.isIdleTimerDisabled = true
        try? synth.start()
        phase = .playing
    }

    func pause() { guard phase == .playing, !paused else { return }; paused = true; synth.stop() }
    func resume() { paused = false; touches.pts = [:]; synth.resume() }
    func toMenu() {
        synth.stop(); paused = false; tutorial = false; replaying = false
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .menu
    }

    func end() {
        synth.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        score = Int(Double(score) * mult)
        let key = "nb_best_\(diff)"
        record = !(practice || tutorial || replaying) && score > UserDefaults.standard.integer(forKey: key)
        if record { UserDefaults.standard.set(score, forKey: key) }
        Stats.add(score: score, combo: maxCombo, hits: total)
        if !replaying && !tutorial { ReplayStore.add(ReplayMeta(id: UUID().uuidString, date: Date(), score: score, rank: rank, diff: diff), rec) }
        phase = .over
    }

    func spawn(_ s: Int) {
        let n = s / 2, half = s % 2 == 1
        let base = half ? (n < 48 ? 0 : min(Double(n - 48) / 400, 0.5)) : min(0.55 + Double(n) / 300, 0.9)
        let stream = n >= 32 && n % 32 >= 28
        let p = stream ? 1.0 : min(base * dens[diff], 0.95)
        let r = rng.unit(), a = rng.unit(), d = rng.unit(), k = rng.unit()
        let t = Tempo.time(n) + (half ? Tempo.len(n) / 2 : 0)
        guard t >= blockUntil else { return }
        let appr = max(0.45, (0.95 - Double(n) / 400) * apprK[diff] * apprMul)
        if !half && n >= 40 && n % 48 == 0 {          // спиннер
            let dur = Tempo.len(n) * 4
            notes.append(Note(t: t, x: 0.5, y: 0.5, appr: 0.6, kind: 2, dur: dur))
            blockUntil = t + dur + 0.5; lx = 0.5; ly = 0.5
            return
        }
        guard r < p else { return }
        let dist = min(0.12 + Double(n) * 0.0015, 0.45) * (0.6 + 0.4 * d) * (stream ? 0.35 : 1)
        lx = min(max(lx + cos(a * 2 * Double.pi) * dist * (size.width > size.height ? 0.55 : 1), 0.1), 0.9)
        ly = min(max(ly + sin(a * 2 * Double.pi) * dist * 0.7, 0.2), 0.82)
        if !half && n >= 24 && k < 0.2 && !stream {               // слайдер
            let rep = (n >= 64 && k < 0.08) ? 2 : 1
            let dur = Tempo.len(n) * (d < 0.5 ? 1 : 2) * Double(rep)
            let ang = (a + 0.5) * 2 * Double.pi
            let ex = min(max(lx + cos(ang) * 0.3, 0.1), 0.9)
            let ey = min(max(ly + sin(ang) * 0.2, 0.2), 0.82)
            notes.append(Note(t: t, x: CGFloat(lx), y: CGFloat(ly), appr: appr, kind: 1,
                              dur: dur, ex: CGFloat(ex), ey: CGFloat(ey), rep: rep))
            lx = ex; ly = ey; blockUntil = t + dur + 0.2
            return
        }
        notes.append(Note(t: t, x: CGFloat(lx), y: CGFloat(ly), appr: appr))
    }

    func miss(_ i: Int, _ t: Double) {
        notes[i].done = true
        combo = 0; hp -= hpLoss; total += 1
        fx.append(FX(x: notes[i].x, y: notes[i].y, born: t, kind: 0))
    }

    func finishSlider(_ i: Int, _ t: Double) {
        let n = notes[i]
        notes[i].done = true
        if n.follow >= n.dur * 0.7 {
            score += 30 * (1 + combo / 25); hp = min(100, hp + 3); synth.hitCounter += 1
            fx.append(FX(x: n.ex, y: n.ey, born: t, kind: 3))
        } else {
            combo = 0; hp -= hpLoss / 2
            fx.append(FX(x: n.ex, y: n.ey, born: t, kind: 0))
        }
    }

    func spin(_ i: Int, _ pts: [CGPoint]) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let p = pts.first, hypot(p.x - c.x, p.y - c.y) > 40 else { prevAng = nil; return }
        let a = atan2(Double(p.y - c.y), Double(p.x - c.x))
        if let pa = prevAng {
            var d = a - pa
            if d > Double.pi { d -= 2 * Double.pi } else if d < -Double.pi { d += 2 * Double.pi }
            notes[i].spun += abs(d)
        }
        prevAng = a
    }

    func finishSpinner(_ i: Int, _ t: Double) {
        let q = notes[i].spun / need(notes[i])
        notes[i].done = true; prevAng = nil; total += 1
        var kind = 0
        if q >= 1 {
            combo += 1; maxCombo = max(maxCombo, combo); accSum += 300
            score += 300 * (1 + combo / 25); hp = min(100, hp + 8); kind = 3
        } else if q >= 0.5 {
            accSum += 100; score += 100; kind = 2
        } else {
            combo = 0; hp -= hpLoss
        }
        if kind > 0 { synth.hitCounter += 1 }
        fx.append(FX(x: 0.5, y: 0.5, born: t, kind: kind))
    }

    func tick() {
        guard phase == .playing, !paused else { return }
        let t = now
        let dt = max(0, min(t - lastT, 0.1)); lastT = t
        while Tempo.time(slot / 2) + (slot % 2 == 1 ? Tempo.len(slot / 2) / 2 : 0) < t + 3 {
            spawn(slot); slot += 1
        }
        if replaying {
            while rpTap < rec.taps.count, rec.taps[rpTap][0] <= t {
                let k = rec.taps[rpTap]
                tap(CGPoint(x: k[1] * size.width, y: k[2] * size.height), at: k[0]); rpTap += 1
            }
            while rpFrame + 1 < rec.frames.count, rec.frames[rpFrame + 1][0] <= t { rpFrame += 1 }
            if rec.frames.isEmpty { rpPts = [] } else {
                let f = rec.frames[rpFrame]
                rpPts = stride(from: 1, to: f.count, by: 2).map { CGPoint(x: f[$0] * size.width, y: f[$0 + 1] * size.height) }
            }
        } else if t - lastRec >= 0.033 {
            lastRec = t
            rec.frames.append([t] + touches.pts.values.flatMap { [Double($0.x / size.width), Double($0.y / size.height)] })
        }
        let pts = replaying ? rpPts : Array(touches.pts.values), rr = radius()
        if let p = pts.first { flashP = p }
        if on(8) {
            for i in notes.indices where !notes[i].done && notes[i].kind < 2 && !notes[i].started && t >= notes[i].t {
                tap(CGPoint(x: notes[i].x * size.width, y: notes[i].y * size.height))
            }
        }
        for i in notes.indices where !notes[i].done {
            let n = notes[i]
            if n.kind == 0 {
                if t > n.t + 0.16 { miss(i, t) }
            } else if n.kind == 1 {
                if !n.started {
                    if t > n.t + 0.16 { miss(i, t) }
                } else {
                    let u = n.pathU(t)
                    let bx = (n.x + (n.ex - n.x) * u) * size.width
                    let by = (n.y + (n.ey - n.y) * u) * size.height
                    let fol = on(8) || pts.contains(where: { hypot($0.x - bx, $0.y - by) < rr * 2.4 })
                    if fol { notes[i].follow += dt }
                    let tkNow = Int(min(1, max(0, (t - n.t) / n.dur)) * Double(n.rep) * 3)
                    if tkNow > n.tk { notes[i].tk = tkNow; if fol { score += 10; synth.hitCounter += 1 } }
                    if t >= n.t + n.dur { finishSlider(i, t) }
                }
            } else {
                if t >= n.t && t < n.t + n.dur { if on(8) { notes[i].spun += need(n) / n.dur * dt * 1.2 } else { spin(i, pts) } }
                if t >= n.t + n.dur { finishSpinner(i, t) }
            }
        }
        notes.removeAll { $0.done }
        fx.removeAll { t - $0.born > 0.5 }
        if on(0) { hp = max(hp, 1) }
        if combo < prevCombo {
            misses += 1
            if vibe && !on(8) { hapticH.impactOccurred() }
            if on(7) { hp = 0 }
        }
        prevCombo = combo
        if hp <= 0 && !ending {
            ending = true
            DispatchQueue.main.async { self.end() }
        }
    }

    func tap(_ p: CGPoint, at: Double? = nil) {
        guard phase == .playing, !paused else { return }
        if replaying && at == nil { return }
        let t = at ?? now, r = radius()
        if !replaying { rec.taps.append([t, Double(p.x / size.width), Double(p.y / size.height)]) }
        var bi = -1
        for i in notes.indices where !notes[i].done && notes[i].kind < 2 && !notes[i].started {
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
        if notes[bi].kind == 1 { notes[bi].started = true } else { notes[bi].done = true }
        combo += 1; maxCombo = max(maxCombo, combo); total += 1
        accSum += Double(pts)
        score += pts * (1 + combo / 25)
        hp = min(100, hp + [0, 1, 2, 4][kind])
        synth.hitCounter += 1
        fx.append(FX(x: notes[bi].x, y: notes[bi].y, born: t, kind: kind))
        if vibe && !on(8) { hapticL.impactOccurred() }
        offs.append((t - notes[bi].t, t)); if offs.count > 12 { offs.removeFirst() }
    }
}

// MARK: - Треки (генерируемые композиции)
struct Track {
    var name: String; var genre: Int; var bpm: Double; var root: Double
    var scale: [Int]; var prog: [Int]; var seed: UInt64
    static let minor = [0, 2, 3, 5, 7, 8, 10], major = [0, 2, 4, 5, 7, 9, 11], dorian = [0, 2, 3, 5, 7, 9, 10]
    static let all: [Track] = [
        Track(name: "Neon Drive", genre: 0, bpm: 100, root: 110, scale: Track.minor, prog: [0, 5, 3, 4], seed: 11),
        Track(name: "Pixel Rain", genre: 1, bpm: 118, root: 130.81, scale: Track.major, prog: [0, 4, 5, 3], seed: 22),
        Track(name: "Midnight House", genre: 2, bpm: 122, root: 87.31, scale: Track.minor, prog: [0, 6, 5, 6], seed: 33),
        Track(name: "Lo-Fi Window", genre: 3, bpm: 82, root: 146.83, scale: Track.dorian, prog: [0, 3, 0, 4], seed: 44),
        Track(name: "Sunset Run", genre: 0, bpm: 108, root: 82.41, scale: Track.minor, prog: [0, 2, 5, 4], seed: 55),
        Track(name: "Chip Hero", genre: 1, bpm: 132, root: 98, scale: Track.major, prog: [0, 3, 4, 0], seed: 66),
        Track(name: "Crystal Cave", genre: 3, bpm: 90, root: 110, scale: Track.major, prog: [0, 5, 3, 4], seed: 77),
        Track(name: "Club 303", genre: 2, bpm: 126, root: 73.42, scale: Track.minor, prog: [0, 5, 6, 4], seed: 88)
    ]
}
struct TracksView: View {
    @ObservedObject var g: Game
    let gn = ["Синтвейв", "8-бит", "Хаус", "Лоу-фай"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Треки").font(.title.bold())
            Text("У каждого трека свой темп, тональность, мелодия и стиль. Темп растёт по ходу игры.")
                .font(.footnote).foregroundColor(.gray)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<Track.all.count, id: \.self) { i in
                        HStack {
                            Button { g.track = i } label: {
                                VStack(alignment: .leading) {
                                    Text(Track.all[i].name).font(.headline).foregroundColor(.white)
                                    Text("\(gn[Track.all[i].genre]) · \(Int(Track.all[i].bpm)) BPM").font(.caption).foregroundColor(.gray)
                                }
                            }
                            Spacer()
                            Button { g.synth.preview(Track.all[i]) } label: {
                                Image(systemName: "play.circle").font(.title2).foregroundColor(.cyan)
                            }
                            Image(systemName: g.track == i ? "checkmark.circle.fill" : "circle").foregroundColor(.cyan)
                        }
                        .padding(12).background(Color.white.opacity(0.08)).cornerRadius(12)
                    }
                }
            }
        }
        .padding(24)
        .onDisappear { g.synth.stop() }
    }
}

// MARK: - Мультитач: нажатия + положение всех пальцев
struct TouchPad: UIViewRepresentable {
    let g: Game
    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        v.g = g
        return v
    }
    func updateUIView(_ v: PadView, context: Context) { v.g = g }
    final class PadView: UIView {
        var g: Game?
        override func touchesBegan(_ ts: Set<UITouch>, with e: UIEvent?) {
            for t in ts {
                let p = t.location(in: self)
                g?.touches.pts[ObjectIdentifier(t)] = p
                g?.tap(p)
            }
        }
        override func touchesMoved(_ ts: Set<UITouch>, with e: UIEvent?) {
            for t in ts { g?.touches.pts[ObjectIdentifier(t)] = t.location(in: self) }
        }
        override func touchesEnded(_ ts: Set<UITouch>, with e: UIEvent?) {
            for t in ts { g?.touches.pts.removeValue(forKey: ObjectIdentifier(t)) }
        }
        override func touchesCancelled(_ ts: Set<UITouch>, with e: UIEvent?) {
            for t in ts { g?.touches.pts.removeValue(forKey: ObjectIdentifier(t)) }
        }
    }
}

// MARK: - Игровой экран
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
            TouchPad(g: g)
            Button { g.pause() } label: {
                Image(systemName: "pause.fill").font(.title2)
                    .foregroundColor(.white.opacity(0.7)).padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.bottom, 30)
            if g.paused { PauseView(g: g) }
        }
        .ignoresSafeArea()
    }

    func ball(_ c: GraphicsContext, _ p: CGPoint, _ r: CGFloat, _ a: Double, _ num: Int?, _ k: CGFloat, _ col: Color, _ ra: Double) {
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        c.fill(circle, with: .color(col.opacity(0.3 * a)))
        c.stroke(circle, with: .color(col.opacity(0.22 * a)), lineWidth: 14)
        c.stroke(circle, with: .color(col.opacity(a)), lineWidth: 4)
        if k > r {
            let ring = Path(ellipseIn: CGRect(x: p.x - k, y: p.y - k, width: 2 * k, height: 2 * k))
            c.stroke(ring, with: .color(Color.white.opacity(ra)), lineWidth: 3)
        }
        if let num = num {
            c.draw(Text("\(num)").font(.system(size: r * 0.85, weight: .bold)).foregroundColor(.white.opacity(a)), at: p)
        }
    }

    func draw(_ c: GraphicsContext, _ s: CGSize) {
        let t = g.now, r = g.radius(), pal = g.palette
        c.fill(Path(CGRect(origin: .zero, size: s)), with: .color(pal[0].opacity(0.12 * g.synth.pulse)))
        // номера: после потери комбо нумерация начинается заново с 1
        var nums: [Int: Int] = [:], cix: [Int: Int] = [:]
        var k = 0
        for (i, n) in g.notes.enumerated() where !n.done && n.kind < 2 && !n.started {
            k += 1; nums[i] = (g.combo + k - 1) % 9 + 1; cix[i] = ((g.combo + k - 1) / 9) % 4
        }
        for (i, n) in g.notes.enumerated().reversed() where !n.done {
            let dt = n.t - t
            if n.kind == 2 { drawSpinner(c, s, n, t); continue }
            if dt > n.appr { continue }
            let a = min(1, (n.appr - dt) / 0.25)
            let p = CGPoint(x: n.x * s.width, y: n.y * s.height)
            if n.kind == 1 {
                let q = CGPoint(x: n.ex * s.width, y: n.ey * s.height)
                var path = Path(); path.move(to: p); path.addLine(to: q)
                c.stroke(path, with: .color(Color.white.opacity(0.35 * a)),
                         style: StrokeStyle(lineWidth: 2 * r + 4, lineCap: .round))
                c.stroke(path, with: .color(Color(red: 0.03, green: 0.05, blue: 0.16).opacity(a)),
                         style: StrokeStyle(lineWidth: 2 * r - 4, lineCap: .round))
                for kk in 1..<(n.rep * 3) {
                    let f = Double(kk) / 3
                    let pp = CGFloat(Int(f) % 2 == 0 ? f - floor(f) : 1 - (f - floor(f)))
                    let dx = p.x + (q.x - p.x) * pp, dy = p.y + (q.y - p.y) * pp
                    c.fill(Path(ellipseIn: CGRect(x: dx - 4, y: dy - 4, width: 8, height: 8)), with: .color(Color.white.opacity(0.6 * a)))
                }
                if n.started {
                    let u = n.pathU(t)
                    let b = CGPoint(x: p.x + (q.x - p.x) * u, y: p.y + (q.y - p.y) * u)
                    ball(c, b, r, 1, nil, 0, pal[0], 1)
                    let f = r * 2.4
                    c.stroke(Path(ellipseIn: CGRect(x: b.x - f, y: b.y - f, width: 2 * f, height: 2 * f)),
                             with: .color(Color.white.opacity(0.25)), lineWidth: 2)
                    continue
                }
                c.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color.white.opacity(0.5 * a)), lineWidth: 3)
            }
            let ap = r * (1 + 2.2 * CGFloat(max(0, dt) / n.appr))
            let fa = g.on(5) ? a * min(1, max(0, (dt - n.appr * 0.3) / (n.appr * 0.25))) : a
            ball(c, p, r, fa, nums[i], ap, pal[cix[i] ?? 0], a)
        }
        if let tp = g.touches.pts.values.first { g.trail.append((tp, t)) }
        g.trail.removeAll { t - $0.1 > 0.3 }
        for (q, bt) in g.trail {
            let al = 1 - (t - bt) / 0.3, rr = CGFloat(14 * al)
            c.fill(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(Color.cyan.opacity(0.35 * al)))
        }
        for f in g.fx where f.kind > 0 {
            let age = t - f.born
            for k in 0..<8 {
                let ang = Double(k) / 8 * 2 * Double.pi
                let px = f.x * s.width + CGFloat(cos(ang) * age * 170), py = f.y * s.height + CGFloat(sin(ang) * age * 170)
                let pr = CGFloat(max(0, 5 - age * 10))
                c.fill(Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: 2 * pr, height: 2 * pr)), with: .color(Color.white.opacity(max(0, 1 - age * 2))))
            }
        }
        let cols: [Color] = [.red, .yellow, .green, .cyan]
        let txt = ["MISS", "MEH", "OK", "PERFECT"]
        for f in g.fx {
            let age = t - f.born
            c.draw(Text(txt[f.kind]).font(.system(size: 22, weight: .heavy))
                    .foregroundColor(cols[f.kind].opacity(max(0, 1 - age * 2))),
                   at: CGPoint(x: f.x * s.width, y: f.y * s.height - CGFloat(age * 40)))
        }
        if g.on(6) {
            var hole = Path(CGRect(origin: .zero, size: s))
            hole.addEllipse(in: CGRect(x: g.flashP.x - 130, y: g.flashP.y - 130, width: 260, height: 260))
            c.fill(hole, with: .color(Color.black.opacity(0.93)), style: FillStyle(eoFill: true))
        }
        let bx = s.width / 2, by = s.height - 40
        c.fill(Path(CGRect(x: bx - 80, y: by - 1, width: 160, height: 2)), with: .color(Color.white.opacity(0.25)))
        c.fill(Path(CGRect(x: bx - 1.5, y: by - 9, width: 3, height: 18)), with: .color(Color.white.opacity(0.6)))
        for o in g.offs {
            let age = t - o.1
            if age > 2 { continue }
            let x = bx + CGFloat(max(-1, min(1, o.0 / 0.16))) * 80
            c.fill(Path(CGRect(x: x - 1.5, y: by - 7, width: 3, height: 14)),
                   with: .color((o.0 < 0 ? Color.blue : Color.orange).opacity(1 - age / 2)))
        }
        if g.tutorial {
            let hint = t < Tempo.time(22) ? "Круг: тапни, когда розовое\nкольцо сожмётся. Цифры: порядок."
                : (t < Tempo.time(46) ? "Слайдер: тапни по началу\nи веди палец за шариком." : "Спиннер: крути палец\nпо кругу вокруг центра!")
            c.draw(Text(hint).font(.system(size: 18, weight: .bold)).foregroundColor(.yellow), at: CGPoint(x: s.width / 2, y: 150))
        }
        // HUD
        let ix: CGFloat = s.width > s.height ? 60 : 20
        let w = s.width - 2 * ix
        c.fill(Path(roundedRect: CGRect(x: ix, y: 52, width: w, height: 8), cornerRadius: 4),
               with: .color(Color.white.opacity(0.15)))
        c.fill(Path(roundedRect: CGRect(x: ix, y: 52, width: w * CGFloat(max(0, g.hp) / 100), height: 8), cornerRadius: 4),
               with: .color(g.hp > 30 ? Color.green : Color.red))
        c.draw(Text("\(g.score)").font(.system(size: 30, weight: .black, design: .monospaced)).foregroundColor(.white),
               at: CGPoint(x: s.width - ix, y: 86), anchor: .trailing)
        c.draw(Text(String(format: "%.1f%%", g.acc * 100)).font(.system(size: 16, design: .monospaced)).foregroundColor(.gray),
               at: CGPoint(x: s.width - ix, y: 114), anchor: .trailing)
        c.draw(Text("\(g.combo)x").font(.system(size: 38, weight: .black)).foregroundColor(.cyan),
               at: CGPoint(x: ix, y: s.height - 60), anchor: .leading)
    }

    func drawSpinner(_ c: GraphicsContext, _ s: CGSize, _ n: Note, _ t: Double) {
        if t < n.t - 0.6 { return }
        let a = t < n.t ? (t - (n.t - 0.6)) / 0.6 : 1
        let m = CGPoint(x: s.width / 2, y: s.height / 2)
        let R = min(s.width, s.height) * 0.38
        let ring = Path(ellipseIn: CGRect(x: m.x - R, y: m.y - R, width: 2 * R, height: 2 * R))
        c.stroke(ring, with: .color(Color.white.opacity(0.2 * a)), lineWidth: 10)
        let q = min(1, n.spun / g.need(n))
        c.stroke(ring.trimmedPath(from: 0, to: CGFloat(q)), with: .color(Color.cyan.opacity(a)), lineWidth: 10)
        c.draw(Text("КРУТИ!").font(.system(size: 34, weight: .black)).foregroundColor(.pink.opacity(a)), at: m)
    }
}

struct PauseView: View {
    @ObservedObject var g: Game
    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("ПАУЗА").font(.system(size: 30, weight: .black)).foregroundColor(.white)
                Button { g.resume() } label: { PillText("ПРОДОЛЖИТЬ", filled: true) }
                Button { g.start() } label: { PillText("ЗАНОВО", filled: false) }
                Button { g.toMenu() } label: { PillText("В МЕНЮ", filled: false) }
            }
        }
    }
}

struct PillText: View {
    let s: String, filled: Bool
    init(_ s: String, filled: Bool) { self.s = s; self.filled = filled }
    var body: some View {
        Text(s).font(.system(size: 20, weight: .heavy))
            .frame(width: 240).padding(.vertical, 13)
            .background(filled ? Color.cyan : Color.white.opacity(0.12))
            .foregroundColor(filled ? .black : .white)
            .cornerRadius(14)
    }
}

// MARK: - Меню
struct MenuView: View {
    @ObservedObject var g: Game
    @State var help = false
    @State var settings = false
    @State var modsSheet = false
    @State var replays = false
    @State var stats = false
    @State var tracks = false
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("NEON BEAT ∞")
                .font(.system(size: 38, weight: .black, design: .monospaced))
                .foregroundColor(.cyan).shadow(color: .cyan, radius: 12)
            Text("Рекорд (\(g.names[g.diff])): \(g.modeBest)").foregroundColor(.gray)
            Picker("", selection: $g.mode) {
                Text("Классика").tag(0)
                Text("Mania").tag(1)
                Text("Taiko").tag(2)
                Text("Catch").tag(3)
            }
            .pickerStyle(.segmented).padding(.horizontal, 40)
            Picker("", selection: $g.diff) {
                ForEach(0..<3) { Text(g.names[$0]).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 40)
            Button { g.duel = 0; g.play() } label: { PillText("ИГРАТЬ", filled: true) }
            if g.mode == 0 {
            Button { g.start(daily: true) } label: { PillText("ЧЕЛЛЕНДЖ ДНЯ", filled: false) }
            Button { modsSheet = true } label: { PillText(g.mods.isEmpty ? "МОДЫ" : "МОДЫ (\(g.mods.count))", filled: false) }
            TextField("Сид (по желанию)", text: $g.seedText)
                .keyboardType(.numberPad).multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder).frame(width: 240)
            }
            HStack(spacing: 16) {
                Button("Как играть") { help = true }
                Button("Обучение") { g.startTutorial() }
                Button("Настройки") { settings = true }
            }.foregroundColor(.gray)
            HStack(spacing: 16) {
                Button("Повторы") { replays = true }
                Button("Статистика") { stats = true }
                Button("Дуэль") { g.startDuel() }
                Button("Треки") { tracks = true }
            }.foregroundColor(.gray)
            Spacer()
            Text("v1.7 · треки и новый генератор музыки").font(.caption).foregroundColor(.gray)
        }
        .sheet(isPresented: $help) { HelpView() }
        .sheet(isPresented: $settings) { SettingsView(g: g) }
        .sheet(isPresented: $modsSheet) { ModsView(g: g) }
        .sheet(isPresented: $replays) { ReplaysView(g: g) }
        .sheet(isPresented: $stats) { StatsView() }
        .sheet(isPresented: $tracks) { TracksView(g: g) }
    }
}

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Как играть").font(.title.bold())
            Text("● Круг: тапни, когда розовое кольцо сожмётся до круга.")
            Text("● Слайдер: тапни по началу и веди палец за шариком до конца.")
            Text("● Спиннер: крути палец по кругу вокруг центра, пока шкала не заполнится.")
            Text("● Номера на кругах показывают порядок. Промах сбрасывает комбо, и нумерация начинается с 1.")
            Text("● Промахи отнимают HP. HP кончилось — игра окончена. Темп растёт сам.")
            Text("● Бить можно двумя пальцами.")
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @ObservedObject var g: Game
    @State var cal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Настройки").font(.title.bold())
            Text("Сдвиг звука: \(Int(g.offsetMs)) мс")
            Slider(value: $g.offsetMs, in: -200...200, step: 5)
            Text("Если круги приходят раньше бита, двигай вправо (+). Если позже, влево (−).")
                .font(.footnote).foregroundColor(.gray)
            Text("Музыка: \(Int(g.musicVol * 100))%")
            Slider(value: $g.musicVol, in: 0...1)
            Text("Звуки попаданий: \(Int(g.sfxVol * 100))%")
            Slider(value: $g.sfxVol, in: 0...1)
            Picker("Экран", selection: $g.orient) {
                Text("Авто").tag(0); Text("Вертикально").tag(1); Text("Горизонтально").tag(2)
            }.pickerStyle(.segmented)
            Picker("Жанр", selection: $g.genre) {
                Text("Синтвейв").tag(0); Text("8-бит").tag(1); Text("Хаус").tag(2); Text("Лоу-фай").tag(3)
            }.pickerStyle(.segmented)
            Toggle("Тренировка: 0.75×, без потери HP", isOn: $g.practice)
            Button("Калибровка звука") { cal = true }.sheet(isPresented: $cal) { CalibView(g: g) }
            Toggle("Вибрация", isOn: $g.vibe)
            Picker("Скин", selection: $g.skin) {
                ForEach(0..<3) { Text(g.skinNames[$0]).tag($0) }
            }.pickerStyle(.segmented)
            Spacer()
        }
        .padding(24)
    }
}

struct ModsView: View {
    @ObservedObject var g: Game
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Моды").font(.title.bold())
            ForEach(0..<9) { i in
                Button { g.toggleMod(i) } label: {
                    HStack {
                        Image(systemName: g.on(i) ? "checkmark.circle.fill" : "circle")
                        Text(g.modNames[i])
                        Spacer()
                        Text(g.modInfo[i]).font(.footnote).foregroundColor(.gray)
                    }
                }.foregroundColor(.white)
            }
            Text("Множитель очков: ×\(String(format: "%.2f", g.mult))").foregroundColor(.cyan)
            Spacer()
        }
        .padding(24)
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
            Text("Ранг \(g.rank)").font(.system(size: 34, weight: .black)).foregroundColor(.yellow)
            Text("Рекорд (\(g.names[g.diff])): \(g.best)").foregroundColor(.gray)
            Text("Сид карты: \(g.seed)").font(.footnote).foregroundColor(.gray)
            if g.duel == 1 {
                Button { g.duelScore = g.score; g.duel = 2; g.seedText = String(g.seed); g.start() } label: { PillText("ХОД ИГРОКА 2", filled: true) }
            } else if g.duel == 2 {
                Text(g.duelScore > g.score ? "ПОБЕДИЛ ИГРОК 1" : (g.duelScore < g.score ? "ПОБЕДИЛ ИГРОК 2" : "НИЧЬЯ"))
                    .font(.system(size: 24, weight: .black)).foregroundColor(.pink)
                Text("Игрок 1: \(g.duelScore)   Игрок 2: \(g.score)").foregroundColor(.gray)
            } else {
                Button { g.start() } label: { PillText("ЕЩЁ РАЗ", filled: true) }
            }
            Button { g.seedText = String(g.seed); g.start() } label: { PillText("ТА ЖЕ КАРТА", filled: false) }
            ShareLink(item: cardImage(g), preview: SharePreview("Результат Neon Beat", image: cardImage(g))) { PillText("ПОДЕЛИТЬСЯ", filled: false) }
            Button { g.duel = 0; g.phase = .menu } label: { PillText("В МЕНЮ", filled: false) }
        }
    }
}

// MARK: - Mania: 4 колонки
final class Mania: ObservableObject {
    struct N { var t: Double; var lane: Int; var done = false }
    @Published var over = false
    @Published var paused = false
    let g: Game
    var notes: [N] = [], fx: [(lane: Int, born: Double, kind: Int)] = []
    var slot = 16, lastLane = 0, ending = false
    var rng = RNG(s: 1)
    var score = 0, combo = 0, maxCombo = 0, total = 0, misses = 0
    var accSum = 0.0, hp = 100.0, record = false
    var flash = [Double](repeating: -9, count: 4)
    var size = CGSize(width: 390, height: 844)
    init(_ g: Game) { self.g = g }

    var now: Double { g.synth.time }
    var fall: Double { [1.2, 0.95, 0.75][g.diff] }
    var acc: Double { total == 0 ? 1 : accSum / Double(300 * total) }
    var rank: String {
        if acc >= 0.999 && misses == 0 { return "SS" }
        return acc >= 0.95 ? "S" : (acc >= 0.9 ? "A" : (acc >= 0.8 ? "B" : (acc >= 0.7 ? "C" : "D")))
    }

    func start() {
        notes = []; fx = []; slot = 16; lastLane = 0; ending = false
        rng = RNG(s: UInt64.random(in: 1...999_999_999))
        score = 0; combo = 0; maxCombo = 0; total = 0; misses = 0; accSum = 0; hp = 100; record = false
        flash = [Double](repeating: -9, count: 4)
        Tempo.speed = 1; Tempo.reset()
        UIApplication.shared.isIdleTimerDisabled = true
        try? g.synth.start()
        over = false; paused = false
    }

    func spawn(_ s: Int) {
        let n = s / 2, half = s % 2 == 1
        let base = half ? (n < 40 ? 0 : min(Double(n - 40) / 300, 0.55)) : min(0.6 + Double(n) / 300, 0.92)
        let p = min(base * g.dens[g.diff], 0.95)
        let r = rng.unit(), a = rng.unit(), d = rng.unit()
        guard r < p else { return }
        let t = Tempo.time(n) + (half ? Tempo.len(n) / 2 : 0)
        var lane = Int(a * 4)
        if lane == lastLane && d < 0.6 { lane = (lane + 1 + Int(d * 10) % 3) % 4 }
        lastLane = lane
        notes.append(N(t: t, lane: lane))
        if !half && n >= 32 && d > 0.8 { notes.append(N(t: t, lane: (lane + 2) % 4)) }
    }

    func tick() {
        guard !over, !paused else { return }
        let t = now
        while Tempo.time(slot / 2) + (slot % 2 == 1 ? Tempo.len(slot / 2) / 2 : 0) < t + fall + 1 {
            spawn(slot); slot += 1
        }
        for i in notes.indices where !notes[i].done && t > notes[i].t + 0.16 {
            notes[i].done = true; combo = 0; misses += 1; total += 1
            hp -= g.missHP[g.diff]
            fx.append((lane: notes[i].lane, born: t, kind: 0))
            if g.vibe { g.hapticH.impactOccurred() }
        }
        notes.removeAll { $0.done }
        fx.removeAll { t - $0.born > 0.4 }
        if hp <= 0 && !ending { ending = true; DispatchQueue.main.async { self.finish() } }
    }

    func press(_ lane: Int) {
        guard !over, !paused else { return }
        let t = now
        flash[lane] = t
        var bi = -1
        for i in notes.indices where !notes[i].done && notes[i].lane == lane {
            let dt = notes[i].t - t
            if dt > 0.2 { break }
            if dt < -0.16 { continue }
            bi = i; break
        }
        guard bi >= 0 else { return }
        let off = abs(t - notes[bi].t)
        let kind = off < 0.06 ? 3 : (off < 0.11 ? 2 : 1)
        let pts = [0, 50, 100, 300][kind]
        notes[bi].done = true
        combo += 1; maxCombo = max(maxCombo, combo); total += 1; accSum += Double(pts)
        score += pts * (1 + combo / 25)
        hp = min(100, hp + [0, 1, 2, 4][kind])
        g.synth.hitCounter += 1
        if g.vibe { g.hapticL.impactOccurred() }
        fx.append((lane: lane, born: t, kind: kind))
    }

    func finish() {
        g.synth.stop(); UIApplication.shared.isIdleTimerDisabled = false
        let key = "nb_mania_\(g.diff)"
        record = score > UserDefaults.standard.integer(forKey: key)
        if record { UserDefaults.standard.set(score, forKey: key) }
        Stats.add(score: score, combo: maxCombo, hits: total)
        over = true
    }
    func pause() { guard !over, !paused else { return }; paused = true; g.synth.stop() }
    func resume() { paused = false; g.synth.resume() }
    func quit() { g.synth.stop(); UIApplication.shared.isIdleTimerDisabled = false; g.phase = .menu }
}

struct LanePad: UIViewRepresentable {
    let onDown: (CGPoint) -> Void
    func makeUIView(context: Context) -> V {
        let v = V(); v.isMultipleTouchEnabled = true; v.backgroundColor = .clear; v.cb = onDown; return v
    }
    func updateUIView(_ v: V, context: Context) { v.cb = onDown }
    final class V: UIView {
        var cb: ((CGPoint) -> Void)?
        override func touchesBegan(_ ts: Set<UITouch>, with e: UIEvent?) {
            for t in ts { cb?(t.location(in: self)) }
        }
    }
}

struct ManiaView: View {
    let g: Game
    @StateObject private var m: Mania
    init(g: Game) { self.g = g; _m = StateObject(wrappedValue: Mania(g)) }

    var body: some View {
        ZStack {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    _ = tl.date
                    m.size = size
                    m.tick()
                    draw(ctx, size)
                }
            }
            LanePad { p in m.press(min(3, max(0, Int(p.x / (m.size.width / 4))))) }
            Button { m.pause() } label: {
                Image(systemName: "pause.fill").font(.title2)
                    .foregroundColor(.white.opacity(0.7)).padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 70)
            if m.paused || m.over {
                ZStack {
                    Color.black.opacity(0.78).ignoresSafeArea()
                    VStack(spacing: 14) {
                        if m.over {
                            Text("ИГРА ОКОНЧЕНА").font(.system(size: 26, weight: .black)).foregroundColor(.white)
                            Text(m.rank).font(.system(size: 80, weight: .black)).foregroundColor(.yellow)
                            if m.record { Text("НОВЫЙ РЕКОРД!").font(.system(size: 20, weight: .heavy)).foregroundColor(.yellow) }
                            Text("\(m.score)").font(.system(size: 48, weight: .black, design: .monospaced)).foregroundColor(.cyan)
                            Text("Макс. комбо: \(m.maxCombo)   Точность: \(String(format: "%.1f", m.acc * 100))%")
                                .foregroundColor(.gray)
                        } else {
                            Text("ПАУЗА").font(.system(size: 30, weight: .black)).foregroundColor(.white)
                            Button { m.resume() } label: { PillText("ПРОДОЛЖИТЬ", filled: true) }
                        }
                        Button { m.start() } label: { PillText(m.over ? "ЕЩЁ РАЗ" : "ЗАНОВО", filled: m.over) }
                        Button { m.quit() } label: { PillText("В МЕНЮ", filled: false) }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { m.start() }
    }

    func draw(_ c: GraphicsContext, _ s: CGSize) {
        let t = m.now, W = s.width, lw = W / 4, hitY = s.height * 0.82
        let cols = g.palette
        for i in 0..<4 {
            let x = CGFloat(i) * lw
            let act = max(0, 1 - (t - m.flash[i]) * 6)
            c.fill(Path(CGRect(x: x, y: 0, width: lw, height: s.height)), with: .color(cols[i].opacity(0.05 + 0.2 * act)))
            if i > 0 { c.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: s.height)), with: .color(Color.white.opacity(0.12))) }
        }
        c.fill(Path(CGRect(x: 0, y: hitY - 2, width: W, height: 4)), with: .color(Color.white.opacity(0.7)))
        let nh: CGFloat = 26
        for n in m.notes where !n.done {
            let y = hitY - CGFloat((n.t - t) / m.fall) * hitY
            if y < -nh { continue }
            let rect = CGRect(x: CGFloat(n.lane) * lw + 6, y: y - nh / 2, width: lw - 12, height: nh)
            c.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(cols[n.lane]))
            c.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color.white.opacity(0.8)), lineWidth: 2)
        }
        let jc: [Color] = [.red, .yellow, .green, .cyan]
        let jt = ["MISS", "MEH", "OK", "PERFECT"]
        for f in m.fx {
            let age = t - f.born
            c.draw(Text(jt[f.kind]).font(.system(size: 22, weight: .heavy)).foregroundColor(jc[f.kind].opacity(max(0, 1 - age * 2.5))),
                   at: CGPoint(x: (CGFloat(f.lane) + 0.5) * lw, y: hitY - 40 - CGFloat(age * 40)))
        }
        let w = W - 40
        c.fill(Path(roundedRect: CGRect(x: 20, y: 52, width: w, height: 8), cornerRadius: 4), with: .color(Color.white.opacity(0.15)))
        c.fill(Path(roundedRect: CGRect(x: 20, y: 52, width: w * CGFloat(max(0, m.hp) / 100), height: 8), cornerRadius: 4),
               with: .color(m.hp > 30 ? Color.green : Color.red))
        c.draw(Text("\(m.score)").font(.system(size: 30, weight: .black, design: .monospaced)).foregroundColor(.white),
               at: CGPoint(x: W - 20, y: 86), anchor: .trailing)
        if m.combo > 1 {
            c.draw(Text("\(m.combo)x").font(.system(size: 48, weight: .black)).foregroundColor(.white.opacity(0.55)),
                   at: CGPoint(x: W / 2, y: s.height * 0.33))
        }
    }
}

// MARK: - Ориентация экрана
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .all
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { AppDelegate.mask }
}
func applyOrientation(_ o: Int) {
    AppDelegate.mask = o == 1 ? .portrait : (o == 2 ? .landscape : .all)
    guard let sc = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    sc.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    if o != 0 { sc.requestGeometryUpdate(.iOS(interfaceOrientations: o == 1 ? .portrait : .landscape), errorHandler: { _ in }) }
}
extension Game {
    var modeBest: Int {
        let k = ["", "nb_mania_", "nb_taiko_", "nb_catch_"][mode]
        return mode == 0 ? best : UserDefaults.standard.integer(forKey: "\(k)\(diff)")
    }
    func play() {
        if mode == 1 { applyOrientation(orient); phase = .mania }
        else if mode >= 2 { applyOrientation(orient == 0 ? (mode == 2 ? 2 : 1) : orient); phase = .arcade }
        else { tutorial = false; start() }
    }
}

// MARK: - Taiko (режим 2) и Catch (режим 3)
final class Arcade: ObservableObject {
    struct N { var t: Double; var lane: Int; var x = 0.0; var done = false }
    @Published var over = false
    @Published var paused = false
    let g: Game
    let mode: Int
    var notes: [N] = [], fx: [(x: CGFloat, y: CGFloat, born: Double, kind: Int)] = []
    var slot = 16, ending = false, lx = 0.5
    var rng = RNG(s: 1)
    var score = 0, combo = 0, maxCombo = 0, total = 0, misses = 0
    var accSum = 0.0, hp = 100.0, record = false
    var cx = 0.5, flash = [-9.0, -9.0]
    var size = CGSize(width: 390, height: 844)
    init(_ g: Game) { self.g = g; mode = g.mode }

    var now: Double { g.synth.time }
    var fall: Double { [1.4, 1.1, 0.85][g.diff] }
    var key: String { (mode == 2 ? "nb_taiko_" : "nb_catch_") + "\(g.diff)" }
    var acc: Double { total == 0 ? 1 : accSum / Double(300 * total) }
    var rank: String {
        if acc >= 0.999 && misses == 0 { return "SS" }
        return acc >= 0.95 ? "S" : (acc >= 0.9 ? "A" : (acc >= 0.8 ? "B" : (acc >= 0.7 ? "C" : "D")))
    }

    func start() {
        notes = []; fx = []; slot = 16; ending = false; lx = 0.5; cx = 0.5
        rng = RNG(s: UInt64.random(in: 1...999_999_999))
        score = 0; combo = 0; maxCombo = 0; total = 0; misses = 0; accSum = 0; hp = 100; record = false
        Tempo.speed = 1; Tempo.reset()
        UIApplication.shared.isIdleTimerDisabled = true
        try? g.synth.start()
        over = false; paused = false
    }

    func spawn(_ s: Int) {
        let n = s / 2, half = s % 2 == 1
        let base = half ? (n < 40 ? 0 : min(Double(n - 40) / 300, 0.55)) : min(0.6 + Double(n) / 300, 0.92)
        let r = rng.unit(), a = rng.unit(), d = rng.unit()
        guard r < min(base * g.dens[g.diff], 0.95) else { return }
        let t = Tempo.time(n) + (half ? Tempo.len(n) / 2 : 0)
        lx = min(max(lx + (a - 0.5) * min(0.3 + Double(n) * 0.002, 0.8), 0.08), 0.92)
        notes.append(N(t: t, lane: d < 0.62 ? 0 : 1, x: lx))
    }

    func pos(_ n: N) -> CGPoint {
        mode == 3 ? CGPoint(x: CGFloat(n.x) * size.width, y: size.height * 0.8)
                  : CGPoint(x: size.width * 0.2, y: size.height * 0.4)
    }
    func good(_ i: Int, _ kind: Int, _ t: Double) {
        let pts = [0, 50, 100, 300][kind], p = pos(notes[i])
        fx.append((x: p.x, y: p.y, born: t, kind: kind))
        notes[i].done = true
        combo += 1; maxCombo = max(maxCombo, combo); total += 1; accSum += Double(pts)
        score += pts * (1 + combo / 25); hp = min(100, hp + [0, 1, 2, 4][kind])
        g.synth.hitCounter += 1
        if g.vibe { g.hapticL.impactOccurred() }
    }
    func bad(_ i: Int, _ t: Double) {
        let p = pos(notes[i])
        fx.append((x: p.x, y: p.y, born: t, kind: 0))
        notes[i].done = true
        combo = 0; misses += 1; total += 1; hp -= g.missHP[g.diff]
        if g.vibe { g.hapticH.impactOccurred() }
    }

    func tick() {
        guard !over, !paused else { return }
        let t = now
        while Tempo.time(slot / 2) + (slot % 2 == 1 ? Tempo.len(slot / 2) / 2 : 0) < t + fall + 1 {
            spawn(slot); slot += 1
        }
        for i in notes.indices where !notes[i].done {
            if mode == 3 {
                if t >= notes[i].t {
                    let dx = abs(notes[i].x - cx)
                    if dx < 0.14 { good(i, dx < 0.06 ? 3 : (dx < 0.10 ? 2 : 1), t) } else { bad(i, t) }
                }
            } else if t > notes[i].t + 0.16 { bad(i, t) }
        }
        notes.removeAll { $0.done }
        fx.removeAll { t - $0.born > 0.5 }
        if hp <= 0 && !ending { ending = true; DispatchQueue.main.async { self.finish() } }
    }

    func press(_ lane: Int) {
        guard mode == 2, !over, !paused else { return }
        let t = now
        flash[lane] = t
        guard let i = notes.indices.first(where: { !notes[$0].done && notes[$0].t - t <= 0.2 && notes[$0].t - t >= -0.16 }) else { return }
        if notes[i].lane != lane { bad(i, t); return }
        let off = abs(t - notes[i].t)
        good(i, off < 0.06 ? 3 : (off < 0.11 ? 2 : 1), t)
    }

    func finish() {
        g.synth.stop(); UIApplication.shared.isIdleTimerDisabled = false
        record = score > UserDefaults.standard.integer(forKey: key)
        if record { UserDefaults.standard.set(score, forKey: key) }
        Stats.add(score: score, combo: maxCombo, hits: total)
        over = true
    }
    func pause() { guard !over, !paused else { return }; paused = true; g.synth.stop() }
    func resume() { paused = false; g.synth.resume() }
    func quit() { g.synth.stop(); UIApplication.shared.isIdleTimerDisabled = false; applyOrientation(0); g.phase = .menu }
}

struct ArcadePad: UIViewRepresentable {
    let down: (CGPoint) -> Void
    let move: (CGPoint) -> Void
    func makeUIView(context: Context) -> V {
        let v = V(); v.isMultipleTouchEnabled = true; v.backgroundColor = .clear; v.d = down; v.m = move; return v
    }
    func updateUIView(_ v: V, context: Context) { v.d = down; v.m = move }
    final class V: UIView {
        var d: ((CGPoint) -> Void)?
        var m: ((CGPoint) -> Void)?
        override func touchesBegan(_ ts: Set<UITouch>, with e: UIEvent?) {
            for t in ts { let p = t.location(in: self); d?(p); m?(p) }
        }
        override func touchesMoved(_ ts: Set<UITouch>, with e: UIEvent?) {
            for t in ts { m?(t.location(in: self)) }
        }
    }
}

struct ArcadeView: View {
    let g: Game
    @StateObject private var a: Arcade
    init(g: Game) { self.g = g; _a = StateObject(wrappedValue: Arcade(g)) }

    var body: some View {
        ZStack {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    _ = tl.date
                    a.size = size
                    a.tick()
                    draw(ctx, size)
                }
            }
            ArcadePad(down: { p in a.press(p.x < a.size.width / 2 ? 0 : 1) },
                      move: { p in if a.mode == 3 { a.cx = min(0.92, max(0.08, Double(p.x / a.size.width))) } })
            Button { a.pause() } label: {
                Image(systemName: "pause.fill").font(.title2).foregroundColor(.white.opacity(0.7)).padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 70)
            if a.paused || a.over {
                ZStack {
                    Color.black.opacity(0.78).ignoresSafeArea()
                    VStack(spacing: 14) {
                        if a.over {
                            Text("ИГРА ОКОНЧЕНА").font(.system(size: 26, weight: .black)).foregroundColor(.white)
                            Text(a.rank).font(.system(size: 80, weight: .black)).foregroundColor(.yellow)
                            if a.record { Text("НОВЫЙ РЕКОРД!").font(.system(size: 20, weight: .heavy)).foregroundColor(.yellow) }
                            Text("\(a.score)").font(.system(size: 48, weight: .black, design: .monospaced)).foregroundColor(.cyan)
                            Text("Макс. комбо: \(a.maxCombo)   Точность: \(String(format: "%.1f", a.acc * 100))%").foregroundColor(.gray)
                        } else {
                            Text("ПАУЗА").font(.system(size: 30, weight: .black)).foregroundColor(.white)
                            Button { a.resume() } label: { PillText("ПРОДОЛЖИТЬ", filled: true) }
                        }
                        Button { a.start() } label: { PillText(a.over ? "ЕЩЁ РАЗ" : "ЗАНОВО", filled: a.over) }
                        Button { a.quit() } label: { PillText("В МЕНЮ", filled: false) }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { a.start() }
    }

    func draw(_ c: GraphicsContext, _ s: CGSize) {
        let t = a.now, W = s.width, H = s.height, cols = g.palette
        if a.mode == 2 {
            let hx = W * 0.2, ty = H * 0.4
            c.fill(Path(CGRect(x: 0, y: ty - 55, width: W, height: 110)), with: .color(Color.white.opacity(0.06)))
            c.stroke(Path(ellipseIn: CGRect(x: hx - 40, y: ty - 40, width: 80, height: 80)), with: .color(Color.white.opacity(0.7)), lineWidth: 4)
            for n in a.notes.reversed() where !n.done {
                let x = hx + CGFloat((n.t - t) / a.fall) * (W - hx)
                if x > W + 30 { continue }
                let col: Color = n.lane == 0 ? .red : .blue
                let r = CGRect(x: x - 30, y: ty - 30, width: 60, height: 60)
                c.fill(Path(ellipseIn: r), with: .color(col))
                c.stroke(Path(ellipseIn: r), with: .color(Color.white), lineWidth: 4)
            }
            for i in 0..<2 {
                let act = max(0, 1 - (t - a.flash[i]) * 6)
                let rect = CGRect(x: CGFloat(i) * W / 2 + 10, y: H * 0.62, width: W / 2 - 20, height: H * 0.3)
                let base: Color = i == 0 ? .red : .blue
                c.fill(Path(roundedRect: rect, cornerRadius: 24), with: .color(base.opacity(0.15 + 0.4 * act)))
                c.draw(Text(i == 0 ? "ДОН" : "КА").font(.system(size: 30, weight: .black)).foregroundColor(.white.opacity(0.7)),
                       at: CGPoint(x: rect.midX, y: rect.midY))
            }
        } else {
            let hy = H * 0.8
            c.fill(Path(CGRect(x: 0, y: hy - 1, width: W, height: 2)), with: .color(Color.white.opacity(0.2)))
            for n in a.notes.reversed() where !n.done {
                let y = hy - CGFloat((n.t - t) / a.fall) * hy
                if y < -20 { continue }
                let r = CGRect(x: CGFloat(n.x) * W - 16, y: y - 16, width: 32, height: 32)
                c.fill(Path(ellipseIn: r), with: .color(cols[Int(n.x * 4) % 4]))
                c.stroke(Path(ellipseIn: r), with: .color(Color.white), lineWidth: 3)
            }
            let cw = min(W * 0.28, 150)
            c.fill(Path(roundedRect: CGRect(x: CGFloat(a.cx) * W - cw / 2, y: hy, width: cw, height: 18), cornerRadius: 9),
                   with: .color(cols[0]))
        }
        let jc: [Color] = [.red, .yellow, .green, .cyan]
        let jt = ["MISS", "MEH", "OK", "PERFECT"]
        for f in a.fx {
            let age = t - f.born
            c.draw(Text(jt[f.kind]).font(.system(size: 22, weight: .heavy)).foregroundColor(jc[f.kind].opacity(max(0, 1 - age * 2.5))),
                   at: CGPoint(x: f.x, y: f.y - 40 - CGFloat(age * 40)))
        }
        let ix: CGFloat = W > H ? 60 : 20
        let w = W - 2 * ix
        c.fill(Path(roundedRect: CGRect(x: ix, y: 52, width: w, height: 8), cornerRadius: 4), with: .color(Color.white.opacity(0.15)))
        c.fill(Path(roundedRect: CGRect(x: ix, y: 52, width: w * CGFloat(max(0, a.hp) / 100), height: 8), cornerRadius: 4),
               with: .color(a.hp > 30 ? Color.green : Color.red))
        c.draw(Text("\(a.score)").font(.system(size: 30, weight: .black, design: .monospaced)).foregroundColor(.white),
               at: CGPoint(x: W - ix, y: 86), anchor: .trailing)
        if a.combo > 1 {
            c.draw(Text("\(a.combo)x").font(.system(size: 44, weight: .black)).foregroundColor(.white.opacity(0.5)),
                   at: CGPoint(x: W / 2, y: H * 0.22))
        }
    }
}

// MARK: - Повторы, обучение, калибровка
struct Replay: Codable {
    var seed: UInt64
    var diff: Int
    var mods: [Int]
    var taps: [[Double]]
    var frames: [[Double]]
}
extension Game {
    func startTutorial() { mode = 0; practice = false; tutorial = true; start() }
    func startReplay() {
        guard let d = UserDefaults.standard.data(forKey: "nb_replay"),
              let r = try? JSONDecoder().decode(Replay.self, from: d) else { return }
        rec = r; diff = r.diff; mods = Set(r.mods); seedText = String(r.seed)
        mode = 0; practice = false; tutorial = false; replayNext = true
        start()
    }
}

struct CalibView: View {
    @ObservedObject var g: Game
    @State var errs: [Double] = []
    @State var running = false
    func tap() {
        let t = g.now
        let n = Int((t / 0.6).rounded())
        guard n >= 2 && n < 16 && abs(t - Tempo.time(n)) < 0.3 else { return }
        errs.append(t - Tempo.time(n))
        if errs.count >= 8 { running = false; g.synth.stop() }
    }
    var body: some View {
        VStack(spacing: 18) {
            Text("Калибровка").font(.title.bold())
            Text("Нажми «Старт» и тапай по кнопке ровно в момент каждого удара кика. Нужно 8 тапов.")
                .font(.footnote).foregroundColor(.gray).multilineTextAlignment(.center)
            if running {
                Button { tap() } label: {
                    Text("ТАП").font(.system(size: 40, weight: .black))
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .background(Color.cyan.opacity(0.3)).cornerRadius(24)
                }
                Text("Тапов: \(errs.count) из 8")
            } else if errs.count >= 8 {
                let avg = errs.reduce(0, +) / Double(errs.count) * 1000
                Text("Средняя ошибка: \(Int(avg)) мс").font(.headline)
                Button("Применить") { g.offsetMs = max(-200, min(200, g.offsetMs + avg)); errs = [] }
            }
            Button(running ? "Стоп" : "Старт") {
                if running { running = false; g.synth.stop() }
                else { errs = []; Tempo.speed = 1; g.synth.forceBase = 100; try? g.synth.start(); running = true }
            }
            .padding(.horizontal, 40).padding(.vertical, 12)
            .background(Color.cyan).foregroundColor(.black).cornerRadius(14)
            Spacer()
        }
        .padding(24)
        .onDisappear { g.synth.stop() }
    }
}

// MARK: - Слайдер: позиция с поворотами
extension Note {
    func pathU(_ now: Double) -> CGFloat {
        let f = min(1, max(0, (now - t) / dur)) * Double(rep)
        let ph = f - floor(f)
        return CGFloat(Int(f) % 2 == 0 ? ph : 1 - ph)
    }
}

// MARK: - Статистика и достижения
enum Stats {
    static func add(score: Int, combo: Int, hits: Int) {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: "st_games") + 1, forKey: "st_games")
        d.set(d.integer(forKey: "st_hits") + hits, forKey: "st_hits")
        d.set(max(d.integer(forKey: "st_combo"), combo), forKey: "st_combo")
        d.set(max(d.integer(forKey: "st_score"), score), forKey: "st_score")
    }
}
struct StatsView: View {
    var body: some View {
        let d = UserDefaults.standard
        let games = d.integer(forKey: "st_games"), hits = d.integer(forKey: "st_hits")
        let combo = d.integer(forKey: "st_combo"), score = d.integer(forKey: "st_score")
        let ach: [(String, Bool)] = [("Первая игра", games >= 1), ("10 игр", games >= 10), ("100 попаданий", hits >= 100),
                                     ("1000 попаданий", hits >= 1000), ("Комбо 50", combo >= 50), ("Комбо 200", combo >= 200),
                                     ("10 000 очков", score >= 10_000), ("100 000 очков", score >= 100_000)]
        VStack(alignment: .leading, spacing: 10) {
            Text("Статистика").font(.title.bold())
            Text("Игр: \(games)   Попаданий: \(hits)")
            Text("Лучшее комбо: \(combo)   Лучший счёт: \(score)")
            Text("Достижения").font(.headline).padding(.top, 8)
            ForEach(0..<ach.count, id: \.self) { i in
                HStack {
                    Image(systemName: ach[i].1 ? "checkmark.seal.fill" : "lock.fill").foregroundColor(ach[i].1 ? .yellow : .gray)
                    Text(ach[i].0).foregroundColor(ach[i].1 ? .white : .gray)
                }
            }
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Повторы (до 10 партий, файлами в Documents)
struct ReplayMeta: Codable, Identifiable { var id: String; var date: Date; var score: Int; var rank: String; var diff: Int }
enum ReplayStore {
    static var dir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var index: [ReplayMeta] {
        get { (UserDefaults.standard.data(forKey: "nb_rindex").flatMap { try? JSONDecoder().decode([ReplayMeta].self, from: $0) }) ?? [] }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: "nb_rindex") } }
    }
    static func add(_ m: ReplayMeta, _ r: Replay) {
        guard let d = try? JSONEncoder().encode(r) else { return }
        try? d.write(to: dir.appendingPathComponent("replay_\(m.id).json"))
        var l = index
        l.insert(m, at: 0)
        for old in l.dropFirst(10) { try? FileManager.default.removeItem(at: dir.appendingPathComponent("replay_\(old.id).json")) }
        index = Array(l.prefix(10))
    }
    static func load(_ m: ReplayMeta) -> Replay? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("replay_\(m.id).json")) else { return nil }
        return try? JSONDecoder().decode(Replay.self, from: d)
    }
    static func remove(_ m: ReplayMeta) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("replay_\(m.id).json"))
        index = index.filter { $0.id != m.id }
    }
}
struct ReplaysView: View {
    @ObservedObject var g: Game
    @State var items = ReplayStore.index
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Повторы").font(.title.bold())
            if items.isEmpty { Text("Пока пусто: сыграй партию в Классике.").foregroundColor(.gray) }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items) { m in
                        HStack {
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let r = ReplayStore.load(m) { g.watch(r) } }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("\(m.rank) · \(m.score) · \(g.names[min(2, m.diff)])").font(.headline).foregroundColor(.white)
                                    Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.gray)
                                }
                            }
                            Spacer()
                            Button { ReplayStore.remove(m); items = ReplayStore.index } label: { Image(systemName: "trash").foregroundColor(.red) }
                        }
                        .padding(12).background(Color.white.opacity(0.08)).cornerRadius(12)
                    }
                }
            }
        }
        .padding(24)
    }
}
extension Game {
    func watch(_ r: Replay) {
        rec = r; diff = r.diff; mods = Set(r.mods); seedText = String(r.seed)
        mode = 0; practice = false; tutorial = false; replayNext = true
        start()
    }
    func startDuel() {
        mode = 0; practice = false; tutorial = false; duel = 1
        seedText = String(UInt64.random(in: 1...999_999_999))
        start()
    }
}

// MARK: - Карточка результата
struct ResultCard: View {
    let g: Game
    var body: some View {
        VStack(spacing: 10) {
            Text("NEON BEAT ∞").font(.system(size: 26, weight: .black, design: .monospaced)).foregroundColor(.cyan)
            Text(g.rank).font(.system(size: 120, weight: .black)).foregroundColor(.yellow)
            Text("\(g.score)").font(.system(size: 54, weight: .black, design: .monospaced)).foregroundColor(.white)
            Text("комбо \(g.maxCombo) · точность \(String(format: "%.1f", g.acc * 100))%").foregroundColor(.gray)
            Text("\(g.names[g.diff]) · сид \(g.seed)").font(.footnote).foregroundColor(.gray)
        }
        .padding(36).frame(width: 360)
        .background(LinearGradient(colors: [Color(red: 0.03, green: 0.03, blue: 0.18), .black], startPoint: .top, endPoint: .bottom))
    }
}
@MainActor func cardImage(_ g: Game) -> Image {
    let r = ImageRenderer(content: ResultCard(g: g))
    r.scale = 3
    return Image(uiImage: r.uiImage ?? UIImage())
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
            case .mania: ManiaView(g: g)
            case .arcade: ArcadeView(g: g)
            }
        }
    }
}

@main
struct NeonBeatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark).onAppear { applyOrientation(UserDefaults.standard.integer(forKey: "nb_orient")) } }
    }
}
