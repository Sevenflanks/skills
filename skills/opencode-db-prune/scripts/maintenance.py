"""Plan by default; rebuild/promote require explicit per-invocation execution flags."""
import argparse
import contextlib
from datetime import datetime
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import time
import uuid

import rebuild


def freeze_cutoff(now, days):
    if now.utcoffset() is None or not 1 <= days <= 36500:
        raise RuntimeError('Expected an aware timestamp and positive retention days')
    # 30 天固定為 720 小時；以 timestamp 相減，避免跨 DST 變成 719/721 小時。
    cutoff_ms = int(now.timestamp()*1000) - days*86400000
    cutoff = datetime.fromtimestamp(cutoff_ms/1000, now.tzinfo)
    return cutoff_ms, cutoff.isoformat(timespec='milliseconds')


def source_default():
    data = Path(os.environ.get('XDG_DATA_HOME', Path.home()/'.local'/'share'))
    return data/'opencode'/'opencode.db'


def discover_deja(executable=None):
    names = ('deja.exe','deja.cmd','deja.ps1','deja') if os.name=='nt' else ('deja',)
    path = str(executable) if executable is not None else next((p for n in names if (p:=shutil.which(n))),None)
    if path is None and executable is None and os.name=='nt':
        # Python 3.11 的 which 會忽略 PATHEXT 未列出的 .ps1；只補查明確
        # PATH 目錄中的既定檔名，不搜尋整顆磁碟，也不執行候選程式。
        path = next((str(Path(folder)/name) for folder in os.get_exec_path() if folder
                     for name in names[:-1] if (Path(folder)/name).is_file()),None)
    if path and Path(path).is_file():
        return {'detected':True, 'executable':str(Path(path).absolute())}
    if executable is not None:
        raise RuntimeError('Specified Deja executable was not found')
    return {'detected':False, 'executable':None}


def external_defaults(source, deja=None):
    cache = Path(os.environ.get('XDG_CACHE_HOME', Path.home()/'.cache'))
    paths = [str(source.parent/'storage'/'session_diff')]
    index = cache/'deja'/'index.db'
    # Deja 是選用整合；只保護已存在的 cache，或已偵測整合的預期 cache。
    if index.exists() or (deja or {}).get('detected'):
        paths.append(str(index))
    return paths


def value_bytes(value):
    if isinstance(value, str):
        return len(value.encode('utf-8'))
    if isinstance(value, bytes):
        return len(value)
    return 8 if value is not None else 0


def profile(source, cutoff_ms, max_seconds, mode='compact'):
    """Read a SQLite snapshot; only emit aggregate sizes/counts, never row values."""
    started = last = time.monotonic()
    with contextlib.closing(rebuild.ro(source)) as db:
        db.set_progress_handler(lambda: int(time.monotonic()-started > max_seconds), 100000)
        db.execute('BEGIN')
        schema = rebuild.check_schema(db,mode)
        session_count,recent=rebuild.session_retention(db,mode,cutoff_ms)
        tables = {}
        payload = rows = 0
        for table in sorted(r[1] for r in schema if r[0]=='table'):
            columns, explicit = rebuild.table_info(db, table)
            offset = int(explicit)
            total = db.execute('SELECT count(*) FROM '+rebuild.quote(table)).fetchone()[0]
            kept = changed = size = 0
            for raw,row in rebuild.retained_rows(db,table,columns,explicit,recent,mode):
                if time.monotonic()-started > max_seconds:
                    raise RuntimeError('Estimate deadline reached; source unchanged')
                changed += int(tuple(row)!=tuple(raw))
                kept += 1
                size += sum(map(value_bytes, row))
                if time.monotonic()-last > 15:
                    rebuild.emit('estimating', table=table, kept_rows=kept)
                    last = time.monotonic()
            tables[table] = {'source_rows':total, 'retained_rows':kept,
                             'removed_rows':total-kept, 'changed_json_rows':changed}
            payload += size
            rows += kept
        # dbstat 是選用能力；沒有它時採來源 logical size，保守估算索引暫存需求。
        page_size = db.execute('PRAGMA page_size').fetchone()[0]
        logical = page_size*db.execute('PRAGMA page_count').fetchone()[0]
        try:
            index_bytes = db.execute("SELECT coalesce(sum(pgsize),0) FROM dbstat WHERE name IN "
                                     "(SELECT name FROM sqlite_schema WHERE type='index')").fetchone()[0]
        except sqlite3.OperationalError:
            index_bytes = logical
        lower = payload + rows*32 + index_bytes
        upper = math.ceil((payload+rows*256)*1.5) + index_bytes
        return {'retention_mode':mode,'session_count':session_count, 'protected_sessions':len(recent), 'tables':tables,
                'estimated_candidate_bytes':{'lower':lower, 'upper':upper},
                'index_temp_budget_bytes':2*index_bytes,
                'estimate_is_preliminary':True, 'elapsed_seconds':round(time.monotonic()-started,1)}


