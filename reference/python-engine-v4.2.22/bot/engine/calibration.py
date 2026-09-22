from __future__ import annotations
import json, math, statistics
from .pricing import classification, kelly
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[2]
DATA_DIR = BASE_DIR / 'data'
from collections import defaultdict

MARKETS = ('1X2','GOALS','CARDS','CORNERS')
BINS = tuple(round(x/100,2) for x in range(50,100,5))


def _clip(p):
    try:
        x = 0.5 if p is None else float(p)
    except (TypeError, ValueError):
        x = 0.5
    if not math.isfinite(x): x = 0.5
    return max(1e-5, min(1-1e-5, x))


def _logit(p):
    p=_clip(0.5 if p is None else p); return math.log(p/(1-p))

def _sigmoid(x):
    if x >= 35: return 1.0
    if x <= -35: return 0.0
    return 1/(1+math.exp(-float(x)))


def load_samples(root=None):
    out=[]
    path=Path(root) if root is not None else DATA_DIR
    if not path.exists(): return out
    for fp in sorted(path.glob('walkforward_*.json')):
        if fp.name=='walkforward_report.json': continue
        try:
            x=json.loads(fp.read_text(encoding='utf-8'))
            if x.get('status')!='ok': continue
            for s in x.get('calibration_samples',[]) or []:
                if isinstance(s,dict) and s.get('market') in MARKETS and s.get('date') is not None:
                    s=dict(s); s['source']='historical'; s['source_report']=fp.name; out.append(s)
        except Exception:
            continue
    # Live settled predictions are incremental feedback. They are appended by
    # Store.settle_game(), so daily settlement improves calibration without
    # forcing a 9,000-match historical rebuild.
    live=path/'live_calibration_samples.jsonl'
    if live.exists():
        try:
            for line in live.read_text(encoding='utf-8').splitlines():
                if not line.strip(): continue
                s=json.loads(line)
                if isinstance(s,dict) and s.get('market') in MARKETS and s.get('date') is not None:
                    s=dict(s); s['source']='live'; out.append(s)
        except Exception:
            pass
    # Deduplicate exact settlement records while preserving the latest source.
    uniq={}
    for s in out:
        key=(str(s.get('game_id',s.get('gid',''))),str(s.get('market')),str(s.get('selection')),str(s.get('date')))
        uniq[key]=s
    return sorted(uniq.values(), key=lambda x: str(x.get('date','')))


def _before(samples, cutoff=None, market=None, league=None):
    rows=[]
    for s in samples:
        if market and s.get('market')!=market: continue
        if league is not None and str(s.get('league_id'))!=str(league): continue
        if cutoff is not None and str(s.get('date','')) >= str(cutoff): continue
        try:
            p=_clip(s['p']); y=float(s['y'])
            if y not in (0.0,1.0): continue
            rows.append((p,y,s))
        except Exception: continue
    return rows


def calibrate_probability(p, samples, market, league=None, cutoff=None, min_n=25, window=None):
    """Leakage-safe empirical calibration with hierarchical shrinkage.
    League+market -> market -> global. The current event is excluded by cutoff.
    """
    p0=_clip(p)
    exact=_before(samples,cutoff,market,league)
    market_rows=_before(samples,cutoff,market,None)
    global_rows=_before(samples,cutoff,None,None)
    if window:
        def trim(rows): return rows[-int(window):]
        exact, market_rows, global_rows = trim(exact), trim(market_rows), trim(global_rows)
    def estimate(rows):
        if not rows: return None
        # Nearest probability neighbourhood, widened until enough evidence exists.
        width=.05
        for _ in range(4):
            local=[y for q,y,_ in rows if abs(q-p0)<=width]
            if len(local)>=min_n: break
            width*=1.5
        if len(local)<8: return None
        # p0 is guaranteed numeric by _clip; keep this division explicitly numeric.
        den = float(len(local) + 2)
        return (float(sum(local)) + 2.0*float(p0))/den, len(local)
    est=estimate(exact)
    source='LEAGUE'
    if est is None:
        est=estimate(market_rows); source='MARKET'
    if est is None:
        est=estimate(global_rows); source='GLOBAL'
    if est is None: return p0, {'source':'NONE','n':0,'raw':p0}
    e,n=est
    n=float(n or 0)
    w=min(.55,n/(n+80.0)) if n>0 else 0.0
    pc=(1-w)*p0+w*e
    return _clip(pc), {'source':source,'n':n,'raw':p0,'empirical':e,'weight':w}


