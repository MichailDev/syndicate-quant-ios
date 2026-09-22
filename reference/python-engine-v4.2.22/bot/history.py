from __future__ import annotations
import datetime as dt
import json
from pathlib import Path
from collections import defaultdict

BASE_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = BASE_DIR / 'data'

REPORT_ENGINE_PREFIXES = ('v4.1', 'v4.2')

LEAGUES = {
    39: '🇬🇧 Premier League',
    140: '🇪🇸 La Liga',
    135: '🇮🇹 Serie A',
    78: '🇩🇪 Bundesliga',
    61: '🇫🇷 Ligue 1',
    235: '🇷🇺 РПЛ',
}
MARKET_NAMES = {'1X2': '1X2', 'GOALS': '⚽ Голы', 'CARDS': '🟨 ЖК', 'CORNERS': '🚩 Угловые'}


def _read_reports():
    root = DATA_DIR
    rows = []
    if not root.exists():
        return rows
    for p in sorted(root.glob('walkforward_*.json')):
        if p.name == 'walkforward_report.json':
            continue
        try:
            x = json.loads(p.read_text(encoding='utf-8'))
            if x.get('status') == 'ok' and any(str(x.get('engine','')).startswith(prefix) for prefix in REPORT_ENGINE_PREFIXES):
                rows.append(x)
        except Exception:
            continue
    return rows


def _fmt_pct(x):
    return f'{float(x or 0) * 100:+.2f}%'


def _agg(rows):
    out = {'reports': len(rows), 'matches': 0, 'bets': 0, 'wins': 0, 'losses': 0, 'pushes': 0,
           'staked': 0.0, 'profit': 0.0, 'expected_profit': 0.0, 'ev_sum': 0.0, 'robust_ev_sum': 0.0,
           'prediction_count': 0, 'prediction_ev_sum': 0.0, 'prediction_robust_ev_sum': 0.0}
    for r in rows:
        out['matches'] += int(r.get('matches', 0) or 0)
        for m in (r.get('metrics') or {}).values():
            out['bets'] += int(m.get('portfolio_bets', 0) or 0)
            out['wins'] += int(m.get('wins', 0) or 0)
            out['losses'] += int(m.get('losses', 0) or 0)
            out['pushes'] += int(m.get('pushes', 0) or 0)
            out['staked'] += float(m.get('staked_units', 0) or 0)
            out['profit'] += float(m.get('profit_units', 0) or 0)
            out['expected_profit'] += float(m.get('expected_profit_units', 0) or 0)
            out['ev_sum'] += float(m.get('avg_ev', 0) or 0) * int(m.get('portfolio_bets', 0) or 0)
            out['robust_ev_sum'] += float(m.get('avg_robust_ev', 0) or 0) * int(m.get('portfolio_bets', 0) or 0)
            n_pred=int(m.get('predictions', 0) or 0)
            out['prediction_count'] += n_pred
            out['prediction_ev_sum'] += float(m.get('avg_prediction_ev', 0) or 0) * n_pred
            out['prediction_robust_ev_sum'] += float(m.get('avg_prediction_robust_ev', 0) or 0) * n_pred
    decisive = out['wins'] + out['losses']
    out['hit_rate'] = out['wins'] / decisive if decisive else 0
    out['roi'] = out['profit'] / out['staked'] if out['staked'] else 0
    out['avg_ev'] = out['ev_sum'] / out['bets'] if out['bets'] else 0
    out['avg_robust_ev'] = out['robust_ev_sum'] / out['bets'] if out['bets'] else 0
    out['avg_prediction_ev'] = out['prediction_ev_sum'] / out['prediction_count'] if out['prediction_count'] else 0
    out['avg_prediction_robust_ev'] = out['prediction_robust_ev_sum'] / out['prediction_count'] if out['prediction_count'] else 0
    return out


def summary():
    rows = _read_reports()
    a = _agg(rows)
    state = {}
    p = DATA_DIR / 'auto_backtest_state.json'
    if p.exists():
        try: state = json.loads(p.read_text(encoding='utf-8'))
        except Exception: state = {}
    return rows, a, state


