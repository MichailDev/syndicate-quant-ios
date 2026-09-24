from __future__ import annotations
import re, statistics, math


def _data(payload):
    if isinstance(payload, dict) and 'data' in payload:
        return payload.get('data')
    return payload


def _first(d, *keys):
    for k in keys:
        if isinstance(d, dict) and d.get(k) is not None:
            return d.get(k)
    return None


def _iter_market_nodes(obj, bookmaker=None):
    """Yield (bookmaker, market_dict, price_dict) from several SStats response shapes.

    SStats documents /Odds/{gameId} as the canonical odds endpoint and /Ls/GameInfo
    as a fallback containing bookmaker odds. Different API generations/aggregators
    can wrap the same market data under data/bookmakers/markets/outcomes, so this
    parser deliberately accepts all of those common shapes without inventing data.
    """
    if isinstance(obj, list):
        for item in obj:
            yield from _iter_market_nodes(item, bookmaker)
        return
    if not isinstance(obj, dict):
        return

    bm = bookmaker
    if _first(obj, 'bookmakerName', 'bookmaker', 'bookmaker_name') is not None:
        bm = _first(obj, 'bookmakerName', 'bookmaker', 'bookmaker_name')
    bid = _first(obj, 'bookmakerId', 'bookmakerID', 'bookmaker_id')
    bookmaker_obj = {'name': bm, 'id': bid}

    market_name = _first(obj, 'marketName', 'market', 'market_name', 'marketTypeName')
    prices = _first(obj, 'odds', 'prices', 'outcomes', 'selections', 'values')
    if market_name is not None and isinstance(prices, list):
        for price in prices:
            if isinstance(price, dict):
                yield bookmaker_obj, obj, price

    # Some responses use bookmaker -> markets, others use data -> bookmakers.
    for key, value in obj.items():
        if key in {'odds', 'prices', 'outcomes', 'selections', 'values'} and market_name is not None:
            continue
        yield from _iter_market_nodes(value, bm)


def flatten_odds(payload):
    data = _data(payload)
    rows = []
    seen = set()
    for bm, market, price in _iter_market_nodes(data):
        mn = str(_first(market, 'marketName', 'market', 'market_name', 'marketTypeName') or '')
        name = str(_first(price, 'name', 'outcomeName', 'selection', 'label', 'outcome') or '')
        value_raw = _first(price, 'value', 'odds', 'odd', 'price', 'coefficient')
        try:
            value = float(value_raw)
        except (TypeError, ValueError):
            continue
        if value <= 1 or not mn or not name:
            continue
        bid = bm.get('id') if isinstance(bm, dict) else None
        bname = bm.get('name') if isinstance(bm, dict) else bm
        opening = _first(price, 'openingValue', 'openingOdds', 'opening', 'openValue')
        key = (str(bid), str(bname), mn, name, value, str(opening))
        if key in seen:
            continue
        seen.add(key)
        rows.append({'bookmaker': bname, 'bookmaker_id': bid, 'market': mn,
                     'name': name, 'odds': value, 'opening': opening})
    return rows


def is_team_total_market(market_name):
    s=str(market_name or '').lower()
    team_markers=('team total','team corners','team cards','team yellow','home total','away total','home corners','away corners','home cards','away cards')
    return any(x in s for x in team_markers)

def classify_market(name):
    s = str(name or '').lower().strip()
    # SStats/Flashscore market labels vary between "Goals Over/Under",
    # "Total Goals", "Goals", "Over/Under", etc.
    if any(x in s for x in ('1x2', 'winner', 'match winner', 'match result', 'full time result', 'full-time result', 'ft result', '3 way', 'three way', '1 x 2')):
        # Exclude double-chance / draw-no-bet style markets that may contain
        # the word 'result' but are not the three-way 1X2 market.
        if any(x in s for x in ('double chance', 'draw no bet', 'dnb', 'to qualify')):
            return None
        return '1X2'
    if any(x in s for x in ('corner', 'corners')):
        return 'CORNERS'
    if any(x in s for x in ('yellow', 'card', 'booking', 'bookings')):
        return 'CARDS'
    # Generic "total" is not enough to call a market Goals: SStats can expose
    # Total Fouls, Total Shots, Total Offsides, etc. Only goal-specific labels
    # are admitted here.
    if any(x in s for x in ('goal', 'goals', 'match total goals', 'total goals', 'goals over', 'goals under')):
        return 'GOALS'
    if any(x in s for x in ('foul', 'fouls', 'shot', 'shots', 'offside', 'offsides', 'possession', 'set piece')):
        return None
    return None


def extract_line(market, price_name):
    text = f'{market} {price_name}'
    vals = re.findall(r'(?<!\d)(\d+(?:[\.,]\d+)?)(?!\d)', text)
    if not vals:
        return None
    try:
        return float(vals[-1].replace(',', '.'))
    except ValueError:
        return None