def _brier(rows):
    return sum((p-y)**2 for p,y,_ in rows)/len(rows) if rows else None

def _logloss(rows):
    if not rows:return None
    return -sum(y*math.log(_clip(p))+(1-y)*math.log(_clip(1-p)) for p,y,_ in rows)/len(rows)


def optimize_component_weights(samples, market, league=None, cutoff=None, window=None):
    """Walk-forward deterministic log-loss optimization over available model components.
    Coarse grid + coordinate refinement; no future observations are used.
    """
    rows=_before(samples,cutoff,market,league)
    if window: rows=rows[-int(window):]
    usable=[]
    names=('base_model','glicko','player_assembly','referee','market_consensus')
    for p,y,src in rows:
        comps=src.get('components') or {}
        vals={k:_clip(comps[k]) for k in names if comps.get(k) is not None}
        if len(vals)>=1: usable.append((vals,y))
    if len(usable)<40:return {k:(1.0 if k=='base_model' else 0.0) for k in names}|{'n':len(usable)}
    active=[k for k in names if sum(1 for v,_ in usable if k in v)>=max(20,int(.5*len(usable)))]
    if not active: active=['base_model']
    w={k:(1/len(active) if k in active else 0.0) for k in names}
    def loss(weights):
        zsum=0.0
        for vals,y in usable:
            den=sum(weights[k] for k in active if k in vals)
            if den<=0: z=_clip(vals.get('base_model', next(iter(vals.values()))))
            else:
                z=_sigmoid(sum(weights[k]*_logit(vals[k]) for k in active if k in vals)/den)
            zsum += -(y*math.log(_clip(z))+(1-y)*math.log(_clip(1-z)))
        return zsum/len(usable)
    best=loss(w)
    # Coordinate ascent on a 0.1 grid while keeping total mass 1.
    for _ in range(4):
        improved=False
        for k in active:
            candidates=[]
            for v in [i/10 for i in range(0,11)]:
                rest=1-v
                others=[x for x in active if x!=k]
                nw=dict(w);nw[k]=v
                if others:
                    old=sum(w[x] for x in others) or 1
                    for x in others:nw[x]=rest*w[x]/old
                elif k in nw:nw[k]=1.0
                l=loss(nw)
                candidates.append((l,nw))
            l,nw=min(candidates,key=lambda x:x[0])
            if l+1e-9<best:best=l;w=nw;improved=True
        if not improved:break
    # Shrink toward base model for robustness.
    for k in active:w[k]=.80*w[k]+(.20 if k=='base_model' else 0.0)
    total=sum(w.values()) or 1
    for k in names:w[k]=w.get(k,0)/total
    w['n']=len(usable);w['log_loss']=best
    return w


def metrics_for_samples(samples):
    """Return compact calibration metrics for settled calibration samples."""
    rows=[]
    for s in samples or []:
        try:
            p=_clip(s.get('p_calibrated', s.get('p', s.get('p_raw'))))
            y=float(s.get('y'))
            if y in (0.0,1.0): rows.append((p,y,s))
        except Exception:
            continue
    if not rows:
        return {'n':0,'brier':None,'log_loss':None,'calibration_error':None}
    bins=[]
    for lo in [i/10 for i in range(0,10)]:
        hi=lo+0.1
        r=[(p,y,_) for p,y,_ in rows if (lo <= p < hi) or (hi >= 1 and lo <= p <= hi)]
        if r:
            bins.append(abs(sum(p for p,_,_ in r)/len(r)-sum(y for _,y,_ in r)/len(r)))
    return {'n':len(rows),'brier':_brier(rows),'log_loss':_logloss(rows),'calibration_error':sum(bins)/len(bins) if bins else None}


