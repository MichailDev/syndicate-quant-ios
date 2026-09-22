from __future__ import annotations
import math, statistics

def _num(v):
    try: return float(v)
    except: return None

def _items(obj):
    if isinstance(obj,list): return obj
    if isinstance(obj,dict):
        for k in ('players','items','data','rows'):
            if isinstance(obj.get(k),list): return obj[k]
    return []

def _minutes(p):
    for k in ('minutes','minutesPlayed','minutes_played','mins','timePlayed'):
        v=_num(p.get(k))
        if v is not None:return max(0,v)
    return 90.0 if (p.get('startXI') or p.get('started') or p.get('isStarting')) else None

def _stat(p,*keys):
    for k in keys:
        v=_num(p.get(k))
        if v is not None:return v
    return 0.0

def player_row(p):
    mins=_minutes(p)
    if mins is None:return None
    return {'id':p.get('playerId') or p.get('id'),'name':p.get('playerName') or p.get('name'),
      'minutes':mins,'xg':_stat(p,'expectedGoals','xG','xg'),'xa':_stat(p,'expectedAssists','xA','xa'),
      'goals':_stat(p,'goals','goal'),'assists':_stat(p,'assists','assist'),
      'shots':_stat(p,'shots','totalShots'),'sot':_stat(p,'shotsOnGoal','sot'),
      'starts':1 if p.get('startXI') or p.get('startXI') else 0}

def extract_players(game, team_id):
    rows=[]
    for p in _items(game.get('playerStats') or game.get('players')):
        tid=p.get('teamId') or p.get('team_id')
        if tid is None or str(tid)==str(team_id):
            r=player_row(p)
            if r: rows.append(r)
    if rows:return rows
    # Fallback to lineupPlayers when detailed player stats are absent.
    for p in _items(game.get('lineupPlayers')):
        tid=p.get('teamId')
        if tid is None or str(tid)==str(team_id):
            r=player_row(p)
            if r: rows.append(r)
    return rows

def _player_contrib(history, team_id):
    agg={}
    for rec in history:
        for p in rec.get('players',[]):
            if not p.get('id'):continue
            a=agg.setdefault(str(p['id']),{'name':p.get('name'),'minutes':0,'xg':0,'xa':0,'goals':0,'assists':0,'shots':0,'sot':0,'starts':0,'games':0})
            for k in ('minutes','xg','xa','goals','assists','shots','sot','starts'): a[k]+=float(p.get(k) or 0)
            a['games']+=1
    return agg

def assemble(history, current_players=None):
    """Deterministic bottom-up assembly. Returns only evidence-supported adjustment."""
    agg=_player_contrib(history,None)
    n=max(1,len(history))
    candidates=[]
    for p in agg.values():
        if p['minutes'] < 180: continue
        per90=lambda x: 90.0*float(p.get(x) or 0.0)/max(float(p.get('minutes') or 0.0),1.0)
        score=0.55*per90('xg')+0.25*per90('xa')+0.12*per90('sot')+0.08*per90('goals')
        p2=dict(p);p2['impact']=score;p2['exp_min']=float(p.get('minutes') or 0.0)/max(float(p.get('games') or 0.0),1.0)
        candidates.append(p2)
    candidates.sort(key=lambda x:x['impact'],reverse=True)
    baseline=sum(max(0,p['impact'])*min(1,p['exp_min']/90) for p in candidates[:8])
    # If confirmed starters are available, estimate availability from their historical contribution.
    avail=1.0
    if current_players:
        ids={str(p.get('id')) for p in current_players if p.get('id') is not None}
        if ids:
            top=candidates[:8]
            total=sum(max(0,p['impact'])*min(1,p['exp_min']/90) for p in top) or 1e-9
            present=sum(max(0,p['impact'])*min(1,p['exp_min']/90) for p in top if str(p.get('id')) in ids)
            avail=max(0.75,min(1.10,0.92+0.18*present/total))
    # Small bounded adjustment: this is not allowed to manufacture signal.
    factor=max(0.94,min(1.06,0.97+0.01*math.tanh(baseline))) * avail
    return {'factor':factor,'baseline':baseline,'players_used':len(candidates),'top_players':candidates[:8], 'confirmed':bool(current_players)}
