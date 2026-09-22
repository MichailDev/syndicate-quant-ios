# Porting Matrix — Python bot → iOS

| Компонент исходного Quant Engine | iOS |
|---|---|
| SStats API | `APIClient.swift` |
| Retry / 429 guard | `APIClient.swift` |
| Match normalization | `QuantEngine.matches` |
| Team historical records | `APIClient.fetchTeamHistory` + `TeamRecord` |
| Dixon–Coles | `QuantMath.dixonColes` |
| Poisson PMF | `QuantMath.poissonPMF` |
| Negative Binomial PMF | `QuantMath.negativeBinomialPMF` |
| Recent weighting | `QuantMath.weightedRecent` |
| Bayesian/shrinkage blend | `QuantMath.shrink` |
| Bottom-Up Player Assembly | `QuantEngine.playerAssembly` |
| ExpMin / minutes weighting | `PlayerAgg` / `PlayerAssembly` |
| Glicko adjustment | `QuantEngine.glickoAdjust` |
| Referee profile | `refereeProfile` |
| Referee shrinkage | `blendRef` |
| Market consensus | quote grouping + median |
| Thin-market guard | minimum 3 bookmakers |
| Price anomaly | 1.25x / 1.35x fair guards |
| Sharp bookmaker guard | Pinnacle / Betfair / SBO / Marathon / Bet365 Exchange detection |
| Market dispersion | sharp-vs-consensus disagreement |
| Robust probability | DCS/sample haircut |
| DCS | source/sample/consensus/freshness/definition composite |
| QCS | MES/DCS/MS/TS/RS composite |
| EV | `QuantMath.ev` |
| Robust EV | `QuantMath.robustEV` |
| Kelly | quarter-Kelly + uncertainty haircut, cap 2% |
| Portfolio correlation | same-game / market / team correlation rules |
| Portfolio cap | max 10% total exposure |
| Quarter lines | split across adjacent half-lines |
| Monte Carlo infrastructure | deterministic probability engine / outcome matrix; production UI uses deterministic seed-compatible calculations |
| Local journal | SwiftData `JournalEntry` |
| Calibration storage | SwiftData `CalibrationSample` |
| Walk-forward result storage | SwiftData `BacktestRun` |
| Background refresh | `BGTaskScheduler` |
| Notifications | `UserNotifications` |
| API secret | iOS Keychain |

## Intentionally preserved safety rules

- NO DATA → NO NUMBER → NO EDGE → NO BET
- no fabricated odds;
- no fabricated lineups;
- no fabricated referee;
- no promotion from one bookmaker to consensus;
- no `Sharp 100` without sharp-book evidence;
- team totals are not silently substituted for match totals;
- price anomalies are blocked;
- insufficient sample is not promoted to a high-confidence bet.

Исходные Python-файлы v4.2.22 сохранены в `reference/python-engine-v4.2.22/` только для аудита и сравнения. Работа iOS-приложения от них не зависит.
