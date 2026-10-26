import Foundation

/// Tiny, safe expression evaluator (no NSExpression crashes on bad input).
/// Supports + - * / % ^, parentheses, sqrt/sin/cos/tan/log/ln/abs/round, pi, e.
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        let s = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "**", with: "^")
            .lowercased()
        guard s.contains(where: \.isNumber) || s.contains("pi") else { return nil }
        // Must look like math: an operator, a function, or a constant.
        let hasOperator = s.dropFirst().contains(where: { "+-*/^%".contains($0) })
        let hasFunction = ["sqrt", "sin", "cos", "tan", "log", "ln", "abs", "round", "pi"].contains { s.contains($0) }
        guard hasOperator || hasFunction else { return nil }
        var parser = Parser(Array(s))
        guard let value = parser.expression() else { return nil }
        parser.skipSpaces()
        guard parser.atEnd, value.isFinite else { return nil }
        return value
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 {
            return String(format: "%.0f", v)
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumSignificantDigits = 12
        f.usesGroupingSeparator = false
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }

        var atEnd: Bool { i >= c.count }
        mutating func skipSpaces() { while i < c.count, c[i] == " " { i += 1 } }
        mutating func peek() -> Character? { skipSpaces(); return i < c.count ? c[i] : nil }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                i += 1
                guard let r = power() else { return nil }
                switch op {
                case "*": v *= r
                case "/": v /= r
                default: v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            guard let ch = peek() else { return nil }
            if ch == "(" {
                i += 1
                let v = expression()
                guard peek() == ")" else { return nil }
                i += 1
                return v
            }
            if ch.isNumber || ch == "." {
                let start = i
                while i < c.count, c[i].isNumber || c[i] == "." || c[i] == "," { i += 1 }
                let str = String(c[start..<i]).replacingOccurrences(of: ",", with: "")
                return Double(str)
            }
            if ch.isLetter {
                let start = i
                while i < c.count, c[i].isLetter { i += 1 }
                let name = String(c[start..<i])
                switch name {
                case "pi": return Double.pi
                case "e": return M_E
                default:
                    guard let arg = primary() else { return nil }
                    switch name {
                    case "sqrt": return sqrt(arg)
                    case "sin": return sin(arg)
                    case "cos": return cos(arg)
                    case "tan": return tan(arg)
                    case "log": return log10(arg)
                    case "ln": return log(arg)
                    case "abs": return abs(arg)
                    case "round": return arg.rounded()
                    default: return nil
                    }
                }
            }
            return nil
        }
    }
}
