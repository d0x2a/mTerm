import Foundation

/// Internal, not `package`, and that is load-bearing: `Parser` calls through
/// this once per byte, and whole-module optimisation can only devirtualise
/// those calls while it can see every conformer. Exposed to the rest of the
/// package, any other module could conform, the calls stay dynamic, and parse
/// throughput fell by a third. Other modules wire a parser up with
/// `Parser.attach(_:)` instead.
protocol ParserSink: AnyObject {
    func parserPrint(_ scalar: Unicode.Scalar)

    /// A run of printable ASCII (0x20...0x7E) met in the ground state, handed
    /// over whole. Most of what a terminal is sent is exactly this, and taking
    /// it a glyph at a time put a protocol call, a width lookup and a checked
    /// grid write on every byte of it — see docs/BENCHMARKS.md. Means the same
    /// as `parserPrint` for each byte in turn.
    func parserPrintASCII(_ run: UnsafeBufferPointer<UInt8>)

    func parserExecute(_ control: UInt8)
    func parserCSI(_ params: [Int], marker: UInt8?, intermediates: [UInt8], final: UInt8)
    func parserOSC(_ data: [UInt8], terminator: UInt8)
    func parserESC(_ final: UInt8, intermediates: [UInt8])

    /// `ESC k <name> ST` — the window name, as screen and tmux define it. Not
    /// an OSC and not a DCS; its own little string sequence, and the one a
    /// shell reaches for when `TERM` is screen-like.
    func parserWindowName(_ name: [UInt8])

    /// A device control string opened: `ESC P params final`.
    ///
    /// Delivered in three parts rather than as one buffer because a DCS is not
    /// necessarily short. `tmux -CC` opens one (`ESC P 1000 p`) and then keeps
    /// it open for the life of the session, streaming every pane's output
    /// through it, so a parser that waited for the terminator would buffer the
    /// entire session and deliver it once, at exit.
    func parserDCSStart(_ params: [Int], intermediates: [UInt8], final: UInt8)
    func parserDCSPut(_ bytes: ArraySlice<UInt8>)
    func parserDCSEnd()
}

/// DCS is ignorable: a sink that has no use for one can leave these alone and
/// the payload is simply dropped, which is what a terminal should do with a
/// device control string it doesn't implement — and emphatically not what
/// mTerm did before, which was to print the payload as text.
extension ParserSink {
    /// A sink with no faster way to take a run gets it a glyph at a time,
    /// which is what a run means.
    func parserPrintASCII(_ run: UnsafeBufferPointer<UInt8>) {
        for b in run { parserPrint(Unicode.Scalar(b)) }
    }

    func parserWindowName(_ name: [UInt8]) {}
    func parserDCSStart(_ params: [Int], intermediates: [UInt8], final: UInt8) {}
    func parserDCSPut(_ bytes: ArraySlice<UInt8>) {}
    func parserDCSEnd() {}
}

