import Foundation

protocol ParserSink: AnyObject {
    func parserPrint(_ scalar: Unicode.Scalar)
    func parserExecute(_ control: UInt8)
    func parserCSI(_ params: [Int], isPrivate: Bool, intermediates: [UInt8], final: UInt8)
    func parserOSC(_ data: [UInt8])
    func parserESC(_ final: UInt8, intermediates: [UInt8])
}

final class Parser {
    private enum State {
        case ground
        case escape
        case csiEntry
        case csiParam
        case csiIgnore
        case osc
    }

    weak var sink: ParserSink?

    private var state: State = .ground
    private var params: [Int] = []
    private var currentParam: Int? = nil
    private var isPrivate: Bool = false
    private var intermediates: [UInt8] = []
    private var oscBuffer: [UInt8] = []

    private var utf8Partial: UInt32 = 0
    private var utf8Remaining: Int = 0

    func feed(bytes: UnsafeBufferPointer<UInt8>) {
        for b in bytes {
            consume(b)
        }
    }

    private func consume(_ b: UInt8) {
        // ESC anywhere except inside OSC's terminator parsing resets us.
        if b == 0x1B && state != .osc {
            state = .escape
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            isPrivate = false
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
            } else if b & 0b1111_0000 == 0b1110_0000 {
                utf8Partial = UInt32(b & 0b0000_1111)
                utf8Remaining = 2
            } else if b & 0b1111_1000 == 0b1111_0000 {
                utf8Partial = UInt32(b & 0b0000_0111)
                utf8Remaining = 3
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
            isPrivate = true
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
        sink?.parserCSI(params, isPrivate: isPrivate, intermediates: intermediates, final: final)
    }

    private func oscByte(_ b: UInt8) {
        if b == 0x07 {                    // BEL — string terminator
            sink?.parserOSC(oscBuffer)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
            return
        }
        if b == 0x1B {                    // ESC — could be ESC \ ST
            // Eat ESC and look for \\ in the next call; simplest: treat ESC as terminator.
            sink?.parserOSC(oscBuffer)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .escape
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            isPrivate = false
            intermediates.removeAll(keepingCapacity: true)
            return
        }
        oscBuffer.append(b)
    }
}
