from __future__ import annotations

def ev(p,odds): return float(p*odds-1.0)
def robust_ev(p_low,odds): return float(p_low*odds-1.0)
def kelly(p,odds,cap=.02,haircut=.75):
    b=float(odds)-1.0; p=float(p); q=1-p
    if b<=0:return 0.0
    f=max(0.0,(b*p-q)/b)*.25*haircut
    return min(cap,f)

def classification(ev_mid,ev_robust,qcs,dcs,ms):
    if ev_robust>0 and ev_mid>=.07 and qcs>=85 and ms>=50 and dcs>=60:return 'S BET'
    if ev_robust>0 and ev_mid>=.05 and qcs>=78 and ms>=50 and dcs>=60:return 'A BET'
    if ev_mid>=.03:return 'B LEAN'
    if ev_mid>0:return 'C WATCH'
    return 'X NO BET'
