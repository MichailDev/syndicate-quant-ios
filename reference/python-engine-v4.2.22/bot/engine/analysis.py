from __future__ import annotations
import math, numpy as np
from scipy.stats import poisson
from .data import quality
from ..models.distributions import dixon_coles_matrix,outcome_probs,fair,clamp,nb_pmf
from .pricing import ev,robust_ev,kelly,classification
from .player import assemble
from .referee import referee_profile,adjust_count

GOAL_LINES=[0.5,1.5,2.5,3.5,4.5]
COUNT_LINES=[1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5,9.5,10.5]

def valid(xs):
    out=[]
    for x in xs:
        try:
            if x is None: continue
            y=float(x)
            if math.isfinite(y): out.append(y)
        except (TypeError,ValueError):
            continue
    return out
def winsor_mean(xs,q=.95):
    a=np.asarray(valid(xs),float)
    if not len(a):return None
    if len(a)<5:return float(a.mean())
    lo,hi=np.quantile(a,1-q),np.quantile(a,q);return float(np.clip(a,lo,hi).mean())
def weighted_recent(xs):
    a=valid(xs)
    if not a:return None
    w=np.exp(np.linspace(-1,0,len(a)));return float(np.average(a,weights=w))
def blend(values,baseline=None,k=8):
    a=valid(values)
    if not a:return baseline
    r=weighted_recent(a); w=len(a)/(len(a)+k)
    return w*r+(1-w)*(baseline if baseline is not None else r)

def team_attack_def(records):
    gf=blend([r.get('gf') for r in records]); ga=blend([r.get('ga') for r in records])
    xg=blend([r.get('xg') for r in records]); xga=blend([r.get('opp_xg') for r in records])
    return gf,ga,xg,xga

def estimate_lambdas(home_records,away_records):
    hgf,hga,hxg,hxga=team_attack_def(home_records); agf,aga,axg,axga=team_attack_def(away_records)
    if any(v is None for v in (hgf,hga,agf,aga)):return None
    h_att=.65*(hxg if hxg is not None else hgf)+.35*hgf; a_att=.65*(axg if axg is not None else agf)+.35*agf
    h_def=.65*hga+.35*(hxga if hxga is not None else hga); a_def=.65*aga+.35*(axga if axga is not None else aga)
    return max(.08,.56*h_att+.44*a_def),max(.08,.56*a_att+.44*h_def)

def glicko_adjust(lam_pair,glicko=None):
    if not glicko:return lam_pair
    d=glicko.get('data') if isinstance(glicko,dict) else glicko
    if isinstance(d,dict):glicko=d
    def get(*keys):
        for k in keys:
            if isinstance(glicko,dict) and k in glicko:return glicko[k]
        return None
    try:
        ph=float(get('homeWinProbability','HomeWinProbability'));pa=float(get('awayWinProbability','AwayWinProbability'))
        edge=max(-1,min(1,ph-pa));factor=max(-.12,min(.12,.20*edge));h,a=lam_pair
        return h*(1+factor),a*(1-factor)
    except:return lam_pair

def model_match(home_records,away_records,glicko=None,rho=-.055,max_goals=12,player_home=None,player_away=None):
    base=estimate_lambdas(home_records,away_records)
    if not base:return None
    ph=assemble(home_records,player_home); pa=assemble(away_records,player_away)
    player_lam=(base[0]*ph['factor'],base[1]*pa['factor'])
    final_lam=glicko_adjust(player_lam,glicko)
    base_mat=dixon_coles_matrix(*base,rho=rho,max_goals=max_goals)
    player_mat=dixon_coles_matrix(*player_lam,rho=rho,max_goals=max_goals)
    mat=dixon_coles_matrix(*final_lam,rho=rho,max_goals=max_goals)
    bh,bd,ba=outcome_probs(base_mat); phm,pdm,pam=outcome_probs(player_mat); hp,dp,ap=outcome_probs(mat)
    # Recent-form component is calculated from the most recent observations only.
    recent_component=None
    if len(home_records)>=6 and len(away_records)>=6:
        rb=estimate_lambdas(home_records[:10],away_records[:10])
        if rb:
            rm=dixon_coles_matrix(*rb,rho=rho,max_goals=max_goals)
            recent_component=outcome_probs(rm)
    return {'lam_home':final_lam[0],'lam_away':final_lam[1],'base_lam_home':base[0],'base_lam_away':base[1],
            'base_matrix':base_mat,'player_matrix':player_mat,'matrix':mat,'p_home':hp,'p_draw':dp,'p_away':ap,'rho':rho,'player_home':ph,'player_away':pa,
            'component_outcomes':{'base_model':(bh,bd,ba),'player_assembly':(phm,pdm,pam),'glicko':(hp,dp,ap),
                                  'recent_form':recent_component,'home_away_context':(bh,bd,ba)}}

