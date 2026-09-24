import Foundation

struct Matrix2D {
  var n: Int
  var a: [Double]
  init(n: Int, fill: Double = 0) {
    self.n = n
    self.a = Array(repeating: fill, count: n * n)
  }
  subscript(_ i: Int, _ j: Int) -> Double {
    get { a[i * n + j] }
    set { a[i * n + j] = newValue }
  }
  var sum: Double { a.reduce(0, +) }
}

enum QuantMath {
  static func clamp(_ x: Double, _ lo: Double = 1e-9, _ hi: Double = 1 - 1e-9) -> Double {
    min(hi, max(lo, x))
  }

  static func mean(_ xs: [Double]) -> Double? {
    xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
  }

  static func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let a = xs.sorted()
    return a[a.count / 2]
  }

  static func mad(_ xs: [Double]) -> Double? {
    guard let m = median(xs), !xs.isEmpty else { return nil }
    return median(xs.map { abs($0 - m) })
  }

  static func variance(_ xs: [Double]) -> Double? {
    guard xs.count > 1, let m = mean(xs) else { return nil }
    return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
  }

  // MARK: - Uncertainty & Confidence

  static func probabilityInterval(
    _ p: Double, sample: Int, dcs: Double, marketMAD: Double
  ) -> (low: Double, mid: Double, high: Double, uncertainty: Double) {
    let n = Double(max(1, sample))
    let sampleU = min(0.16, 0.055 + 0.12 / sqrt(n))
    let qualityU = min(0.10, max(0, 60 - dcs) / 600.0)
    let marketU = min(0.08, marketMAD / 100.0)
    let u = min(0.25, sampleU + qualityU + marketU)
    let mid = clamp(p)
    return (clamp(mid - u), mid, clamp(mid + u), u)
  }

  static func confidenceAdjustedProbability(_ p: Double, uncertainty: Double) -> Double {
    let c = clamp(1 - min(0.80, uncertainty), 0.20, 1.0)
    return clamp(0.5 + (clamp(p) - 0.5) * c)
  }

  // MARK: - Shrinkage

  static func weightedRecent(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    var sw = 0.0
    var sx = 0.0
    for (i, x) in xs.enumerated() {
      let w = exp(-1.0 + Double(i) / Double(max(xs.count - 1, 1)))
      sw += w
      sx += w * x
    }
    return sx / sw
  }

  static func shrink(_ xs: [Double], baseline: Double?, k: Double = 8) -> Double? {
    guard let r = weightedRecent(xs) else { return baseline }
    guard let b = baseline else { return r }
    let w = Double(xs.count) / (Double(xs.count) + k)
    return w * r + (1 - w) * b
  }

  // MARK: - Poisson / Dixon–Coles / NB

  static func poissonPMF(_ k: Int, _ lambda: Double) -> Double {
    guard k >= 0 else { return 0 }
    if lambda <= 0 { return k == 0 ? 1 : 0 }
    var p = exp(-lambda)
    if k == 0 { return p }
    for i in 1...k { p *= lambda / Double(i) }
    return p
  }

  static func dixonColes(
    _ lh0: Double, _ la0: Double, rho: Double = -0.055, maxGoals: Int = 12
  ) -> Matrix2D {
    let lh = max(1e-8, lh0)
    let la = max(1e-8, la0)
    var m = Matrix2D(n: maxGoals + 1)
    for i in 0...maxGoals {
      for j in 0...maxGoals {
        var p = poissonPMF(i, lh) * poissonPMF(j, la)
        if i == 0 && j == 0 { p *= 1 - lh * la * rho }
        if i == 0 && j == 1 { p *= 1 + lh * rho }
        if i == 1 && j == 0 { p *= 1 + la * rho }
        if i == 1 && j == 1 { p *= 1 - rho }
        m[i, j] = max(0, p)
      }
    }
    let s = m.sum
    if s > 0 {
      for i in 0...maxGoals {
        for j in 0...maxGoals { m[i, j] /= s }
      }
    }
    return m
  }

  static func outcomes(_ m: Matrix2D) -> (home: Double, draw: Double, away: Double) {
    var h = 0.0
    var d = 0.0
    var a = 0.0
    for i in 0..<m.n {
      for j in 0..<m.n {
        if i > j { h += m[i, j] } else if i == j { d += m[i, j] } else { a += m[i, j] }
      }
    }
    return (h, d, a)
  }

  static func totalOver(_ m: Matrix2D, _ line: Double) -> Double {
    var p = 0.0
    for i in 0..<m.n {
      for j in 0..<m.n { if Double(i + j) > line { p += m[i, j] } }
    }
    return p
  }

  static func negativeBinomialPMF(_ k: Int, mean: Double, variance: Double) -> Double {
    let mu = max(1e-9, mean)
    let v = max(mean + 1e-9, variance)
    let r = mu * mu / (v - mu)
    let p = r / (r + mu)
    var prob = 1.0
    if k == 0 { return pow(p, r) }
    for x in 1...k { prob *= (r + Double(x) - 1) / Double(x) * (1 - p) }
    return prob * pow(p, r)
  }

  // MARK: - EV & Kelly

  /// EV = p × odds − 1
  static func ev(p: Double, odds: Double) -> Double { p * odds - 1 }

  /// Full Kelly — БЕЗ урезаний. Все haircut'ы применяются в QuantEngine.
  static func kelly(p: Double, odds: Double) -> Double {
    let b = odds - 1
    let q = 1 - p
    guard b > 0 else { return 0 }
    return max(0, (b * p - q) / b)
  }

  // MARK: - Monte Carlo

  static func deterministicUniform(_ seed: inout UInt64) -> Double {
    seed = 6_364_136_223_846_793_005 &* seed &+ 1_442_695_040_888_963_407
    return Double(seed >> 11) / Double(1 << 53)
  }

  static func monteCarloOutcome(
    _ matrix: Matrix2D, n: Int = 50000, seed: UInt64 = 42
  ) -> (Double, Double, Double) {
    var h = 0, d = 0, a = 0
    var s = seed
    var flat = [Double]()
    flat.reserveCapacity(matrix.n * matrix.n)
    for x in matrix.a { flat.append(x) }
    var c = 0.0
    var cum = [Double]()
    for p in flat { c += p; cum.append(c) }
    for _ in 0..<n {
      let u = deterministicUniform(&s)
      var idx = 0
      while idx < cum.count - 1 && u > cum[idx] { idx += 1 }
      let i = idx / matrix.n
      let j = idx % matrix.n
      if i > j { h += 1 } else if i == j { d += 1 } else { a += 1 }
    }
    let z = Double(max(n, 1))
    return (Double(h) / z, Double(d) / z, Double(a) / z)
  }

  static func monteCarloTotal(
    _ matrix: Matrix2D, line: Double, n: Int = 50000, seed: UInt64 = 42, over: Bool = true
  ) -> Double {
    var s = seed
    var flat = [Double]()
    var cum = [Double]()
    var c = 0.0
    for p in matrix.a { flat.append(p); c += p; cum.append(c) }
    var hits = 0
    for _ in 0..<n {
      let u = deterministicUniform(&s)
      var idx = 0
      while idx < cum.count - 1 && u > cum[idx] { idx += 1 }
      let i = idx / matrix.n
      let j = idx % matrix.n
      let yes = Double(i + j) > line
      if yes == over { hits += 1 }
    }
    return Double(hits) / Double(max(n, 1))
  }

  static func normalCDF(_ x: Double) -> Double { 0.5 * (1 + erf(x / sqrt(2))) }
}