def normalize_selection(name):
    n = str(name or '').strip()
    low = n.lower()
    aliases = {
        '1': '1', 'home': '1', 'home win': '1', 'home team': '1',
        'x': 'X', 'draw': 'X',
        '2': '2', 'away': '2', 'away win': '2', 'away team': '2',
        'over': 'Over', 'under': 'Under',
    }
    if low in aliases:
        return aliases[low]
    if any(x in low for x in ('home win','home team','home winner','home')) and 'away' not in low:
        return '1'
    if any(x in low for x in ('away win','away team','away winner','away')) and 'home' not in low:
        return '2'
    if any(x in low for x in ('draw','tie','x')) and len(low) <= 12:
        return 'X'
    if low.startswith('over '): return 'Over'
    if low.startswith('under '): return 'Under'
    return n



def market_key(market, name):
    sel=normalize_selection(name)
    if market=='1X2': return sel
    line=extract_line(market,name)
    return f'{sel}{line:g}' if line is not None else None


def key_bookmakers(rows, market, key):
    books=set()
    for r in rows:
        if classify_market(r.get('market')) != market or is_team_total_market(r.get('market')): continue
        if market_key(market,r.get('name','')) != key: continue
        bid=r.get('bookmaker_id')
        name=r.get('bookmaker')
        if bid is not None: books.add('id:'+str(bid))
        elif name: books.add('name:'+str(name).strip().lower())
    return books

def build_market_map(rows, market):
    result = {}
    for r in rows:
        if classify_market(r['market']) != market or is_team_total_market(r.get('market')):
            continue
        sel = normalize_selection(r['name'])
        if market == '1X2':
            key = sel
        else:
            line = extract_line(r['market'], r['name'])
            if line is None:
                continue
            key = f'{sel}{line:g}'
        # Consensus price is the median across books. Using the maximum here
        # can turn a stale/outlier quote into artificial double-digit EV.
        result.setdefault(key, []).append(r['odds'])
    return {k: statistics.median(v) for k, v in result.items() if v}


def market_quality(rows, market):
    usable = [r for r in rows if classify_market(r['market']) == market and not is_team_total_market(r.get('market')) and r['odds'] > 1]
    books = len({r['bookmaker_id'] for r in usable if r.get('bookmaker_id') is not None})
    if not books:
        books = len({str(r.get('bookmaker')) for r in usable if r.get('bookmaker')})
    groups = {}
    for r in usable:
        line = None if market == '1X2' else extract_line(r['market'], r['name'])
        key = (line, normalize_selection(r['name']))
        groups.setdefault(key, []).append(r['odds'])
    dispersions = []
    for vals in groups.values():
        if len(vals) >= 2:
            med = statistics.median(vals)
            if med is None or not math.isfinite(float(med)) or float(med) <= 0: continue
            mad = statistics.median(abs(x - med) for x in vals)
            if mad is None or not math.isfinite(float(mad)): continue
            dispersions.append(float(mad) / max(float(med), 1e-9))
    disp = float(sum(dispersions) / len(dispersions)) if dispersions else .25
    score = min(100, 20 + min(35, books * 3) + min(25, len(groups) * 2) + max(0, 20 - 45 * disp))
    return {'score': round(score, 1), 'bookmakers': books, 'dispersion': disp}


def consensus_odds(rows, market, key):
    vals = []
    for r in rows:
        if classify_market(r['market']) != market or is_team_total_market(r.get('market')):
            continue
        sel = normalize_selection(r['name'])
        line = None if market == '1X2' else extract_line(r['market'], r['name'])
        k = sel if market == '1X2' else (f'{sel}{line:g}' if line is not None else None)
        if k == key:
            vals.append(r['odds'])
    if not vals:
        return None
    return statistics.median(vals)


def merge_odds_rows(primary, fallback):
    out=list(primary or []); seen=set()
    for r in out:
        seen.add((str(r.get('bookmaker_id')),str(r.get('bookmaker')),str(r.get('market')),str(r.get('name')),str(r.get('odds'))))
    for r in (fallback or []):
        k=(str(r.get('bookmaker_id')),str(r.get('bookmaker')),str(r.get('market')),str(r.get('name')),str(r.get('odds')))
        if k not in seen: out.append(r); seen.add(k)
    return out

def one_x_two_complete(rows):
    sels={normalize_selection(r.get('name')) for r in (rows or []) if classify_market(r.get('market'))=='1X2' and float(r.get('odds') or 0)>1}
    return {'complete':{'1','X','2'} <= sels,'has_home':'1' in sels,'has_draw':'X' in sels,'has_away':'2' in sels}

def enrich_rows(rows, market):
    for r in rows:
        r['market_type'] = classify_market(r.get('market', ''))
        r['is_team_total'] = is_team_total_market(r.get('market', ''))
        if r['market_type'] != market or r.get('is_team_total'):
            r['key'] = None
            continue
        sel = normalize_selection(r.get('name', ''))
        if market == '1X2':
            r['key'] = sel
        else:
            line = extract_line(r.get('market', ''), r.get('name', ''))
            r['key'] = f'{sel}{line:g}' if line is not None else None
    return rows