def quick_audit(source, min_reclaim_gib=1, min_free_ratio=0.1):
    """Only pager/schema metadata; no history rows, checkpoint or size prediction."""
    if not math.isfinite(min_reclaim_gib) or min_reclaim_gib < 0 or not 0 <= min_free_ratio <= 1:
        raise RuntimeError('Invalid quick audit thresholds')
    source=Path(source).absolute()
    before=rebuild.identity(source)
    with contextlib.closing(rebuild.ro(source)) as db:
        db.execute('BEGIN')
        page_size=db.execute('PRAGMA page_size').fetchone()[0]
        pages=db.execute('PRAGMA page_count').fetchone()[0]
        free=db.execute('PRAGMA freelist_count').fetchone()[0]
        compatibility=rebuild.schema_diagnostics(db)
    # Files may still be changing: these observations are advisory, never an offline gate.
    sidecars={suffix:Path(str(source)+suffix).stat().st_size
              for suffix in ('-wal','-shm','-journal') if Path(str(source)+suffix).exists()}
    worthwhile=free*page_size >= min_reclaim_gib*2**30 and free/max(pages,1) >= min_free_ratio
    return {'source_main_bytes':before['size'],'sidecar_bytes':sidecars,'page_size':page_size,
            'page_count':pages,'freelist_count':free,'freelist_bytes':free*page_size,
            'freelist_ratio':free/max(pages,1),'schema':compatibility,
            'recommendation':('review_schema' if not compatibility['supported'] else
                              'estimate_compact' if worthwhile else 'skip_or_request_full_estimate'),
            'note':'Advisory snapshot only. Freelist bytes are not guaranteed reclaim; aggressive benefit needs a full estimate.'}


def create_plan(source, run_root, days=None, reserve_gib=8, external_paths=None, max_seconds=1800,
                mode='compact', deja_executable=None, original='keep'):
    rebuild.retention_mode({'retention_mode':mode})
    rebuild.original_disposition({'original_disposition':original})
    deja = discover_deja(deja_executable)
    if mode=='compact' and days is not None:
        raise RuntimeError('The days option applies only to aggressive mode; compact preserves all history')
    source = Path(source).absolute()
    if not source.is_file() or source.resolve()!=source or rebuild.identity(source)['links']!=1:
        raise RuntimeError('Expected a regular, unlinked source database')
    if not math.isfinite(reserve_gib) or reserve_gib < 1:
        raise RuntimeError('Reserve must be at least 1 GiB')
    run_root = Path(run_root).absolute()
    preserved = list(dict.fromkeys(external_defaults(source,deja)+list(map(str,external_paths or []))))
    protected = [source.parent] + [Path(p).absolute() for p in preserved]
    if any(run_root==p or p in run_root.parents for p in protected):
        raise RuntimeError('Run artifacts must be outside the source and preserved data directories')
    now = datetime.now().astimezone()
    if mode=='aggressive':
        days = 30 if days is None else days
        cutoff_ms, cutoff_iso = freeze_cutoff(now, days)
    else:
        cutoff_ms = cutoff_iso = None
    before = rebuild.identity(source)
    audit = profile(source, cutoff_ms, max_seconds,mode)
    run_id = now.strftime('%Y%m%dT%H%M%S')+'-'+uuid.uuid4().hex[:12]
    run_dir = run_root/run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    needed = audit['estimated_candidate_bytes']['upper'] + audit['index_temp_budget_bytes'] + reserve_gib*2**30
    policy = {
        'format_version':3, 'retention_mode':mode, 'original_disposition':original, 'run_id':run_id,
        'created_at':now.isoformat(), 'retention_days':days,
        'cutoff_ms':cutoff_ms, 'cutoff_iso':cutoff_iso,
        'source_db':str(source), 'source_file_id_at_plan':{k:before[k] for k in ('device','inode')},
        'candidate_db':str(source.parent/(source.stem+'.candidate-'+run_id+'.db')),
        'rollback_db':str(source.parent/(source.stem+'.rollback-'+run_id+'.db')),
        'minimum_free_gib_before_build':math.ceil(needed/2**30),
        'minimum_free_gib_before_temp':math.ceil(audit['index_temp_budget_bytes']/2**30+reserve_gib),
        'minimum_free_gib_during_build':reserve_gib,
        'preserve_external_paths':[str(Path(p).absolute()) for p in preserved],
        'integrations':{'deja':deja},
    }
    audit.update(original_disposition=original,reclaim_requires_original_removal=True,
                 estimated_net_freed_after_promotion_bytes={
                     'lower':(-audit['estimated_candidate_bytes']['upper'] if original=='keep' else before['size']-audit['estimated_candidate_bytes']['upper']),
                     'upper':(-audit['estimated_candidate_bytes']['lower'] if original=='keep' else before['size']-audit['estimated_candidate_bytes']['lower'])},
                 source_main_bytes=before['size'], cutoff=cutoff_iso, retention_days=days,
                 observed_free_bytes=shutil.disk_usage(source.parent).free,
                 recommended_start_free_bytes=needed,
                 estimated_reclaim_bytes={
                     'lower':before['size']-audit['estimated_candidate_bytes']['upper'],
                     'upper':before['size']-audit['estimated_candidate_bytes']['lower']},
                 policy_sha256=rebuild.policy_hash(policy),
                 integrations=policy['integrations'],
                 note='Estimate only. No checkpoint, rebuild, replacement or deletion was performed.')
    rebuild.write_report(run_dir/'policy.json', policy)
    rebuild.write_report(run_dir/'estimate.json', audit)
    rebuild.emit('plan_ready', run_directory=str(run_dir), **audit)
    return policy, audit, run_dir


