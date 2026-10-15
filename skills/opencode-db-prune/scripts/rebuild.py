"""Windows offline rebuild engine. Use maintenance.py for authorized CLI actions."""
import contextlib
import ctypes
import ctypes.wintypes as wt
import hashlib
import json
import os
from pathlib import Path
import pickle
import shutil
import sqlite3
import subprocess
import time
import tempfile

TOOLS = {'read', 'bash', 'shell', 'apply_patch', 'patch', 'edit', 'write'}
CORE = {
    'message': ['id','session_id','time_created','time_updated','data'],
    'part': ['id','message_id','session_id','time_created','time_updated','data'],
    'event': ['id','aggregate_id','seq','type','data'],
    'event_sequence': ['aggregate_id','seq','owner_id'],
}
COMPATIBILITY = json.loads((Path(__file__).parent.parent/'references'/'compatibility.json').read_text(encoding='utf-8'))


def retention_mode(policy):
    mode=policy.get('retention_mode')
    if mode not in ('compact','aggressive'):
        raise RuntimeError('Explicit supported retention mode required; create a fresh plan')
    return mode


def original_disposition(policy):
    value=policy.get('original_disposition')
    if value not in ('keep','delete'):
        raise RuntimeError('Explicit original disposition required; create a fresh plan')
    return value


def policy_hash(policy):
    return hashlib.sha256(json.dumps(policy,sort_keys=True,separators=(',',':')).encode('utf-8')).hexdigest()


def validate_paths(policy, report_path):
    paths = [Path(policy[k]).absolute() for k in ('source_db','candidate_db','rollback_db')]
    source, candidate, rollback = paths
    if len({str(p).casefold() for p in paths}) != 3 or not source.is_file():
        raise RuntimeError('Expected an existing source and three distinct database paths')
    if any(p.resolve()!=p for p in paths) or any(identity(p)['links']!=1 for p in paths if p.exists()):
        raise RuntimeError('Refusing linked or redirected database paths')
    if source.parent!=candidate.parent or source.parent!=rollback.parent:
        raise RuntimeError('All database paths must share the source directory')
    report = Path(report_path).absolute()
    protected = paths + [Path(p).absolute() for p in policy.get('preserve_external_paths',[])]
    if source.parent==report.parent or source.parent in report.parents or any(report==p or p in report.parents for p in protected):
        raise RuntimeError('Report overlaps a protected database or external data path')
    return paths


class MaintenanceLease:
    """同一來源每次只允許一個維護程序；程序退出後由 Windows 刪除 lease。"""
    def __init__(self, source):
        if os.name!='nt':
            raise RuntimeError('Mutations are supported on Windows only')
        self.kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        fn=self.kernel.CreateFileW
        fn.argtypes=[wt.LPCWSTR,wt.DWORD,wt.DWORD,wt.LPVOID,wt.DWORD,wt.DWORD,wt.HANDLE]
        fn.restype=wt.HANDLE
        self.kernel.CloseHandle.argtypes=[wt.HANDLE]
        self.kernel.CloseHandle.restype=wt.BOOL
        self.handle=fn(str(source)+'.maintenance.lock',0xC0000000,0,None,1,0x04000080,None)
        if self.handle==wt.HANDLE(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())

    def __enter__(self):
        return self

    def __exit__(self,*args):
        self.kernel.CloseHandle(self.handle)


def emit(phase, **values):
    print(json.dumps({'phase':phase, **values}, ensure_ascii=False), flush=True)


def quote(name):
    return '"' + name.replace('"','""') + '"'


def ro(path, immutable=False):
    uri = Path(path).resolve().as_uri() + '?mode=ro' + ('&immutable=1' if immutable else '')
    db = sqlite3.connect(uri, uri=True, timeout=2)
    db.execute('PRAGMA query_only=ON')
    db.execute('PRAGMA cache_size=-32768')
    db.execute('PRAGMA temp_store=MEMORY')
    return db


