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

// MARK: - Quarter-line settlement result

enum AsianOutcome: String {
  case win = "WIN"
  case halfWin = "HALF_WIN"
  case push = "PUSH"
  case halfLoss = "HALF_LOSS"
  case loss = "LOSS"
  case void = "VOID"

  /// PnL как множитель stake: WIN → (odds-1), HALF_WIN → (odds-1)/2, PUSH → 0, ...
  func pnlMultiplier(odds: Double) -> Double {
    switch self {
    case .win:      return odds - 1
    case .halfWin:  return (odds - 1) * 0.5
    case .push:     return 0
    case .halfLoss: return -0.5
    case .loss:     return -1
    case .void:     return 0
    }
  }

  /// Для Brier/LogLoss — считаем win=1, push=0.5, loss=0
  var probabilityValue: Double {
    switch self {
    case .win, .halfWin: return 1.0
    case .push:          return 0.5
    case .halfLoss, .loss, .void: return 0.0
    }
  }
}

// MARK: - QuantMath

enum QuantMath {

  // MARK: - Basic

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

  // MARK: - Uncertainty

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

  /// Wilson score 95% CI для вероятности (n = размер выборки, k = успехов)
  static func wilsonInterval(successes k: Int, trials n: Int, z: Double = 1.96)
    -> (low: Double, high: Double)
  {
    guard n > 0 else { return (0, 1) }
    let p = Double(k) / Double(n)
    let denom = 1 + z * z / Double(n)
    let centre = (p + z * z / (2 * Double(n))) / denom
    let margin = z * sqrt(p * (1 - p) / Double(n) + z * z / (4 * Double(n) * Double(n))) / denom
    return (max(0, centre - margin), min(1, centre + margin))
  }

  /// Beta-сжатие: сглаживает вероятность маленьких выборок к prior
  static func betaShrink(_ successes: Int, _ n: Int, priorMean: Double = 0.5,
                          priorStrength: Double = 4) -> Double {
    let s = Double(successes) + priorMean * priorStrength
    let t = Double(n) + priorStrength
    return t > 0 ? s / t : priorMean
  }

  // MARK: - Weighting & shrinkage

