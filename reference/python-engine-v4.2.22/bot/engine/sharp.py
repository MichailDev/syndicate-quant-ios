from __future__ import annotations
import statistics,re
SHARP=('pinnacle','betfair','sbo','sbobet','marathon','bet365 exchange')

def _key(market,name):
    s=str(name).lower()
    if market=='1X2':
        if s in ('1','home','home win'):return '1'
        if s in ('x','draw'):return 'X'
        if s in ('2','away','away win'):return '2'
    nums=re.findall(r'(?<!\d)(\d+(?:\.\d+)?)(?!\d)',s)
    line=float(nums[-1]) if nums else None
    if 'over' in s:return f'Over{line:g}' if line is not None else None
    if 'under' in s:return f'Under{line:g}' if line is not None else None
    return None

def movement(rows_open,rows_close,market,key):
    def vals(rows,sharp=False):
        out=[]
        for r in rows:
            if r.get('market_type')!=market or r.get('key')!=key:continue
            if sharp and not any(x in str(r.get('bookmaker','')).lower() for x in SHARP):continue
            try:
                if r.get('odds',0)>1:out.append(float(r['odds']))
            except:pass
        return out
    all_o,all_c=vals(rows_open),vals(rows_close); sh_o,sh_c=vals(rows_open,True),vals(rows_close,True)
    med=lambda x: statistics.median(x) if x else None
    mo,mc=med(all_o),med(all_c); so,sc=med(sh_o),med(sh_c)
    move=(float(mc)/float(mo)-1.0) if mo is not None and mc is not None and float(mo)>0 else 0.0
    sharp_move=(float(sc)/float(so)-1.0) if so is not None and sc is not None and float(so)>0 else move
    disagreement=abs(float(sc)/float(mc)-1.0) if sc is not None and mc is not None and float(mc)>0 else 0.0
    score=0
    if sh_c: score+=35
    if len(all_c)>=4:score+=25
    if abs(sharp_move)>=.01:score+=20
    if disagreement<=.03:score+=20
    return {'open':mo,'close':mc,'sharp_open':so,'sharp_close':sc,'movement':move,'sharp_movement':sharp_move,'disagreement':disagreement,'score':score}