class Guard:
    """拒絕新的寫入者；允許唯讀驗證與原檔改名，不代替檔案身分核對。"""
    def __init__(self, path, access=0x80000000):
        self.path = Path(path)
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        fn = self.kernel.CreateFileW
        fn.argtypes = [wt.LPCWSTR,wt.DWORD,wt.DWORD,wt.LPVOID,wt.DWORD,wt.DWORD,wt.HANDLE]
        fn.restype = wt.HANDLE
        self.kernel.CloseHandle.argtypes = [wt.HANDLE]
        self.kernel.CloseHandle.restype = wt.BOOL
        self.handle = fn(str(self.path),access,1|4,None,3,0x80,None)
        if self.handle == wt.HANDLE(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle is not None:
            self.kernel.CloseHandle(self.handle)
            self.handle = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def identity(path):
    path = Path(path)
    st = path.stat()
    if path.is_symlink() or getattr(st,'st_file_attributes',0) & 0x400:
        raise RuntimeError('Refusing reparse-point database')
    return {'device':st.st_dev,'inode':st.st_ino,'size':st.st_size,
            'mtime_ns':st.st_mtime_ns,'links':st.st_nlink}


def assert_identity(path, expected):
    actual = identity(path)
    if any(actual[k] != expected[k] for k in ('device','inode','size','mtime_ns')):
        raise RuntimeError('Database identity or contents changed')


def require_no_sidecars(path):
    if any(Path(str(path)+suffix).exists() for suffix in ('-wal','-shm','-journal')):
        raise RuntimeError('SQLite sidecars present; refusing immutable read or replacement')


def host_stopped():
    # 主機 CIM 不可觀察時要拒絕操作，不能降級為沙箱的空程序清單。
    if os.name!='nt':
        raise RuntimeError('Host process verification is supported on Windows only')
    command = ("$ErrorActionPreference='Stop'; $p=@(Get-CimInstance Win32_Process -ErrorAction Stop); "
               "if (!($p | Where-Object ProcessId -eq 4) -or !($p | Where-Object ProcessId -eq $PID)) "
               "{ throw 'Incomplete host process visibility' }; "
               "@($p | Where-Object Name -like '*opencode*').Count")
    result = subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',command],
                            capture_output=True,text=True,timeout=30,check=True)
    if int(result.stdout.strip()) != 0:
        raise RuntimeError('OpenCode is running')


def check_space(path, minimum):
    free = shutil.disk_usage(Path(path).parent).free
    if free < minimum*2**30:
        raise RuntimeError('Insufficient free space; original retained')
    return free


def space_monitor(source, minimum):
    last=[0.0]
    def check():
        if time.monotonic()-last[0]>2:
            last[0]=time.monotonic()
            if (shutil.disk_usage(Path(source).parent).free < minimum*2**30 or
                    shutil.disk_usage(tempfile.gettempdir()).free < minimum*2**30):
                return 1
        return 0
    return check


def file_hash(path):
    h = hashlib.sha256()
    with open(path,'rb') as f:
        for chunk in iter(lambda:f.read(8*2**20),b''):
            h.update(chunk)
    return h.hexdigest()


def tree_hash(path):
    path = Path(path)
    if not path.exists():
        return {'exists':False}
    identity(path)
    if path.is_file():
        before=identity(path)
        result={'exists':True,'kind':'file','files':1,'bytes':before['size'],'sha256':file_hash(path)}
        assert_identity(path,before)
        return result
    h = hashlib.sha256(); count = total = 0
    for item in sorted(p for p in path.rglob('*') if p.is_file()):
        before=identity(item)
        h.update(str(item.relative_to(path)).encode('utf-8'))
        h.update(bytes.fromhex(file_hash(item)))
        assert_identity(item,before)
        count += 1; total += item.stat().st_size
    return {'exists':True,'kind':'directory','files':count,'bytes':total,'sha256':h.hexdigest()}


def digest_row(h, row):
    # 型別與欄位邊界一併雜湊，報告只留 digest，絕不輸出對話或憑證。
    data = pickle.dumps(tuple(row), protocol=5)
    h.update(len(data).to_bytes(8,'big')); h.update(data)


