from __future__ import annotations
import asyncio, datetime as dt, json, os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = BASE_DIR / 'data'
from .backtest import run
from .config import settings

STATE = DATA_DIR / 'auto_backtest_state.json'
LOCK = asyncio.Lock()
TASK = None
STOP_EVENT = asyncio.Event()

INSTITUTIONAL_HISTORY_TARGETS = [
    (39, 2023, 500), (39, 2024, 500), (39, 2025, 500),
    (140, 2023, 500), (140, 2024, 500), (140, 2025, 500),
    (135, 2023, 500), (135, 2024, 500), (135, 2025, 500),
    (78, 2023, 500), (78, 2024, 500), (78, 2025, 500),
    (61, 2023, 500), (61, 2024, 500), (61, 2025, 500),
    (235, 2023, 500), (235, 2024, 500), (235, 2025, 500),
]

def _now(): return dt.datetime.now(dt.timezone.utc).isoformat()

def _read_state():
    try: return json.loads(STATE.read_text(encoding='utf-8'))
    except Exception: return {}

def _write_state(**patch):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    state=_read_state(); state.update(patch); state['updated_at']=_now()
    tmp=STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state,ensure_ascii=False,indent=2),encoding='utf-8')
    os.replace(tmp,STATE)
    return state

def parse_targets(value: str):
    out=[]
    for token in (value or '').split(','):
        parts=token.strip().split(':')
        if len(parts)<2: continue
        try: out.append((int(parts[0]),int(parts[1]),int(parts[2]) if len(parts)>2 else settings.backtest_limit))
        except ValueError: pass
    required={(l,y) for l,y,_ in INSTITUTIONAL_HISTORY_TARGETS}
    if not required.issubset({(l,y) for l,y,_ in out}): return list(INSTITUTIONAL_HISTORY_TARGETS)
    return out

def due(force=False):
    if force: return True
    state=_read_state(); last=state.get('last_success')
    if not last: return True
    try:
        d=dt.datetime.fromisoformat(str(last).replace('Z','+00:00'))
        if d.tzinfo is None: d=d.replace(tzinfo=dt.timezone.utc)
        return (dt.datetime.now(dt.timezone.utc)-d).total_seconds() >= settings.auto_backtest_interval_hours*3600
    except Exception: return True

def status():
    s=_read_state()
    s['in_memory_running']=LOCK.locked()
    return s

def _report_path(league, year):
    return DATA_DIR / f'walkforward_{league}_{year}.json'

def _raw_path(league, year):
    return DATA_DIR / 'backtest_raw' / f'{league}_{year}.json'

def _details_path(league, year):
    return DATA_DIR / 'backtest_raw' / f'{league}_{year}_details.json'

def _valid_current_report(league, year):
    p=_report_path(league,year)
    try:
        x=json.loads(p.read_text(encoding='utf-8'))
        return x.get('status')=='ok' and str(x.get('engine','')).startswith('v4.2.22')
    except Exception:
        return False

async def _run_target(league,year,limit,progress,idx,total,stage='full'):
    timeout=max(5,int(getattr(settings,'backtest_target_timeout_minutes',45)))*60
    return await asyncio.wait_for(
        run(league,year,limit,settings.backtest_markets,write_report=(stage!='collect'),progress=progress,target_index=idx,target_total=total,stage=stage),
        timeout=timeout)


LEAGUES = {
    39: 'Premier League',
    78: 'Bundesliga',
    140: 'La Liga',
    135: 'Serie A',
    61: 'Ligue 1',
    235: 'Russian Premier League',
}
YEARS = (2023, 2024, 2025)

def league_name(league):
    return LEAGUES.get(int(league), f'League {league}')

def target_inventory(league, year):
    paths = {
        'report': _report_path(league, year),
        'raw': _raw_path(league, year),
        'details': _details_path(league, year),
        'detail_errors': _details_path(league, year).with_name(_details_path(league, year).stem + '_errors.json'),
    }
    def size(p):
        try: return p.stat().st_size
        except Exception: return 0
    report_ok=_valid_current_report(league, year)
    raw_exists=paths['raw'].exists() and size(paths['raw'])>100
    details_exists=paths['details'].exists() and size(paths['details'])>10
    return {
        'league': int(league), 'year': int(year), 'name': league_name(league),
        'report_ok': report_ok, 'raw_exists': raw_exists, 'details_exists': details_exists,
        'exists': bool(report_ok or raw_exists or details_exists),
        'report_path': str(paths['report']), 'raw_path': str(paths['raw']),
        'details_path': str(paths['details']), 'detail_errors_path': str(paths['detail_errors']),
    }

