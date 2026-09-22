from __future__ import annotations
import statistics, math

def referee_profile(records, referee_name, field='cards'):
    if not referee_name:return {'n':0,'value':None,'fouls':None,'confidence':0}
    vals=[];fouls=[]
    target=str(referee_name).strip().lower()
    for r in records:
        if str(r.get('referee') or '').strip().lower()!=target: continue
        if r.get(field) is not None and r.get('opp_'+field) is not None: vals.append(float(r[field])+float(r['opp_'+field]))
        if r.get('fouls') is not None and r.get('opp_fouls') is not None:fouls.append(float(r['fouls'])+float(r['opp_fouls']))
    n=len(vals)
    n=float(n or 0)
    return {'n':int(n),'value':statistics.mean(vals) if vals else None,'fouls':statistics.mean(fouls) if fouls else None,'confidence':min(100.0,n/10.0*100.0)}

def adjust_count(base, profile, league_base=None):
    if not profile or profile.get('value') is None or profile['n']<6:return base
    rb=profile['value']; lb=league_base if league_base and league_base>0 else base
    n=float(profile.get('n') or 0)
    w=min(.55, n/(n+8.0)) if n>0 else 0.0
    return max(.1,base*(1-w)+rb*w) if lb==base else max(.1,base*(1-w)+rb*w)
