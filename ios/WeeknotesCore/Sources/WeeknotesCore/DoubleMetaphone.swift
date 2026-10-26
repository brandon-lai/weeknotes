import Foundation

/// Double Metaphone (Lawrence Philips), ported line for line from the `double-metaphone`
/// npm package v2.0.1 by Titus Wormer (MIT). The port keeps that implementation's quirks,
/// including its JavaScript slicing semantics, so the two can be compared code for code:
/// `DoubleMetaphoneTests` checks this port against codes the JS produced.
///
/// Used by stage 3 (dictionary) to decide whether a misheard word "sounds like" a name.
public enum DoubleMetaphone {
    public static func codes(_ value: String) -> (primary: String, secondary: String) {
        var primary = ""
        var secondary = ""
        var index = 0
        let length = value.count
        let last = length - 1
        let normalized = value.uppercased() + "     "
        let characters = Array(normalized)
        let isSlavoGermanic = matches(#"W|K|CZ|WITZ"#, normalized)
        let isGermanic = matches(#"^(VAN |VON |SCH)"#, normalized)

        func char(_ i: Int) -> String {
            i >= 0 && i < characters.count ? String(characters[i]) : ""
        }
        /// JavaScript `String.prototype.slice` semantics, negative indexes included.
        func slice(_ start: Int, _ end: Int? = nil) -> String {
            let count = characters.count
            var a = start < 0 ? max(count + start, 0) : min(start, count)
            var b = end.map { $0 < 0 ? max(count + $0, 0) : min($0, count) } ?? count
            if a >= b { return "" }
            a = max(a, 0); b = min(b, count)
            return String(characters[a..<b])
        }
        func isVowel(_ s: String) -> Bool { matches("[AEIOUY]", s) }

        // Skip this at beginning of word.
        if matches(#"^(GN|KN|PN|WR|PS)"#, normalized) {
            index += 1
        }

        // Initial X is pronounced Z, which maps to S. Such as `Xavier`.
        if char(0) == "X" {
            primary += "S"
            secondary += "S"
            index += 1
        }

        while index < length {
            let previous = char(index - 1)
            let next = char(index + 1)
            let nextnext = char(index + 2)
            var subvalue: String

            switch char(index) {
            case "A", "E", "I", "O", "U", "Y", "À", "Ê", "É":
                if index == 0 {
                    // All initial vowels now map to `A`.
                    primary += "A"
                    secondary += "A"
                }
                index += 1

            case "B":
                primary += "P"
                secondary += "P"
                if next == "B" { index += 1 }
                index += 1

            case "Ç":
                primary += "S"
                secondary += "S"
                index += 1

            case "C":
                // Various Germanic.
                if previous == "A" && next == "H" && nextnext != "I" && !isVowel(char(index - 2))
                    && (nextnext != "E" || {
                        let s = slice(index - 2, index + 4)
                        return s == "BACHER" || s == "MACHER"
                    }())
                {
                    primary += "K"
                    secondary += "K"
                    index += 2
                    break
                }

                // Special case for `Caesar`.
                if index == 0 && slice(index + 1, index + 6) == "AESAR" {
                    primary += "S"
                    secondary += "S"
                    index += 2
                    break
                }

                // Italian `Chianti`.
                if slice(index + 1, index + 4) == "HIA" {
                    primary += "K"
                    secondary += "K"
                    index += 2
                    break
                }

                if next == "H" {
                    // Find `Michael`.
                    if index > 0 && nextnext == "A" && char(index + 3) == "E" {
                        primary += "K"
                        secondary += "X"
                        index += 2
                        break
                    }

                    // Greek roots such as `chemistry`, `chorus`.
                    if index == 0 && matches(#"^CH(IA|EM|OR([^E])|YM|ARAC|ARIS)"#, normalized) {
                        primary += "K"
                        secondary += "K"
                        index += 2
                        break
                    }

                    // Germanic, Greek, or otherwise `CH` for `KH` sound.
                    if isGermanic
                        || matches(#"ORCHES|ARCHIT|ORCHID"#, slice(index - 2, index + 4))
                        || nextnext == "T" || nextnext == "S"
                        || ((index == 0 || previous == "A" || previous == "E" || previous == "O" || previous == "U")
                            && matches(#"[ BFHLMNRVW]"#, nextnext))
                    {
                        primary += "K"
                        secondary += "K"
                    } else if index == 0 {
                        primary += "X"
                        secondary += "X"
                    } else if slice(0, 2) == "MC" {
                        // Such as `McHugh`.
                        primary += "K"
                        secondary += "K"
                    } else {
                        primary += "X"
                        secondary += "K"
                    }
                    index += 2
                    break
                }

                // Such as `Czerny`.
                if next == "Z" && slice(index - 2, index) != "WI" {
                    primary += "S"
                    secondary += "X"
                    index += 2
                    break
                }

                // Such as `Focaccia`.
                if slice(index + 1, index + 4) == "CIA" {
                    primary += "X"
                    secondary += "X"
                    index += 3
                    break
                }

                // Double `C`, but not `McClellan`.
                if next == "C" && !(index == 1 && char(0) == "M") {
                    // Such as `Bellocchio`, but not `Bacchus`.
                    if (nextnext == "I" || nextnext == "E" || nextnext == "H") && slice(index + 2, index + 4) != "HU" {
                        subvalue = slice(index - 1, index + 4)
                        // Such as `Accident`, `Accede`, `Succeed`.
                        if (index == 1 && previous == "A") || subvalue == "UCCEE" || subvalue == "UCCES" {
                            primary += "KS"
                            secondary += "KS"
                        } else {
                            // Such as `Bacci`, `Bertucci`, other Italian.
                            primary += "X"
                            secondary += "X"
                        }
                        index += 3
                        break
                    } else {
                        // Pierce's rule.
                        primary += "K"
                        secondary += "K"
                        index += 2
                        break
                    }
                }

                if next == "G" || next == "K" || next == "Q" {
                    primary += "K"
                    secondary += "K"
                    index += 2
                    break
                }

                // Italian.
                if next == "I" && (nextnext == "E" || nextnext == "O") {
                    primary += "S"
                    secondary += "X"
                    index += 2
                    break
                }

                if next == "I" || next == "E" || next == "Y" {
                    primary += "S"
                    secondary += "S"
                    index += 2
                    break
                }

                primary += "K"
                secondary += "K"

                // Skip two extra characters ahead in `Mac Caffrey`, `Mac Gregor`.
                if next == " " && (nextnext == "C" || nextnext == "G" || nextnext == "Q") {
                    index += 3
                    break
                }
                index += 1

            case "D":
                if next == "G" {
                    if nextnext == "E" || nextnext == "I" || nextnext == "Y" {
                        // Such as `edge`.
                        primary += "J"
                        secondary += "J"
                        index += 3
                    } else {
                        // Such as `Edgar`.
                        primary += "TK"
                        secondary += "TK"
                        index += 2
                    }
                    break
                }
                if next == "T" || next == "D" {
                    primary += "T"
                    secondary += "T"
                    index += 2
                    break
                }
                primary += "T"
                secondary += "T"
                index += 1

            case "F":
                if next == "F" { index += 1 }
                index += 1
                primary += "F"
                secondary += "F"

            case "G":
                if next == "H" {
                    if index > 0 && !isVowel(previous) {
                        primary += "K"
                        secondary += "K"
                        index += 2
                        break
                    }

                    // Such as `Ghislane`, `Ghiradelli`.
                    if index == 0 {
                        if nextnext == "I" {
                            primary += "J"
                            secondary += "J"
                        } else {
                            primary += "K"
                            secondary += "K"
                        }
                        index += 2
                        break
                    }

                    // Parker's rule (with some further refinements).
                    let minus2 = char(index - 2), minus3 = char(index - 3), minus4 = char(index - 4)
                    if minus2 == "B" || minus2 == "H" || minus2 == "D"
                        || minus3 == "B" || minus3 == "H" || minus3 == "D"
                        || minus4 == "B" || minus4 == "H"
                    {
                        index += 2
                        break
                    }

                    // Such as `laugh`, `McLaughlin`, `cough`, `gough`, `rough`, `tough`.
                    if index > 2 && previous == "U" && matches("[CGLRT]", char(index - 3)) {
                        primary += "F"
                        secondary += "F"
                    } else if index > 0 && previous != "I" {
                        primary += "K"
                        secondary += "K"
                    }
                    index += 2
                    break
                }

                if next == "N" {
                    if index == 1 && isVowel(char(0)) && !isSlavoGermanic {
                        primary += "KN"
                        secondary += "N"
                    } else if slice(index + 2, index + 4) != "EY" && slice(index + 1) != "Y" && !isSlavoGermanic {
                        // Not like `Cagney`.
                        primary += "N"
                        secondary += "KN"
                    } else {
                        primary += "KN"
                        secondary += "KN"
                    }
                    index += 2
                    break
                }

                // Such as `Tagliaro`.
                if slice(index + 1, index + 3) == "LI" && !isSlavoGermanic {
                    primary += "KL"
                    secondary += "L"
                    index += 2
                    break
                }

                // -ges-, -gep-, -gel- at beginning.
                if index == 0 && matches(#"Y[\s\S]|E[BILPRSY]|I[BELN]"#, slice(1, 3)) {
                    primary += "K"
                    secondary += "J"
                    index += 2
                    break
                }

                // -ger-, -gy-.
                if (slice(index + 1, index + 3) == "ER" && previous != "I" && previous != "E"
                    && !matches(#"^[DMR]ANGER"#, slice(0, 6)))
                    || (next == "Y" && !matches("[EGIR]", previous))
                {
                    primary += "K"
                    secondary += "J"
                    index += 2
                    break
                }

                // Italian such as `biaggi`.
                if next == "E" || next == "I" || next == "Y"
                    || ((previous == "A" || previous == "O") && next == "G" && nextnext == "I")
                {
                    if slice(index + 1, index + 3) == "ET" || isGermanic {
                        // Obvious Germanic.
                        primary += "K"
                        secondary += "K"
                    } else {
                        primary += "J"
                        // Always soft if French ending.
                        secondary += slice(index + 1, index + 5) == "IER " ? "J" : "K"
                    }
                    index += 2
                    break
                }

                if next == "G" { index += 1 }
                index += 1
                primary += "K"
                secondary += "K"

            case "H":
                // Only keep if first & before vowel or between two vowels.
                if isVowel(next) && (index == 0 || isVowel(previous)) {
                    primary += "H"
                    secondary += "H"
                    index += 1
                }
                index += 1

            case "J":
                // Obvious Spanish, `jose`, `San Jacinto`.
                if slice(index, index + 4) == "JOSE" || slice(0, 4) == "SAN " {
                    if slice(0, 4) == "SAN " || (index == 0 && char(index + 4) == " ") {
                        primary += "H"
                        secondary += "H"
                    } else {
                        primary += "J"
                        secondary += "H"
                    }
                    index += 1
                    break
                }

                if index == 0 {
                    primary += "J"
                    // Such as `Yankelovich` or `Jankelowicz`.
                    secondary += "A"
                } else if !isSlavoGermanic && (next == "A" || next == "O") && isVowel(previous) {
                    // Spanish pronunciation of such as `bajador`.
                    primary += "J"
                    secondary += "H"
                } else if index == last {
                    primary += "J"
                } else if previous != "S" && previous != "K" && previous != "L" && !matches("[LTKSNMBZ]", next) {
                    primary += "J"
                    secondary += "J"
                } else if next == "J" {
                    index += 1
                }
                index += 1

            case "K":
                if next == "K" { index += 1 }
                primary += "K"
                secondary += "K"
                index += 1

            case "L":
                if next == "L" {
                    // Spanish such as `cabrillo`, `gallegos`.
                    if (index == length - 3
                        && ((previous == "A" && nextnext == "E")
                            || (previous == "I" && (nextnext == "O" || nextnext == "A"))))
                        || (previous == "A" && nextnext == "E"
                            && (char(last) == "A" || char(last) == "O" || matches("AS|OS", slice(last - 1, length))))
                    {
                        primary += "L"
                        index += 2
                        break
                    }
                    index += 1
                }
                primary += "L"
                secondary += "L"
                index += 1

            case "M":
                if next == "M"
                    // Such as `dumb`, `thumb`.
                    || (previous == "U" && next == "B" && (index + 1 == last || slice(index + 2, index + 4) == "ER"))
                {
                    index += 1
                }
                index += 1
                primary += "M"
                secondary += "M"

            case "N":
                if next == "N" { index += 1 }
                index += 1
                primary += "N"
                secondary += "N"

            case "Ñ":
                index += 1
                primary += "N"
                secondary += "N"

            case "P":
                if next == "H" {
                    primary += "F"
                    secondary += "F"
                    index += 2
                    break
                }
                // Also account for `campbell` and `raspberry`.
                if next == "P" || next == "B" { index += 1 }
                index += 1
                primary += "P"
                secondary += "P"

            case "Q":
                if next == "Q" { index += 1 }
                index += 1
                primary += "K"
                secondary += "K"

            case "R":
                // French such as `Rogier`, but exclude `Hochmeier`.
                if index == last && !isSlavoGermanic && previous == "E" && char(index - 2) == "I"
                    && char(index - 4) != "M" && char(index - 3) != "E" && char(index - 3) != "A"
                {
                    secondary += "R"
                } else {
                    primary += "R"
                    secondary += "R"
                }
                if next == "R" { index += 1 }
                index += 1

            case "S":
                // Special cases `island`, `isle`, `carlisle`, `carlysle`.
                if next == "L" && (previous == "I" || previous == "Y") {
                    index += 1
                    break
                }

                // Special case `sugar-`.
                if index == 0 && slice(1, 5) == "UGAR" {
                    primary += "X"
                    secondary += "S"
                    index += 1
                    break
                }

                if next == "H" {
                    if matches("EIM|OEK|OLM|OLZ", slice(index + 1, index + 5)) {
                        // Germanic.
                        primary += "S"
                        secondary += "S"
                    } else {
                        primary += "X"
                        secondary += "X"
                    }
                    index += 2
                    break
                }

                if next == "I" && (nextnext == "O" || nextnext == "A") {
                    if isSlavoGermanic {
                        primary += "S"
                        secondary += "S"
                    } else {
                        primary += "S"
                        secondary += "X"
                    }
                    index += 3
                    break
                }

                // German & Anglicisations, such as `Smith` match `Schmidt`, `snider` match `Schneider`.
                if next == "Z" || (index == 0 && (next == "L" || next == "M" || next == "N" || next == "W")) {
                    primary += "S"
                    secondary += "X"
                    if next == "Z" { index += 1 }
                    index += 1
                    break
                }

                if next == "C" {
                    // Schlesinger's rule.
                    if nextnext == "H" {
                        subvalue = slice(index + 3, index + 5)
                        // Dutch origin, such as `school`, `schooner`.
                        if matches("E[DMNR]|UY|OO", subvalue) {
                            if subvalue == "ER" || subvalue == "EN" {
                                // Such as `schermerhorn`, `schenker`.
                                primary += "X"
                                secondary += "SK"
                            } else {
                                primary += "SK"
                                secondary += "SK"
                            }
                            index += 3
                            break
                        }

                        if index == 0 && !isVowel(char(3)) && char(3) != "W" {
                            primary += "X"
                            secondary += "S"
                        } else {
                            primary += "X"
                            secondary += "X"
                        }
                        index += 3
                        break
                    }

                    if nextnext == "I" || nextnext == "E" || nextnext == "Y" {
                        primary += "S"
                        secondary += "S"
                        index += 3
                        break
                    }

                    primary += "SK"
                    secondary += "SK"
                    index += 3
                    break
                }

                subvalue = slice(index - 2, index)
                // French such as `resnais`, `artois`.
                if index == last && (subvalue == "AI" || subvalue == "OI") {
                    secondary += "S"
                } else {
                    primary += "S"
                    secondary += "S"
                }
                if next == "S" { index += 1 }
                index += 1

            case "T":
                if next == "I" && nextnext == "O" && char(index + 3) == "N" {
                    primary += "X"
                    secondary += "X"
                    index += 3
                    break
                }

                if (next == "I" && nextnext == "A") || (next == "C" && nextnext == "H") {
                    primary += "X"
                    secondary += "X"
                    index += 3
                    break
                }

                if next == "H" || (next == "T" && nextnext == "H") {
                    // Special case `Thomas`, `Thames` or Germanic.
                    if isGermanic || ((nextnext == "O" || nextnext == "A") && char(index + 3) == "M") {
                        primary += "T"
                        secondary += "T"
                    } else {
                        primary += "0"
                        secondary += "T"
                    }
                    index += 2
                    break
                }

                if next == "T" || next == "D" { index += 1 }
                index += 1
                primary += "T"
                secondary += "T"

            case "V":
                if next == "V" { index += 1 }
                primary += "F"
                secondary += "F"
                index += 1

            case "W":
                // Can also be in middle of word (as already taken care of for initial).
                if next == "R" {
                    primary += "R"
                    secondary += "R"
                    index += 2
                    break
                }

                if index == 0 {
                    if isVowel(next) {
                        // `Wasserman` should match `Vasserman`.
                        primary += "A"
                        secondary += "F"
                    } else if next == "H" {
                        // Need `Uomo` to match `Womo`.
                        primary += "A"
                        secondary += "A"
                    }
                }

                // `Arnow` should match `Arnoff`.
                if ((previous == "E" || previous == "O") && next == "S" && nextnext == "K"
                    && (char(index + 3) == "I" || char(index + 3) == "Y"))
                    || slice(0, 3) == "SCH"
                    || (index == last && isVowel(previous))
                {
                    secondary += "F"
                    index += 1
                    break
                }

                // Polish such as `Filipowicz`.
                if next == "I" && (nextnext == "C" || nextnext == "T") && char(index + 3) == "Z" {
                    primary += "TS"
                    secondary += "FX"
                    index += 4
                    break
                }
                index += 1

            case "X":
                // French such as `breaux`.
                if !(index == last && previous == "U" && (char(index - 2) == "A" || char(index - 2) == "O")) {
                    primary += "KS"
                    secondary += "KS"
                }
                if next == "C" || next == "X" { index += 1 }
                index += 1

            case "Z":
                // Chinese pinyin such as `Zhao`.
                if next == "H" {
                    primary += "J"
                    secondary += "J"
                    index += 2
                    break
                } else if (next == "Z" && (nextnext == "A" || nextnext == "I" || nextnext == "O"))
                    || (isSlavoGermanic && index > 0 && previous != "T")
                {
                    primary += "S"
                    secondary += "TS"
                } else {
                    primary += "S"
                    secondary += "S"
                }
                if next == "Z" { index += 1 }
                index += 1

            default:
                index += 1
            }
        }

        return (primary, secondary)
    }

    /// True when two words share a primary or secondary code.
    public static func soundAlike(_ a: String, _ b: String) -> Bool {
        let x = codes(a), y = codes(b)
        let left = Set([x.primary, x.secondary].filter { !$0.isEmpty })
        let right = Set([y.primary, y.secondary].filter { !$0.isEmpty })
        return !left.isDisjoint(with: right)
    }

    private static func matches(_ pattern: String, _ string: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }
}
