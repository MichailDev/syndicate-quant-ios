from __future__ import annotations
import argparse,asyncio,json,statistics,datetime,math,os,time
from collections import defaultdict
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = BASE_DIR / 'data'
RAW_DIR = DATA_DIR / 'backtest_raw'
from .api.sstats import SStatsClient,data_of
from .config import settings
from .engine.data import extract_team_game,full_game
from .engine.odds import flatten_odds,build_market_map,market_quality,enrich_rows,consensus_odds,classify_market,key_bookmakers,merge_odds_rows,one_x_two_complete
from .engine.analysis import analyze_1x2,analyze_goals,analyze_count_market
from .engine.referee import referee_profile
from .engine.sharp import movement
from .engine.portfolio import select_portfolio
from .engine.calibration import load_samples, apply_calibration, metrics_for_samples

MARKETS=['1X2','GOALS','CARDS','CORNERS']
ENGINE_VERSION='v4.2.22'

def ts(x):
    if not x:return datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
    try:return datetime.datetime.fromisoformat(str(x).replace('Z','+00:00'))
    except:return datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)

def actual_for(full):
    g=full.get('game') or {}
    h_raw=g.get('homeFTResult'); a_raw=g.get('awayFTResult')
    s=full.get('statistics') or {}
    def to_num(v):
        try:
            return int(float(v)) if v is not None and v != '' else None
        except (TypeError,ValueError):
            return None
    h=to_num(h_raw); a=to_num(a_raw)
    out={'1X2':{},'GOALS':{},'CARDS':{},'CORNERS':{}}
    if h is not None and a is not None:
        out['1X2']={'1':h>a,'X':h==a,'2':h<a}
        goals=h+a
        out['GOALS']={f'Over{x:.1f}':goals>x for x in [.5,1.5,2.5,3.5,4.5]} | {f'Under{x:.1f}':goals<x for x in [.5,1.5,2.5,3.5,4.5]}
    ch=to_num(s.get('yellowCardsHome')); ca=to_num(s.get('yellowCardsAway'))
    if ch is not None and ca is not None:
        cards=ch+ca
        out['CARDS']={f'Over{x:.1f}':cards>x for x in [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5,9.5,10.5]} | {f'Under{x:.1f}':cards<x for x in [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5,9.5,10.5]}
    kh=to_num(s.get('cornerKicksHome')); ka=to_num(s.get('cornerKicksAway'))
    if kh is not None and ka is not None:
        corners=kh+ka
        out['CORNERS']={f'Over{x:.1f}':corners>x for x in [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5,9.5,10.5]} | {f'Under{x:.1f}':corners<x for x in [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5,9.5,10.5]}
    return out


def merge_odds(primary, fallback):
    """Merge odds sources without discarding markets from the primary source.
    Prefer the primary quote when the same bookmaker/market/selection is present.
    This specifically fixes historical 1X2 gaps where /Odds returns only one or two
    outcomes while GameInfo contains the missing Home/Draw/Away prices.
    """
    out=list(primary or [])
    seen=set()
    for r in out:
        seen.add((str(r.get('bookmaker_id')),str(r.get('bookmaker')),str(r.get('market')),str(r.get('name')),str(r.get('odds'))))
    for r in (fallback or []):
        key=(str(r.get('bookmaker_id')),str(r.get('bookmaker')),str(r.get('market')),str(r.get('name')),str(r.get('odds')))
        if key not in seen:
            out.append(r); seen.add(key)
    return out

def one_x_two_coverage(rows):
    """Return complete bookmaker/consensus coverage diagnostics for 1X2."""
    by_book=defaultdict(set)
    for r in rows or []:
        if classify_market(r.get('market')) != '1X2' or r.get('odds',0) <= 1: continue
        sel=r.get('key') or r.get('name')
        if sel in {'1','X','2'}:
            bid=r.get('bookmaker_id') or r.get('bookmaker') or 'unknown'
            by_book[str(bid)].add(sel)
    complete_books=sum(1 for v in by_book.values() if {'1','X','2'} <= v)
    all_sels=set().union(*by_book.values()) if by_book else set()
    return {'books':len(by_book),'complete_books':complete_books,'has_home':'1' in all_sels,'has_draw':'X' in all_sels,'has_away':'2' in all_sels,'complete':{'1','X','2'} <= all_sels}