def slim_message(raw):
    obj = json.loads(raw)
    summary = obj.get('summary')
    if isinstance(summary,dict) and 'diffs' in summary:
        if not isinstance(summary['diffs'],list):
            raise RuntimeError('Unexpected message summary.diffs type')
        summary['diffs'] = []
        return json.dumps(obj,ensure_ascii=False,separators=(',',':'))
    return raw


def tool_projection(obj):
    state = obj.get('state') or {}
    return (obj.get('type'),obj.get('tool'),state.get('input'),
            state.get('output') if obj.get('tool') in ('bash','shell') else None,
            (state.get('metadata') or {}).get('exit'),obj.get('time'),
            state.get('time'),obj.get('synthetic'),obj.get('ignored'))


def slim_part(raw):
    obj = json.loads(raw)
    if obj.get('type') == 'text':
        return raw
    if obj.get('type') != 'tool' or obj.get('tool') not in TOOLS:
        return None
    original = tool_projection(obj)
    state = obj.get('state')
    if isinstance(state,dict):
        if obj.get('tool') not in ('bash','shell') and 'output' in state:
            state['output'] = ''
        if isinstance(state.get('metadata'),dict):
            metadata = state['metadata']
            state['metadata'] = {'exit':metadata['exit']} if 'exit' in metadata else {}
    if isinstance(obj.get('metadata'),dict):
        obj['metadata'] = {}
    if tool_projection(obj) != original:
        raise RuntimeError('Preserved tool fields changed')
    return json.dumps(obj,ensure_ascii=False,separators=(',',':'))


def table_info(db, table):
    info = db.execute('PRAGMA table_info('+quote(table)+')').fetchall()
    columns = [row[1] for row in info]
    # INTEGER PRIMARY KEY 本身就是 rowid；其他表另外保留原始 rowid 與缺口。
    pk = [row for row in info if row[5]]
    alias = len(pk)==1 and pk[0][2].upper()=='INTEGER'
    return columns, not alias


def rows_for(db, table, columns, explicit_rowid, recent, mode='compact'):
    select = ('rowid,' if explicit_rowid else '') + ','.join(map(quote,columns))
    if table == 'event' and mode=='aggressive':
        # 只排序小型 rowid，避免把近期十多 GiB JSON 倒進 SQLite sorter。
        if len(recent)>db.getlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER):
            raise RuntimeError('Protected session set exceeds SQLite bind limit')
        marks=','.join('?' for _ in recent) or 'NULL'
        ids = db.execute('SELECT rowid FROM event WHERE aggregate_id IN ('+marks+') ORDER BY rowid',list(recent))
        while True:
            batch = [r[0] for r in ids.fetchmany(64)]
            if not batch:
                break
            marks = ','.join('?' for _ in batch)
            yield from db.execute('SELECT '+select+' FROM event WHERE rowid IN ('+marks+') ORDER BY rowid',batch)
    else:
        yield from db.execute('SELECT '+select+' FROM '+quote(table)+' ORDER BY rowid')


def session_retention(db, mode, cutoff_ms):
    sessions=db.execute('SELECT id,time_updated FROM session').fetchall()
    return len(sessions),{sid for sid,updated in sessions if mode=='compact' or updated>=cutoff_ms}


def retained_rows(db, table, columns, explicit, recent, mode):
    """One retention pipeline for planning and rebuilding; yield original + retained row."""
    offset=int(explicit)
    sid_column='aggregate_id' if table in ('event','event_sequence') else 'session_id'
    sid_index=columns.index(sid_column)+offset if sid_column in columns else None
    data_index=columns.index('data')+offset if 'data' in columns else None
    for raw in rows_for(db,table,columns,explicit,recent,mode):
        sid=raw[sid_index] if sid_index is not None else None
        row=raw
        if mode=='aggressive' and sid not in recent:
            if table=='event_sequence':
                continue
            if table in ('message','part'):
                slim=(slim_message if table=='message' else slim_part)(raw[data_index])
                if slim is None:
                    continue
                if slim!=raw[data_index]:
                    row=list(raw); row[data_index]=slim
        yield raw,row


