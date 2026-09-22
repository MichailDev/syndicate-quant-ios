import Foundation

struct BacktestResult { var matches=0;var bets=0;var wins=0;var losses=0;var pushes=0;var profit=0.0;var staked=0.0;var maxDrawdown=0.0;var maxLosingStreak=0;var hitRate:Double{wins+losses>0 ? Double(wins)/Double(wins+losses):0};var roi:Double{staked>0 ? profit/staked:0} }

struct CalibrationEngine {
    static func brier(_ samples:[CalibrationSample])->Double {guard !samples.isEmpty else{return 0};return samples.reduce(0){$0+($1.predicted-$1.actual)*($1.predicted-$1.actual)}/Double(samples.count)}
    static func bias(_ samples:[CalibrationSample])->Double {guard !samples.isEmpty else{return 0};return samples.reduce(0){$0+($1.predicted-$1.actual)}/Double(samples.count)}
    static func multiplier(_ samples:[CalibrationSample])->Double {let b=bias(samples);return max(0.90,min(1.10,1-b))}
}

struct WalkForwardBacktester {
    func run(matches:[Match], histories:[String:[TeamRecord]], odds:[String:JSONValue], infos:[String:JSONValue]) -> BacktestResult {
        let engine=QuantEngine();var r=BacktestResult();var equity=0.0,peak=0.0,lossStreak=0
        for match in matches.sorted(by:{($0.start ?? .distantPast)<($1.start ?? .distantPast)}) {
            guard let h=match.homeID,let a=match.awayID,let info=infos[match.id],let odd=odds[match.id] else{continue}
            let hs=histories[h] ?? [], awayRecords=histories[a] ?? []
            let signals=engine.portfolio(engine.signals(match:match,info:info,oddsJSON:odd,homeHistory:hs,awayHistory:awayRecords))
            for s in signals {r.bets += 1;r.staked += s.stake;guard let actual=actualResult(info:info,signal:s) else{continue};let pnl:Double;if actual==1{r.wins += 1;pnl=s.stake*(s.odds-1);lossStreak=0}else if actual==0.5{r.pushes += 1;pnl=0}else{r.losses += 1;pnl = -s.stake;lossStreak += 1;r.maxLosingStreak=max(r.maxLosingStreak,lossStreak)};r.profit += pnl;equity += pnl;peak=max(peak,equity);r.maxDrawdown=max(r.maxDrawdown,peak-equity)}
            r.matches += 1
        }
        return r
    }
    private func actualResult(info:JSONValue,signal:BetSignal)->Double? {
        let home=info.firstNumber(keys:["homeftresult","homescore","homegoals","home_score"]),away=info.firstNumber(keys:["awayftresult","awayscore","awaygoals","away_score"])
        if signal.market=="1X2",let h=home,let a=away {let win=signal.selection.lowercased().contains("home") || signal.selection=="1" ? h>a : signal.selection.lowercased().contains("draw") || signal.selection=="x" ? h==a : a>h;return win ? 1:0}
        let total=info.firstNumber(keys:["totalgoals","goals","score"]);guard let total else{return nil};guard let line=signal.line else{return nil};let over=signal.selection.lowercased().contains("over") || signal.selection.lowercased().hasPrefix("o");if abs(line.rounded()-line)<0.001 && Double(Int(line))==total{return 0.5};return over ? (total>line ? 1:0):(total<line ? 1:0)
    }
}