def load_policy(path):
    policy = json.loads(Path(path).read_text(encoding='utf-8'))
    if policy.get('format_version')!=3:
        raise RuntimeError('Unsupported policy format')
    mode=rebuild.retention_mode(policy)
    rebuild.original_disposition(policy)
    if mode=='aggressive':
        if round(datetime.fromisoformat(policy['cutoff_iso']).timestamp()*1000)!=policy['cutoff_ms']:
            raise RuntimeError('Cutoff fields disagree')
    elif any(policy.get(k) is not None for k in ('cutoff_ms','cutoff_iso','retention_days')):
        raise RuntimeError('Compact mode must preserve all history without a cutoff')
    return policy


def inspect_run(policy, report_path, verify_hashes=False):
    """Read paths as bytes/stat only. Never open SQLite, replay WAL, retry or delete."""
    report_path=Path(report_path)
    report=json.loads(report_path.read_text(encoding='utf-8')) if report_path.is_file() else {}
    trusted=report.get('policy_sha256')==rebuild.policy_hash(policy)
    files={}
    for key in ('source_db','candidate_db','rollback_db'):
        path=Path(policy[key]).absolute()
        item={'path':str(path),'exists':path.exists(),
              'sidecars':{suffix:Path(str(path)+suffix).stat().st_size
                          for suffix in ('-wal','-shm','-journal') if Path(str(path)+suffix).exists()},
              'matching_recorded_roles':[],'hash_verification':'not_requested'}
        if item['exists']:
            try:
                before=rebuild.identity(path)
                item['identity']=before
                if trusted:
                    for role,identity_key in (('original','source_identity'),('candidate','candidate_identity')):
                        expected=report.get(identity_key,{})
                        if all(before[k]==expected.get(k) for k in ('device','inode')):
                            item['matching_recorded_roles'].append(role)
                if verify_hashes and not item['sidecars']:
                    digest=rebuild.file_hash(path);rebuild.assert_identity(path,before)
                    item['sha256']=digest
                    item['hash_verification']='snapshot_only'
                    item['matching_recorded_hashes']=[role for role,key in
                        (('original','source_sha256'),('candidate','candidate_sha256'))
                        if trusted and report.get(key)==digest]
                elif verify_hashes:
                    item['hash_verification']='skipped_sidecars_present'
            except Exception as error:
                item['observation_error']=type(error).__name__
                item['matching_recorded_roles']=[]
        files[key]=item
    stage=report.get('status','no_report')
    action='manual_recovery_required_preserve_all_files'
    source,candidate,rollback=(files[k] for k in ('source_db','candidate_db','rollback_db'))
    no_sidecars=all(not item['sidecars'] for item in files.values())
    if trusted and no_sidecars and not any('observation_error' in item for item in files.values()):
        if stage=='candidate_validated' and 'original' in source['matching_recorded_roles'] and 'candidate' in candidate['matching_recorded_roles'] and not rollback['exists']:
            action='promotion_requires_authorization_and_fresh_validation'
        elif stage=='original_retained' and 'candidate' in source['matching_recorded_roles'] and 'original' in rollback['matching_recorded_roles'] and not candidate['exists']:
            action='keep_original_or_authorize_verified_purge'
        elif stage=='complete' and 'candidate' in source['matching_recorded_roles'] and not candidate['exists'] and not rollback['exists']:
            action='completed_record_recheck_current_database_before_new_run'
    return {'last_recorded_stage':stage,'report_matches_policy':trusted,'files':files,'next_action':action,
            'note':'Read-only observations, not an offline/approval gate. No SQLite connection or WAL replay was attempted.'}