def schema_rows(db):
    return db.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()


def schema_diagnostics(db):
    schema=schema_rows(db)
    digest=hashlib.sha256(json.dumps(schema,separators=(',',':')).encode()).hexdigest()
    supported=COMPATIBILITY['supported_schemas']
    matched=next((item for item in supported if item['schema_sha256']==digest),None)
    # SQL text/default literals may contain private values; diagnostics emit object names only.
    observed={(r[0],r[1]):tuple(r) for r in schema}
    differences=[]
    for item in supported:
        expected={(r[0],r[1]):tuple(r) for r in item['schema']}
        differences.append({'supported_id':item['id'],
            'added_objects':[list(k) for k in sorted(observed.keys()-expected.keys())],
            'missing_objects':[list(k) for k in sorted(expected.keys()-observed.keys())],
            'changed_objects':[list(k) for k in sorted(expected.keys() & observed.keys()) if expected[k]!=observed[k]]})
    return {'supported':matched is not None,'schema_sha256':digest,
            'supported_id':matched['id'] if matched else None,
            'user_version':db.execute('PRAGMA user_version').fetchone()[0],
            'application_id':db.execute('PRAGMA application_id').fetchone()[0],
            'differences':[] if matched else differences}


class SchemaError(RuntimeError):
    def __init__(self, diagnostics):
        super().__init__('Unexpected database schema; inspect structural differences and review migrations; original retained')
        self.diagnostics=diagnostics


def check_schema(db, mode='compact'):
    schema = schema_rows(db)
    tables = {r[1] for r in schema if r[0]=='table'}
    diagnostics=schema_diagnostics(db)
    if not diagnostics['supported']:
        raise SchemaError(diagnostics)
    internal={r[0] for r in db.execute("SELECT name FROM sqlite_schema WHERE type='table' AND name LIKE 'sqlite_%'")}
    if internal-{'sqlite_sequence'}:
        raise RuntimeError('Unexpected internal tables; preserve source for inspection')
    for table, expected in CORE.items():
        if table_info(db,table)[0] != expected:
            raise RuntimeError('Unexpected core table columns')
    if mode=='aggressive':
        for name in ('session_message','session_context_epoch','session_input'):
            if name in tables and db.execute('SELECT 1 FROM '+quote(name)+' LIMIT 1').fetchone():
                raise RuntimeError('Alternative conversation store is nonempty')
    if any(r[0] not in ('table','index') or 'WITHOUT ROWID' in (r[3] or '').upper() for r in schema):
        raise RuntimeError('Unsupported schema objects; original retained')
    return schema


def inspect_candidate(path, expected, metadata):
    with contextlib.closing(ro(path,True)) as db:
        if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise RuntimeError('Candidate integrity_check failed')
        if db.execute('PRAGMA foreign_key_check').fetchone() is not None:
            raise RuntimeError('Candidate foreign_key_check failed')
        for key,value in metadata.items():
            if db.execute('PRAGMA '+key).fetchone()[0] != value:
                raise RuntimeError('SQLite application metadata mismatch')
        for table, spec in expected.items():
            columns, explicit = table_info(db,table)
            select = ('rowid,' if explicit else '') + ','.join(map(quote,columns))
            h=hashlib.sha256(); count=0; last=time.monotonic()
            for row in db.execute('SELECT '+select+' FROM '+quote(table)+' ORDER BY rowid'):
                digest_row(h,row); count+=1
                if time.monotonic()-last>20:
                    emit('validating_rows',table=table,rows=count); last=time.monotonic()
            if count != spec['rows'] or h.hexdigest() != spec['sha256']:
                raise RuntimeError('Candidate content mismatch: '+table)
            emit('table_validated',table=table,rows=count)


def write_report(path, data):
    temp=Path(str(path)+'.tmp')
    with open(temp,'w',encoding='utf-8') as f:
        json.dump(data,f,ensure_ascii=False,indent=2); f.flush(); os.fsync(f.fileno())
    os.replace(temp,path)