def invalidate_target(league, year):
    # Explicit "update" means a fresh historical snapshot from SStats.
    # The files are removed only for the selected league/season; other history remains intact.
    inv = [_report_path(league,year), _details_path(league,year),
           _details_path(league,year).with_name(_details_path(league,year).stem + '_errors.json'),
           _raw_path(league,year)]
    for p in inv:
        try: p.unlink()
        except FileNotFoundError: pass
        except Exception: pass

def target_status(league, year):
    return target_inventory(league, year)

async def run_single(league, year, limit=None, progress=None, force_update=False, target_index=1, target_total=1):
    """Run exactly one selected league/season; never touches other targets."""
    league, year = int(league), int(year)
    if running():
        return {'status':'running','league':league,'year':year}
    async with LOCK:
        STOP_EVENT.clear()
        if force_update:
            invalidate_target(league, year)
        _write_state(status='running', mode='manual-single', started_at=_now(), finished_at=None,
                     error=None, target_index=target_index, target_total=target_total, league=league, year=year,
                     match_done=0, match_total=0, detail_done=0, detail_total=0,
                     received_matches=0, last_completed_target=None, raw_path=None)
        async def cb(kind,idx,total,l,y,info):
            if kind=='fetch' and isinstance(info,dict):
                _write_state(status='running',phase='fetch',target_index=target_index,target_total=target_total,league=l,year=y,
                             received_matches=info.get('received',0),raw_path=info.get('raw_path'),
                             fetch_errors=info.get('errors') or [],heartbeat_at=_now())
            elif kind=='fetch_request' and isinstance(info,dict):
                _write_state(status='running',phase='fetch',league=l,year=y,fetch_source=info.get('source'),
                             fetch_offset=info.get('offset',0),fetch_limit=info.get('limit',0),
                             fetch_message=info.get('message'),heartbeat_at=_now())
            elif kind=='target_start':
                _write_state(status='running',phase='fetch',league=l,year=y,heartbeat_at=_now())
            elif kind=='details' and isinstance(info,dict):
                _write_state(status='running',phase='details',league=l,year=y,
                             detail_done=info.get('done',0),detail_total=info.get('total',0),
                             match_done=info.get('done',0),match_total=info.get('total',0),
                             missing_details=info.get('missing',0),heartbeat_at=_now())
            elif kind=='match' and isinstance(info,dict):
                _write_state(status='running',phase='model-processing',target_index=target_index,target_total=target_total,
                             league=l,year=y,match_done=info.get('done',0),match_total=info.get('total',0),
                             detail_done=info.get('done',0),detail_total=info.get('total',0),
                             heartbeat_at=_now())
            elif kind=='target_partial':
                _write_state(status='running',phase='target-partial',target_index=target_index,target_total=target_total,league=l,year=y,
                             detail_done=info.get('full',0),detail_total=info.get('matches',0),
                             missing_details=info.get('missing',0),details_path=info.get('details_path'),
                             last_error=str(info.get('message',''))[:800],heartbeat_at=_now())
            elif kind=='target_done':
                _write_state(status='completed',phase='target-complete',league=l,year=y,
                             detail_done=info.get('matches',0),detail_total=info.get('matches',0),
                             match_done=info.get('matches',0),match_total=info.get('matches',0),
                             received_matches=info.get('matches',0),last_completed_target=f'{l}:{y}',
                             finished_at=_now(),last_success=_now(),heartbeat_at=_now(),error=None)
            elif kind=='target_error':
                _write_state(status='error',phase='target-error',league=l,year=y,error=str(info)[:800],
                             last_error=str(info)[:800],heartbeat_at=_now())
            if progress: await progress(kind,target_index,target_total,l,y,info)
        timeout=max(5,int(getattr(settings,'backtest_target_timeout_minutes',45)))*60
        try:
            result=await asyncio.wait_for(run(league,year,limit or settings.backtest_limit,settings.backtest_markets,
                                               write_report=True,progress=cb,target_index=target_index,target_total=target_total),timeout=timeout)
            _write_state(status='completed',phase='target-complete',finished_at=_now(),last_success=_now(),
                         last_completed_target=f'{league}:{year}',completed_targets=1,failed_targets=0,
                         results=[result],error=None,heartbeat_at=_now())
            return result
        except asyncio.CancelledError:
            _write_state(status='cancelled',finished_at=_now(),error='Backtest stopped by user')
            raise
        except Exception as e:
            _write_state(status='error',finished_at=_now(),error=str(e)[:800],last_error=str(e)[:800],
                         failed_targets=1,heartbeat_at=_now())
            raise