def execute(action, policy, report, approved, no_backup):
    # CLI flags 是本次授權的執行閘門；agent 仍須先取得人類的明確指令。
    mode=rebuild.retention_mode(policy)
    disposition=rebuild.original_disposition(policy)
    if not approved or ((disposition=='delete' or action=='purge') and not no_backup):
        raise RuntimeError('Execution requires approval; deleting original also requires no-full-backup acceptance')
    source, _, _ = rebuild.validate_paths(policy, report)
    before = rebuild.identity(source)
    if action=='build' and any(before[k]!=v for k,v in policy['source_file_id_at_plan'].items()):
        raise RuntimeError('Source file was replaced after planning; create a fresh plan')
    if action=='build':
        return rebuild.build(policy, report)
    if action=='promote':
        return rebuild.promote(policy, report)
    if action=='purge':
        return rebuild.purge(policy, report)
    raise RuntimeError('Unsupported mutation action')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    status = sub.add_parser('status', help='Read-only host/process and storage gate')
    status.add_argument('--source', type=Path, default=source_default())
    quick = sub.add_parser('quick', help='Read-only pager health audit without history scan')
    quick.add_argument('--source', type=Path, default=source_default())
    quick.add_argument('--min-reclaim-gib', type=float, default=1)
    quick.add_argument('--min-free-ratio', type=float, default=0.1)
    plan = sub.add_parser('plan', help='Read-only estimate and frozen per-run policy')
    plan.add_argument('--source', type=Path, default=source_default())
    plan.add_argument('--run-root', type=Path, required=True)
    plan.add_argument('--mode', choices=['compact','aggressive'], default='compact')
    plan.add_argument('--original', choices=['keep','delete'], default='keep', help='Retain original by default; delete needs explicit waiver')
    plan.add_argument('--days', type=int, help='Aggressive mode only; default 30 days')
    plan.add_argument('--deja-executable', type=Path, help='Optional explicit Deja executable location')
    plan.add_argument('--reserve-gib', type=float, default=8)
    plan.add_argument('--preserve-path', type=Path, action='append', help='Additional external path to preserve')
    plan.add_argument('--max-seconds', type=int, default=1800)
    inspect = sub.add_parser('inspect-run', help='Read-only interrupted-run file/sidecar diagnostics')
    inspect.add_argument('--policy', type=Path, required=True)
    inspect.add_argument('--report', type=Path, required=True)
    inspect.add_argument('--verify-hashes', action='store_true', help='Optional expensive raw file SHA256; never SQLite replay')
    for action in ('build','promote','purge'):
        command = sub.add_parser(action)
        command.add_argument('--policy', type=Path, required=True)
        command.add_argument('--report', type=Path, required=True)
        command.add_argument('--execute', action='store_true')
        command.add_argument('--accept-no-full-backup', action='store_true')
    args = parser.parse_args(argv)
    policy = None
    try:
        if args.action=='quick':
            rebuild.emit('quick_audit',**quick_audit(args.source,args.min_reclaim_gib,args.min_free_ratio))
        elif args.action=='status':
            try:
                rebuild.host_stopped()
            except RuntimeError as error:
                if str(error)!='OpenCode is running':
                    raise
                rebuild.emit('waiting_for_opencode_exit')
                return 2
            rebuild.emit('eligible_for_offline_lock_check', source_main_bytes=args.source.stat().st_size,
                         free_bytes=shutil.disk_usage(args.source.parent).free,
                         sidecars_present=[s for s in ('-wal','-shm','-journal') if Path(str(args.source)+s).exists()])
        elif args.action=='plan':
            extra = list(map(str,args.preserve_path or []))
            create_plan(args.source, args.run_root, args.days, args.reserve_gib,
                        extra, args.max_seconds,args.mode,args.deja_executable,args.original)
        else:
            policy = load_policy(args.policy)
            if args.action=='inspect-run':
                rebuild.emit('run_inspection',**inspect_run(policy,args.report,args.verify_hashes))
            else:
                execute(args.action, policy, args.report, args.execute,args.accept_no_full_backup)
        return 0
    except Exception as error:
        # Exception / SQLite error text can contain reflected private data.
        state = rebuild.failure_state(policy,args.report) if policy else {}
        if isinstance(error,rebuild.SchemaError):
            state['schema_diagnostics']=error.diagnostics
        rebuild.emit('operation_failed', action=args.action, error_type=type(error).__name__, **state,
                     reason=str(error) if isinstance(error,RuntimeError) else 'Inspect local state; raw exception omitted')
        return 1


if __name__=='__main__':
    sys.exit(main())