def overview_text():
    rows, a, state = summary()
    if not rows:
        return '🗂 ИСТОРИЯ СИСТЕМЫ\n\nПока нет завершённых исторических отчётов.\nЗапусти /backtest или дождись автоматической проверки.'
    last = state.get('last_success')
    last_txt = '—'
    league_ids = {int(r.get('league', 0)) for r in rows if r.get('league') is not None}
    seasons = {(int(r.get('league', 0)), int(r.get('year', 0))) for r in rows if r.get('league') is not None and r.get('year') is not None}
    if last:
        try:
            last_txt = dt.datetime.fromisoformat(last.replace('Z', '+00:00')).strftime('%d.%m.%Y %H:%M UTC')
        except Exception:
            last_txt = str(last)[:19]
    return (
        '🗂 ИСТОРИЯ СИСТЕМЫ\n\n'
        f'Отчётов: {a["reports"]} | Матчей: {a["matches"]}\n'
        f'Лиг: {len(league_ids)} | Сезонов/лиг: {len(seasons)}\n'
        f'Ставок портфеля: {a["bets"]}\n'
        f'✅ W {a["wins"]}  ❌ L {a["losses"]}  ↩️ P {a["pushes"]}\n'
        f'🎯 Hit rate: {a["hit_rate"]*100:.1f}%\n'
        f'💰 Profit: {a["profit"]:+.4f} банка\n'
        f'📈 ROI: {_fmt_pct(a["roi"])}\n'
        f'🧮 Avg EV: {_fmt_pct(a["avg_ev"])}\n'
        f'🛡 Avg Robust EV: {_fmt_pct(a["avg_robust_ev"])}\n'
        f'🔎 Avg Prediction EV: {_fmt_pct(a["avg_prediction_ev"])} | Robust: {_fmt_pct(a["avg_prediction_robust_ev"])}\n'
        f'🔄 Последняя авто-проверка: {last_txt}'
    )


def leagues_text():
    rows, _, _ = summary()
    if not rows:
        return '🗂 ПО ЛИГАМ\n\nНет исторических данных.'
    groups = defaultdict(list)
    for r in rows:
        groups[int(r.get('league', 0))].append(r)
    lines = ['🗂 ИСТОРИЯ — ПО ЛИГАМ', '']
    for lid in sorted(groups, key=lambda x: LEAGUES.get(x, f'Лига {x}')):
        a = _agg(groups[lid])
        lines.append(f'{LEAGUES.get(lid, f"Лига {lid}")}')
        lines.append(f'  {a["bets"]} bets | W/L/P {a["wins"]}/{a["losses"]}/{a["pushes"]} | HR {a["hit_rate"]*100:.1f}% | ROI {_fmt_pct(a["roi"])}')
    return '\n'.join(lines)[:3900]


def markets_text():
    rows, _, _ = summary()
    if not rows:
        return '🗂 ПО РЫНКАМ\n\nНет исторических данных.'
    buckets = defaultdict(list)
    for r in rows:
        for market, metric in (r.get('metrics') or {}).items():
            x = dict(metric)
            x['_market'] = market
            buckets[market].append(x)
    lines = ['🗂 ИСТОРИЯ — ПО РЫНКАМ', '']
    for market in ['1X2', 'GOALS', 'CARDS', 'CORNERS']:
        ms = buckets.get(market, [])
        if not ms: continue
        bets = sum(int(x.get('portfolio_bets', 0) or 0) for x in ms)
        wins = sum(int(x.get('wins', 0) or 0) for x in ms)
        losses = sum(int(x.get('losses', 0) or 0) for x in ms)
        pushes = sum(int(x.get('pushes', 0) or 0) for x in ms)
        staked = sum(float(x.get('staked_units', 0) or 0) for x in ms)
        profit = sum(float(x.get('profit_units', 0) or 0) for x in ms)
        ev = sum(float(x.get('avg_ev', 0) or 0) * int(x.get('portfolio_bets', 0) or 0) for x in ms) / bets if bets else 0
        hr = wins/(wins+losses) if wins+losses else 0
        roi = profit/staked if staked else 0
        lines.append(f'{MARKET_NAMES.get(market, market)}')
        lines.append(f'  {bets} bets | W/L/P {wins}/{losses}/{pushes} | HR {hr*100:.1f}% | ROI {_fmt_pct(roi)} | EV {_fmt_pct(ev)}')
    return '\n'.join(lines)[:3900]