async def run_league_all_seasons(league, years=None, limit=None, progress=None, force_update=False):
    """Two-stage historical workflow for one league.

    Stage 1: collect the complete season snapshot + per-match details and persist them.
    Stage 2: analyze only seasons whose collection stage completed successfully.
    This deliberately separates data acquisition from modelling so a model error cannot
    erase or invalidate an already collected historical dataset.
    """
    years=list(years or YEARS)
    total=len(years)
    results=[]
    stage_state={}
    for year in years:
        inv=target_inventory(league, year)
        stage_state[year]={'collection':'pending','analysis':'pending','raw':inv.get('raw_exists',False),'details':inv.get('details_exists',False)}
        if inv.get('report_ok') and not force_update:
            stage_state[year]['collection']='ok'; stage_state[year]['analysis']='ok'
        elif inv.get('raw_exists') and inv.get('details_exists') and not force_update:
            stage_state[year]['collection']='ok'
    _write_state(status='running',phase='collect',mode='league-staged',league=int(league),target_index=0,target_total=total,stage_statuses=stage_state,heartbeat_at=_now(),error=None)
    if progress:
        await progress('stage_start',0,total,league,0,{'stage':'collect','statuses':stage_state})

    # -------- Stage 1: COLLECTION --------
    for idx, year in enumerate(years, 1):
        if STOP_EVENT.is_set(): raise asyncio.CancelledError()
        inv=target_inventory(league,year)
        if force_update:
            invalidate_target(league,year); inv=target_inventory(league,year)
        if stage_state[year]['collection']=='ok' and inv.get('raw_exists') and inv.get('details_exists'):
            if progress: await progress('collection_done',idx,total,league,year,{'matches':0,'cached':True,'status':'ok'})
            continue
        try:
            result=await _run_target(league,year,limit,progress,idx,total,stage='collect')
            ok=result.get('status')=='ok' and result.get('integrity_status')=='complete'
            stage_state[year]['collection']='ok' if ok else 'error'
            stage_state[year].update({'matches':result.get('matches',0),'coverage':result.get('detail_coverage',0),'raw':True,'details':result.get('usable_full_matches',0)>0})
            _write_state(status='running',phase='collect',league=int(league),target_index=idx,target_total=total,stage_statuses=stage_state,received_matches=result.get('matches',0),raw_path=result.get('raw_path'),heartbeat_at=_now(),last_error=None if ok else 'Collection incomplete')
            if not ok:
                results.append({'league':int(league),'year':int(year),'status':'error','stage':'collection','error':f"Collection incomplete: {result.get('detail_coverage',0):.1%}"})
        except asyncio.CancelledError: raise
        except Exception as e:
            err=str(e)[:800]; stage_state[year]['collection']='error'; stage_state[year]['collection_error']=err
            _write_state(status='running',phase='collect',league=int(league),target_index=idx,target_total=total,stage_statuses=stage_state,last_error=err,heartbeat_at=_now())
            results.append({'league':int(league),'year':int(year),'status':'error','stage':'collection','error':err})
            if progress: await progress('collection_error',idx,total,league,year,err)
        if idx<total: await asyncio.sleep(1.0)

    _write_state(status='running',phase='analysis',league=int(league),target_index=0,target_total=total,stage_statuses=stage_state,heartbeat_at=_now(),last_error=None)
    if progress:
        await progress('stage_start',total,total,league,0,{'stage':'analysis','statuses':stage_state})

    # -------- Stage 2: ANALYSIS --------
    for idx, year in enumerate(years, 1):
        if STOP_EVENT.is_set(): raise asyncio.CancelledError()
        if stage_state[year]['collection']!='ok':
            stage_state[year]['analysis']='error'; stage_state[year]['analysis_error']='Collection stage failed; analysis skipped.'
            if progress: await progress('analysis_error',idx,total,league,year,stage_state[year]['analysis_error'])
            continue
        if _valid_current_report(league,year) and not force_update:
            stage_state[year]['analysis']='ok'
            _write_state(status='running',phase='analysis',league=int(league),target_index=idx,target_total=total,stage_statuses=stage_state,last_completed_target=f'{league}:{year}',heartbeat_at=_now(),last_error=None)
            if progress: await progress('analysis_done',idx,total,league,year,{'status':'ok','cached':True})
            results.append({'league':int(league),'year':int(year),'status':'ok','collection':'ok','analysis':'ok','skipped_existing':True})
            continue
        try:
            result=await _run_target(league,year,limit,progress,idx,total,stage='analysis')
            stage_state[year]['analysis']='ok' if result.get('status') in ('ok','partial') else 'error'
            results.append({'league':int(league),'year':int(year),'status':result.get('status','ok'),'collection':'ok','analysis':stage_state[year]['analysis'],'matches':result.get('matches',0),'predictions':result.get('predictions',0),'bets':result.get('portfolio_bets',0)})
            _write_state(status='running',phase='analysis',league=int(league),target_index=idx,target_total=total,stage_statuses=stage_state,last_completed_target=f'{league}:{year}' if stage_state[year]['analysis']=='ok' else None,heartbeat_at=_now(),last_error=None)
        except asyncio.CancelledError: raise
        except Exception as e:
            err=str(e)[:800]; stage_state[year]['analysis']='error'; stage_state[year]['analysis_error']=err
            _write_state(status='running',phase='analysis',league=int(league),target_index=idx,target_total=total,stage_statuses=stage_state,last_error=err,heartbeat_at=_now())
            results.append({'league':int(league),'year':int(year),'status':'error','stage':'analysis','collection':'ok','analysis':'error','error':err})
            if progress: await progress('analysis_error',idx,total,league,year,err)
        if idx<total: await asyncio.sleep(1.0)

    # Preserve a compact per-league stage manifest for /backtest_status and recovery.
    manifest={'league':int(league),'updated_at':_now(),'stage_state':stage_state,'results':results}
    try:
        (DATA_DIR / f'backtest_{league}_stages.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    except Exception: pass
    ok=sum(1 for r in results if r.get('status') in ('ok','partial','skipped'))
    failed=sum(1 for y in years if stage_state[y].get('analysis')!='ok')
    final_status='ok' if failed==0 else ('partial' if ok else 'error')
    _write_state(status='completed' if final_status=='ok' else final_status,phase='done',league=int(league),target_index=total,target_total=total,stage_statuses=stage_state,results=results,completed_targets=ok,failed_targets=failed,finished_at=_now(),last_success=_now() if final_status=='ok' else _read_state().get('last_success'),error=None if final_status=='ok' else 'One or more league seasons failed',heartbeat_at=_now())
    return {'status':final_status,'league':int(league),'results':results,'completed_targets':ok,'failed_targets':failed,'stage_state':stage_state}


async def verify(force=False, progress=None):
    if LOCK.locked(): return {'status':'running','state':status()}
    if not due(force): return {'status':'skipped','reason':'interval','state':status()}
    async with LOCK:
        STOP_EVENT.clear()
        targets=parse_targets(settings.auto_backtest_targets)
        _write_state(status='running',started_at=_now(),finished_at=None,error=None,target_index=0,target_total=len(targets),match_done=0,match_total=0,last_completed_target=None)
        results=[]
        async def cb(kind,idx,total,league,year,info):
            if kind=='match' and isinstance(info,dict):
                _write_state(status='running',phase='match-processing',target_index=idx,target_total=total,league=league,year=year,match_done=info.get('done',0),match_total=info.get('total',0),detail_done=info.get('done',0),detail_total=info.get('total',0),heartbeat_at=_now())
            elif kind=='details' and isinstance(info,dict):
                _write_state(status='running',phase='details',target_index=idx,target_total=total,league=league,year=year,detail_done=info.get('done',0),detail_total=info.get('total',0),heartbeat_at=_now())
            elif kind=='fetch' and isinstance(info,dict):
                _write_state(status='running',phase='fetch',target_index=idx,target_total=total,league=league,year=year,match_done=0,match_total=info.get('received',0),received_matches=info.get('received',0),raw_path=info.get('raw_path'),fetch_errors=info.get('errors') or [],last_error=(info.get('errors') or [None])[-1],heartbeat_at=_now())
            elif kind=='fetch_request' and isinstance(info,dict):
                _write_state(status='running',phase='fetch',target_index=idx,target_total=total,league=league,year=year,match_done=0,match_total=info.get('received',0),received_matches=info.get('received',0),raw_path=None,fetch_source=info.get('source'),fetch_offset=info.get('offset',0),fetch_limit=info.get('limit',0),fetch_message=info.get('message'),heartbeat_at=_now())
            elif kind=='target_start':
                _write_state(status='running',phase='fetch',target_index=idx,target_total=total,league=league,year=year,match_done=0,match_total=0,detail_done=0,detail_total=0,received_matches=0,raw_path=None,fetch_errors=[],last_error=None,heartbeat_at=_now())
            elif kind=='target_done':
                _write_state(status='running',phase='target-complete',target_index=idx,target_total=total,league=league,year=year,match_done=info.get('matches',0) if isinstance(info,dict) else 0,match_total=info.get('matches',0) if isinstance(info,dict) else 0,last_completed_target=f'{league}:{year}',last_error=None,heartbeat_at=_now())
            elif kind=='target_partial':
                _write_state(status='running',phase='target-partial',target_index=idx,target_total=total,league=league,year=year,match_total=info.get('matches',0),detail_done=info.get('full',0),detail_total=info.get('matches',0),missing_details=info.get('missing',0),details_path=info.get('details_path'),error=str(info.get('message',''))[:800],last_error=str(info.get('message',''))[:800],heartbeat_at=_now())
            elif kind=='target_error':
                _write_state(status='running',phase='target-error',target_index=idx,target_total=total,league=league,year=year,error=str(info)[:800],last_error=str(info)[:800],heartbeat_at=_now())
            if progress: await progress(kind,idx,total,league,year,info)
        try:
            for idx,(league,year,limit) in enumerate(targets,1):
                if STOP_EVENT.is_set():
                    raise asyncio.CancelledError()
                if (not force) and _valid_current_report(league,year):
                    result={'league':league,'year':year,'status':'ok','skipped_existing':True}
                    results.append(result)
                    await cb('target_done',idx,len(targets),league,year,{'matches':0,'predictions':0,'bets':0,'skipped_existing':True})
                    continue
                try:
                    result=await _run_target(league,year,limit,cb,idx,len(targets))
                    results.append(result)
                except asyncio.CancelledError: raise
                except Exception as e:
                    err=str(e)[:500]
                    results.append({'league':league,'year':year,'status':'error','error':err})
                    await cb('target_error',idx,len(targets),league,year,err)
                if idx<len(targets): await asyncio.sleep(1.0)
            ok=sum(1 for r in results if r.get('status')=='ok')
            failed=len(results)-ok
            if ok:
                _write_state(status='completed',started_at=_read_state().get('started_at'),finished_at=_now(),last_success=_now(),results=results,error=None,completed_targets=ok,failed_targets=failed)
                return {'status':'ok','results':results}
            _write_state(status='error',finished_at=_now(),results=results,error='All backtest targets failed',completed_targets=0,failed_targets=failed)
            return {'status':'error','results':results}
        except asyncio.CancelledError:
            _write_state(status='cancelled',finished_at=_now(),results=results,error='Backtest stopped by user',completed_targets=sum(1 for r in results if r.get('status')=='ok'))
            return {'status':'cancelled','results':results}
        except Exception as e:
            _write_state(status='error',finished_at=_now(),results=results,error=str(e)[:800])
            return {'status':'error','results':results,'error':str(e)[:800]}

def running(): return LOCK.locked()

def task_running():
    return bool(TASK and not TASK.done())

def launch_league(league, years=None, limit=None, progress=None, force_update=False):
    global TASK
    if task_running() or LOCK.locked():
        return TASK
    TASK=asyncio.create_task(run_league_all_seasons(
        league, years or YEARS, limit or settings.backtest_limit, progress, force_update))
    return TASK

def launch(force=False, progress=None):
    global TASK
    if running(): return TASK
    TASK=asyncio.create_task(verify(force,progress))
    return TASK

async def stop():
    global TASK
    if not (running() or task_running()): return False
    STOP_EVENT.set()
    if TASK and not TASK.done(): TASK.cancel()
    return True

async def scheduler():
    # v4.2.22: historical backtest is manual-only. Kept for compatibility,
    # but it never launches historical work.
    while True:
        await asyncio.sleep(3600)

async def main():
    force='--force' in os.sys.argv
    print(json.dumps(await verify(force),ensure_ascii=False,indent=2))

if __name__=='__main__': asyncio.run(main())
