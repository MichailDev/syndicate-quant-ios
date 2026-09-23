from __future__ import annotations

def corr(a,b):
    if a.get('game_id')==b.get('game_id'):
        if a.get('selection','').startswith('Over') and b.get('selection','').startswith('Under') and a.get('market')==b.get('market'): return .95
        if a.get('market')==b.get('market'): return .82
        if {a.get('market'),b.get('market')}=={'GOALS','CARDS'}: return .20
        if {a.get('market'),b.get('market')}=={'GOALS','CORNERS'}: return .25
        return .35
    if a.get('home') in (b.get('home'),b.get('away')) or a.get('away') in (b.get('home'),b.get('away')): return .20
    return .03

def select_portfolio(results,max_items=8,max_total_stake=.10):
    ranked=sorted([r for r in results if r.get('bet_layer',{}).get('eligible', r.get('classification') in ('S BET','A BET')) and r.get('robust_ev',0)>0 and r.get('qcs',0)>=78],key=lambda x:(x.get('robust_ev',0),x.get('qcs',0)),reverse=True)
    chosen=[]; total=0
    for r in ranked:
        st=min(.02,float(r.get('stake') or 0))
        if total+st>max_total_stake: continue
        if any(corr(r,x)>=.65 for x in chosen): continue
        r=dict(r);r['portfolio_corr']=max([corr(r,x) for x in chosen],default=0);chosen.append(r);total+=st
        if len(chosen)>=max_items:break
    return chosen