def optimize_market_blend(samples, market, league=None, cutoff=None, window=None):
    w=optimize_component_weights(samples,market,league,cutoff,window=window)
    return {'model_weight':w.get('base_model',1.0)+w.get('glicko',0)+w.get('player_assembly',0)+w.get('referee',0),'market_weight':w.get('market_consensus',0),'n':w.get('n',0),'log_loss':w.get('log_loss')}


def apply_calibration(row, samples, cutoff=None, min_samples=25, window=None):
    market=row.get('market'); league=row.get('league_id')
    p=float(row.get('p',0) or 0)
    comps=row.get('component_attribution') or {}
    if row.get('market_prob') is not None: comps['market_consensus']=row.get('market_prob')
    # Fill missing component probabilities with raw model only; missing evidence never creates a component.
    comps={k:_clip(v) for k,v in comps.items() if v is not None}
    row['component_attribution']=comps
    w=optimize_component_weights(samples,market,league,cutoff,window=window)
    vals=dict(comps); vals.setdefault('base_model',p)
    active=[k for k in ('base_model','glicko','player_assembly','referee','market_consensus') if k in vals]
    den=sum(w.get(k,0) for k in active)
    if den>0:
        z=_sigmoid(sum(w.get(k,0)*_logit(vals[k]) for k in active)/den)
    else:z=p
    z,meta=calibrate_probability(z,samples,market,league,cutoff,min_n=min_samples,window=window)
    row['p_raw']=p; row['p']=z; row['fair']=1/z if z>0 else row.get('fair')
    n=float(row.get('n',1) or 1); dcs=float(row.get('dcs',60) or 60); disp=float(row.get('ms_dispersion',0) or 0)
    if not math.isfinite(n) or n<=0: n=1.0
    if not math.isfinite(dcs): dcs=60.0
    if not math.isfinite(disp): disp=0.0
    haircut=.02+.09/math.sqrt(max(n,1))+.08*(100-dcs)/100+.05*min(1,disp)
    pl=_clip(z*(1-haircut)); row['p_low']=pl
    odds=float(row.get('odds',0) or 0)
    if odds>1:
        row['ev']=z*odds-1; row['robust_ev']=pl*odds-1
    # Calibration is part of the prediction layer, so all execution fields are
    # recomputed from the calibrated probability (not stale pre-calibration values).
    row['stake']=kelly(pl,odds,cap=.02) if odds>1 else 0.0
    row['classification']=classification(float(row.get('ev',0) or 0),float(row.get('robust_ev',0) or 0),float(row.get('qcs',0) or 0),float(row.get('dcs',0) or 0),float(row.get('ms',0) or 0))
    veto=bool(row.get('price_anomaly') or row.get('thin_market') or row.get('extreme_price') or row.get('market_conflict'))
    if veto:
        row['classification']='X'; row['stake']=0.0
    row['prediction_layer']={
        'probability':row['p'],'robust_probability':row['p_low'],'fair':row['fair'],
        'calibrated':True,'source':meta.get('source','NONE')
    }
    row['bet_layer']={
        'eligible':bool((not veto) and row['classification'] in ('S BET','A BET') and row.get('data_integrity',True) and float(row.get('robust_ev',0) or 0)>0),
        'classification':row['classification'],'stake':row['stake'],'veto':veto
    }
    row['calibration']={**meta,'weights':{k:w.get(k,0) for k in ('base_model','glicko','player_assembly','referee','market_consensus')},'n_train':w.get('n',0),'window':window}
    return row