package final class Parser {
    package init() {}

    private enum State {
        case ground
        case escape
        case csiEntry
        case csiParam
        case csiIgnore
        case osc
        /// `ESC P` seen; collecting parameters and intermediates up to the
        /// final byte.
        case dcsEntry
        /// Past the final byte; everything up to the string terminator is
        /// payload and is streamed to the sink as it arrives.
        case dcsPassthrough
        /// A DCS whose introducer didn't parse, and the string sequences with
        /// no meaning here (APC, PM, SOS). Payload is swallowed rather than
        /// printed, and the terminator still ends it.
        case dcsIgnore
        /// `ESC k` seen; collecting the window name up to the terminator.
        case windowName
    }

    /// Strong on purpose, and worth 2x on the parse hot path.
    ///
    /// `consume` reaches the sink for every printable byte, and a `weak`
    /// reference cannot be held in a register across that loop: each access
    /// is a `swift_unknownObjectWeakLoadStrong` — a side-table lock and an
    /// atomic retain — followed by the matching release. Profiling a 64 MB
    /// ASCII replay, those two calls were half of all samples on the parsing
    /// thread, and making this strong took the same replay from 15.6 MB/s to
    /// 30.8 MB/s (see docs/BENCHMARKS.md).
    ///
    /// It cannot cycle: `TerminalState` has no reference back to `Parser`.
    /// `Session` owns both and outlives them, which is the only ownership
    /// this reference ever participates in.
    var sink: ParserSink?

    /// Feed this parser's output into `state`. The way other modules set
    /// `sink`, which they can't name — see `ParserSink`.
    package func attach(_ state: TerminalState) {
        sink = state
    }

    private var state: State = .ground
    private var params: [Int] = []
    private var currentParam: Int? = nil
    /// The private-parameter marker byte ('?', '>', '<', '='), when the
    /// sequence carried one. They don't mean the same thing — '?' introduces
    /// DEC private modes, '>' the secondary device attributes — so collapsing
    /// them into a single flag loses the distinction.
    private var marker: UInt8? = nil
    private var intermediates: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    /// DCS payload accumulated within one `feed` call, flushed at its end (or
    /// at the terminator). Per-byte delivery would cost a protocol call per
    /// byte of a tmux session; per-`feed` matches the 8 KB the PTY hands us.
    private var dcsScratch: [UInt8] = []
    /// Body of a window-name string. Short by nature, so unlike the DCS
    /// payload it is buffered whole and delivered at the terminator.
    private var stringBuffer: [UInt8] = []

    private var utf8Partial: UInt32 = 0
    private var utf8Remaining: Int = 0
    /// The length the lead byte announced, which `pendingSequence` needs to
    /// know how many bytes `utf8Partial` holds. Set on lead bytes only.
    private var utf8Length: Int = 0

    package func feed(bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else { flushDCS(); return }
        let count = bytes.count
        var i = 0
        while i < count {
            // Printable ASCII in the ground state goes to the sink as a run
            // rather than through `consume` a byte at a time. It is what
            // `groundByte` would do with each of them, including dropping a
            // UTF-8 sequence the run cuts short.
            if state == .ground {
                var end = i
                // 0x20...0x7E: anything below 0x20 wraps round to the top of
                // the byte range, so one unsigned compare covers both edges.
                while end < count, base[end] &- 0x20 < 0x5F { end += 1 }
                if end > i {
                    utf8Remaining = 0
                    sink?.parserPrintASCII(UnsafeBufferPointer(start: base + i, count: end - i))
                    i = end
                    continue
                }
            }
            consume(base[i])
            i += 1
        }
        // Whatever payload this chunk ended mid-stream. The terminator path
        // flushes itself, before it reports the end.
        flushDCS()
    }

    /// The bytes that bring a fresh parser to where this one is: partway
    /// through an escape sequence or a UTF-8 character, or nothing at all.
    ///
    /// Something that copies a buffer between reads needs this as well as the
    /// grid. A read ends wherever the kernel cut it, often inside a sequence,
    /// and the rest of that sequence arrives at the start of the next read —
    /// which a parser starting from the ground state would print as text.
    /// Rebuilt from what the parser kept rather than the bytes it saw: `CSI 03`
    /// comes back as `CSI 3`, which means the same thing.
    package func pendingSequence() -> [UInt8] {
        func csiBody() -> [UInt8] {
            var out: [UInt8] = []
            if let marker { out.append(marker) }
            for p in params { out += Array(String(p).utf8); out.append(0x3B) }
            if let currentParam { out += Array(String(currentParam).utf8) }
            out += intermediates
            return out
        }
        switch state {
        case .ground:
            guard utf8Remaining > 0 else { return [] }
            let consumed = utf8Length - utf8Remaining
            let lead: UInt8 = utf8Length == 2 ? 0xC0 : utf8Length == 3 ? 0xE0 : 0xF0
            var out = [lead | UInt8(truncatingIfNeeded: utf8Partial >> (6 * (consumed - 1)))]
            for i in 1 ..< max(1, consumed) {
                out.append(0x80 | UInt8(truncatingIfNeeded: (utf8Partial >> (6 * (consumed - 1 - i))) & 0x3F))
            }
            return out
        case .escape:
            return [0x1B] + intermediates
        case .csiEntry:
            return [0x1B, 0x5B]
        case .csiParam:
            return [0x1B, 0x5B] + csiBody()
        case .csiIgnore:
            return [0x1B, 0x5B, 0x3C, 0x3C]             // a second marker is ignored to the end
        case .osc:
            return [0x1B, 0x5D] + oscBuffer
        case .dcsEntry:
            return [0x1B, 0x50] + csiBody()
        case .dcsPassthrough:
            // The final byte isn't kept once the introducer is dispatched;
            // any will do to swallow the rest of the payload.
            return [0x1B, 0x50] + csiBody() + [0x70]
        case .dcsIgnore:
            return [0x1B, 0x5F]
        case .windowName:
            return [0x1B, 0x6B] + stringBuffer
        }
    }

    private func flushDCS() {
        guard !dcsScratch.isEmpty else { return }
        sink?.parserDCSPut(dcsScratch[...])
        dcsScratch.removeAll(keepingCapacity: true)
    }

    private func consume(_ b: UInt8) {
        // ESC anywhere except inside a string (OSC, DCS) resets us — inside
        // one it is how the ST terminator begins.
        if b == 0x1B && state != .osc && state != .dcsPassthrough
            && state != .dcsIgnore && state != .windowName {
            state = .escape
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            marker = nil
            intermediates.removeAll(keepingCapacity: true)
            return
        }

        switch state {
        case .ground:        groundByte(b)
        case .escape:        escapeByte(b)
        case .csiEntry:      csiEntryByte(b)
        case .csiParam:      csiParamByte(b)
        case .csiIgnore:     csiIgnoreByte(b)
        case .osc:           oscByte(b)
        case .dcsEntry:      dcsEntryByte(b)
        case .dcsPassthrough: dcsPassthroughByte(b)
        case .dcsIgnore:     dcsIgnoreByte(b)
        case .windowName:    windowNameByte(b)
        }
    }

    private func groundByte(_ b: UInt8) {
        if b == 0x7F { return }      // DEL ignored
        if b < 0x20 {
            sink?.parserExecute(b)
            return
        }
        if b < 0x80 {
            utf8Remaining = 0
            sink?.parserPrint(Unicode.Scalar(b))
            return
        }
        // UTF-8 multibyte
        if utf8Remaining == 0 {
            if b & 0b1110_0000 == 0b1100_0000 {
                utf8Partial = UInt32(b & 0b0001_1111)
                utf8Remaining = 1
                utf8Length = 2
            } else if b & 0b1111_0000 == 0b1110_0000 {
                utf8Partial = UInt32(b & 0b0000_1111)
                utf8Remaining = 2
                utf8Length = 3
            } else if b & 0b1111_1000 == 0b1111_0000 {
                utf8Partial = UInt32(b & 0b0000_0111)
                utf8Remaining = 3
                utf8Length = 4
            } else {
                sink?.parserPrint(Unicode.Scalar(0xFFFD)!)
            }
        } else {
            utf8Partial = (utf8Partial << 6) | UInt32(b & 0b0011_1111)
            utf8Remaining -= 1
            if utf8Remaining == 0 {
                let scalar = Unicode.Scalar(utf8Partial) ?? Unicode.Scalar(0xFFFD)!
                utf8Partial = 0
                sink?.parserPrint(scalar)
            }
        }
    }

    private func escapeByte(_ b: UInt8) {
        switch b {
        case 0x5B:                        // '['
            state = .csiEntry
        case 0x5D:                        // ']'
            oscBuffer.removeAll(keepingCapacity: true)
            state = .osc
        case 0x6B:                        // 'k' — screen/tmux window name
            // Same failure as 'P' below: it fell through the 0x30...0x7E case
            // as an ESC dispatch and the name printed as text. Only visible
            // under tmux, because that is when TERM goes screen-like and a
            // shell starts emitting these — oh-my-zsh sets the window name to
            // the command it is about to run, so running `cd` printed "cd" and
            // running `claude` printed "claude".
            stringBuffer.removeAll(keepingCapacity: true)
            state = .windowName
        case 0x5F, 0x5E, 0x58:            // '_' APC, '^' PM, 'X' SOS
            // No meaning here, but they are strings: swallow to the
            // terminator rather than printing the body.
            state = .dcsIgnore
        case 0x50:                        // 'P' — DCS
            // Without this, 'P' fell through the 0x30...0x7E case below as an
            // ESC dispatch and the payload printed as text: `ESC P 1000 p`
            // from `tmux -CC` put a literal "1000p" on screen.
            state = .dcsEntry
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x30...0x7E:
            sink?.parserESC(b, intermediates: intermediates)
            state = .ground
        default:
            state = .ground
        }
    }

    private func csiEntryByte(_ b: UInt8) {
        switch b {
        case 0x3C...0x3F:                 // '<' '=' '>' '?'
            marker = b
            state = .csiParam
        case 0x30...0x39:                 // digit
            currentParam = Int(b - 0x30)
            state = .csiParam
        case 0x3B:                        // ';'
            params.append(0)
            state = .csiParam
        case 0x20...0x2F:
            intermediates.append(b)
            state = .csiParam
        case 0x40...0x7E:
            dispatchCSI(final: b)
            state = .ground
        case 0x18, 0x1A:
            state = .ground
        default:
            state = .csiIgnore
        }
    }

    private func csiParamByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39:
            currentParam = (currentParam ?? 0) * 10 + Int(b - 0x30)
        case 0x3B:
            params.append(currentParam ?? 0)
            currentParam = nil
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x40...0x7E:
            dispatchCSI(final: b)
            state = .ground
        case 0x18, 0x1A:
            state = .ground
        default:
            state = .csiIgnore
        }
    }

    private func csiIgnoreByte(_ b: UInt8) {
        if (0x40...0x7E).contains(b) {
            state = .ground
        }
    }

    private func dispatchCSI(final: UInt8) {
        if let p = currentParam { params.append(p) }
        currentParam = nil
        sink?.parserCSI(params, marker: marker, intermediates: intermediates, final: final)
    }

    // MARK: DCS

    /// Parameters and intermediates, exactly as CSI collects them, up to the
    /// final byte that names the control.
    private func dcsEntryByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39:                 // digit
            currentParam = (currentParam ?? 0) * 10 + Int(b - 0x30)
        case 0x3B:                        // ';'
            params.append(currentParam ?? 0)
            currentParam = nil
        case 0x3C...0x3F:                 // private marker
            marker = b
        case 0x20...0x2F:                 // intermediate
            intermediates.append(b)
        case 0x40...0x7E:                 // final
            if let p = currentParam { params.append(p) }
            currentParam = nil
            sink?.parserDCSStart(params, intermediates: intermediates, final: b)
            state = .dcsPassthrough
        default:
            state = .dcsIgnore
        }
    }

    /// Payload. Handed to the sink a byte at a time is too slow for a stream
    /// that carries a whole tmux session, so runs between terminators are
    /// passed as slices — see `feed`.
    private func dcsPassthroughByte(_ b: UInt8) {
        if b == 0x1B {                    // ESC — the ST terminator's first half
            flushDCS()                    // payload before the end, not after
            sink?.parserDCSEnd()
            state = .escape
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            marker = nil
            intermediates.removeAll(keepingCapacity: true)
            return
        }
        if b == 0x07 {                    // BEL, accepted as a terminator too
            flushDCS()
            sink?.parserDCSEnd()
            state = .ground
            return
        }
        dcsScratch.append(b)
    }

    private func windowNameByte(_ b: UInt8) {
        if b == 0x1B {                    // ESC — the ST terminator's first half
            sink?.parserWindowName(stringBuffer)
            stringBuffer.removeAll(keepingCapacity: true)
            state = .escape
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            marker = nil
            intermediates.removeAll(keepingCapacity: true)
            return
        }
        if b == 0x07 {                    // BEL, accepted as a terminator too
            sink?.parserWindowName(stringBuffer)
            stringBuffer.removeAll(keepingCapacity: true)
            state = .ground
            return
        }
        stringBuffer.append(b)
    }

    private func dcsIgnoreByte(_ b: UInt8) {
        if b == 0x1B {
            state = .escape
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            marker = nil
            intermediates.removeAll(keepingCapacity: true)
            return
        }
        if b == 0x07 { state = .ground }
    }

    private func oscByte(_ b: UInt8) {
        if b == 0x07 {                    // BEL — string terminator
            sink?.parserOSC(oscBuffer, terminator: 0x07)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
            return
        }
        if b == 0x1B {                    // ESC — could be ESC \ ST
            // Eat ESC and look for \\ in the next call; simplest: treat ESC as terminator.
            sink?.parserOSC(oscBuffer, terminator: 0x1B)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .escape
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            marker = nil
            intermediates.removeAll(keepingCapacity: true)
            return
        }
        oscBuffer.append(b)
    }
}
