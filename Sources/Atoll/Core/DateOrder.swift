import Foundation

// The macOS 27.2 SDK gives `Date` its own `<=` and `>=` (new symbols, back-deployed before 27.2). Early
// macOS 27.2 betas report 27.2 but their Foundation doesn't export them yet, so the back-deployment
// thunk skips its fallback and calls a weak symbol that resolved to nothing: EXC_BAD_ACCESS at 0x0 the
// first time two dates are compared with `<=` (the plan scheduler, in the tests and in the app).
// These module-level versions shadow Foundation's for every direct comparison in Mac Flow, so nothing
// depends on those symbols. They do exactly what Foundation's do.
extension Date {
    @inline(__always)
    static func <= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
    }

    @inline(__always)
    static func >= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
    }
}
