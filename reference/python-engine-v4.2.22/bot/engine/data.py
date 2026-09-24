from __future__ import annotations
from dataclasses import dataclass

def num(v):
    if v is None:return None
    try:return float(v)
    except:return None

def full_game(payload):
    if isinstance(payload,dict) and 'data' in payload:return payload.get('data') or {}
    return payload or {}

def team_id(game,side): return ((game.get('game') or {}).get(side+'Team') or {}).get('id')

def extract_team_game(payload,target_team_id):
    g=full_game(payload); base=g.get('game') or {}; hid=team_id(g,'home'); aid=team_id(g,'away')
    if target_team_id not in (hid,aid):return None
    side='home' if target_team_id==hid else 'away'; pref='Home' if side=='home' else 'Away'; op='Away' if side=='home' else 'Home'; s=g.get('statistics') or {}
    def S(k):return num(s.get(k+pref))
    def O(k):return num(s.get(k+op))
    gf=num(base.get('homeFTResult' if side=='home' else 'awayFTResult')); ga=num(base.get('awayFTResult' if side=='home' else 'homeFTResult'))
    return {'id':base.get('id'),'date':base.get('date'),'dateUtc':base.get('dateUtc'),'status':base.get('status'),'team_id':target_team_id,'gf':gf,'ga':ga,
      'corners':S('cornerKicks'),'opp_corners':O('cornerKicks'),'cards':S('yellowCards'),'opp_cards':O('yellowCards'),
      'fouls':S('fouls'),'opp_fouls':O('fouls'),'shots':S('totalShots'),'sot':S('shotsOnGoal'),'possession':S('ballPossession'),
      'xg':S('expectedGoals'),'opp_xg':O('expectedGoals'),'referee':g.get('refereeName') or base.get('refereeName'), 'players': __import__('bot.engine.player',fromlist=['extract_players']).extract_players(g,target_team_id)}

def quality(records):
    n=len(records)
    if not n:return 0.0
    comp=[]
    for r in records:
        fields=[r.get('gf'),r.get('ga'),r.get('corners'),r.get('cards'),r.get('fouls'),r.get('xg')]
        comp.append(sum(v is not None for v in fields)/len(fields))
    sample=min(100,n/15*100); return round(.55*sample+.45*(sum(comp)/n)*100,1)