def diagnostics_text():
    rows, _, _ = summary()
    if not rows: return '🔬 ДИАГНОСТИКА\n\nНет исторических данных.'
    totals=defaultdict(int)
    for r in rows:
        for k,v in (r.get('diagnostics') or {}).items():
            if isinstance(v,(int,float)): totals[k]+=int(v)
    keys=['warmup_skipped','odds_missing','one_x_two_complete','one_x_two_incomplete','one_x_two_missing_home','one_x_two_missing_draw','one_x_two_missing_away','thin_predictions','robust_ev_nonpositive','qcs_below_78','ev_below_5','eligible','portfolio_rejected']
    lines=['🔬 ДИАГНОСТИКА','']
    for k in keys:
        if k in totals: lines.append(f'{k}: {totals[k]}')
    lines += ['', 'Цель диагностики — видеть, где сигнал теряется: данные → рынок → модель → EV/Robust EV → QCS → портфель.']
    return '\n'.join(lines)[:3900]


def reliability_text():
    rows, _, _ = summary()
    if not rows:
        return '🧱 НАДЁЖНОСТЬ ЛИГ\n\nНет исторических данных.'
    buckets=defaultdict(list)
    for r in rows:
        buckets[int(r.get('league',0))].append(r)
    lines=['🧱 НАДЁЖНОСТЬ ЛИГ','']
    for lid,rs in sorted(buckets.items(), key=lambda x: LEAGUES.get(x[0],f'Лига {x[0]}')):
        n=0; bs=[]; ces=[]
        for r in rs:
            for m in (r.get('metrics') or {}).values():
                mn=int(m.get('calibration_n',0) or 0); n += mn
                if m.get('brier') is not None: bs.extend([float(m['brier'])]*mn)
                if m.get('calibration_error') is not None: ces.extend([float(m['calibration_error'])]*mn)
        if n:
            b=sum(bs)/len(bs) if bs else .25; ce=sum(ces)/len(ces) if ces else .15
            score=max(0,min(100,100*(1-1.5*b-ce)))
            lines.append(f'{LEAGUES.get(lid,f"Лига {lid}")} | N={n} | Brier {b:.4f} | CalErr {ce:.4f} | Reliability {score:.0f}/100')
    lines += ['', 'Reliability — статистическая устойчивость данных/вероятностей, не рейтинг прибыльности.']
    return '\n'.join(lines)[:3900]


def accuracy_text():
    rows, _, _ = summary()
    if not rows: return '🧠 ТОЧНОСТЬ МОДЕЛИ\n\nНет исторических данных.'
    lines=['🧠 ТОЧНОСТЬ МОДЕЛИ','']
    agg=defaultdict(list)
    for r in rows:
        for market,metric in (r.get('metrics') or {}).items():
            if metric.get('brier') is not None: agg[market].append(metric)
    for market in ['1X2','GOALS','CARDS','CORNERS']:
        ms=agg.get(market,[])
        if not ms: continue
        n=sum(int(x.get('calibration_n',0) or 0) for x in ms)
        b=sum(float(x.get('brier',0) or 0)*int(x.get('calibration_n',0) or 0) for x in ms)/n if n else 0
        ll=sum(float(x.get('log_loss',0) or 0)*int(x.get('calibration_n',0) or 0) for x in ms)/n if n else 0
        ce=sum(float(x.get('calibration_error',0) or 0)*int(x.get('calibration_n',0) or 0) for x in ms)/n if n else 0
        pred_ev=sum(float(x.get('avg_prediction_ev',0) or 0)*int(x.get('predictions',0) or 0) for x in ms)/sum(int(x.get('predictions',0) or 0) for x in ms) if sum(int(x.get('predictions',0) or 0) for x in ms) else 0
        bet_ev=sum(float(x.get('avg_ev',0) or 0)*int(x.get('portfolio_bets',0) or 0) for x in ms)/sum(int(x.get('portfolio_bets',0) or 0) for x in ms) if sum(int(x.get('portfolio_bets',0) or 0) for x in ms) else 0
        lines.append(f'{MARKET_NAMES.get(market,market)} | N={n} | Brier={b:.4f} | LogLoss={ll:.4f} | CalErr={ce:.4f}')
        lines.append(f'  Prediction EV={pred_ev:+.2%} | Portfolio EV={bet_ev:+.2%}')
    lines += ['', 'Brier/LogLoss/CalErr — точность вероятностей; Prediction EV — все проверенные прогнозы; Portfolio EV — только отобранные ставки.', 'Калибровка: обучение использует только наблюдения до даты текущего матча; текущий матч исключён.']
    return '\n'.join(lines)[:3900]