def robust_probability(p,n,dcs,market_dispersion=0):
    haircut=.02+.09/math.sqrt(max(n,1))+.08*(100-dcs)/100+.05*min(1,market_dispersion)
    return clamp(p*(1-haircut))

def dcs_score(home_records,away_records,market_stats=None,consensus_strength=75):
    n=min(len(home_records),len(away_records)); sample=min(100,n/15*100)
    completeness=(float(quality(home_records) or 0.0)+float(quality(away_records) or 0.0))/2.0
    ms=(market_stats or {}).get('score',55)
    source=90; freshness=85; definition=95
    return round(.30*source+.25*sample+.20*min(100,consensus_strength)+.15*freshness+.10*definition,1)

def qcs(dcs,ms,ts=75,rs=75,mes=75):return round(.30*mes+.20*dcs+.20*ms+.15*ts+.15*rs,1)

def monte_carlo_matrix(matrix,n=50000,seed=42):
    rng=np.random.default_rng(seed);flat=matrix.ravel();idx=rng.choice(len(flat),size=n,p=flat);size=matrix.shape[0]
    h=idx//size;a=idx%size
    return h,a

def mc_outcome_probs(matrix,n=50000,seed=42):
    h,a=monte_carlo_matrix(matrix,n,seed);return float((h>a).mean()),float((h==a).mean()),float((h<a).mean())

def mc_total_probability(matrix,line,n=50000,seed=42,over=True):
    h,a=monte_carlo_matrix(matrix,n,seed);tot=h+a
    return float((tot>line).mean()) if over else float((tot<line).mean())

def _finish(market,selection,line,p,odds,dcs,ms,n,model_type='DC',disp=0,consensus=None,price_status='HISTORICAL/CLOSING',sim_prob=None,sharp=None,market_bookmakers=0,component_attribution=None,market_prob=None):
    sharp=sharp or {}; guard=max(0,min(100,float(sharp.get('score',0))))
    has_sharp_data=bool(sharp.get('sharp_close') or sharp.get('sharp_open'))
    if sharp.get('disagreement',0)>.05: ms=max(0,ms-15)
    if has_sharp_data and sharp.get('score',0)<35: ms=max(0,ms-20)
    pl=robust_probability(p,n,dcs,disp);fair_odds=fair(p);e=ev(p,odds);re=robust_ev(pl,odds)
    if has_sharp_data and sharp.get('disagreement',0)>.05: re*=.70
    if has_sharp_data and sharp.get('score',0)<35: re=-abs(re)
    # Market-vs-model outlier guard. A quote >1.35x model fair is not
    # automatically value: it is a PRICE ANOMALY until independently verified.
    # Integrity guards: a line with only one book is not a consensus market,
    # and a very low total line is especially vulnerable to team-total / match-total
    # mapping mistakes. Never promote such a quote to A BET without corroboration.
    thin_market = market_bookmakers < 2
    extreme_price = bool(fair_odds > 0 and odds > fair_odds * 1.25)
    price_anomaly = bool(fair_odds > 0 and odds > fair_odds * 1.35)
    market_conflict = bool(disp > 0.20)
    if price_anomaly or thin_market or extreme_price or market_conflict:
        re=-abs(re)
    qc=qcs(dcs,ms)
    verdict='X' if (price_anomaly or thin_market or extreme_price or market_conflict) else classification(e,re,qc,dcs,ms)
    return {'market':market,'selection':selection,'line':line,'odds':odds,'p':p,'p_low':pl,'fair':fair_odds,'ev':e,'robust_ev':re,'dcs':dcs,'ms':ms,'qcs':qc,
      'classification':verdict,'price_anomaly':price_anomaly or extreme_price,'thin_market':thin_market,'market_conflict':market_conflict,'market_bookmakers':market_bookmakers,
      'stake':0.0 if (price_anomaly or thin_market or extreme_price or market_conflict) else kelly(pl,odds,cap=.02),'model':model_type,'component_attribution':component_attribution or {},'market_prob':market_prob,'sharp_guard':sharp,'n':n,'consensus_odds':consensus,'price_status':price_status,'sim_p':sim_prob}