def build(policy, report_path):
    retention_mode(policy)
    original_disposition(policy)
    source,candidate,rollback = validate_paths(policy,report_path)
    if candidate.exists() or rollback.exists() or Path(report_path).exists():
        raise RuntimeError('Candidate must be new and in source directory')
    host_stopped()
    check_space(source,policy['minimum_free_gib_before_build'])
    check_space(Path(tempfile.gettempdir())/'sqlite-temp-budget',policy.get('minimum_free_gib_before_temp',policy['minimum_free_gib_during_build']))
    with MaintenanceLease(source):
        return build_locked(policy,report_path,source,candidate)


def build_locked(policy,report_path,source,candidate):
    mode=retention_mode(policy)
    # 只讓 SQLite 自己 checkpoint，不手動刪 WAL/SHM，也不做來源 DELETE/VACUUM。
    with contextlib.closing(sqlite3.connect(source,timeout=2)) as checkpoint:
        if checkpoint.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0] != 0:
            raise RuntimeError('Checkpoint is busy')
    require_no_sidecars(source)
    with Guard(source), contextlib.closing(ro(source,True)) as src:
        require_no_sidecars(source)
        original = identity(source)
        if original['links'] != 1:
            raise RuntimeError('Unexpected source hard links')
        schema=check_schema(src,mode)
        if src.execute('PRAGMA foreign_key_check').fetchone() is not None:
            raise RuntimeError('Source foreign_key_check failed; preserve for inspection')
        if src.execute('SELECT 1 FROM part p JOIN message m ON p.message_id=m.id WHERE p.session_id!=m.session_id LIMIT 1').fetchone():
            raise RuntimeError('Part and message session ownership disagree')
        metadata={k:src.execute('PRAGMA '+k).fetchone()[0] for k in ('user_version','application_id','page_size')}
        session_count,recent=session_retention(src,mode,policy['cutoff_ms'])
        orphan=src.execute('SELECT 1 FROM event_sequence e LEFT JOIN session s ON s.id=e.aggregate_id WHERE s.id IS NULL LIMIT 1').fetchone()
        if orphan and mode=='aggressive':
            raise RuntimeError('Event aggregate not represented by a session')
        auxiliary={p:tree_hash(p) for p in policy.get('preserve_external_paths',[])}
        report={'status':'building','source':str(source),'candidate':str(candidate),'policy_sha256':policy_hash(policy),
                'source_identity':original,'retention_mode':mode,'cutoff':policy['cutoff_iso'],
                'session_count':session_count,'protected_sessions':len(recent),
                'metadata':metadata,'schema_sha256':hashlib.sha256(pickle.dumps(schema,5)).hexdigest(),
                'auxiliary':auxiliary,'tables':{}}
        write_report(report_path,report)
        fd=os.open(candidate,os.O_CREAT|os.O_EXCL|os.O_RDWR);os.close(fd)
        with contextlib.closing(sqlite3.connect(candidate)) as dst:
            dst.set_progress_handler(space_monitor(source,policy['minimum_free_gib_during_build']),100000)
            dst.execute('PRAGMA journal_mode=DELETE'); dst.execute('PRAGMA synchronous=FULL')
            dst.execute('PRAGMA cache_size=-65536'); dst.execute('PRAGMA temp_store=FILE')
            dst.execute('PRAGMA page_size='+str(metadata['page_size']))
            for kind,name,_,sql in schema:
                if kind=='table':dst.execute(sql)
            has_sequence=src.execute("SELECT 1 FROM sqlite_schema WHERE name='sqlite_sequence'").fetchone() is not None
            if has_sequence and dst.execute("SELECT 1 FROM sqlite_schema WHERE name='sqlite_sequence'").fetchone() is None:
                # 舊 migration 可留下 sequence 內表，即使目前已無 AUTOINCREMENT。
                dst.execute('CREATE TABLE "__retention_sequence_seed"(id INTEGER PRIMARY KEY AUTOINCREMENT)')
                dst.execute('DROP TABLE "__retention_sequence_seed"')
            changed=total=0; last=time.monotonic()
            ordered=sorted([r[1] for r in schema if r[0]=='table'],key=lambda n:(n=='event',n))
            if has_sequence:ordered.append('sqlite_sequence')
            for table in ordered:
                columns, explicit=table_info(src,table)
                names=(['rowid'] if explicit else [])+columns
                insert='INSERT INTO '+quote(table)+'('+','.join(map(quote,names))+') VALUES('+','.join('?' for _ in names)+')'
                offset=int(explicit); h=hashlib.sha256(); seen=kept=0
                dst.execute('BEGIN')
                if table=='sqlite_sequence':dst.execute('DELETE FROM sqlite_sequence')
                for raw,row in retained_rows(src,table,columns,explicit,recent,mode):
                    seen+=1
                    changed+=int(tuple(row)!=tuple(raw))
                    dst.execute(insert,row);digest_row(h,row);kept+=1;total+=1
                    if kept%20000==0:
                        dst.commit();check_space(source,policy['minimum_free_gib_during_build']);dst.execute('BEGIN')
                    if time.monotonic()-last>15:
                        emit('copying',table=table,read_rows=seen,kept_rows=kept,
                             candidate_gib=round(candidate.stat().st_size/2**30,3))
                        check_space(source,policy['minimum_free_gib_during_build']);last=time.monotonic()
                dst.commit()
                source_count=src.execute('SELECT count(*) FROM '+quote(table)).fetchone()[0]
                report['tables'][table]={'rows':kept,'source_rows':source_count,'read_rows':seen,'sha256':h.hexdigest()}
                write_report(report_path,report);emit('table_copied',table=table,rows=kept)
            for kind,name,_,sql in schema:
                if kind=='index':
                    emit('creating_index',name=name);check_space(source,policy['minimum_free_gib_during_build'])
                    dst.execute(sql);dst.commit()
            for key,value in metadata.items():dst.execute('PRAGMA '+key+'='+str(value))
            dst.commit()
        require_no_sidecars(candidate)
        inspect_candidate(candidate,report['tables'],metadata)
        with contextlib.closing(ro(candidate,True)) as check:
            if schema_rows(check)!=schema:
                raise RuntimeError('Rebuilt schema differs')
        assert_identity(source,original); require_no_sidecars(source)
        report.update(status='candidate_validated',candidate_identity=identity(candidate),
                      candidate_sha256=file_hash(candidate),source_sha256=file_hash(source),changed_json_rows=changed)
        write_report(report_path,report)
        emit('candidate_validated',bytes=candidate.stat().st_size,protected_sessions=len(recent))
        return report