def _safe_float(v, default=0.0):
    try:
        return float(v)
    except Exception:
        return default


def _market_rows(rows):
    buckets = defaultdict(list)
    for r in rows:
        for market, metric in (r.get('metrics') or {}).items():
            x = dict(metric)
            x['_league'] = int(r.get('league', 0) or 0)
            x['_year'] = int(r.get('year', 0) or 0)
            x['_integrity'] = r.get('integrity_status', 'unknown')
            x['_detail_coverage'] = _safe_float(r.get('detail_coverage', 0))
            x['_one_x_two_complete'] = int((r.get('one_x_two_coverage') or {}).get('complete_matches', 0) or 0)
            x['_one_x_two_incomplete'] = int((r.get('one_x_two_coverage') or {}).get('incomplete_matches', 0) or 0)
            buckets[market].append(x)
    return buckets


def _weighted(rows, value_key, weight_key):
    den = sum(int(x.get(weight_key, 0) or 0) for x in rows)
    if not den:
        return 0.0
    return sum(_safe_float(x.get(value_key)) * int(x.get(weight_key, 0) or 0) for x in rows) / den


def _market_audit_status(bets, seasons, roi, robust_ev, brier, calerr, coverage, calibration_n, max_dd=0.0, rejection=0.0):
    # Explicit evidence gates. ROI is necessary but never sufficient. High
    # rejection, poor calibration, weak data coverage or excessive drawdown
    # prevent a market from being treated as a stable core candidate.
    if (bets >= 120 and seasons >= 2 and calibration_n >= 60 and roi > 0 and robust_ev > 0
            and coverage >= .98 and brier <= .23 and calerr <= .10 and rejection <= .80
            and max_dd <= max(1.0, bets * .03)):
        return '🟢 CORE'
    if (bets >= 60 and seasons >= 2 and roi > 0 and robust_ev > 0 and coverage >= .95
            and rejection <= .90):
        return '🟡 SECONDARY'
    if bets >= 30 and (roi > 0 or robust_ev > 0) and seasons >= 1:
        return '🟠 WATCHLIST'
    if bets >= 60 and roi <= 0 and robust_ev <= 0 and seasons >= 2:
        return '🔴 EXCLUDE'
    return '⚪ INSUFFICIENT DATA'