async def run(league,year,limit,markets,write_report=True, progress=None, target_index=None, target_total=None, stage='full'):
    async with SStatsClient(settings.sstats_base_url,settings.sstats_api_key,settings.request_timeout, settings.sstats_connect_timeout, settings.sstats_trust_env, settings.sstats_retry_attempts, settings.sstats_min_request_gap) as api:
        # Historical retrieval is deliberately resilient. First try the simple
        # season-list request that worked in earlier bot versions. If SStats
        # rejects/times out that request, fall back to small paginated pages.
        # This avoids the v4.2.x failure mode where the target can sit at 0/0
        # before any historical matches are saved.
        if progress:
            await progress('target_start', target_index, target_total, league, year, {'matches':0})
        raw=[]
        max_rows=min(1000,max(1,int(limit or settings.backtest_limit)))
        request_errors=[]
        response_meta=[]
        RAW_DIR.mkdir(parents=True, exist_ok=True)
        raw_path=RAW_DIR / f'{league}_{year}.json'
        details_path=RAW_DIR / f'{league}_{year}_details.json'

        # Resume-first policy: once a season list has been successfully saved,
        # never re-hit /Games/list just because a later detail request timed out.
        # This is critical for long Windows runs and also prevents duplicate
        # API traffic after a restart.
        raw_cache_loaded=False
        if stage == 'analysis' and not raw_path.exists():
            raise RuntimeError(f'Collection stage not found for league={league}, season={year}: {raw_path}')
        if stage == 'analysis' and not details_path.exists():
            raise RuntimeError(f'Detail collection not found for league={league}, season={year}: {details_path}')
        try:
            cached_raw=json.loads(raw_path.read_text(encoding='utf-8'))
            cached_rows=cached_raw.get('matches') if isinstance(cached_raw,dict) else None
            if isinstance(cached_rows,list) and cached_rows:
                raw=list(cached_rows)[:max_rows]
                raw_cache_loaded=True
                response_meta.append({'source':'raw-cache','count':len(raw),'path':str(raw_path)})
                if progress:
                    await progress('fetch', target_index, target_total, league, year, {'received':len(raw),'raw_path':str(raw_path),'errors':[],'cache_hit':True})
        except Exception:
            raw_cache_loaded=False

        async def fetch_page(offset=0, take=None, ended=None, source_label="Games/list", canonical=False):
            take=min(1000, max_rows if take is None else int(take))
            # Canonical SStats historical request: LeagueId + Year + Limit + Order.
            # Offset/TimeZone are intentionally NOT sent on the first request because
            # older bot versions worked with this exact documented shape.
            params={"LeagueId":league,"Year":year,"Limit":take,"Order":1}
            if not canonical and offset:
                params["Offset"] = offset
            if ended is True:
                params["Ended"] = True
            if progress:
                await progress('fetch_request', target_index, target_total, league, year, {
                    'source': source_label, 'offset': offset, 'limit': take, 'ended': ended,
                    'received': len(raw), 'message': f'GET /Games/list canonical={canonical} offset={offset} limit={take}'
                })
            payload=await api.games(**params)
            page=data_of(payload) or []
            if isinstance(payload,dict):
                response_meta.append({"source":source_label,"offset":offset,"canonical":canonical,"count":payload.get("count"),"total":payload.get("TotalCount"),"status":payload.get("status"),"message":payload.get("message"),"requestQuery":payload.get("requestQuery")})
            return page if isinstance(page,list) else []

        if not raw_cache_loaded:
            # Official SStats documentation's canonical historical example.
            # First request is deliberately simple. Pagination is only a fallback when
            # the server returns fewer rows than requested.
            try:
                page=await fetch_page(0, max_rows, ended=None, canonical=True)
                raw.extend(page)
            except Exception as e:
                request_errors.append(f'plain-list-canonical: {str(e)[:400]}')

        # Some SStats installations cap /Games/list below the requested Limit.
        # Only then use Offset, without the unverified TimeZone parameter.
        if (not raw_cache_loaded) and raw and len(raw) < max_rows:
            offset=len(raw)
            while len(raw)<max_rows:
                take=min(1000,max_rows-len(raw))
                try:
                    page=await fetch_page(offset,take,ended=None,canonical=False)
                    if not page: break
                    raw.extend(page)
                    offset += len(page)
                    if len(page)<take: break
                except Exception as e:
                    request_errors.append(f'plain-page {offset}: {str(e)[:260]}')
                    break

        # If the canonical season request is empty, explicitly try Ended=true.
        if (not raw_cache_loaded) and not raw:
            try:
                page=await fetch_page(0,max_rows,ended=True,canonical=True)
                raw.extend(page)
            except Exception as e:
                request_errors.append(f'ended-list-canonical: {str(e)[:400]}')

        # Last-resort official query endpoint. This is only used when /Games/list
        # produced no rows, so it cannot hide a partially successful list response.
        if (not raw_cache_loaded) and not raw:
            try:
                fields=["Id","Date","HomeTeamName","AwayTeamName","HomeTeam","AwayTeam","HomeFTResult","AwayFTResult","Status","LeagueId","Year"]
                q=await api.games_query(f"LeagueId = {int(league)} AND Year = {int(year)}", fields=fields, order="Date", offset=0, limit=max_rows, timezone=3)
                qrows=data_of(q) or []
                if isinstance(qrows, list):
                    for x in qrows:
                        if not isinstance(x,dict): continue
                        gid=x.get("Id") or x.get("id")
                        if gid is None: continue
                        raw.append({"id":gid,"date":x.get("Date") or x.get("date"),"status":x.get("Status") or x.get("status"),"homeFTResult":x.get("HomeFTResult"),"awayFTResult":x.get("AwayFTResult"),"homeTeam":(x.get("HomeTeam") if isinstance(x.get("HomeTeam"),dict) else {"id":x.get("HomeTeamId"),"name":x.get("HomeTeamName")}),"awayTeam":(x.get("AwayTeam") if isinstance(x.get("AwayTeam"),dict) else {"id":x.get("AwayTeamId"),"name":x.get("AwayTeamName")}),"_source":"Games/query"})
                response_meta.append({"source":"Games/query","count":len(qrows) if isinstance(qrows,list) else 0,"status":q.get("status") if isinstance(q,dict) else None,"message":q.get("message") if isinstance(q,dict) else None})
            except Exception as e:
                request_errors.append(f'games-query: {str(e)[:400]}')

        # De-duplicate pages and retain completed matches. The documented list
        # object exposes status 8/9/10/17/18 for finished/technical results.
        # Also accept statusName=Finished and a populated FT score as a safe
        # compatibility fallback; never accept an upcoming/live row as settled.
        uniq={}
        for x in raw:
            if not isinstance(x,dict): continue
            gid=x.get('id') or x.get('gameId') or x.get('gameID')
            if gid is not None: uniq[str(gid)]=x
        raw_all=list(uniq.values())
        def finished(x):
            try:
                st=int(x.get('status')) if x.get('status') not in (None,'') else None
            except Exception: st=None
            if st in (8,9,10,17,18): return True
            sn=str(x.get('statusName') or '').strip().lower()
            if sn in ('finished','finished after extra time','finished after penalties','technical defeat','walkover','матч завершён','завершен'): return True
            # ApiSaGame documents homeFTResult/awayFTResult. These are the
            # main-time scores and are present for completed matches.
            return x.get('homeFTResult') is not None and x.get('awayFTResult') is not None
        raw=[x for x in raw_all if finished(x)]
        raw=sorted(raw,key=lambda x:ts(x.get('date') or x.get('dateUtc')))[:max_rows]

        # Persist the raw season list before the expensive per-match detail
        # phase. A timeout later in the target can therefore be resumed/debugged
        # without losing the successfully fetched match list.
        RAW_DIR.mkdir(parents=True, exist_ok=True)
        raw_path=str(raw_path)
        try:
            with open(raw_path,'w',encoding='utf-8') as rf:
                json.dump({'league':league,'year':year,'matches':raw,'fetched_at':datetime.datetime.utcnow().isoformat(),'request_errors':request_errors,'response_meta':response_meta,'received_raw_before_status_filter':len(raw_all)},rf,ensure_ascii=False,indent=2)
        except Exception:
            pass
        if progress:
            await progress('fetch', target_index, target_total, league, year, {'received':len(raw),'raw_path':raw_path,'errors':request_errors[-2:]})
        if not raw:
            detail='; '.join(request_errors[-3:]) if request_errors else ('API returned rows but none were recognized as completed' if raw_all else 'empty response')
            raise RuntimeError(f'No completed matches returned for league={league}, season={year}; {detail}')
        # Detail cache makes a long historical run resumable. A target timeout or
        # Windows restart no longer throws away already downloaded /Games/{id}.
        details_path=Path(details_path)
        full={}
        try:
            cached=json.loads(details_path.read_text(encoding='utf-8'))
            if isinstance(cached,dict):
                full={str(k):v for k,v in cached.items() if isinstance(v,dict)}
        except Exception:
            full={}
        # Detail recovery is intentionally conservative: low concurrency + a global
        # SStats rate gate + failed-only retry rounds. This prevents a transient 429/
        # timeout from turning into a permanently incomplete season.
        concurrency=max(1,int(getattr(settings,'sstats_backtest_concurrency',2)))
        sem=asyncio.Semaphore(concurrency)
        errors_path=details_path.with_name(details_path.stem + '_errors.json')
        journal_path=details_path.with_name(details_path.stem + '_error_journal.jsonl')
        try:
            ecached=json.loads(errors_path.read_text(encoding='utf-8'))
            if isinstance(ecached,dict): detail_errors={str(k):v for k,v in ecached.items()}
            else: detail_errors={}
        except Exception:
            detail_errors={}

        def classify_error(err):
            text=str(err)
            low=text.lower()
            if '429' in low or 'rate limit' in low or 'too many requests' in low:
                return 'rate_limit', True
            if any(x in low for x in ('timeout','connecterror','network error','remoteprotocol','connection reset','temporarily unavailable','502','503','504','500')):
                return 'network_or_server', True
            if '404' in low or 'not found' in low:
                return 'not_found', False
            if '401' in low or '403' in low or 'authorization' in low:
                return 'auth', False
            if 'invalid json' in low or 'empty payload' in low:
                return 'data_missing', True
            return 'other', False

        def save_detail_checkpoint():
            tmp=details_path.with_suffix('.tmp')
            tmp.write_text(json.dumps(full,ensure_ascii=False,default=str),encoding='utf-8')
            os.replace(tmp,details_path)
            etmp=errors_path.with_suffix('.tmp')
            etmp.write_text(json.dumps(detail_errors,ensure_ascii=False,indent=2),encoding='utf-8')
            os.replace(etmp,errors_path)

        def append_journal(gid, err, attempt, elapsed=None):
            kind,retryable=classify_error(err)
            rec={'ts_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'game_id':gid,
                 'endpoint':f'/Games/{gid}','attempt':attempt,'kind':kind,'retryable':retryable,
                 'elapsed_ms':elapsed,'error':str(err)[:1000]}
            try:
                with journal_path.open('a',encoding='utf-8') as jf:
                    jf.write(json.dumps(rec,ensure_ascii=False)+'\n')
            except Exception: pass
            return kind,retryable

        async def one(x, attempt_no=1):
            gid=x.get('id'); key=str(gid)
            if key in full:
                return gid,full[key],None,False
            started=time.monotonic()
            async with sem:
                try:
                    payload=data_of(await api.game(gid))
                    if payload:
                        return gid,payload,None,False
                    err='empty payload'
                except Exception as e:
                    err=e
            elapsed=int((time.monotonic()-started)*1000)
            kind,retryable=append_journal(gid,err,attempt_no,elapsed)
            return gid,None,f'{kind}: {str(err)[:700]}',retryable

        async def persist_progress(done_count):
            try: save_detail_checkpoint()
            except Exception: pass
            if progress:
                failed=sum(1 for v in detail_errors.values() if isinstance(v,dict) or v)
                await progress('details', target_index, target_total, league, year, {
                    'done':done_count,'total':detail_total,'full':len(full),'cached':len(full),
                    'missing':detail_total-len(full),'errors':failed,
                    'attempted':done_count,'pending':detail_total-len(full),
                    'retry_round':retry_round
                })

        detail_total=len(raw)
        retry_rounds=max(0,int(getattr(settings,'backtest_detail_retry_rounds',2)))
        retry_cooldown=max(0.0,float(getattr(settings,'backtest_detail_retry_cooldown_seconds',8.0)))
        retry_round=0
        pending=[x for x in raw if str(x.get('id')) not in full]
        # First pass: all currently missing IDs. On resume this is exactly the
        # failed/unfetched subset, never the already completed cache.
        for batch_start in range(0,len(pending),25):
            batch=pending[batch_start:batch_start+25]
            results=await asyncio.gather(*(one(x,1) for x in batch))
            for gid,payload,err,retryable in results:
                key=str(gid)
                if payload:
                    full[key]=payload; detail_errors.pop(key,None)
                elif err:
                    detail_errors[key]={'message':err,'retryable':retryable,'attempts':1,'last_attempt_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
            retry_round=0
            await persist_progress(min(detail_total,len(full)+len(detail_errors)))

        # Failed-only recovery passes. A 429/network failure is retried; a 404/auth
        # failure is retained as permanent and is not hammered again in this run.
        for retry_round in range(1,retry_rounds+1):
            retry_ids=[]
            for x in raw:
                key=str(x.get('id'))
                if key not in full and key in detail_errors:
                    val=detail_errors[key]
                    msg=val.get('message','') if isinstance(val,dict) else str(val)
                    _,retryable=classify_error(msg)
                    if retryable: retry_ids.append(x)
            if not retry_ids: break
            await asyncio.sleep(retry_cooldown*retry_round)
            for batch_start in range(0,len(retry_ids),25):
                batch=retry_ids[batch_start:batch_start+25]
                results=await asyncio.gather(*(one(x,retry_round+1) for x in batch))
                for gid,payload,err,retryable in results:
                    key=str(gid)
                    old=detail_errors.get(key,{})
                    attempts=(old.get('attempts',1) if isinstance(old,dict) else 1)+1
                    if payload:
                        full[key]=payload; detail_errors.pop(key,None)
                    elif err:
                        detail_errors[key]={'message':err,'retryable':retryable,'attempts':attempts,'last_attempt_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
                await persist_progress(min(detail_total,len(full)+len(detail_errors)))

        missing_ids=[str(x.get('id')) for x in raw if str(x.get('id')) not in full]
        coverage=(float(len(full))/float(detail_total)) if detail_total not in (None, 0) else 0.0
        min_coverage=max(0.0,min(1.0,float(getattr(settings,'backtest_min_coverage',0.98))))
        # A near-complete target may be processed with an explicit PARTIAL status;
        # missing matches are never fabricated and are excluded from calibration.
        # Below the integrity threshold, stop before model generation and leave a
        # resumable checkpoint.
        if missing_ids and coverage < min_coverage:
            kind_counts=defaultdict(int)
            for gid in missing_ids:
                val=detail_errors.get(gid,{})
                msg=val.get('message','') if isinstance(val,dict) else str(val)
                kind_counts[classify_error(msg)[0]] += 1
            msg=(f'Historical details incomplete: {len(missing_ids)}/{detail_total} matches missing '
                 f'({coverage:.1%} coverage, required {min_coverage:.1%}); checkpoint saved at {details_path}')
            if progress:
                await progress('target_partial', target_index, target_total, league, year, {
                    'matches':detail_total,'full':len(full),'missing':len(missing_ids),
                    'coverage':coverage,'required_coverage':min_coverage,'details_path':str(details_path),
                    'error_kinds':dict(kind_counts),'message':msg})
            raise RuntimeError(msg)

        integrity_status='complete' if not missing_ids else 'partial'
        if stage == 'collect':
            # Stage 1 ends after the historical snapshot and all requested match details
            # have been persisted. No model/odds/calibration work is performed here.
            collection_meta={
                'league':league,'year':year,'status':'ok' if integrity_status=='complete' else 'partial',
                'matches':len(raw),'usable_full_matches':len(full),'missing_detail_matches':len(missing_ids),
                'detail_coverage':coverage,'integrity_status':integrity_status,
                'raw_path':raw_path,'details_path':str(details_path),
                'collected_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'engine':ENGINE_VERSION
            }
            cp=RAW_DIR / f'{league}_{year}_collection.json'
            try:
                cp.write_text(json.dumps(collection_meta,ensure_ascii=False,indent=2),encoding='utf-8')
            except Exception: pass
            if progress:
                await progress('collection_done', target_index, target_total, league, year, collection_meta)
            return collection_meta
        if stage == 'analysis':
            if integrity_status != 'complete':
                raise RuntimeError(f'Collection stage incomplete for league={league}, season={year}: {len(missing_ids)} details missing ({coverage:.1%})')
        integrity_status='complete' if not missing_ids else 'partial'
        if missing_ids and progress:
            await progress('target_partial_ok', target_index, target_total, league, year, {
                'matches':detail_total,'full':len(full),'missing':len(missing_ids),'coverage':coverage,
                'required_coverage':min_coverage,'details_path':str(details_path),
                'message':f'Детализация {coverage:.1%}: пропущено {len(missing_ids)}; расчёт продолжается без них.'})

        team_hist=defaultdict(list);predictions=[]
        total_raw=len(raw)
        calibration_history=load_samples()
        # If this exact target was previously built, its old outcomes must not
        # become training data for an earlier match on a rebuild. That would be
        # look-ahead leakage. The current target is rebuilt chronologically from
        # an empty target-specific training slice; other leagues/older dates remain
        # available as hierarchical prior information.
        current_report_name=f'walkforward_{league}_{year}.json'
        rolling_samples=[x for x in calibration_history if x.get('source_report') != current_report_name]
        diag={'warmup_skipped':0,'odds_missing':0,'market_rows':{m:0 for m in markets},'predictions_by_market':{m:0 for m in markets},'thin_predictions':0,'robust_ev_nonpositive':0,'qcs_below_78':0,'ev_below_5':0,'eligible':0,'portfolio_rejected':0,'one_x_two_incomplete':0,'one_x_two_complete':0,'one_x_two_missing_home':0,'one_x_two_missing_draw':0,'one_x_two_missing_away':0}
        total_raw=len(raw)
        for mi,m in enumerate(raw, 1):
            if progress and (mi == 1 or mi % 25 == 0 or mi == total_raw):
                await progress('match', target_index, target_total, league, year, {'done':mi,'total':total_raw})
            gid=m.get('id');fg=full.get(str(gid));h=(m.get('homeTeam') or {}).get('id');a=(m.get('awayTeam') or {}).get('id')
            if not fg or not h or not a:continue
            hp=list(team_hist[h][-settings.lookback_matches:]);ap=list(team_hist[a][-settings.lookback_matches:])
            if len(hp)<settings.min_sample or len(ap)<settings.min_sample:
                diag['warmup_skipped'] += 1
                team_hist[h].append(extract_team_game(fg,h));team_hist[a].append(extract_team_game(fg,a));continue
            raw_close=[]; raw_open=[]
            try:
                raw_close=flatten_odds(await api.odds(gid))
            except Exception:
                raw_close=[]
            try:
                raw_open=flatten_odds(await api.odds(gid,opening=True))
            except Exception:
                raw_open=[]
            recognized={classify_market(r.get('market')) for r in raw_close}
            recognized.discard(None)
            # Always inspect GameInfo when 1X2 is absent/incomplete, and also when
            # the primary odds response contains no usable secondary market. Merge
            # rather than replace so a fallback cannot erase valid primary quotes.
            probe_1x2=one_x_two_coverage(enrich_rows(list(raw_close),'1X2'))
            need_fallback=(not raw_close) or not (recognized & {'GOALS','CARDS','CORNERS'}) or not probe_1x2['complete']
            if need_fallback:
                try:
                    fallback=flatten_odds(await api.flashscore_game_info(gid))
                    if fallback:
                        raw_close=merge_odds(raw_close,fallback)
                        if not raw_open:
                            raw_open=[r for r in fallback if r.get('opening') not in (None,'')]
                except Exception:
                    pass
            if not raw_close: diag['odds_missing'] += 1
            cov=one_x_two_coverage(enrich_rows(list(raw_close),'1X2'))
            if cov['complete']: diag['one_x_two_complete'] += 1
            else:
                diag['one_x_two_incomplete'] += 1
                if not cov['has_home']: diag['one_x_two_missing_home'] += 1
                if not cov['has_draw']: diag['one_x_two_missing_draw'] += 1
                if not cov['has_away']: diag['one_x_two_missing_away'] += 1
            try:glicko=await api.glicko(gid)
            except:glicko=None
            ref=(fg.get('refereeName') or (fg.get('game') or {}).get('refereeName'))
            rp=referee_profile(hp+ap,ref,'cards')
            for market in markets:
                cr=enrich_rows(list(raw_close),market)
                op=enrich_rows(list(raw_open),market)
                om=build_market_map(cr,market);mq=market_quality(cr,market);cons={k:consensus_odds(cr,market,k) for k in om};sharp={k:movement(op,cr,market,k) for k in om}
                diag['market_rows'][market] += len(om)
                book_counts={k:len(key_bookmakers(cr,market,k)) for k in om}
                if market=='1X2':rs=analyze_1x2(hp,ap,om,glicko,mq,consensus=cons,sharp_map=sharp,bookmaker_counts=book_counts)
                elif market=='GOALS':rs=analyze_goals(hp,ap,om,glicko,mq,consensus=cons,sharp_map=sharp,bookmaker_counts=book_counts)
                elif market=='CARDS':rs=analyze_count_market(hp,ap,'cards','CARDS',odds_map=om,market_stats=mq,consensus=cons,ref_profile=rp,sharp_map=sharp,bookmaker_counts=book_counts)
                else:rs=analyze_count_market(hp,ap,'corners','CORNERS',odds_map=om,market_stats=mq,consensus=cons,sharp_map=sharp,bookmaker_counts=book_counts)
                for r in rs:
                    r['market_bookmakers']=int(book_counts.get(r.get('selection',''),0))
                    row={'gid':gid,'date':m.get('dateUtc') or m.get('date'),'home':(m.get('homeTeam') or {}).get('name'),'away':(m.get('awayTeam') or {}).get('name'), 'league_id':league, **r}
                    if settings.calibration_enabled:
                        apply_calibration(row,rolling_samples,cutoff=str(row.get('date','')),min_samples=settings.calibration_min_samples,window=settings.calibration_window_matches)
                    predictions.append(row)
                    # In a historical walk-forward run, this settled observation becomes training data only for later matches.
                    try:
                        target=actual_for(fg)[market].get(r.get('selection'))
                        if target is not None:
                            rolling_samples.append({'date':row.get('date'),'league_id':league,'market':market,'selection':r.get('selection'),'p':float(row.get('p_raw',row.get('p',0))),'p_calibrated':float(row.get('p',0)),'market_prob':row.get('market_prob'),'components':row.get('component_attribution') or {},'y':1.0 if bool(target) else 0.0})
                    except Exception:
                        pass
                    diag['predictions_by_market'][market] += 1
            team_hist[h].append(extract_team_game(fg,h));team_hist[a].append(extract_team_game(fg,a))
        # Chronological portfolio simulation: select bets separately for each match-day.
        # This avoids look-ahead-like portfolio selection across the entire historical sample.
        by_day=defaultdict(list)
        for p in predictions:
            by_day[str(p.get('date',''))[:10]].append(p)
        for p in predictions:
            if int(p.get('market_bookmakers',0)) < 3: diag['thin_predictions'] += 1
            if float(p.get('robust_ev',0) or 0) <= 0: diag['robust_ev_nonpositive'] += 1
            if float(p.get('qcs',0) or 0) < 78: diag['qcs_below_78'] += 1
            if float(p.get('ev',0) or 0) < .05: diag['ev_below_5'] += 1
            if float(p.get('robust_ev',0) or 0)>0 and float(p.get('qcs',0) or 0)>=78 and int(p.get('market_bookmakers',0))>=3:
                diag['eligible'] += 1
        selected=[]
        for day in sorted(by_day):
            selected.extend(select_portfolio(by_day[day],max_items=8,max_total_stake=.10))
        diag['portfolio_rejected']=max(0,diag['eligible']-len(selected))

        # Probability calibration is measured on every settled prediction, not only bets.
        # This separates model accuracy from portfolio profitability and prevents the
        # history panel from hiding useful probability errors behind a strict EV filter.
        calibration_by_market=defaultdict(list)
        for p in predictions:
            try:
                target=actual_for(full[str(p['gid'])])[p['market']].get(p['selection'])
                if target is None: continue
                prob=max(1e-6,min(1-1e-6,float(p.get('p',0))))
                y=1.0 if bool(target) else 0.0
                calibration_by_market[p['market']].append((prob,y))
            except Exception:
                continue

        calibration_samples=[]
        for p in predictions:
            try:
                target=actual_for(full[str(p['gid'])])[p['market']].get(p['selection'])
                if target is None: continue
                calibration_samples.append({'date':p.get('date'),'league_id':league,'market':p.get('market'),'selection':p.get('selection'),'p':float(p.get('p_raw',p.get('p',0))),'p_calibrated':float(p.get('p',0)),'market_prob':p.get('market_prob'),'components':p.get('component_attribution') or {},'y':1.0 if bool(target) else 0.0})
            except Exception: continue

        metrics={}
        for market in markets:
            ps=[p for p in predictions if p['market']==market]
            bets=[p for p in selected if p['market']==market]
            wins=losses=pushes=0;profit=staked=expected=0.0;curve=0.0;peak=0.0;max_dd=0.0;loss_streak=max_loss_streak=0
            for p in sorted(bets,key=lambda x:ts(x.get('date'))):
                act=actual_for(full[str(p['gid'])])[market].get(p['selection'])
                if act is None: continue
                stake=min(.02,float(p.get('stake') or 0))
                staked += stake
                expected += float(p.get('ev') or 0)*stake
                if act == 'PUSH':
                    pushes += 1; pl=0.0; loss_streak=0
                elif bool(act):
                    wins += 1; pl=(float(p['odds'])-1.0)*stake; loss_streak=0
                else:
                    losses += 1; pl=-stake; loss_streak += 1; max_loss_streak=max(max_loss_streak,loss_streak)
                profit += pl;curve += pl;peak=max(peak,curve);max_dd=max(max_dd,peak-curve)
            n=wins+losses+pushes;decisive=wins+losses
            metrics[market]={
                'predictions':len(ps),'portfolio_bets':n,'wins':wins,'losses':losses,'pushes':pushes,
                'hit_rate':float(wins)/float(decisive) if decisive else 0.0,'profit_units':profit,'staked_units':staked,
                'roi':float(profit)/float(staked) if staked else 0.0,'yield':float(profit)/float(staked) if staked else 0.0,
                'expected_profit_units':expected,'avg_ev':statistics.mean([p['ev'] for p in bets]) if bets else 0,
                'avg_robust_ev':statistics.mean([p['robust_ev'] for p in bets]) if bets else 0,
                'avg_prediction_ev':statistics.mean([p['ev'] for p in ps]) if ps else 0,
                'avg_prediction_robust_ev':statistics.mean([p['robust_ev'] for p in ps]) if ps else 0,
                'avg_qcs':statistics.mean([float(p.get('qcs',0) or 0) for p in ps]) if ps else 0,
                'avg_dcs':statistics.mean([float(p.get('dcs',0) or 0) for p in ps]) if ps else 0,
                'avg_market_score':statistics.mean([float(p.get('ms',0) or 0) for p in ps]) if ps else 0,
                'avg_bookmakers':statistics.mean([float(p.get('market_bookmakers',0) or 0) for p in ps]) if ps else 0,
                'thin_market_rate':(sum(1 for p in ps if bool(p.get('thin_market')))/len(ps)) if ps else 0,
                'price_anomaly_rate':(sum(1 for p in ps if bool(p.get('price_anomaly')))/len(ps)) if ps else 0,
                'market_conflict_rate':(sum(1 for p in ps if bool(p.get('market_conflict')))/len(ps)) if ps else 0,
                'sharp_data_rate':(sum(1 for p in ps if isinstance(p.get('sharp_guard'),dict) and (p.get('sharp_guard') or {}).get('sharp_close') is not None)/len(ps)) if ps else 0,
                'avg_sharp_score':statistics.mean([float((p.get('sharp_guard') or {}).get('score',0) or 0) for p in ps]) if ps else 0,
                'brier': (sum((float(p.get('p',0))- (1.0 if bool(actual_for(full[str(p['gid'])])[market].get(p['selection'])) else 0.0))**2 for p in ps if actual_for(full[str(p['gid'])])[market].get(p['selection']) is not None)/sum(1 for p in ps if actual_for(full[str(p['gid'])])[market].get(p['selection']) is not None)) if any(actual_for(full[str(p['gid'])])[market].get(p['selection']) is not None for p in ps) else None,
                'calibration_n': sum(1 for p in ps if actual_for(full[str(p['gid'])])[market].get(p['selection']) is not None),
                'max_drawdown_units':max_dd,'max_losing_streak':max_loss_streak,
                'avg_odds':statistics.mean([float(p.get('odds',0) or 0) for p in bets]) if bets else 0,
                'profit_factor':(sum((float(p.get('odds',0))-1.0)*min(.02,float(p.get('stake') or 0)) for p in bets if actual_for(full[str(p['gid'])])[market].get(p['selection']) is True) / max(sum(min(.02,float(p.get('stake') or 0)) for p in bets if actual_for(full[str(p['gid'])])[market].get(p['selection']) is False),1e-9)) if bets else 0,
                'selection_metrics':{},
            }
            if market == '1X2':
                for sel in ('1','X','2'):
                    sb=[p for p in bets if p.get('selection')==sel]
                    sw=sl=0; ss=sp=0.0
                    for p in sb:
                        act=actual_for(full[str(p['gid'])])[market].get(sel)
                        if act is None: continue
                        stake=min(.02,float(p.get('stake') or 0)); ss += stake
                        if act is True:
                            sw += 1; sp += (float(p['odds'])-1.0)*stake
                        elif act is False:
                            sl += 1; sp -= stake
                    metrics[market]['selection_metrics'][sel]={'bets':sw+sl,'wins':sw,'losses':sl,'roi':sp/ss if ss else 0.0,'profit_units':sp,'staked_units':ss}
            cal=calibration_by_market.get(market,[])
            if cal:
                brier=sum((p-y)**2 for p,y in cal)/len(cal)
                logloss=sum(-(y*math.log(max(p,1e-12))+(1-y)*math.log(max(1-p,1e-12))) for p,y in cal)/len(cal)
                bins=defaultdict(list)
                for p0,y0 in cal: bins[min(9,int(p0*10))].append((p0,y0))
                calerr=sum(abs(sum(p0 for p0,_ in vals)/len(vals)-sum(y0 for _,y0 in vals)/len(vals))*len(vals) for vals in bins.values())/len(cal)
                metrics[market].update({'calibration_n':len(cal),'brier':brier,'log_loss':logloss,'calibration_error':calerr})
            else:
                metrics[market].update({'calibration_n':0,'brier':None,'log_loss':None,'calibration_error':None})
        out={'league':league,'year':year,'matches':len(raw),'usable_full_matches':len(full),'missing_detail_matches':len(missing_ids),'detail_coverage':coverage,'integrity_status':integrity_status,'predictions':len(predictions),'portfolio_bets':len(selected),'diagnostics':diag,'one_x_two_coverage':{'complete_matches':diag.get('one_x_two_complete',0),'incomplete_matches':diag.get('one_x_two_incomplete',0),'missing_home':diag.get('one_x_two_missing_home',0),'missing_draw':diag.get('one_x_two_missing_draw',0),'missing_away':diag.get('one_x_two_missing_away',0)},'calibration_samples':calibration_samples,'metrics':metrics,'generated_at':datetime.datetime.utcnow().isoformat(),'engine':f'{ENGINE_VERSION} institutional no-ML: exact-date recovery + calibrated prediction layer + normalized market prior + bookmaker-integrity gate + chronological portfolio + diagnostics + player assembly + referee + sharp guard'}
        out['status']='ok' if integrity_status=='complete' else 'partial'
        DATA_DIR.mkdir(parents=True,exist_ok=True)
        if write_report:
            safe=f'{league}_{year}'
            with open(DATA_DIR / f'walkforward_{safe}.json','w',encoding='utf-8') as f: json.dump(out,f,ensure_ascii=False,indent=2)
            with open(DATA_DIR / 'walkforward_report.json','w',encoding='utf-8') as f: json.dump(out,f,ensure_ascii=False,indent=2)
        # Historical bets are persisted separately from live predictions so the
        # normal live-statistics table is not polluted by backtest results.
        from .db.store import Store
        db=Store()
        run_id=db.backtest_run_start(league,year)
        db.backtest_bets_save(run_id, selected, lambda r: actual_for(full[str(r['gid'])])[r['market']].get(r['selection']))
        db.backtest_run_finish(run_id,matches=len(raw),predictions=len(predictions),portfolio_bets=len(selected),status=out['status'])
        if progress:
            await progress('target_done', target_index, target_total, league, year, {'matches':len(raw),'predictions':len(predictions),'bets':len(selected)})
        return out

def main():
    p=argparse.ArgumentParser(description='SStats chronological walk-forward backtest. No ML, full deterministic engine.')
    p.add_argument('--league',type=int,required=True);p.add_argument('--year',type=int,required=True);p.add_argument('--limit',type=int,default=300);p.add_argument('--markets',default='1X2,GOALS,CARDS,CORNERS');p.add_argument('--stage',choices=['full','collect','analysis'],default='full')
    a=p.parse_args();print(json.dumps(asyncio.run(run(a.league,a.year,a.limit,[x.strip().upper() for x in a.markets.split(',')],stage=a.stage)),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
