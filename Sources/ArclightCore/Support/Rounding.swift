extension Double {
    /// Rounded to `places` decimals, halves away from zero: `(self * 10ⁿ).rounded() / 10ⁿ`.
    public func rounded(places: Int) -> Double {
        var m = 1.0
        for _ in 0..<places { m *= 10 }
        return (self * m).rounded() / m
    }
}
