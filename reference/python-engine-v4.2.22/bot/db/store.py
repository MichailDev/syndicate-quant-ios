from __future__ import annotations
import json, sqlite3, pathlib, datetime

BASE_DIR = pathlib.Path(__file__).resolve().parents[2]
DATA_DIR = BASE_DIR / 'data'

class Store:
    def __init__(self, path=None):
        path = path or str(DATA_DIR / 'syndicate.db')
        pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        with sqlite3.connect(path) as c:
            c.execute('CREATE TABLE IF NOT EXISTS snapshots(id INTEGER PRIMARY KEY,game_id TEXT,fetched_at TEXT,payload TEXT)')
            c.execute('CREATE TABLE IF NOT EXISTS predictions(id INTEGER PRIMARY KEY,game_id TEXT,fetched_at TEXT,market TEXT,selection TEXT,odds REAL,p REAL,p_low REAL,fair REAL,ev REAL,robust_ev REAL,qcs REAL,dcs REAL,stake REAL,verdict TEXT,model TEXT,n REAL,consensus_odds REAL,price_status TEXT,settled INTEGER DEFAULT 0,actual REAL,profit REAL)')
            c.execute('CREATE TABLE IF NOT EXISTS daily_forecasts(forecast_date TEXT PRIMARY KEY,created_at TEXT,payload TEXT)')
            c.execute('CREATE INDEX IF NOT EXISTS ix_pred_game ON predictions(game_id)')
            c.execute('CREATE INDEX IF NOT EXISTS ix_pred_settle ON predictions(settled)')
            c.execute('CREATE TABLE IF NOT EXISTS backtest_runs(id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT, finished_at TEXT, league_id INTEGER, season INTEGER, matches INTEGER, predictions INTEGER, portfolio_bets INTEGER, status TEXT, error TEXT)')
            c.execute('CREATE TABLE IF NOT EXISTS backtest_bets(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, game_id TEXT, match_date TEXT, league_id INTEGER, season INTEGER, market TEXT, selection TEXT, odds REAL, p REAL, fair REAL, ev REAL, robust_ev REAL, qcs REAL, stake REAL, verdict TEXT, actual REAL, profit REAL, FOREIGN KEY(run_id) REFERENCES backtest_runs(id))')
            for col, typ in [('line','REAL'),('sim_p','REAL'),('ms','REAL'),('sharp_json','TEXT'),('meta_json','TEXT'),('clv','REAL'),('settled_at','TEXT'),('forecast_date','TEXT')]:
                try: c.execute(f'ALTER TABLE predictions ADD COLUMN {col} {typ}')
                except sqlite3.OperationalError: pass

    def backtest_run_start(self, league_id, season):
        with sqlite3.connect(self.path) as c:
            cur=c.execute('INSERT INTO backtest_runs(started_at,league_id,season,status) VALUES(?,?,?,?)', (datetime.datetime.utcnow().isoformat(), int(league_id), int(season), 'running'))
            return cur.lastrowid

    def backtest_run_finish(self, run_id, matches=0, predictions=0, portfolio_bets=0, status='ok', error=None):
        with sqlite3.connect(self.path) as c:
            c.execute('UPDATE backtest_runs SET finished_at=?,matches=?,predictions=?,portfolio_bets=?,status=?,error=? WHERE id=?', (datetime.datetime.utcnow().isoformat(), int(matches), int(predictions), int(portfolio_bets), status, error, int(run_id)))

    def backtest_bets_save(self, run_id, rows, actual_fn):
        if not rows: return 0
        n=0
        with sqlite3.connect(self.path) as c:
            for r in rows:
                try:
                    actual=actual_fn(r)
                    if actual is None: continue
                    if actual == 'PUSH': profit=0.0
                    elif bool(actual): profit=(float(r.get('odds') or 0)-1.0)*float(r.get('stake') or 0)
                    else: profit=-float(r.get('stake') or 0)
                    c.execute('INSERT INTO backtest_bets(run_id,game_id,match_date,league_id,season,market,selection,odds,p,fair,ev,robust_ev,qcs,stake,verdict,actual,profit) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', (int(run_id),str(r.get('gid')),r.get('date'),int(r.get('league_id') or 0),int(r.get('season') or 0),r.get('market'),r.get('selection'),r.get('odds'),r.get('p'),r.get('fair'),r.get('ev'),r.get('robust_ev'),r.get('qcs'),r.get('stake'),r.get('classification'),0.5 if actual=='PUSH' else (1.0 if bool(actual) else 0.0),profit))
                    n+=1
                except Exception:
                    continue
        return n

    def snapshot(self, game_id, payload):
        with sqlite3.connect(self.path) as c:
            c.execute('INSERT INTO snapshots(game_id,fetched_at,payload) VALUES(?,?,?)', (str(game_id), datetime.datetime.utcnow().isoformat(), json.dumps(payload, ensure_ascii=False, default=str)))

    def prediction(self, game_id, r):
        with sqlite3.connect(self.path) as c:
            exists = c.execute('SELECT 1 FROM predictions WHERE game_id=? AND market=? AND selection=? AND settled=0 LIMIT 1', (str(game_id), r.get('market'), r.get('selection'))).fetchone()
            if exists: return
            c.execute('''INSERT INTO predictions(game_id,fetched_at,market,selection,odds,p,p_low,fair,ev,robust_ev,qcs,dcs,stake,verdict,model,n,consensus_odds,price_status,line,sim_p,ms,sharp_json,meta_json,forecast_date) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                      (str(game_id),datetime.datetime.utcnow().isoformat(),r.get('market'),r.get('selection'),r.get('odds'),r.get('p'),r.get('p_low'),r.get('fair'),r.get('ev'),r.get('robust_ev'),r.get('qcs'),r.get('dcs'),r.get('stake'),r.get('classification'),r.get('model'),r.get('n'),r.get('consensus_odds'),r.get('price_status'),r.get('line'),r.get('sim_p'),r.get('ms'),json.dumps(r.get('sharp_guard') or {},ensure_ascii=False),json.dumps(r,ensure_ascii=False,default=str), r.get('forecast_date')))


    def save_daily_forecast(self, forecast_date, rows):
        """Replace today's stored forecast with the latest Prognos result."""
        with sqlite3.connect(self.path) as c:
            c.execute(
                'INSERT OR REPLACE INTO daily_forecasts(forecast_date,created_at,payload) VALUES(?,?,?)',
                (str(forecast_date), datetime.datetime.utcnow().isoformat(),
                 json.dumps(rows, ensure_ascii=False, default=str))
            )

    def daily_forecast(self, forecast_date):
        with sqlite3.connect(self.path) as c:
            row = c.execute(
                'SELECT created_at,payload FROM daily_forecasts WHERE forecast_date=?',
                (str(forecast_date),)
            ).fetchone()
        if not row:
            return None
        try:
            payload = json.loads(row[1])
        except Exception:
            payload = []
        return {'created_at': row[0], 'rows': payload if isinstance(payload, list) else []}

    def unsettled_game_ids(self, limit=100):
        with sqlite3.connect(self.path) as c:
            return [r[0] for r in c.execute('SELECT DISTINCT game_id FROM predictions WHERE settled=0 LIMIT ?', (int(limit),)).fetchall()]

    def settle_game(self, game_id, actual, closing_odds=None):
        with sqlite3.connect(self.path) as c:
            rows = c.execute('SELECT id,selection,odds,market,stake FROM predictions WHERE game_id=? AND settled=0', (str(game_id),)).fetchall()
            changed=0
            for pid, sel, odds, market, stake in rows:
                outcome = (actual.get(market, {}) if isinstance(actual, dict) else {}).get(sel)
                if outcome is None: continue
                stake = float(stake or 0)
                if outcome == 'PUSH':
                    actual_value, profit = 0.5, 0.0
                else:
                    win = bool(outcome); actual_value = 1.0 if win else 0.0
                    profit = (float(odds)-1.0)*stake if win else -stake
                close = None
                try: close = float((closing_odds or {}).get((market,sel))) if (closing_odds or {}).get((market,sel)) else None
                except Exception: close = None
                clv = ((1.0/close)/(1.0/float(odds))-1.0) if close and float(odds)>1 and close>1 else None
                # Persist settled live observations as incremental calibration
                # feedback. This is intentionally append-only and contains no
                # future information at prediction time.
                try:
                    meta=json.loads((c.execute('SELECT meta_json FROM predictions WHERE id=?',(pid,)).fetchone() or ['{}'])[0] or '{}')
                    sample={
                        'game_id':str(game_id),'date':meta.get('date_utc') or meta.get('date') or meta.get('match_date'),
                        'league_id':meta.get('league_id'),'market':market,'selection':sel,
                        'p':float(meta.get('p_raw',meta.get('p',0)) or 0),
                        'p_calibrated':float(meta.get('p',0) or 0),
                        'market_prob':meta.get('market_prob'),'components':meta.get('component_attribution') or {},
                        'y':actual_value
                    }
                    if sample['date'] is not None and market:
                        pathlib.Path(self.path).parent.mkdir(parents=True,exist_ok=True)
                        with open(pathlib.Path(self.path).parent/'live_calibration_samples.jsonl','a',encoding='utf-8') as lf:
                            lf.write(json.dumps(sample,ensure_ascii=False,default=str)+'\n')
                except Exception:
                    pass
                c.execute('UPDATE predictions SET settled=1,actual=?,profit=?,clv=?,settled_at=? WHERE id=?', (actual_value, profit, clv, datetime.datetime.utcnow().isoformat(), pid))
                changed += 1
            return changed

    def daily_report(self, forecast_date, timezone_offset=0):
        """Return settled live prediction statistics for a local forecast date."""
        import datetime as _dt
        target=str(forecast_date)
        with sqlite3.connect(self.path) as c:
            rows=c.execute('SELECT market,selection,odds,p,ev,stake,actual,profit,settled_at,forecast_date,meta_json FROM predictions WHERE settled=1').fetchall()
        selected=[]
        tz=_dt.timezone(_dt.timedelta(hours=int(timezone_offset)))
        for row in rows:
            fd=row[9]
            if fd and str(fd)[:10]==target:
                selected.append(row)
                continue
            # Backward compatibility: infer local match date from stored metadata.
            try:
                meta=json.loads(row[10] or '{}')
                raw=meta.get('date_utc') or meta.get('date') or meta.get('match_date')
                if raw:
                    x=_dt.datetime.fromisoformat(str(raw).replace('Z','+00:00'))
                    if x.tzinfo is None: x=x.replace(tzinfo=_dt.timezone.utc)
                    if x.astimezone(tz).date().isoformat()==target:
                        selected.append(row)
            except Exception:
                pass
        wins=sum(1 for r in selected if r[6]==1.0); losses=sum(1 for r in selected if r[6]==0.0); pushes=sum(1 for r in selected if r[6]==0.5)
        staked=sum(float(r[5] or 0) for r in selected); profit=sum(float(r[7] or 0) for r in selected)
        decisive=wins+losses
        return {'date':target,'bets':len(selected),'wins':wins,'losses':losses,'pushes':pushes,'hit_rate':wins/decisive if decisive else 0,'staked_units':staked,'profit_units':profit,'roi':profit/staked if staked else 0,'rows':selected}

    def stats(self):
        with sqlite3.connect(self.path) as c:
            rows = c.execute('SELECT odds,p,ev,stake,actual,profit FROM predictions WHERE settled=1').fetchall()
        total = len(rows)
        wins = sum(1 for r in rows if r[4] == 1.0)
        losses = sum(1 for r in rows if r[4] == 0.0)
        pushes = sum(1 for r in rows if r[4] == 0.5)
        decisive = wins + losses
        staked = sum(float(r[3] or 0) for r in rows)
        profit = sum(float(r[5] or 0) for r in rows)
        avg_ev = sum(float(r[2] or 0) for r in rows)/total if total else 0
        avg_odds = sum(float(r[0] or 0) for r in rows)/total if total else 0
        expected_profit = sum(float(r[2] or 0)*float(r[3] or 0) for r in rows)
        return {'bets':total,'wins':wins,'losses':losses,'pushes':pushes,'hit_rate':wins/decisive if decisive else 0,
                'profit_units':profit,'staked_units':staked,'roi':profit/staked if staked else 0,'yield':profit/staked if staked else 0,
                'avg_ev':avg_ev,'expected_profit':expected_profit,'avg_odds':avg_odds}
