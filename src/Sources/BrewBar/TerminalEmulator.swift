import Foundation

/// A minimal line-oriented terminal emulator that renders brew's live output exactly the way a real
/// terminal (Terminal.app) does, then exposes the current screen as plain text for the console view.
///
/// WHY THIS EXISTS
/// Homebrew's parallel download queue redraws a *block* of N status lines every frame. To overwrite
/// those lines in place it moves the cursor **up** `N-1` rows (`ESC[<n>F`), rewrites each line
/// followed by an erase-to-end (`ESC[K`), and brackets the frame in a DEC 2026 synchronized update
/// (`ESC[?2026h` … `l`). (Verified against Homebrew's `download_queue.rb` / `utils/tty.rb`:
/// `move_cursor_up_beginning` → `\e[<n>F`, `move_cursor_beginning` → `\e[0G`, `clear_to_end` →
/// `\e[K`, `move_cursor_down` → `\e[<n>B`.)
///
/// The previous implementation translated only `ESC[0G` into a carriage return and **stripped** the
/// cursor-up sequence. With one download that worked (single line rewritten via CR), but with two or
/// more downloads the cursor-up was discarded, so each frame was appended *below* the previous one —
/// producing the garbled, interleaved block users saw. Emulating a real cursor that can move up as
/// well as to column 0 makes the multi-line redraw collapse onto the same block, matching a terminal.
///
/// SCOPE
/// This is intentionally tiny: a growable array of line buffers plus a cursor (row, column). It
/// honours the control codes brew actually emits (CR, LF, CHA/`G`, CUU/`A`, CUD/`B`, CPL/`F`,
/// CNL/`E`, EL/`K`) and silently drops every other CSI / DEC-private / OSC escape (colours, cursor
/// show/hide, synchronized-update markers). It is pure (no AppKit, no model state) so it is unit
/// testable. The emulator keeps *all* scrollback — brew only ever moves the cursor up within the
/// current live block, never off the top of real history, so a single growing buffer is faithful.
struct TerminalEmulator {
    /// One screen row. Stored as a `Character` array so a mid-line overwrite (cursor not at the end)
    /// replaces the right columns without disturbing the rest of the line.
    private var lines: [[Character]] = [[]]
    /// Cursor row (index into `lines`) and column (index into that line's characters).
    private var row = 0
    private var col = 0

    /// Feed a chunk of text (ANSI control sequences intact) and update the screen. Call `render()`
    /// afterwards to read the resulting plain text.
    ///
    /// We iterate over **Unicode scalars**, not `Character` grapheme clusters. This is essential: a
    /// terminal processes a byte/scalar stream, and `"\r\n"` is a SINGLE Swift `Character` (one
    /// extended-grapheme cluster, scalars `[13, 10]`). Iterating by `Character` would hand us that
    /// combined CRLF cluster, where `isNewline` is true but the carriage-return's **column reset is
    /// invisible** — the old code treated it as a bare line feed, so the column from the previous
    /// line leaked onto the next, pushing each line progressively to the right (the observed bug on
    /// real `brew fetch` output). Scalar iteration keeps CR (`\r`) and LF (`\n`) as distinct codes.
    mutating func feed(_ text: String) {
        var index = 0
        let scalars = Array(text.unicodeScalars)
        func next() -> Unicode.Scalar? {
            guard index < scalars.count else { return nil }
            defer { index += 1 }
            return scalars[index]
        }

        while let s = next() {
            switch s {
            case "\u{1B}":  // ESC — start of an escape sequence.
                consumeEscape(next: next)
            case "\r":  // Carriage return: cursor to column 0 (does NOT change the row).
                col = 0
            case "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}":  // LF and other line breaks.
                lineFeed()
            case "\u{08}":  // Backspace: move left one column (brew's spinner occasionally emits it).
                if col > 0 { col -= 1 }
            default:
                writeScalar(s)
            }
        }
    }

    /// The screen as plain text: rows joined by newlines, trailing blank padding on each line removed.
    func render() -> String {
        lines.map { String($0) }.joined(separator: "\n")
    }

    /// Reset to an empty screen (new command).
    mutating func reset() {
        lines = [[]]
        row = 0
        col = 0
    }

    /// Replace the whole screen with `text` and put the cursor at the end of the last line. Used when
    /// the model sets `output` directly (a command heading, an error line) so the emulator's cursor
    /// stays consistent with the visible text.
    mutating func seed(_ text: String) {
        lines = text.isEmpty ? [[]] : text.components(separatedBy: "\n").map { Array($0) }
        row = lines.count - 1
        col = lines[row].count
    }

    /// Drop the oldest rows while the rendered text exceeds `maxBytes`, keeping roughly the last half.
    /// Returns the dropped-prefix note the caller should prepend (empty when nothing was trimmed).
    /// Trimming whole rows (never mid-block) keeps the live-redraw cursor maths intact: brew only ever
    /// moves the cursor up within the current block, which is always near the tail that we keep.
    mutating func trim(toUTF8 maxBytes: Int) -> Bool {
        guard render().utf8.count > maxBytes else { return false }
        // Keep rows from the end until we're back under half the limit.
        var kept = [[Character]]()
        var bytes = 0
        let target = maxBytes / 2
        for line in lines.reversed() {
            let lineBytes = String(line).utf8.count + 1
            if bytes + lineBytes > target && !kept.isEmpty { break }
            bytes += lineBytes
            kept.append(line)
        }
        lines = Array(kept.reversed())
        if lines.isEmpty { lines = [[]] }
        row = min(row, lines.count - 1)
        col = min(col, lines[row].count)
        return true
    }