  /// Экспоненциальный decay с tunable half-life.
  static func weightedRecent(_ xs: [Double], halfLife: Double = 0.5) -> Double? {
    guard !xs.isEmpty else { return nil }
    var sw = 0.0
    var sx = 0.0
    let n = xs.count
    for (i, x) in xs.enumerated() {
      // Экспоненциальный decay: newest → weight=1, oldest → weight=halfLife^n
      let age = Double(n - 1 - i)
      let w = pow(halfLife, age)
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

  // MARK: - Poisson family

  static func poissonPMF(_ k: Int, _ lambda: Double) -> Double {
    guard k >= 0 else { return 0 }
    if lambda <= 0 { return k == 0 ? 1 : 0 }
    var p = exp(-lambda)
    if k == 0 { return p }
    for i in 1...k { p *= lambda / Double(i) }
    return p
  }

  static func dixonColes(_ lh0: Double, _ la0: Double,
                         rho: Double = -0.055, maxGoals: Int = 12) -> Matrix2D {
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

  /// Bivariate Poisson с общей компонентой λ3 (для низких счётов)
  static func bivariatePoisson(_ lh: Double, _ la: Double, l3: Double = 0.05,
                               maxGoals: Int = 12) -> Matrix2D {
    let l1 = max(1e-8, lh - l3)
    let l2 = max(1e-8, la - l3)
    let lc = max(0, l3)
    var m = Matrix2D(n: maxGoals + 1)
    for i in 0...maxGoals {
      for j in 0...maxGoals {
        // Сумма по общей компоненте k
        var p = 0.0
        for k in 0...min(i, j) {
          let kd = Double(k)
          p += poissonPMF(k, lc)
              * poissonPMF(i - k, l1)
              * poissonPMF(j - k, l2)
        }
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
    var h = 0.0; var d = 0.0; var a = 0.0
    for i in 0..<m.n {
      for j in 0..<m.n {
        if i > j { h += m[i, j] }
        else if i == j { d += m[i, j] }
        else { a += m[i, j] }
      }
    }
    return (h, d, a)
  }

  static func totalOver(_ m: Matrix2D, _ line: Double) -> Double {
    var p = 0.0
    for i in 0..<m.n {
      for j in 0..<m.n {
        if Double(i + j) > line { p += m[i, j] }
      }
    }
    return p
  }

  /// Возвращает полную дистрибуцию тотала: P(total = k) для k = 0..maxGoals*2
  static func totalDistribution(_ m: Matrix2D) -> [Double] {
    let maxTotal = (m.n - 1) * 2
    var dist = Array(repeating: 0.0, count: maxTotal + 1)
    for i in 0..<m.n {
      for j in 0..<m.n {
        let t = i + j
        if t <= maxTotal { dist[t] += m[i, j] }
      }
    }
    return dist
  }

  // MARK: - Negative Binomial

  static func negativeBinomialPMF(_ k: Int, mean: Double, variance: Double) -> Double {
    let mu = max(1e-9, mean)
    let v = max(mean + 1e-9, variance)
    let r = mu * mu / (v - mu)
    let p = r / (r + mu)
    if k == 0 { return pow(p, r) }
    var prob = 1.0
    for x in 1...k { prob *= (r + Double(x) - 1) / Double(x) * (1 - p) }
    return prob * pow(p, r)
  }

  // MARK: - Asian / quarter lines

  /// Разбивает линию на список "обычных" линий.
  /// Over 9.25 → [Over 9.0, Over 9.5]
  /// Over 9.0  → [Over 9.0]
  /// Over 9.5  → [Over 9.5]
  /// Over 9.75 → [Over 9.5, Over 10.0]
  static func splitQuarterLine(_ line: Double) -> [Double] {
    let frac = abs(line) - floor(abs(line))
    let sign: Double = line < 0 ? -1 : 1
    let base = floor(abs(line))
    // .0 или .5 → одна линия
    if abs(frac) < 0.001 || abs(frac - 0.5) < 0.001 {
      return [line]
    }
    // .25 или .75 → две линии
    if abs(frac - 0.25) < 0.001 {
      // 9.25 → 9.0 и 9.5
      return [sign * base, sign * (base + 0.5)]
    }
    if abs(frac - 0.75) < 0.001 {
      // 9.75 → 9.5 и 10.0
      return [sign * (base + 0.5), sign * (base + 1.0)]
    }
    // Прочие дробные — не азиатская, вернём как есть
    return [line]
  }

  /// Вероятность Over при азиатской линии: 0.5 * P(over line1) + 0.5 * P(over line2)
  static func overAsianProbability(
    _ dist: [Double], line: Double
  ) -> (over: Double, push: Double) {
    let lines = splitQuarterLine(line)
    if lines.count == 1 {
      let l = lines[0]
      let over = probTotalGreater(dist, l)
      let exact = probTotalEqual(dist, l)
      return (over, exact)
    }
    // Quarter line: две линии, вес 0.5 каждая
    let l1 = lines[0]
    let l2 = lines[1]
    let over1 = probTotalGreater(dist, l1)
    let over2 = probTotalGreater(dist, l2)
    let push1 = probTotalEqual(dist, l1)
    let push2 = probTotalEqual(dist, l2)
    return (0.5 * over1 + 0.5 * over2, 0.5 * push1 + 0.5 * push2)
  }

  /// Вероятность Under при азиатской линии
  static func underAsianProbability(
    _ dist: [Double], line: Double
  ) -> (under: Double, push: Double) {
    let lines = splitQuarterLine(line)
    if lines.count == 1 {
      let l = lines[0]
      let under = probTotalLess(dist, l)
      let exact = probTotalEqual(dist, l)
      return (under, exact)
    }
    let l1 = lines[0]; let l2 = lines[1]
    let under1 = probTotalLess(dist, l1)
    let under2 = probTotalLess(dist, l2)
    let push1 = probTotalEqual(dist, l1)
    let push2 = probTotalEqual(dist, l2)
    return (0.5 * under1 + 0.5 * under2, 0.5 * push1 + 0.5 * push2)
  }

  private static func probTotalGreater(_ dist: [Double], _ line: Double) -> Double {
    let ceilLine = Int(floor(line)) + 1
    var p = 0.0
    for k in ceilLine..<dist.count { p += dist[k] }
    return p
  }
  private static func probTotalLess(_ dist: [Double], _ line: Double) -> Double {
    let floorLine = Int(ceil(line)) - 1
    guard floorLine >= 0 else { return 0 }
    var p = 0.0
    for k in 0...min(floorLine, dist.count - 1) { p += dist[k] }
    return p
  }
  private static func probTotalEqual(_ dist: [Double], _ line: Double) -> Double {
    let k = Int(line)
    if Double(k) != line { return 0 }
    guard k >= 0 && k < dist.count else { return 0 }
    return dist[k]
  }

  /// Settlement азиатской линии при known total goals
  static func settleAsianTotal(
    total: Int, line: Double, isOver: Bool
  ) -> AsianOutcome {
    let lines = splitQuarterLine(line)
    var score = 0.0
    var weight = 0.0
    for l in lines {
      weight += 1.0
      if isOver {
        if Double(total) > l { score += 1 }
        else if Double(total) == l { score += 0.5 }  // push
        // иначе 0
      } else {
        if Double(total) < l { score += 1 }
        else if Double(total) == l { score += 0.5 }
      }
    }
    let ratio = weight > 0 ? score / weight : 0
    if ratio >= 0.999 { return .win }
    if ratio >= 0.749 { return .halfWin }
    if ratio >= 0.501 { return .push }
    if ratio >= 0.251 { return .halfLoss }
    return .loss
  }

  // MARK: - EV & Kelly

  static func ev(p: Double, odds: Double) -> Double { p * odds - 1 }

  /// Full Kelly (без урезаний — модификаторы в QuantEngine)
  static func kelly(p: Double, odds: Double) -> Double {
    let b = odds - 1
    let q = 1 - p
    guard b > 0 else { return 0 }
    return max(0, (b * p - q) / b)
  }

  /// Fractional Kelly с явным fraction (0.25 для quarter Kelly)
  static func fractionalKelly(p: Double, odds: Double, fraction: Double = 0.25) -> Double {
    fraction * kelly(p: p, odds: odds)
  }

  // MARK: - Monte Carlo

  static func deterministicUniform(_ seed: inout UInt64) -> Double {
    seed = 6_364_136_223_846_793_005 &* seed &+ 1_442_695_040_888_963_407
    return Double(seed >> 11) / Double(1 << 53)
  }

  static func monteCarloOutcome(_ matrix: Matrix2D, n: Int = 50000, seed: UInt64 = 42)
    -> (Double, Double, Double)
  {
    var h = 0; var d = 0; var a = 0
    var s = seed
    var cum = [Double]()
    var c = 0.0
    for p in matrix.a { c += p; cum.append(c) }
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
    var cum = [Double]()
    var c = 0.0
    for p in matrix.a { c += p; cum.append(c) }
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

  // MARK: - Statistical metrics (для Metrics / BacktestEngine)

  static func logLoss(predicted: Double, actual: Double) -> Double {
    let eps = 1e-9
    let p = min(1 - eps, max(eps, predicted))
    return actual == 1 ? -log(p) : -log(1 - p)
  }

  static func brierScore(predicted: Double, actual: Double) -> Double {
    (predicted - actual) * (predicted - actual)
  }

  static func sharpe(returns: [Double]) -> Double {
    guard returns.count > 1 else { return 0 }
    let m = returns.reduce(0, +) / Double(returns.count)
    let v = returns.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(returns.count)
    let sd = v > 0 ? sqrt(v) : 0
    return sd > 0 ? m / sd : 0
  }

  static func sortino(returns: [Double]) -> Double {
    let negs = returns.filter { $0 < 0 }
    guard !negs.isEmpty, !returns.isEmpty else { return 0 }
    let m = returns.reduce(0, +) / Double(returns.count)
    let v = negs.reduce(0) { $0 + $1 * $1 } / Double(negs.count)
    let sd = v > 0 ? sqrt(v) : 0
    return sd > 0 ? m / sd : 0
  }

  static func profitFactor(grossWin: Double, grossLoss: Double) -> Double {
    if grossLoss > 0 { return grossWin / grossLoss }
    return grossWin > 0 ? 99 : 0
  }

  // MARK: - Referee RSI

  /// RSI-подобный индекс судьи. >50 — жёсткий, <50 — мягкий.
  /// cardsPerGame = среднее карточек за игру, n = размер выборки.
  static func refereeRSI(cardsPerGame: Double, leagueMean: Double, n: Int) -> Double {
    guard n >= 3, leagueMean > 0 else { return 50 }
    let ratio = cardsPerGame / leagueMean
    // Маппим ratio [0.5..1.5] → RSI [0..100]
    let rsi = 50 + (ratio - 1.0) * 100
    return max(0, min(100, rsi))
  }

  // MARK: - Normal

  static func normalCDF(_ x: Double) -> Double { 0.5 * (1 + erf(x / sqrt(2))) }
}