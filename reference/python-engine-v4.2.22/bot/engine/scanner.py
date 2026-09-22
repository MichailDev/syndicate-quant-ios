from __future__ import annotations
import asyncio
import datetime as dt
from .data import extract_team_game, full_game
from .odds import flatten_odds,build_market_map,market_quality,consensus_odds,enrich_rows,classify_market,market_key,key_bookmakers,merge_odds_rows,one_x_two_complete
from .analysis import analyze_1x2,analyze_goals,analyze_count_market
from .referee import referee_profile
from .sharp import movement
from .portfolio import select_portfolio
from .calibration import load_samples, apply_calibration
from .player import extract_players
from ..backtest import actual_for

MARKETS = ('1X2','GOALS','CARDS','CORNERS')
LEAGUE_NAMES = {39:'Premier League',78:'Bundesliga',140:'La Liga',135:'Serie A',61:'Ligue 1',235:'Russian Premier League',2:'UEFA Champions League',3:'UEFA Europa League'}
TOP_LEAGUE_IDS = {39,78,140,135,61,235,2,3}
TOP_LEAGUE_NAME_ALIASES = (
    ('premier league',), ('bundesliga',), ('la liga',), ('serie a',),
    ('ligue 1',), ('russian premier league',), ('premier liga',),
    ('российская премьер-лига',), ('рпл',), ('champions league',),
    ('europa league',), ('conference league',),
)
EXCLUDE_TOKENS = ('friendly','friendlies','club friendly','international friendly','women','woman','female','femen','femin','dames','ladies','женщ','женск',"women's",'wsl','u19 women','u20 women','u21 women','u23 women')
# Deliberately narrow: generic words such as "international", "qualification"
# and "qualifying" are NOT exclusions by themselves because they also occur in
# UEFA club-competition qualification rounds.
NATIONAL_COMP_PHRASES = (
    'fifa world cup','world cup',"fifa women's world cup",
    'uefa euro','euro championship','european championship',
    'uefa nations league','nations league',
    'world championship', 'olympics', 'olympic football',
    'кубок мира','чемпионат мира','чемпионат европы','евро',
    'лига наций','олимпиада','олимпийские игры'
)
NATIONAL_TEAM_PHRASES = ('national team','national teams','national side','women national')