def market_audit_text():
    rows, _, _ = summary()
    if not rows:
        return '🎯 MARKET AUDIT\n\nНет завершённых исторических отчётов.'

    buckets = _market_rows(rows)
    lines = [
        '🎯 MARKET AUDIT',
        '',
        'Как читать: статус учитывает выборку, сезоны, ROI, Robust EV, калибровку и целостность данных.',
        'CORE/SECONDARY не означают гарантии прибыли; WATCHLIST = данных мало для решения.',
        ''
    ]

    market_stats = {}
    for market in ['1X2', 'GOALS', 'CARDS', 'CORNERS']:
        ms = buckets.get(market, [])
        if not ms:
            continue
        bets = sum(int(x.get('portfolio_bets', 0) or 0) for x in ms)
        preds = sum(int(x.get('predictions', 0) or 0) for x in ms)
        staked = sum(_safe_float(x.get('staked_units')) for x in ms)
        profit = sum(_safe_float(x.get('profit_units')) for x in ms)
        roi = profit / staked if staked else 0.0
        robust_ev = _weighted(ms, 'avg_robust_ev', 'portfolio_bets')
        brier = _weighted(ms, 'brier', 'calibration_n') if any(x.get('brier') is not None for x in ms) else 0.0
        calerr = _weighted(ms, 'calibration_error', 'calibration_n') if any(x.get('calibration_error') is not None for x in ms) else 0.0
        seasons = len({x['_year'] for x in ms if x['_year']})
        positive_seasons = sum(
            1 for y in {x['_year'] for x in ms if x['_year']}
            if (lambda ys: (sum(_safe_float(z.get('profit_units')) for z in ys) / sum(_safe_float(z.get('staked_units')) for z in ys) if sum(_safe_float(z.get('staked_units')) for z in ys) else 0) > 0)([z for z in ms if z['_year'] == y])
        )
        coverage = min((_safe_float(x.get('_detail_coverage'), 0) for x in ms), default=0.0)
        pred_robust = _weighted(ms, 'avg_prediction_robust_ev', 'predictions')
        rejection = max(0, preds - bets) / preds if preds else 0.0
        calibration_n = sum(int(x.get('calibration_n', 0) or 0) for x in ms)
        avg_qcs = _weighted(ms, 'avg_qcs', 'predictions')
        avg_dcs = _weighted(ms, 'avg_dcs', 'predictions')
        avg_ms = _weighted(ms, 'avg_market_score', 'predictions')
        avg_books = _weighted(ms, 'avg_bookmakers', 'predictions')
        anomaly = _weighted(ms, 'price_anomaly_rate', 'predictions')
        conflict = _weighted(ms, 'market_conflict_rate', 'predictions')
        sharp_rate = _weighted(ms, 'sharp_data_rate', 'predictions')
        max_dd = max((_safe_float(x.get('max_drawdown_units')) for x in ms), default=0.0)
        avg_odds = _weighted(ms, 'avg_odds', 'portfolio_bets')
        profit_factor = _weighted(ms, 'profit_factor', 'portfolio_bets')
        one_x2_complete = sum(int(x.get('_one_x_two_complete', 0) or 0) for x in ms)
        one_x2_incomplete = sum(int(x.get('_one_x_two_incomplete', 0) or 0) for x in ms)
        one_x2_total = one_x2_complete + one_x2_incomplete
        one_x2_coverage = one_x2_complete / one_x2_total if one_x2_total else None
        last = [x for x in ms if x['_year'] == max((z['_year'] for z in ms if z['_year']), default=0)]
        last_staked = sum(_safe_float(x.get('staked_units')) for x in last)
        last_profit = sum(_safe_float(x.get('profit_units')) for x in last)
        last_roi = last_profit / last_staked if last_staked else 0.0
        last_bets = sum(int(x.get('portfolio_bets', 0) or 0) for x in last)
        status = _market_audit_status(bets, positive_seasons, roi, robust_ev, brier, calerr, coverage, calibration_n, max_dd=max_dd, rejection=rejection)
        market_stats[market] = dict(bets=bets, preds=preds, roi=roi, robust_ev=robust_ev, brier=brier, calerr=calerr,
                                    seasons=seasons, positive_seasons=positive_seasons, coverage=coverage,
                                    pred_robust=pred_robust, rejection=rejection, status=status)
        lines.append(f'{MARKET_NAMES.get(market, market)} — {status}')
        lines.append(f'  N={bets} bets / {preds} pred | ROI={_fmt_pct(roi)} | RobustEV={_fmt_pct(robust_ev)}')
        lines.append(f'  Сезоны: {positive_seasons}/{seasons} положит. | Последний сезон: {last_bets} bets / ROI {_fmt_pct(last_roi)}')
        lines.append(f'  Cal N={calibration_n} | Brier={brier:.4f} | CalErr={calerr:.4f} | QCS={avg_qcs:.1f} | DCS={avg_dcs:.1f}')
        lines.append(f'  MarketScore={avg_ms:.1f} | Books={avg_books:.1f} | Data={coverage:.1%} | Reject={rejection:.1%}')
        lines.append(f'  DD={max_dd:.2f}u | PF={profit_factor:.2f} | AvgOdds={avg_odds:.2f}')
        lines.append(f'  Price anomaly={anomaly:.1%} | Conflict={conflict:.1%} | Sharp data={sharp_rate:.1%}')
        if market == '1X2':
            lines.append(f'  1X2 odds coverage={one_x2_coverage:.1%}' if one_x2_coverage is not None else '  1X2 odds coverage=нет данных')
            sm=ms
            for sel,label in (('1','П1'),('X','Н'),('2','П2')):
                sb=[z.get('selection_metrics',{}).get(sel,{}) for z in sm if z.get('selection_metrics',{}).get(sel)]
                bn=sum(int(z.get('bets',0) or 0) for z in sb); st=sum(_safe_float(z.get('staked_units')) for z in sb); pr=sum(_safe_float(z.get('profit_units')) for z in sb)
                lines.append(f'  {label}: {bn} bets | ROI {_fmt_pct(pr/st if st else 0)}')
        lines.append('')

    # League × market candidates. Require at least two seasons where possible;
    # this prevents a single strong season from defining specialization.
    candidates = []
    for market, ms in buckets.items():
        by_league = defaultdict(list)
        for x in ms:
            by_league[x['_league']].append(x)
        for lid, ls in by_league.items():
            bets = sum(int(x.get('portfolio_bets', 0) or 0) for x in ls)
            if bets < 40:
                continue
            staked = sum(_safe_float(x.get('staked_units')) for x in ls)
            profit = sum(_safe_float(x.get('profit_units')) for x in ls)
            roi = profit / staked if staked else 0.0
            rev = _weighted(ls, 'avg_robust_ev', 'portfolio_bets')
            years = len({x['_year'] for x in ls if x['_year']})
            pos_years = 0
            for y in {x['_year'] for x in ls if x['_year']}:
                ys=[z for z in ls if z['_year']==y]
                st=sum(_safe_float(z.get('staked_units')) for z in ys)
                pr=sum(_safe_float(z.get('profit_units')) for z in ys)
                if st and pr/st > 0: pos_years += 1
            if roi > 0 and rev > 0 and pos_years >= min(2, years):
                candidates.append((roi, bets, market, lid, years, pos_years, rev))

    if candidates:
        candidates.sort(key=lambda x: (x[5], x[6], x[0], x[1]), reverse=True)
        lines += ['🔎 КАНДИДАТЫ ДЛЯ СПЕЦИАЛИЗАЦИИ', '']
        for roi, bets, market, lid, years, pos_years, rev in candidates[:8]:
            lines.append(f'{MARKET_NAMES.get(market, market)} × {LEAGUES.get(lid, f"Лига {lid}")}')
            lines.append(f'  {bets} bets | {pos_years}/{years} сез. + | ROI {_fmt_pct(roi)} | RobustEV {_fmt_pct(rev)}')
        lines.append('')
        lines.append('Это кандидаты для дальнейшего исследования, а не автоматический приказ ставить только на них.')
    else:
        lines += ['🔎 КАНДИДАТЫ ДЛЯ СПЕЦИАЛИЗАЦИИ', '', 'Пока нет сегмента «рынок × лига» с достаточной выборкой и устойчивым результатом во времени.']

    lines += [
        '',
        '📌 Следующий фильтр: проверять CORE/SECONDARY на новых данных, не перенастраивая пороги под уже полученный результат.',
    ]
    return '\n'.join(lines)[:3900]