def analyze_1x2(home_records,away_records,odds_map=None,glicko=None,market_stats=None,consensus=None,player_home=None,player_away=None,sharp_map=None,bookmaker_counts=None):
    m=model_match(home_records,away_records,glicko,player_home=player_home,player_away=player_away);out=[]
    if not m:return out
    dcs=dcs_score(home_records,away_records,market_stats,75 if consensus else 55);ms=(market_stats or {}).get('score',55);disp=(market_stats or {}).get('dispersion',0);mc=mc_outcome_probs(m['matrix'],n=50000,seed=17)
    implied={k:(1/float((consensus or {}).get(k))) for k in ('1','X','2') if (consensus or {}).get(k)}
    isum=sum(implied.values()) or 1.0
    implied={k:v/isum for k,v in implied.items()}
    for sel,p,pmc in [('1',m['p_home'],mc[0]),('X',m['p_draw'],mc[1]),('2',m['p_away'],mc[2])]:
        odds=(odds_map or {}).get(sel)
        if odds:
            i=('1','X','2').index(sel); comp={'base_model':m['component_outcomes']['base_model'][i],'player_assembly':m['component_outcomes']['player_assembly'][i],'glicko':m['component_outcomes']['glicko'][i], 'home_away_context':m['component_outcomes']['home_away_context'][i]}
            if m['component_outcomes'].get('recent_form'): comp['recent_form']=m['component_outcomes']['recent_form'][i]
            out.append(_finish('1X2',sel,None,p,odds,dcs,ms,len(home_records)+len(away_records),'DIXON_COLES+MC',disp,(consensus or {}).get(sel),sim_prob=pmc,sharp=(sharp_map or {}).get(sel),market_bookmakers=int((bookmaker_counts or {}).get(sel,0)),market_prob=implied.get(sel),component_attribution=comp))
    return out

def _total_over(matrix,line):
    return float(sum(matrix[i,j] for i in range(matrix.shape[0]) for j in range(matrix.shape[1]) if i+j>line))


def analyze_goals(home_records,away_records,odds_map=None,glicko=None,market_stats=None,consensus=None,player_home=None,player_away=None,sharp_map=None,bookmaker_counts=None):
    m=model_match(home_records,away_records,glicko,player_home=player_home,player_away=player_away);out=[]
    if not m:return out
    dcs=dcs_score(home_records,away_records,market_stats,75 if consensus else 55);ms=(market_stats or {}).get('score',55);disp=(market_stats or {}).get('dispersion',0)
    comp_mats={'base_model':m['base_matrix'],'player_assembly':m['player_matrix'],'glicko':m['matrix']}
    for line in GOAL_LINES:
        p_over=_total_over(m['matrix'],line);mc_over=mc_total_probability(m['matrix'],line,n=50000,seed=int(line*10+3),over=True)
        co=(consensus or {})
        io=(1/float(co.get(f'Over{line:g}'))) if co.get(f'Over{line:g}') else None
        iu=(1/float(co.get(f'Under{line:g}'))) if co.get(f'Under{line:g}') else None
        den=(io or 0)+(iu or 0)
        market_pair={'Over':(io/den if io is not None and den else None),'Under':(iu/den if iu is not None and den else None)}
        for side,p,pmc in [('Over',p_over,mc_over),('Under',1-p_over,1-mc_over)]:
            key=f'{side}{line:g}';odds=(odds_map or {}).get(key)
            if not odds:continue
            comp={name:(_total_over(cm,line) if side=='Over' else 1-_total_over(cm,line)) for name,cm in comp_mats.items()}
            out.append(_finish('GOALS',key,line,p,odds,dcs,ms,len(home_records)+len(away_records),'DIXON_COLES+MC',disp,co.get(key),sim_prob=pmc,sharp=(sharp_map or {}).get(key),market_bookmakers=int((bookmaker_counts or {}).get(key,0)),market_prob=market_pair.get(side),component_attribution=comp))
    return out