    // MARK: - Cursor / writing

    private mutating func lineFeed() {
        row += 1
        while row >= lines.count { lines.append([]) }
        // A line feed moves down a row; column is preserved by a real terminal, but brew always
        // follows a block redraw with a column reset (CR / `[0G` / `[nF`). Keeping col as-is is
        // faithful; the next CR/CHA brings it back to 0 before the next line is written.
    }

    private mutating func writeScalar(_ s: Unicode.Scalar) {
        if row >= lines.count { while row >= lines.count { lines.append([]) } }

        // Zero-width combining marks (e.g. the U+FE0E/U+FE0F variation selectors brew appends to the
        // `✔︎` glyph) do not occupy their own cell. Fold them onto the previous character so the
        // check mark renders as one grapheme and the column count stays correct.
        if s.properties.canonicalCombiningClass != .notReordered
            || (0xFE00...0xFE0F).contains(s.value)   // variation selectors
            || s.properties.isGraphemeExtend {
            if col > 0 && col - 1 < lines[row].count {
                let prev = lines[row][col - 1]
                lines[row][col - 1] = Character(String(prev) + String(s))
            }
            return
        }

        let ch = Character(s)
        // Pad with spaces if the cursor is past the current end of the line.
        while lines[row].count < col { lines[row].append(" ") }
        if col < lines[row].count {
            lines[row][col] = ch        // overwrite in place
        } else {
            lines[row].append(ch)       // extend at the end
        }
        col += 1
    }

    // MARK: - Escape parsing

    /// Parse one escape sequence after the ESC. Handles CSI (`ESC[ … final`) with the cursor-motion
    /// and erase codes brew uses; everything else is consumed and ignored.
    private mutating func consumeEscape(next: () -> Unicode.Scalar?) {
        guard let first = next() else { return }
        switch first {
        case "[":  // CSI
            var params = ""
            var isPrivate = false
            while let c = next() {
                if c == "?" || c == "<" || c == "=" || c == ">" { isPrivate = true; continue }
                if ("0"..."9").contains(c) || c == ";" { params.unicodeScalars.append(c); continue }
                applyCSI(final: c, params: params, isPrivate: isPrivate)
                return
            }
        case "]":  // OSC — consume up to BEL or ESC\ (string terminator).
            while let c = next() {
                if c == "\u{07}" { return }
                if c == "\u{1B}" { _ = next(); return }
            }
        default:
            // Two-char escape (e.g. ESC(B charset) or a lone ESC: drop it.
            return
        }
    }

    /// Apply a CSI final byte. `params` is the raw numeric parameter string (e.g. "2", "0", "").
    private mutating func applyCSI(final: Unicode.Scalar, params: String, isPrivate: Bool) {
        // DEC-private sequences (`ESC[?…`) are modes like synchronized-output (2026) and cursor
        // show/hide (25); none affect the rendered text, so ignore them.
        if isPrivate { return }
        let n = max(1, Int(params) ?? 1)       // default count is 1 for motion codes
        let n0 = Int(params) ?? 0              // default 0 for column addressing (CHA)
        switch final {
        case "A":  // CUU — cursor up n rows, column unchanged.
            row = max(0, row - n)
        case "B":  // CUD — cursor down n rows, column unchanged.
            row += n; while row >= lines.count { lines.append([]) }
        case "E":  // CNL — cursor down n rows, column 0.
            row += n; while row >= lines.count { lines.append([]) }; col = 0
        case "F":  // CPL — cursor up n rows, column 0. (brew's `move_cursor_up_beginning`)
            row = max(0, row - n); col = 0
        case "G":  // CHA — cursor to column n (1-based). `[0G`/`[G` → column 0.
            col = max(0, n0 - (n0 > 0 ? 1 : 0))
        case "d":  // VPA — cursor to row n (1-based).
            row = max(0, (Int(params) ?? 1) - 1); while row >= lines.count { lines.append([]) }
        case "K":  // EL — erase in line.
            eraseInLine(mode: n0)
        case "H", "f":  // CUP — not used by brew's queue; ignore to avoid mis-positioning.
            break
        default:
            break  // SGR colours (`m`), scroll regions, etc. — no effect on plain text.
        }
    }

    /// Erase-in-line. Mode 0 (default): cursor→end. Mode 1: start→cursor. Mode 2: whole line.
    private mutating func eraseInLine(mode: Int) {
        guard row < lines.count else { return }
        switch mode {
        case 1:
            for i in 0..<min(col + 1, lines[row].count) { lines[row][i] = " " }
        case 2:
            lines[row].removeAll(keepingCapacity: true)
        default:  // 0
            if col < lines[row].count { lines[row].removeSubrange(col..<lines[row].count) }
        }
    }
}