def replace_file(source,candidate,rollback):
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    fn=kernel.ReplaceFileW
    fn.argtypes=[wt.LPCWSTR,wt.LPCWSTR,wt.LPCWSTR,wt.DWORD,wt.LPVOID,wt.LPVOID]
    fn.restype=wt.BOOL
    if not fn(str(source),str(candidate),str(rollback),0,None,None):
        # 1177 可能已移走 original。任何錯誤均保留所有檔名，不猜測或清除。
        raise ctypes.WinError(ctypes.get_last_error())


def handle_identity(guard):
    class FileInfo(ctypes.Structure):
        _fields_=[('attributes',wt.DWORD),('created',wt.FILETIME),('accessed',wt.FILETIME),
                  ('written',wt.FILETIME),('volume',wt.DWORD),('size_high',wt.DWORD),
                  ('size_low',wt.DWORD),('links',wt.DWORD),('index_high',wt.DWORD),('index_low',wt.DWORD)]
    info=FileInfo()
    fn=guard.kernel.GetFileInformationByHandle
    fn.argtypes=[wt.HANDLE,ctypes.POINTER(FileInfo)]
    fn.restype=wt.BOOL
    if not fn(guard.handle,ctypes.byref(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    return (info.volume,info.index_high,info.index_low,info.links)


def delete_original(rollback, original_guard):
    # pathname 可在 stat 後被合法替換；DELETE handle 必須和全程持有的原檔
    # handle 指向同一個 file ID，再標記該 handle 的檔案刪除，避免刪到新同名檔。
    with Guard(rollback,access=0x00010080) as deletion_guard:
        actual=handle_identity(deletion_guard)
        if actual!=handle_identity(original_guard) or actual[-1]!=1:
            raise RuntimeError('Rollback handle no longer identifies the original; preserve files')
        class Disposition(ctypes.Structure):
            _fields_=[('delete_file',wt.BOOL)]
        fn=deletion_guard.kernel.SetFileInformationByHandle
        fn.argtypes=[wt.HANDLE,ctypes.c_int,wt.LPVOID,wt.DWORD]
        fn.restype=wt.BOOL
        disposition=Disposition(True)
        if not fn(deletion_guard.handle,4,ctypes.byref(disposition),ctypes.sizeof(disposition)):
            raise ctypes.WinError(ctypes.get_last_error())
    original_guard.close()
    if Path(rollback).exists():
        raise RuntimeError('Original deleted by handle but rollback pathname reoccupied; unrelated file retained')


def promote(policy,report_path):
    retention_mode(policy)
    original_disposition(policy)
    source,candidate,rollback=validate_paths(policy,report_path)
    with MaintenanceLease(source):
        return promote_locked(policy,report_path,source,candidate,rollback)


def promote_locked(policy,report_path,source,candidate,rollback):
    report=json.loads(Path(report_path).read_text(encoding='utf-8'))
    if report['status']!='candidate_validated':raise RuntimeError('Candidate not validated')
    if report.get('policy_sha256')!=policy_hash(policy):
        raise RuntimeError('Policy changed since candidate validation')
    if source.parent!=candidate.parent or source.parent!=rollback.parent or rollback.exists():
        raise RuntimeError('Invalid or existing rollback path')
    if (str(source),str(candidate))!=(report['source'],report['candidate']):
        raise RuntimeError('Report does not describe these paths')
    host_stopped()
    require_no_sidecars(source);require_no_sidecars(candidate)
    with Guard(source) as original_guard:
        assert_identity(source,report['source_identity'])
        if file_hash(source)!=report['source_sha256']:
            raise RuntimeError('Source changed since candidate validation')
        with Guard(candidate):
            assert_identity(candidate,report['candidate_identity'])
            if file_hash(candidate)!=report['candidate_sha256']:raise RuntimeError('Candidate changed')
        # ReplaceFileW 的 replacement 以 no-sharing 開啟；新 guard 若拿不到，
        # 保留 original + 新 DB + sidecars，不在可能有新 writer 時自動回復。
        report['status']='promotion_started';write_report(report_path,report)
        replace_file(source,candidate,rollback)
        with Guard(source):
            require_no_sidecars(source);require_no_sidecars(rollback)
            assert_identity(source,report['candidate_identity'])
            assert_identity(rollback,report['source_identity'])
            try:
                with contextlib.closing(ro(source,True)) as check:
                    if check.execute('PRAGMA quick_check').fetchall()!=[('ok',)]:raise RuntimeError('Post-switch quick_check failed')
                    if check.execute('PRAGMA foreign_key_check').fetchone() is not None:raise RuntimeError('Post-switch foreign_key_check failed')
                if file_hash(source)!=report['candidate_sha256']:raise RuntimeError('Post-switch content changed')
                for path,expected in report['auxiliary'].items():
                    if tree_hash(path)!=expected:raise RuntimeError('External Deja data changed; retain original')
                host_stopped()
                require_no_sidecars(source);require_no_sidecars(rollback)
                assert_identity(rollback,report['source_identity'])
            except Exception:
                # 只有拿到新檔 guard、確認兩檔身分與無 sidecar 的確定狀態
                # 才可回復。writer 競態／1177 等不確定狀態不會走到這裡。
                host_stopped()
                require_no_sidecars(source);require_no_sidecars(rollback)
                assert_identity(source,report['candidate_identity'])
                assert_identity(rollback,report['source_identity'])
                if candidate.exists():raise RuntimeError('Recovery candidate name occupied; retain both')
                report['status']='restoring_original';write_report(report_path,report)
                original_guard.close()
                replace_file(source,rollback,candidate)
                with Guard(source):
                    require_no_sidecars(source)
                    assert_identity(source,report['source_identity'])
                    report['status']='original_restored_candidate_retained';write_report(report_path,report)
                raise
            report['status']='post_switch_validated';write_report(report_path,report)
            report.update(new_bytes=source.stat().st_size,rollback=str(rollback))
            if original_disposition(policy)=='keep':
                report.update(status='original_retained',reclaimed_main_bytes=0,net_freed_bytes=-report['new_bytes'],
                              retained_original_bytes=report['source_identity']['size'])
            else:
                # 只有此處不可逆；以全程持有的原檔 handle 核對後刪除。
                delete_original(rollback,original_guard)
                report.update(status='complete',reclaimed_main_bytes=report['source_identity']['size']-report['new_bytes'],
                              net_freed_bytes=report['source_identity']['size']-report['new_bytes'])
            write_report(report_path,report)
    emit(report['status'],new_bytes=report['new_bytes'],reclaimed_main_bytes=report['reclaimed_main_bytes'])
    return report


def purge(policy,report_path):
    """Separate authorized deletion of an original retained after successful promotion."""
    source,candidate,rollback=validate_paths(policy,report_path)
    with MaintenanceLease(source):
        report=json.loads(Path(report_path).read_text(encoding='utf-8'))
        if (report.get('status')!='original_retained' or original_disposition(policy)!='keep' or
                report.get('policy_sha256')!=policy_hash(policy) or
                (report.get('source'),report.get('candidate'),report.get('rollback'))!=tuple(map(str,(source,candidate,rollback)))):
            raise RuntimeError('No verified retained original for this policy and report')
        host_stopped()
        require_no_sidecars(source);require_no_sidecars(rollback)
        with Guard(source),Guard(rollback) as original_guard:
            require_no_sidecars(source);require_no_sidecars(rollback)
            current=identity(source)
            if current['links']!=1 or any(current[k]!=report['candidate_identity'][k] for k in ('device','inode')):
                raise RuntimeError('Active database identity changed; original retained')
            assert_identity(rollback,report['source_identity'])
            if file_hash(rollback)!=report['source_sha256']:
                raise RuntimeError('Retained original changed; preserve files')
            # 使用者可能已正常使用新 DB；允許內容增加，但必須仍是切換的新檔且完整有效。
            with contextlib.closing(ro(source,True)) as db:
                check_schema(db,'compact')
                if db.execute('PRAGMA integrity_check').fetchall()!=[('ok',)] or db.execute('PRAGMA foreign_key_check').fetchone():
                    raise RuntimeError('Active database validation failed; original retained')
            host_stopped();require_no_sidecars(source);require_no_sidecars(rollback)
            assert_identity(source,current);assert_identity(rollback,report['source_identity'])
            delete_original(rollback,original_guard)
            report.update(status='complete',new_bytes=current['size'],
                          reclaimed_main_bytes=report['source_identity']['size']-current['size'],
                          released_original_bytes=report['source_identity']['size'],retained_original_bytes=0,
                          net_freed_bytes=report['source_identity']['size']-current['size'])
            write_report(report_path,report)
        emit('complete',released_original_bytes=report['released_original_bytes'])
        return report



def failure_state(policy,report_path):
    try:
        report=json.loads(Path(report_path).read_text(encoding='utf-8'))
        expected=report['source_identity']
        retained=False
        for key in ('source_db','rollback_db'):
            path=Path(policy[key])
            if path.exists():
                actual=identity(path)
                retained |= all(actual[k]==expected[k] for k in ('device','inode','size','mtime_ns'))
        return {'original_retained':retained,'last_recorded_stage':report['status'],
                'post_switch_validation_recorded':report['status'] in ('post_switch_validated','original_retained','complete')}
    except Exception:
        return {'original_retained':'unknown','last_recorded_stage':'unknown'}