def recent_text(limit=8):
    rows, _, _ = summary()
    rows = sorted(rows, key=lambda r: (int(r.get('year', 0)), int(r.get('league', 0))), reverse=True)[:limit]
    if not rows:
        return '🗂 ПОСЛЕДНИЕ ОТЧЁТЫ\n\nНет исторических данных.'
    lines = ['🗂 ПОСЛЕДНИЕ ОТЧЁТЫ', '']
    for r in rows:
        a = _agg([r])
        lid = int(r.get('league', 0))
        season = f'{int(r.get("year", 0))}/{str(int(r.get("year", 0))+1)[-2:]}'
        lines.append(f'{LEAGUES.get(lid, f"Лига {lid}")} {season}')
        d=r.get('diagnostics') or {}
        lines.append(f'  {a["bets"]} bets | W/L/P {a["wins"]}/{a["losses"]}/{a["pushes"]} | ROI {_fmt_pct(a["roi"])} | EV {_fmt_pct(a["avg_ev"])}')
        lines.append(f'  Matches {r.get("matches",0)} | Full {r.get("usable_full_matches",0)} | Pred {r.get("predictions",0)} | Eligible {d.get("eligible",0)}')
        lines.append(f'  Reject: thin {d.get("thin_predictions",0)} | Robust≤0 {d.get("robust_ev_nonpositive",0)} | QCS<78 {d.get("qcs_below_78",0)} | Portfolio {d.get("portfolio_rejected",0)}')
    return '\n'.join(lines)[:3900]