def distribution_for(vals):
    a=np.asarray(valid(vals),float);mu=float(a.mean());var=float(a.var(ddof=1)) if len(a)>1 else mu
    if var>mu*1.10:return nb_pmf(mu,var,60),'NEGATIVE_BINOMIAL',mu,var
    p=poisson.pmf(np.arange(61),max(mu,1e-9));return p/p.sum(),'POISSON',mu,var

def analyze_count_market(home_records,away_records,field,market,lines=COUNT_LINES,odds_map=None,market_stats=None,consensus=None,ref_profile=None,sharp_map=None,player_home=None,player_away=None,bookmaker_counts=None):
    # Use both team and opponent observations: for corners/cards, the opponent value is an independent contextual observation.
    vals=valid([r.get(field) for r in home_records+away_records]+[r.get('opp_'+field) for r in home_records+away_records])
    if field=='cards' and ref_profile and ref_profile.get('value') is not None and ref_profile.get('n',0)>=6:
        vals += [ref_profile['value']]*min(6,ref_profile['n'])
    if len(vals)<6:return []
    pmf,kind,mu,var=distribution_for(vals);
    ref_pmf=None
    if field=='cards' and ref_profile and ref_profile.get('value') is not None and ref_profile.get('n',0)>=6:
        ref_vals=vals[:]+[float(ref_profile['value'])]*min(6,int(ref_profile['n']))
        ref_pmf,_,_,_=distribution_for(ref_vals)
    dcs=dcs_score(home_records,away_records,market_stats,75 if consensus else 55);ms=(market_stats or {}).get('score',55);disp=(market_stats or {}).get('dispersion',0);out=[]
    for line in lines:
        p_over=float(pmf[int(math.floor(line))+1:].sum());rng=np.random.default_rng(int(line*100+11));sample=rng.choice(np.arange(len(pmf)),size=50000,p=pmf);mc_over=float((sample>line).mean())
        co=(consensus or {})
        io=(1/float(co.get(f'Over{line:g}'))) if co.get(f'Over{line:g}') else None
        iu=(1/float(co.get(f'Under{line:g}'))) if co.get(f'Under{line:g}') else None
        den=(io or 0)+(iu or 0)
        market_pair={'Over':(io/den if io is not None and den else None),'Under':(iu/den if iu is not None and den else None)}
        for side,p,pmc in [('Over',p_over,mc_over),('Under',1-p_over,1-mc_over)]:
            key=f'{side}{line:g}';odds=(odds_map or {}).get(key)
            if odds:out.append(_finish(market,key,line,p,odds,dcs,ms,len(vals),kind,disp,co.get(key),pmc,market_bookmakers=int((bookmaker_counts or {}).get(key,0)),market_prob=market_pair.get(side),component_attribution={'base_model':(float(p_over) if side=='Over' else float(1-p_over)),'referee':((float((ref_pmf[int(math.floor(line))+1:].sum())) if side=='Over' else float(1-ref_pmf[int(math.floor(line))+1:].sum())) if ref_pmf is not None else None)}))
    return out