class Scanner:
    def __init__(self,api,store,settings):
        self.api=api;self.store=store;self.s=settings
        self._hist={};self._glicko={};self._full={};self._odds={}
        self.last_upcoming_diagnostics=''
        self._upcoming_cache={}

    @classmethod
    def _scope_text(cls, m):
        raw=m.get('raw') or {}
        parts=[]
        for k in ('league','tournament','competition','leagueName','tournamentName','competitionName'):
            v=raw.get(k)
            if isinstance(v,dict): parts += [str(v.get('name') or v.get('title') or '')]
            elif v: parts += [str(v)]
        for side in ('homeTeam','awayTeam'):
            obj=raw.get(side)
            if isinstance(obj,dict): parts += [str(obj.get('name') or obj.get('title') or '')]
            elif obj: parts += [str(obj)]
        parts += [str(m.get('league') or ''),str(m.get('homeTeam',{}).get('name') or ''),str(m.get('awayTeam',{}).get('name') or '')]
        return ' | '.join(parts).lower()

    @classmethod
    def _exclusion_reason(cls,m):
        text=cls._scope_text(m)
        # Friendly/women filtering is intentionally explicit and remains broad.
        for token in EXCLUDE_TOKENS:
            if token in text:
                return 'friendly_or_women', token
        # National competitions: require a known competition phrase. Do not use
        # generic "international/qualification/qualifying" substrings.
        for phrase in NATIONAL_COMP_PHRASES:
            if phrase in text:
                return 'national_competition', phrase
        names=[str(m.get('homeTeam',{}).get('name') or ''),str(m.get('awayTeam',{}).get('name') or '')]
        for n in names:
            nl=n.lower()
            for phrase in NATIONAL_TEAM_PHRASES:
                if phrase in nl:
                    return 'national_team', phrase
        return None, None

    @classmethod
    def _is_excluded_match(cls,m):
        reason,_=cls._exclusion_reason(m)
        return reason is not None

    @classmethod
    def _is_top_match(cls,m):
        lid=m.get('league_id')
        try:
            if int(lid) in TOP_LEAGUE_IDS: return True
        except Exception: pass
        text=cls._scope_text(m)
        # Include UEFA club competitions even if SStats introduces a new ID.
        if ('uefa champions league' in text or 'uefa europa league' in text or 'uefa conference league' in text): return True
        if ('champions league' in text or 'europa league' in text or 'conference league' in text) and 'women' not in text: return True
        # SStats can occasionally omit/rename league IDs in /Ls/List. Use
        # conservative competition-name aliases as a fallback.
        for aliases in TOP_LEAGUE_NAME_ALIASES:
            if any(a in text for a in aliases): return True
        return False

    @staticmethod
    def _rows(payload):
        if isinstance(payload,dict):
            for key in ('data','games','matches','items','results'):
                value=payload.get(key)
                if isinstance(value,list): return value
        return payload if isinstance(payload,list) else []

    @staticmethod
    def _id(obj,*keys):
        if not isinstance(obj,dict): return None
        for k in keys:
            v=obj.get(k)
            if v is not None and v!='': return v
        return None

    @classmethod
    def _game_id(cls,m):
        return cls._id(m,'id','gameId','gameID','eventId','eventID','matchId','matchID','flashId','flashID')

    @classmethod
    def _team(cls,m,side):
        obj=m.get(side+'Team') or m.get(side) or m.get(side+'team')
        if isinstance(obj,dict):
            tid=cls._id(obj,'id','teamId','teamID','flashId','flashID')
            name=cls._id(obj,'name','teamName','title') or '?'
            return tid,name
        tid=cls._id(m,side+'TeamId',side+'TeamID',side+'Id',side+'ID')
        return tid,(obj if isinstance(obj,str) else '?')

    @classmethod
    def _normalize_match(cls,m):
        gid=cls._game_id(m); hid,hn=cls._team(m,'home'); aid,an=cls._team(m,'away')
        if not gid or not hid or not aid:return None
        league_obj=m.get('league') or m.get('tournament') or m.get('competition') or {}
        if isinstance(league_obj,dict):
            league_name=cls._id(league_obj,'name','leagueName','title')
            league_id=cls._id(league_obj,'id','leagueId','leagueID')
        else:
            league_name=str(league_obj) if league_obj else None; league_id=None
        league_name=league_name or cls._id(m,'leagueName','tournamentName','competitionName')
        league_id=league_id or cls._id(m,'leagueId','leagueID','tournamentId','competitionId')
        date=m.get('date') or m.get('startTime') or m.get('startDate') or m.get('dateUtc') or m.get('startTimeUtc')
        return {'raw':m,'id':gid,'homeTeam':{'id':hid,'name':hn},'awayTeam':{'id':aid,'name':an},
                'date':date,'dateUtc':m.get('dateUtc') or m.get('startTimeUtc') or date,
                'league':league_name,'league_id':league_id}

    @classmethod
    def _game_meta(cls, fg):
        g=fg.get('game') if isinstance(fg,dict) else {}
        if not isinstance(g,dict): g={}
        league_obj=g.get('league') or g.get('tournament') or g.get('competition') or {}
        lname=None; lid=None
        if isinstance(league_obj,dict):
            lname=cls._id(league_obj,'name','leagueName','title','shortName')
            lid=cls._id(league_obj,'id','leagueId','leagueID','tournamentId','competitionId')
        elif league_obj:
            lname=str(league_obj)
        lname=lname or cls._id(g,'leagueName','tournamentName','competitionName','leagueTitle','tournamentTitle','competitionTitle')
        lid=lid or cls._id(g,'leagueId','leagueID','tournamentId','competitionId','competitionID')
        return lname,lid,g

    @staticmethod
    def _parse_api_datetime(value, naive_tz):
        if value is None or value == '':
            return None
        try:
            if isinstance(value, (int, float)):
                return dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
            text=str(value).strip()
            if text.replace('.', '', 1).isdigit():
                v=float(text)
                if v > 1e11: v /= 1000.0
                return dt.datetime.fromtimestamp(v, tz=dt.timezone.utc)
            x=dt.datetime.fromisoformat(text.replace('Z','+00:00'))
            return x if x.tzinfo else x.replace(tzinfo=naive_tz)
        except Exception:
            return None

    @classmethod
    def _select_today_start(cls, m, now_local, moscow):
        # SStats may provide both UTC and local representations. Prefer a
        # representation that is unambiguously inside today's Moscow window.
        # This avoids rejecting a valid match merely because one API field is
        # timezone-naive or encoded in a different convention.
        candidates=[]
        raw_utc=m.get('dateUtc')
        raw_local=m.get('date')
        x=cls._parse_api_datetime(raw_utc, dt.timezone.utc)
        if x is not None: candidates.append(('dateUtc', x.astimezone(moscow)))
        x=cls._parse_api_datetime(raw_local, moscow)
        if x is not None: candidates.append(('date', x.astimezone(moscow)))
        # First: today and still upcoming.
        for source, local in candidates:
            if local.date()==now_local.date() and local>now_local:
                return local, source, 'upcoming'
        # Second: today but already started, for diagnostics.
        for source, local in candidates:
            if local.date()==now_local.date():
                return local, source, 'started'
        # Third: a valid timestamp, but outside today's Moscow date.
        if candidates:
            return candidates[0][1], candidates[0][0], 'out_of_window'
        return None, None, 'invalid'

    async def upcoming(self,force=False,scope="all"):
        # LIVE FORECAST WINDOW: today only, Moscow time (UTC+3).
        # No Upcoming endpoint and no future-date fallback are used here.
        moscow=dt.timezone(dt.timedelta(hours=3))
        now_local=dt.datetime.now(moscow)
        today_local=now_local.date()
        today_iso=today_local.isoformat()
        cache_key=f'{scope}:{today_iso}'
        if isinstance(self._upcoming_cache,dict) and cache_key in self._upcoming_cache and not force:
            return self._upcoming_cache[cache_key]

        diagnostics=[]; candidates=[]

        async def fetch_endpoint(label, fn, attempts):
            last_err=None
            for i in range(1, attempts+1):
                try:
                    payload=await fn()
                    rows=self._rows(payload)
                    diagnostics.append(f'{label} retry#{i}: {len(rows)}')
                    if rows:
                        return rows
                except Exception as e:
                    last_err=str(e)[:180]
                    diagnostics.append(f'{label} retry#{i} ERROR: {last_err}')
                if i < attempts:
                    await asyncio.sleep(float(i))
            return []

        # Always query both exact-date endpoints once. One endpoint may return
        # only a partial slice (for example 40 matches) while /Ls/List contains
        # the broader daily set. Their union is then deduplicated below.
        rows_games=await fetch_endpoint(
            f'/Games/list Date={today_iso}',
            lambda: self.api.games(Date=today_iso, TimeZone=3, Limit=max(40, int(self.s.scan_matches)), Order=1),
            3)
        rows_ls=await fetch_endpoint(
            f'/Ls/List Date={today_iso}',
            lambda: self.api.flashscore_list(Date=today_iso, TimeZone=3, Limit=1000),
            3)
        candidates.extend(rows_games); candidates.extend(rows_ls)
        if not candidates:
            diagnostics.append('TODAY_DATA_TIMEOUT: no exact-date matches returned from SStats')

        seen=set();clean=[];invalid=0;out_of_window=0;started=0;duplicates=0;scope_excluded=0
        excluded={'friendly_or_women':0,'national_competition':0,'national_team':0}
        excluded_examples={'friendly_or_women':[],'national_competition':[],'national_team':[]}
        scope_examples=[]
        for raw in candidates:
            m=self._normalize_match(raw)
            if not m: invalid+=1; continue
            local, source, status = self._select_today_start(m, now_local, moscow)
            if status=='invalid': invalid+=1; continue
            if status=='started': started+=1; continue
            if status!='upcoming' or local.date()!=today_local:
                out_of_window+=1; continue
            # Canonicalize the match time so downstream analysis/display uses
            # one consistent Moscow/UTC representation.
            m['date']=local.isoformat()
            m['dateUtc']=local.astimezone(dt.timezone.utc).isoformat()
            gid=str(m['id'])
            if gid in seen:
                duplicates += 1; continue
            reason,token=self._exclusion_reason(m)
            if reason:
                excluded[reason]=excluded.get(reason,0)+1
                if len(excluded_examples.get(reason,[])) < 3:
                    excluded_examples.setdefault(reason,[]).append(f"{m.get('league') or '?'}: {m.get('homeTeam',{}).get('name','?')}–{m.get('awayTeam',{}).get('name','?')} [{token}]")
                continue
            if scope == 'top' and not self._is_top_match(m):
                scope_excluded += 1
                if len(scope_examples)<5:
                    scope_examples.append(f"{m.get('league') or '?'}: {m.get('homeTeam',{}).get('name','?')}–{m.get('awayTeam',{}).get('name','?')} [league_id={m.get('league_id')}]" )
                continue
            seen.add(gid);clean.append(m)
            if len(clean)>=self.s.scan_matches: break

        diagnostics.append(f'window=MOSCOW_TODAY({today_iso})')
        diagnostics.append(
            f'parsed_candidates={len(candidates)}, usable={len(clean)}, invalid_schema={invalid}, '
            f'already_started={started}, out_of_window={out_of_window}, duplicates={duplicates}, '
            f'scope_excluded={scope_excluded}, excluded_friendly_women={excluded.get("friendly_or_women",0)}, '
            f'excluded_national_comp={excluded.get("national_competition",0)}, excluded_national_team={excluded.get("national_team",0)}'
        )
        for k,items in excluded_examples.items():
            if items: diagnostics.append(f"{k}: " + ' || '.join(items))
        if scope_examples:
            diagnostics.append('scope_examples: ' + ' || '.join(scope_examples))
        self.last_upcoming_diagnostics=' | '.join(diagnostics)
        self._upcoming_cache[cache_key]=clean
        return clean

    async def settle_finished(self):
        ids=self.store.unsettled_game_ids(limit=100)
        if not ids:return 0
        sem=asyncio.Semaphore(2)
        async def one(gid):
            async with sem:
                try:
                    fg=full_game(await self.api.game(gid));g=fg.get('game') or {}
                    if int(g.get('status') or 0) not in (8,9,10,17,18):return 0
                    closing={}
                    try:
                        rows=flatten_odds(await self.api.odds(gid))
                        for market in MARKETS:
                            for key in build_market_map(enrich_rows(list(rows),market),market):
                                closing[(market,key)]=build_market_map(enrich_rows(list(rows),market),market).get(key)
                    except Exception:
                        pass
                    changed=self.store.settle_game(gid,actual_for(fg),closing);return 1 if changed else 0
                except Exception:return 0
        return sum(await asyncio.gather(*(one(gid) for gid in ids)))

    async def history(self,team_id):
        key=str(team_id)
        if key in self._hist:return self._hist[key]
        rows=[]
        try:
            p=await self.api.games(Team=team_id,Ended=True,Limit=self.s.lookback_matches,TimeZone=self.s.timezone,Order=-1)
            rows=self._rows(p)
        except Exception:
            try:
                p=await self.api.flashscore_list(Team=team_id,Ended='true',Limit=self.s.lookback_matches,TimeZone=self.s.timezone)
                rows=self._rows(p)
            except Exception: rows=[]
        sem=asyncio.Semaphore(2)
        async def one(x):
            async with sem:
                try:return extract_team_game(await self.api.game(self._game_id(x)),team_id)
                except Exception:
                    try:return extract_team_game(await self.api.flashscore_game_info(self._game_id(x)),team_id)
                    except Exception:return None
        vals=[v for v in await asyncio.gather(*(one(x) for x in rows)) if v]
        self._hist[key]=vals
        return vals

    async def glicko(self,gid):
        key=str(gid)
        if key in self._glicko:return self._glicko[key]
        try:self._glicko[key]=await self.api.glicko(gid)
        except Exception:self._glicko[key]=None
        return self._glicko[key]

    async def full(self,gid):
        key=str(gid)
        if key in self._full:return self._full[key]
        try:self._full[key]=full_game(await self.api.game(gid))
        except Exception:
            try:self._full[key]=full_game(await self.api.flashscore_game_info(gid))
            except Exception:self._full[key]={}
        return self._full[key]

    async def odds_bundle(self,gid,fg):
        """Return closing/opening rows with an automatic Flashscore fallback.

        /Odds/{id} expects the canonical SStats game id. /Ls/List can return
        Flashscore-style ids, for which /Odds may return 404. GameInfo is the
        documented fallback and contains bookmaker odds.
        """
        key=str(gid)
        if key in self._odds:return self._odds[key]
        close=[];opening=[];source='none';errors=[]
        try:
            close=flatten_odds(await self.api.odds(gid));source='Odds'
        except Exception as e: errors.append(str(e)[:100])
        # Opening=true is not accepted consistently by all SStats deployments.
        # Treat 404/429 as unavailable rather than failing the whole match.
        try:
            opening=flatten_odds(await self.api.odds(gid,opening=True))
        except Exception:
            opening=[]

        recognized={classify_market(r.get('market')) for r in close}
        recognized.discard(None)
        needed={'1X2','GOALS','CARDS','CORNERS'}
        x2=one_x_two_complete(close)
        if not close or not (recognized & needed-{ '1X2' }) or not x2['complete']:
            try:
                fallback=flatten_odds(fg)
                if fallback:
                    close=merge_odds_rows(close,fallback);source='Odds+Ls/GameInfo' if source=='Odds' else 'Ls/GameInfo'
                    if not opening:
                        opening=[r for r in fallback if r.get('opening') not in (None,'')]
            except Exception as e: errors.append(f'GameInfo odds: {str(e)[:80]}')
        self._odds[key]=(close,opening,source,errors)
        return self._odds[key]

    async def analyze_match_markets(self,m,markets):
        gid=m.get('id');h=m.get('homeTeam') or {};a=m.get('awayTeam') or {};hid=h.get('id');aid=a.get('id')
        if not gid or not hid or not aid:return []
        hp,ap,fg,gk=await asyncio.gather(self.history(hid),self.history(aid),self.full(gid),self.glicko(gid))
        od,op,source,od_errors=await self.odds_bundle(gid,fg)
        referee=(fg.get('refereeName') or (fg.get('game') or {}).get('refereeName'))
        ph=extract_players(fg,hid);pa=extract_players(fg,aid)
        all_results=[]
        snapshot_base={'match':m,'full':fg,'odds':od,'opening_odds':op,'glicko':gk,'odds_source':source,'odds_errors':od_errors,'referee':referee}
        for market in markets:
            rows=enrich_rows(list(od),market);open_rows=enrich_rows(list(op),market)
            om=build_market_map(rows,market);mq=market_quality(rows,market)
            cons={k:consensus_odds(rows,market,k) for k in om}
            sharp={k:movement(open_rows,rows,market,k) for k in om}
            rp=referee_profile(hp+ap,referee,'cards') if market=='CARDS' else None
            book_counts={k:len(key_bookmakers(rows, market, k)) for k in om}
            kw={'odds_map':om,'market_stats':mq,'consensus':cons,'player_home':ph,'player_away':pa,'sharp_map':sharp,'bookmaker_counts':book_counts}
            if market=='1X2': rs=analyze_1x2(hp,ap,glicko=gk,**kw)
            elif market=='GOALS': rs=analyze_goals(hp,ap,glicko=gk,**kw)
            elif market=='CARDS': rs=analyze_count_market(hp,ap,'cards','CARDS',ref_profile=rp,**kw)
            elif market=='CORNERS': rs=analyze_count_market(hp,ap,'corners','CORNERS',**kw)
            else: rs=[]
            for r in rs:
                # Integrity is enforced inside pricing, before portfolio selection.
                r['market_bookmakers'] = int(book_counts.get(r.get('selection',''),0))
                league_name,league_id,game_meta=self._game_meta(fg)
                league_id = m.get('league_id') or league_id
                league_name = m.get('league') or league_name or (LEAGUE_NAMES.get(int(league_id)) if str(league_id).isdigit() else None)
                base_date=m.get('date') or game_meta.get('date') or game_meta.get('startTime') or game_meta.get('dateUtc')
                date_utc=m.get('dateUtc') or game_meta.get('dateUtc') or game_meta.get('startTimeUtc') or base_date
                r.update(game_id=gid,home=h.get('name','?'),away=a.get('name','?'),date=base_date,
                         date_utc=date_utc, league=league_name,
                         league_id=league_id,price_status='HISTORICAL/CLOSING',odds_source=source)
                # Never allow an already-started or undated match into a new forecast.
                try:
                    raw_dt=date_utc
                    if isinstance(raw_dt,(int,float)):
                        x=dt.datetime.fromtimestamp(float(raw_dt),tz=dt.timezone.utc)
                    else:
                        txt=str(raw_dt).strip()
                        if txt.replace('.', '', 1).isdigit():
                            v=float(txt); v=v/1000 if v>1e11 else v
                            x=dt.datetime.fromtimestamp(v,tz=dt.timezone.utc)
                        else:
                            x=dt.datetime.fromisoformat(txt.replace('Z','+00:00'))
                            if x.tzinfo is None: x=x.replace(tzinfo=dt.timezone.utc)
                    local=x.astimezone(dt.timezone(dt.timedelta(hours=self.s.timezone)))
                    now=dt.datetime.now(dt.timezone(dt.timedelta(hours=self.s.timezone)))
                    r['pre_match_time_valid'] = local > now
                except Exception:
                    r['pre_match_time_valid'] = False
                # Institutional data-integrity gate: a BET requires identity metadata.
                r['data_integrity'] = bool(r.get('league') and r.get('date_utc') and source != 'none' and r.get('pre_match_time_valid', False) and r.get('market_bookmakers',0) >= 3 and r.get('odds',0) > 1)
                r['sharp_label'] = ('VERIFIED '+str(round(float((r.get('sharp_guard') or {}).get('score',0))))+' / 100') if ((r.get('sharp_guard') or {}).get('sharp_close') or (r.get('sharp_guard') or {}).get('sharp_open')) else 'N/A'
                r['player_adjustment_label'] = 'CALC' if (r.get('component_attribution') or {}).get('player_assembly') is not None else 'N/A'
                r['referee_adjustment_label'] = 'CALC' if (r.get('component_attribution') or {}).get('referee') is not None else 'N/A'
                all_results.append(r)
        # Leakage-safe calibration: only reports dated before this match are eligible.
        try:
            cal_samples=load_samples()
            cutoff=str(date_utc or '')
            for rr in all_results:
                if rr.get('game_id')==gid:
                    if getattr(self.s,'calibration_enabled',True):
                        apply_calibration(rr,cal_samples,cutoff=cutoff,min_samples=getattr(self.s,'calibration_min_samples',25),window=getattr(self.s,'calibration_window_matches',500))
                    rr['calibration_enabled']=bool(rr.get('calibration',{}).get('source')!='NONE')
        except Exception:
            pass
        self.store.snapshot(gid,{**snapshot_base,'markets':markets})
        return all_results

    async def scan_many(self,markets,scope="all"):
        markets=[m for m in markets if m in MARKETS]
        games=await self.upcoming(scope=scope);results=[];errors=[];sem=asyncio.Semaphore(2)
        async def one(m):
            async with sem:
                try:return m,await self.analyze_match_markets(m,markets),None
                except Exception as e:return m,[],e
        for m,rs,err in await asyncio.gather(*(one(x) for x in games)):
            if err:errors.append(f'{m.get("id")}: {type(err).__name__}: {str(err)[:140]}');continue
            results.extend(rs)
        if not games:
            raise RuntimeError('SStats не вернул пригодных предстоящих матчей. Диагностика: '+self.last_upcoming_diagnostics)
        if errors and not results:
            raise RuntimeError('Матчи найдены, но анализ не выполнен. '+self.last_upcoming_diagnostics+' | '+' ; '.join(errors[:5]))
        results=[r for r in results if r.get('data_integrity',False)]
        # Prediction layer contains every valid modeled outcome; Bet layer is a strict
        # execution subset selected later by portfolio rules.
        for r in results:
            r['prediction_layer']['scope']=scope
            r['bet_layer']['data_integrity']=bool(r.get('data_integrity'))
        if not results:
            raise RuntimeError('Нет сигналов с полной идентификацией матча (лига/дата/котировки). '+self.last_upcoming_diagnostics)
        return sorted(results,key=lambda x:(x.get('robust_ev',-999),x.get('qcs',0)),reverse=True)

    async def scan(self,market,scope="all"):
        return await self.scan_many([market],scope=scope)

    async def scan_portfolio(self,markets,scope="all"):
        allr=await self.scan_many(markets,scope=scope)
        return select_portfolio(allr,max_items=getattr(self.s,'portfolio_max_bets',8),max_total_stake=getattr(self.s,'daily_max_stake_pct',.10))
