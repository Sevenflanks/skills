"""Real SQLite/Windows cases; fixtures use temporary siblings of this test file."""
import contextlib
from datetime import datetime, timezone, timedelta
import io
import hashlib
import json
import os
import shutil
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
import rebuild as rebuild_opencode
import maintenance
from rebuild import build,promote,Guard,ro,file_hash,failure_state

SCHEMA = '''
CREATE TABLE session(id TEXT PRIMARY KEY,time_updated INTEGER NOT NULL,time_created INTEGER,title TEXT);
CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,time_created INTEGER NOT NULL,time_updated INTEGER NOT NULL,data TEXT NOT NULL,FOREIGN KEY(session_id) REFERENCES session(id));
CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT NOT NULL,session_id TEXT NOT NULL,time_created INTEGER NOT NULL,time_updated INTEGER NOT NULL,data TEXT NOT NULL,FOREIGN KEY(message_id) REFERENCES message(id));
CREATE INDEX part_session_idx ON part(session_id);
CREATE TABLE event_sequence(aggregate_id TEXT PRIMARY KEY,seq INTEGER NOT NULL,owner_id TEXT);
CREATE TABLE event(id TEXT PRIMARY KEY,aggregate_id TEXT NOT NULL,seq INTEGER NOT NULL,type TEXT NOT NULL,data TEXT NOT NULL,FOREIGN KEY(aggregate_id) REFERENCES event_sequence(aggregate_id));
CREATE UNIQUE INDEX event_aggregate_seq_idx ON event(aggregate_id,seq);
CREATE TABLE untouched(id INTEGER PRIMARY KEY,value BLOB);
CREATE TABLE allocator(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT);
CREATE TABLE session_message(id TEXT PRIMARY KEY);
'''


class SQLiteFixture(unittest.TestCase):
    def fixture_schema(self):
        with contextlib.closing(ro(self.source)) as db:
            schema=rebuild_opencode.schema_rows(db)
        digest=hashlib.sha256(json.dumps(schema,separators=(',',':')).encode()).hexdigest()
        p2=patch.dict(rebuild_opencode.COMPATIBILITY,{'supported_schemas':[{'id':'fixture','schema_sha256':digest,'schema':schema}]})
        p2.start();self.addCleanup(p2.stop)

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name).resolve()
        self.db_dir=self.folder/'data';self.db_dir.mkdir()
        self.source=self.db_dir/'source.db';self.candidate=self.db_dir/'candidate.db'
        self.rollback=self.db_dir/'rollback.db';self.report=self.folder/'report.json'
        self.policy={'source_db':str(self.source),'candidate_db':str(self.candidate),
            'rollback_db':str(self.rollback),'cutoff_ms':100,'cutoff_iso':'fixture boundary',
            'minimum_free_gib_before_build':0,'minimum_free_gib_during_build':0,
            'preserve_external_paths':[],'retention_mode':'aggressive','original_disposition':'delete'}
        self.deja_executable=self.folder/'deja.exe'
        self.deja_executable.write_bytes(b'Fixture for path discovery only; never executed')
        self.real_which=shutil.which
        discovery=patch('maintenance.shutil.which',return_value=None)
        discovery.start();self.addCleanup(discovery.stop)
        environment=patch.dict(os.environ,{'XDG_CACHE_HOME':str(self.folder/'cache'),
                                          'PATH':str(self.folder/'empty-path')})
        environment.start();self.addCleanup(environment.stop)
        db=sqlite3.connect(self.source);db.executescript(SCHEMA)
        db.execute('PRAGMA user_version=17');db.execute('PRAGMA application_id=23')
        db.executemany('INSERT INTO session VALUES(?,?,?,?)',[
            ('old',99,0,'old title'),('recent',101,0,'recent title'),('boundary',100,0,'exact boundary')])
        self.old_message='{"role":"assistant","time":{"created":1},"summary":{"diffs":["REMOVE"],"title":"keep"}}'
        self.new_message='{ "role": "assistant", "summary": {"diffs":["KEEP"]}, "time":{"created":9} }'
        db.executemany('INSERT INTO message(rowid,id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?)',[
            (10,'m_old','old',1,1,self.old_message),(20,'m_recent','recent',9,9,self.new_message),
            (30,'m_boundary','boundary',8,8,self.new_message)])
        self.read={'type':'tool','tool':'read','state':{'status':'completed',
            'input':{'filePath':'a.ts'},'output':'discard old read output',
            'metadata':{'exit':0,'diagnostics':{'large':'unused'}},'time':{'start':3,'end':4}},
            'metadata':{'unused':True}}
        self.bash={'type':'tool','tool':'bash','state':{'input':{'command':'git status'},
            'output':'complete output','metadata':{'exit':7,'diagnostics':'unused'}}}
        parts=[('text',{'type':'text','text':'完整舊文字'}),('thinking',{'type':'reasoning','text':'unused'}),
            ('file',{'type':'file','url':'fixture.png'}),('read',self.read),('bash',self.bash),
            ('task',{'type':'tool','tool':'task','state':{'input':{'prompt':'unused'},'output':'unused'}})]
        for rowid,(name,value) in enumerate(parts,100):
            db.execute('INSERT INTO part(rowid,id,message_id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?,?)',
                       (rowid,name,'m_old','old',1,1,json.dumps(value,ensure_ascii=False)))
        self.big_reasoning=json.dumps({'type':'reasoning','text':'完整保留'*100000},ensure_ascii=False)
        db.execute('INSERT INTO part(rowid,id,message_id,session_id,time_created,time_updated,data) VALUES(200,?,?,?,?,?,?)',
                   ('new_reasoning','m_recent','recent',1,1,self.big_reasoning))
        db.execute('INSERT INTO part(rowid,id,message_id,session_id,time_created,time_updated,data) VALUES(300,?,?,?,?,?,?)',
                   ('boundary_file','m_boundary','boundary',1,1,'{ "type": "file", "url": "keep.png" }'))
        db.executemany('INSERT INTO event_sequence VALUES(?,?,?)',[('old',1,None),('recent',2,None),('boundary',1,None)])
        db.executemany('INSERT INTO event(rowid,id,aggregate_id,seq,type,data) VALUES(?,?,?,?,?,?)',[
            (700,'e_old','old',1,'test','old'),(800,'e_new1','recent',1,'test','new1'),
            (900,'e_new2','recent',2,'test','new2'),(1000,'e_boundary','boundary',1,'test','boundary')])
        db.execute('INSERT INTO untouched VALUES(42,?)',(b'\x00\xffkeep',));db.commit();db.close()
        db=sqlite3.connect(self.source)
        db.execute('INSERT INTO allocator VALUES(1,"keep")');db.execute('INSERT INTO allocator VALUES(77,"removed")')
        db.execute('DELETE FROM allocator WHERE id=77');db.commit();db.close()
        self.fixture_schema()
        self.host_patch=patch('rebuild.host_stopped',return_value=None)
        self.host_patch.start();self.addCleanup(self.host_patch.stop)

@unittest.skipUnless(os.name=='nt','Real Windows sharing and ReplaceFileW required')
class RebuildTests(SQLiteFixture):
    def test_estimate_and_build_agree_on_retention_for_every_table(self):
        estimate=maintenance.profile(self.source,100,30,'aggressive')
        result=build(self.policy,self.report)
        for table,counts in estimate['tables'].items():
            self.assertEqual(result['tables'][table]['rows'],counts['retained_rows'],table)
        self.assertEqual(sum(v['changed_json_rows'] for v in estimate['tables'].values()),result['changed_json_rows'])

    def test_recent_raw_rows_and_deja_fields_survive_while_old_auxiliary_is_removed(self):
        original_hash=file_hash(self.source)
        result=build(self.policy,self.report)
        self.assertEqual(file_hash(self.source),original_hash)
        self.assertEqual(result['protected_sessions'],2)
        with contextlib.closing(ro(self.candidate,True)) as db:
            self.assertEqual(db.execute('SELECT data FROM message WHERE id="m_recent"').fetchone()[0],self.new_message)
            self.assertEqual(db.execute('SELECT data FROM message WHERE id="m_boundary"').fetchone()[0],self.new_message)
            old=json.loads(db.execute('SELECT data FROM message WHERE id="m_old"').fetchone()[0])
            self.assertEqual(old,{'role':'assistant','time':{'created':1},'summary':{'diffs':[],'title':'keep'}})
            self.assertEqual({x[0] for x in db.execute('SELECT id FROM part')},
                             {'text','read','bash','new_reasoning','boundary_file'})
            read=json.loads(db.execute('SELECT data FROM part WHERE id="read"').fetchone()[0])
            self.assertEqual(read['state']['input'],{'filePath':'a.ts'})
            self.assertEqual(read['state']['output'],'')
            self.assertEqual(read['state']['metadata'],{'exit':0})
            self.assertEqual(read['metadata'],{})
            bash=json.loads(db.execute('SELECT data FROM part WHERE id="bash"').fetchone()[0])
            self.assertEqual(bash['state']['output'],'complete output')
            self.assertEqual(bash['state']['metadata'],{'exit':7})
            self.assertEqual(db.execute('SELECT data FROM part WHERE id="new_reasoning"').fetchone()[0],self.big_reasoning)
            self.assertEqual(db.execute('SELECT rowid,id,seq FROM event ORDER BY rowid').fetchall(),
                             [(800,'e_new1',1),(900,'e_new2',2),(1000,'e_boundary',1)])
            self.assertEqual(db.execute('SELECT * FROM untouched').fetchall(),[(42,b'\x00\xffkeep')])
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0],17)
            self.assertEqual(db.execute('PRAGMA application_id').fetchone()[0],23)
            self.assertEqual(db.execute('SELECT seq FROM sqlite_sequence WHERE name="allocator"').fetchone()[0],77)
            db.close()
        writer=sqlite3.connect(self.candidate)
        writer.execute('INSERT INTO allocator(value) VALUES("next")')
        self.assertEqual(writer.execute('SELECT max(id) FROM allocator').fetchone()[0],78)
        writer.rollback();writer.close()

    def test_legacy_sequence_table_without_autoincrement_is_preserved(self):
        db=sqlite3.connect(self.source);db.execute('DROP TABLE allocator')
        db.execute('INSERT INTO sqlite_sequence(name,seq) VALUES("legacy",8123)');db.commit();db.close()
        self.fixture_schema()
        build(self.policy,self.report)
        with contextlib.closing(ro(self.candidate,True)) as dst:
            self.assertEqual(dst.execute('SELECT name,seq FROM sqlite_sequence').fetchall(),[('legacy',8123)])

    def test_interrupted_build_leaves_original_bytes_and_rows_intact(self):
        original=file_hash(self.source)
        with patch('rebuild.digest_row',side_effect=RuntimeError('Injected build failure')):
            with self.assertRaisesRegex(RuntimeError,'Injected build failure'):
                build(self.policy,self.report)
        self.assertEqual(file_hash(self.source),original)
        self.assertFalse(self.rollback.exists())

    def test_nonempty_alternative_store_refuses_before_creating_candidate(self):
        db=sqlite3.connect(self.source);db.execute('INSERT INTO session_message VALUES("v2")');db.commit();db.close()
        original=file_hash(self.source)
        with self.assertRaisesRegex(RuntimeError,'Alternative conversation'):
            build(self.policy,self.report)
        self.assertFalse(self.candidate.exists());self.assertEqual(file_hash(self.source),original)

    def test_guard_blocks_real_writer(self):
        with Guard(self.source):
            with self.assertRaises(PermissionError):
                with open(self.source,'r+b'):pass

    def test_keep_original_then_purge_requires_separate_authorization(self):
        self.policy['original_disposition']='keep'
        original=file_hash(self.source)
        build(self.policy,self.report)
        result=promote(self.policy,self.report)
        self.assertEqual(result['status'],'original_retained')
        self.assertEqual(file_hash(self.rollback),original)
        self.assertEqual(result['reclaimed_main_bytes'],0)
        with self.assertRaises(RuntimeError):
            maintenance.execute('purge',self.policy,self.report,True,False)
        self.assertTrue(self.rollback.exists())
        result=maintenance.execute('purge',self.policy,self.report,True,True)
        self.assertEqual(result['status'],'complete')
        self.assertFalse(self.rollback.exists())

    def test_purge_allows_valid_updates_but_refuses_tampered_original_and_sidecars(self):
        self.policy['original_disposition']='keep'
        build(self.policy,self.report);promote(self.policy,self.report)
        wal=Path(str(self.rollback)+'-wal');wal.write_bytes(b'not safe to replay')
        with self.assertRaisesRegex(RuntimeError,'sidecars'):
            maintenance.execute('purge',self.policy,self.report,True,True)
        self.assertTrue(self.rollback.exists());wal.unlink()
        original=self.rollback.read_bytes();stat=self.rollback.stat()
        changed=bytearray(original);changed[-1]^=1;self.rollback.write_bytes(changed)
        os.utime(self.rollback,ns=(stat.st_atime_ns,stat.st_mtime_ns))
        with self.assertRaisesRegex(RuntimeError,'original changed'):
            maintenance.execute('purge',self.policy,self.report,True,True)
        self.assertTrue(self.rollback.exists())
        self.rollback.write_bytes(original);os.utime(self.rollback,ns=(stat.st_atime_ns,stat.st_mtime_ns))
        db=sqlite3.connect(self.source)
        db.execute('INSERT INTO session VALUES("later",500,500,"normal later use")');db.commit();db.close()
        maintenance.execute('purge',self.policy,self.report,True,True)
        self.assertFalse(self.rollback.exists())
        with contextlib.closing(ro(self.source,True)) as db:
            self.assertEqual(db.execute('SELECT title FROM session WHERE id="later"').fetchone()[0],'normal later use')

    def test_purge_refuses_replaced_active_database(self):
        self.policy['original_disposition']='keep'
        build(self.policy,self.report);promote(self.policy,self.report)
        self.source.rename(self.db_dir/'moved.db');shutil.copyfile(self.db_dir/'moved.db',self.source)
        with self.assertRaisesRegex(RuntimeError,'identity changed'):
            maintenance.execute('purge',self.policy,self.report,True,True)
        self.assertTrue(self.rollback.exists())

    def test_existing_deja_cache_survives_build_and_promotion_without_executable(self):
        cache=self.folder/'cache'/'deja'/'index.db';cache.parent.mkdir(parents=True)
        cache.write_bytes(b'old optional cache')
        policy,_,folder=maintenance.create_plan(self.source,self.folder/'cache-runs')
        policy.update(minimum_free_gib_before_build=0,minimum_free_gib_before_temp=0,minimum_free_gib_during_build=0)
        report=folder/'report.json'
        maintenance.execute('build',policy,report,True,True)
        maintenance.execute('promote',policy,report,True,True)
        self.assertEqual(cache.read_bytes(),b'old optional cache')

    def test_second_build_after_preflight_cannot_overwrite_first_validated_report(self):
        completed={}
        def another_build_finishes_during_host_probe():
            with patch('rebuild.host_stopped',return_value=None):
                build(self.policy,self.report)
            completed['report']=self.report.read_bytes()
            completed['candidate']=file_hash(self.candidate)
        with patch('rebuild.host_stopped',side_effect=another_build_finishes_during_host_probe):
            with self.assertRaises((RuntimeError,FileExistsError)):
                build(self.policy,self.report)
        self.assertEqual(self.report.read_bytes(),completed['report'])
        self.assertEqual(file_hash(self.candidate),completed['candidate'])
        self.assertEqual(json.loads(self.report.read_text(encoding='utf-8'))['status'],'candidate_validated')
        promote(self.policy,self.report)

    def test_validated_atomic_promotion_then_deletion(self):
        build(self.policy,self.report)
        new_hash=file_hash(self.candidate)
        result=promote(self.policy,self.report)
        self.assertEqual(result['status'],'complete')
        self.assertEqual(file_hash(self.source),new_hash)
        self.assertFalse(self.rollback.exists());self.assertFalse(self.candidate.exists())

    def test_tampered_candidate_cannot_replace_original(self):
        build(self.policy,self.report);original=file_hash(self.source)
        metadata=self.candidate.stat()
        db=sqlite3.connect(self.candidate);db.execute('DELETE FROM part');db.commit();db.close()
        os.utime(self.candidate,ns=(metadata.st_atime_ns,metadata.st_mtime_ns))
        with self.assertRaises(RuntimeError):promote(self.policy,self.report)
        self.assertEqual(file_hash(self.source),original);self.assertFalse(self.rollback.exists())
        self.assertEqual(json.loads(self.report.read_text(encoding='utf-8'))['status'],'candidate_validated')

    def test_writer_in_promotion_gap_preserves_both_databases(self):
        build(self.policy,self.report);original=file_hash(self.source)
        handles=[]
        try:
            real_replace=rebuild_opencode.replace_file
            def open_writer(source,candidate,rollback):
                real_replace(source,candidate,rollback)
                handles.append(open(source,'r+b'))
            with patch('rebuild.replace_file',side_effect=open_writer):
                with self.assertRaises(OSError):promote(self.policy,self.report)
            self.assertTrue(self.source.exists());self.assertTrue(self.rollback.exists())
            self.assertEqual(file_hash(self.rollback),original)
        finally:
            for handle in handles:handle.close()

    def test_changed_single_file_deja_index_restores_original_and_keeps_candidate(self):
        index=self.folder/'index.db';index.write_bytes(b'original cache')
        self.policy['preserve_external_paths']=[str(index)]
        build(self.policy,self.report);original=file_hash(self.source)
        index.write_bytes(b'changed cache!')
        with self.assertRaisesRegex(RuntimeError,'External Deja data changed'):
            promote(self.policy,self.report)
        self.assertTrue(self.candidate.exists())
        self.assertEqual(file_hash(self.source),original)
        self.assertFalse(self.rollback.exists())
        self.assertEqual(index.read_bytes(),b'changed cache!')

    def test_report_failure_after_deletion_does_not_claim_original_retained(self):
        build(self.policy,self.report);new_hash=file_hash(self.candidate)
        real_write=rebuild_opencode.write_report
        def fail_complete(path,data):
            if data['status']=='complete':raise OSError('injected report disk failure')
            real_write(path,data)
        with patch('rebuild.write_report',side_effect=fail_complete):
            with self.assertRaises(OSError):promote(self.policy,self.report)
        self.assertFalse(self.rollback.exists())
        self.assertEqual(file_hash(self.source),new_hash)
        state=failure_state(self.policy,self.report)
        self.assertFalse(state['original_retained'])
        self.assertTrue(state['post_switch_validation_recorded'])



    def test_cli_missing_any_execution_acceptance_cannot_checkpoint_or_create_candidate(self):
        self.policy.update(format_version=3,retention_mode='aggressive',cutoff_iso='1970-01-01T00:00:00.100+00:00',
                           integrations={'deja':{'detected':True,'executable':str(self.deja_executable)}})
        path=self.folder/'policy.json';path.write_text(json.dumps(self.policy),encoding='utf-8')
        original=file_hash(self.source)
        all_flags=['--execute','--accept-no-full-backup']
        for missing in all_flags:
            with contextlib.redirect_stdout(io.StringIO()):
                code=maintenance.main(['build','--policy',str(path),'--report',str(self.report)]+
                                      [f for f in all_flags if f!=missing])
            self.assertEqual(code,1)
            self.assertFalse(self.candidate.exists());self.assertFalse(self.report.exists())
            self.assertEqual(file_hash(self.source),original)

    def test_changed_policy_cannot_promote_validated_candidate(self):
        build(self.policy,self.report);original=file_hash(self.source)
        self.policy['cutoff_ms']=999
        with self.assertRaisesRegex(RuntimeError,'Policy changed'):promote(self.policy,self.report)
        self.assertEqual(file_hash(self.source),original);self.assertTrue(self.candidate.exists())
        self.assertFalse(self.rollback.exists())

    def test_same_path_report_in_source_directory_and_low_space_are_refused(self):
        original=file_hash(self.source)
        invalid=dict(self.policy,candidate_db=str(self.source))
        with self.assertRaises(RuntimeError):build(invalid,self.report)
        with self.assertRaises(RuntimeError):build(self.policy,self.db_dir/'source.db-wal')
        with patch('rebuild.shutil.disk_usage',return_value=shutil.disk_usage(self.source)._replace(free=0)):
            with self.assertRaises(RuntimeError):build(dict(self.policy,minimum_free_gib_before_build=1),self.report)
        self.assertEqual(file_hash(self.source),original);self.assertFalse(self.candidate.exists())

    def test_unknown_schema_stops_before_candidate_creation(self):
        db=sqlite3.connect(self.source);db.execute('CREATE TABLE new_conversation(id TEXT)');db.commit();db.close()
        original=file_hash(self.source)
        with self.assertRaisesRegex(RuntimeError,'Unexpected database schema'):build(self.policy,self.report)
        self.assertEqual(file_hash(self.source),original);self.assertFalse(self.candidate.exists())

    def test_source_edit_with_restored_mtime_cannot_discard_new_data_during_promotion(self):
        build(self.policy,self.report);metadata=self.source.stat()
        db=sqlite3.connect(self.source);db.execute('UPDATE session SET title="new title" WHERE id="old"');db.commit();db.close()
        os.utime(self.source,ns=(metadata.st_atime_ns,metadata.st_mtime_ns))
        changed=file_hash(self.source)
        with self.assertRaisesRegex(RuntimeError,'Source changed'):promote(self.policy,self.report)
        self.assertEqual(file_hash(self.source),changed);self.assertFalse(self.rollback.exists())

    def test_partial_replace_failure_keeps_original_under_actual_rollback_name(self):
        build(self.policy,self.report);original=file_hash(self.source)
        def partial(source,candidate,rollback):
            os.rename(source,rollback)
            raise OSError(1177,'Injected partial ReplaceFileW failure')
        with patch('rebuild.replace_file',side_effect=partial):
            with self.assertRaises(OSError):promote(self.policy,self.report)
        self.assertFalse(self.source.exists());self.assertTrue(self.candidate.exists())
        self.assertEqual(file_hash(self.rollback),original)
        self.assertTrue(failure_state(self.policy,self.report)['original_retained'])

    def test_second_month_rebuild_retains_all_session_message_ids_and_further_ages_parts(self):
        build(self.policy,self.report);promote(self.policy,self.report)
        self.policy.update(cutoff_ms=200,candidate_db=str(self.db_dir/'second.db'),rollback_db=str(self.db_dir/'second-old.db'))
        second_report=self.folder/'second.json'
        build(self.policy,second_report);promote(self.policy,second_report)
        with contextlib.closing(ro(self.source,True)) as db:
            self.assertEqual(db.execute('SELECT id FROM session ORDER BY id').fetchall(),[('boundary',),('old',),('recent',)])
            self.assertEqual(db.execute('SELECT id FROM message ORDER BY id').fetchall(),[('m_boundary',),('m_old',),('m_recent',)])
            self.assertEqual(db.execute('SELECT id FROM part ORDER BY id').fetchall(),[('bash',),('read',),('text',)])
            self.assertEqual(db.execute('SELECT count(*) FROM event').fetchone()[0],0)

    def test_lease_blocks_duplicate_maintenance_without_creating_candidate(self):
        with rebuild_opencode.MaintenanceLease(self.source):
            with self.assertRaises(OSError):build(self.policy,self.report)
        self.assertFalse(self.candidate.exists())
        self.assertFalse(Path(str(self.source)+'.maintenance.lock').exists())

    def test_all_retained_edit_and_shell_inputs_survive(self):
        inputs={'shell':{'command':'echo keep'},'apply_patch':{'patchText':'*** keep patch'},
                'patch':{'patch':'keep patch'},'edit':{'filePath':'f','oldString':'before','newString':'after'},
                'write':{'filePath':'f','content':'complete content'}}
        db=sqlite3.connect(self.source)
        for name,value in inputs.items():
            data={'type':'tool','tool':name,'state':{'status':'completed','input':value,'output':'keep shell output',
                                                  'metadata':{'exit':5,'unused':'drop'},'time':{'start':7}}}
            db.execute('INSERT INTO part VALUES(?,?,?,?,?,?)',(name,'m_old','old',1,1,json.dumps(data)))
        db.commit();db.close();build(self.policy,self.report)
        with contextlib.closing(ro(self.candidate,True)) as db:
            for name,expected in inputs.items():
                state=json.loads(db.execute('SELECT data FROM part WHERE id=?',(name,)).fetchone()[0])['state']
                self.assertEqual(state['input'],expected)
                self.assertEqual(state['output'],'keep shell output' if name=='shell' else '')
                self.assertEqual(state['metadata'],{'exit':5});self.assertEqual(state['time'],{'start':7})

    def test_rollback_path_replacement_before_delete_cannot_delete_unrelated_file(self):
        build(self.policy,self.report);original=file_hash(self.source)
        moved=self.db_dir/'renamed-original.db'
        real_write=rebuild_opencode.write_report
        def replace_path(path,data):
            real_write(path,data)
            if data['status']=='post_switch_validated':
                os.rename(self.rollback,moved)
                self.rollback.write_bytes(b'UNRELATED FILE MUST SURVIVE')
        with patch('rebuild.write_report',side_effect=replace_path):
            with self.assertRaisesRegex(RuntimeError,'Rollback handle'):promote(self.policy,self.report)
        self.assertEqual(file_hash(moved),original)
        self.assertEqual(self.rollback.read_bytes(),b'UNRELATED FILE MUST SURVIVE')
        self.assertEqual(json.loads(self.report.read_text(encoding='utf-8'))['status'],'post_switch_validated')

    def test_rollback_rename_after_delete_handle_open_never_targets_new_path_occupant(self):
        build(self.policy,self.report)
        moved=self.db_dir/'moved-original.db'
        real_identity=rebuild_opencode.handle_identity
        calls=[]
        def rename_after_identity(guard):
            result=real_identity(guard);calls.append(1)
            if len(calls)==2:
                os.rename(self.rollback,moved)
                self.rollback.write_bytes(b'UNRELATED FILE MUST SURVIVE')
            return result
        with patch('rebuild.handle_identity',side_effect=rename_after_identity):
            with self.assertRaisesRegex(RuntimeError,'pathname reoccupied'):promote(self.policy,self.report)
        self.assertEqual(self.rollback.read_bytes(),b'UNRELATED FILE MUST SURVIVE')
        self.assertFalse(moved.exists())
        self.assertEqual(json.loads(self.report.read_text(encoding='utf-8'))['status'],'post_switch_validated')

    def test_invalid_source_references_or_session_ownership_stop_before_candidate(self):
        db=sqlite3.connect(self.source);db.execute('UPDATE event SET aggregate_id="missing" WHERE id="e_old"');db.commit();db.close()
        original=file_hash(self.source)
        with self.assertRaisesRegex(RuntimeError,'Source foreign_key_check'):build(self.policy,self.report)
        self.assertEqual(file_hash(self.source),original);self.assertFalse(self.candidate.exists())
        db=sqlite3.connect(self.source);db.execute('UPDATE event SET aggregate_id="old" WHERE id="e_old"')
        db.execute('UPDATE part SET session_id="recent" WHERE id="text"');db.commit();db.close()
        original=file_hash(self.source)
        with self.assertRaisesRegex(RuntimeError,'ownership disagree'):build(self.policy,self.report)
        self.assertEqual(file_hash(self.source),original);self.assertFalse(self.candidate.exists())

    def test_default_compact_without_deja_reclaims_space_and_retains_every_raw_row(self):
        db=sqlite3.connect(self.source)
        db.execute('INSERT INTO session_message VALUES("alternative store must remain")')
        db.executemany('INSERT INTO untouched VALUES(?,?)',[(n,b'x'*8192) for n in range(1000,1012)])
        db.commit();db.execute('DELETE FROM untouched WHERE id>=1000');db.commit()
        self.assertGreater(db.execute('PRAGMA freelist_count').fetchone()[0],0)
        tables=('session','message','part','event','event_sequence','allocator','untouched','session_message','sqlite_sequence')
        expected={t:db.execute('SELECT rowid,* FROM "'+t+'" ORDER BY rowid').fetchall() for t in tables}
        db.close();original=file_hash(self.source);old_size=self.source.stat().st_size
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            code=maintenance.main(['plan','--source',str(self.source),'--run-root',str(self.folder/'compact-runs')])
        self.assertEqual(code,0)
        folder=Path(json.loads(output.getvalue().strip().splitlines()[-1])['run_directory'])
        audit=json.loads((folder/'estimate.json').read_text(encoding='utf-8'))
        policy=maintenance.load_policy(folder/'policy.json')
        self.assertFalse(policy['integrations']['deja']['detected'])
        self.assertEqual(policy['retention_mode'],'compact');self.assertIsNone(policy['cutoff_ms'])
        self.assertIsNone(policy['cutoff_iso']);self.assertIsNone(policy['retention_days'])
        self.assertEqual(audit['tables']['part']['removed_rows'],0)
        self.assertEqual(audit['tables']['event']['removed_rows'],0)
        self.assertFalse(any(Path(p).name=='index.db' for p in policy['preserve_external_paths']))
        self.assertEqual(file_hash(self.source),original)
        policy.update(minimum_free_gib_before_build=0,minimum_free_gib_before_temp=0,minimum_free_gib_during_build=0)
        (folder/'policy.json').write_text(json.dumps(policy),encoding='utf-8')
        report=folder/'report.json'
        for action in ('build','promote'):
            with contextlib.redirect_stdout(io.StringIO()):
                code=maintenance.main([action,'--policy',str(folder/'policy.json'),'--report',str(report),
                                       '--execute'])
            self.assertEqual(code,0)
        result=json.loads(report.read_text(encoding='utf-8'))
        self.assertEqual(result['status'],'original_retained');self.assertEqual(result['changed_json_rows'],0)
        self.assertEqual(file_hash(Path(policy['rollback_db'])),original)
        maintenance.execute('purge',policy,report,True,True)
        self.assertLess(self.source.stat().st_size,old_size)
        with contextlib.closing(ro(self.source,True)) as db:
            actual={t:db.execute('SELECT rowid,* FROM "'+t+'" ORDER BY rowid').fetchall() for t in tables}
        self.assertEqual(actual,expected)


    def test_aggressive_mode_without_deja_can_plan_build_and_promote(self):
        original=file_hash(self.source)
        output=io.StringIO()
        with contextlib.redirect_stdout(output):
            code=maintenance.main(['plan','--source',str(self.source),'--run-root',str(self.folder/'missing-runs'),
                                   '--mode','aggressive','--original','delete'])
        self.assertEqual(code,0)
        folder=Path(json.loads(output.getvalue().strip().splitlines()[-1])['run_directory'])
        policy=maintenance.load_policy(folder/'policy.json')
        self.assertFalse(policy['integrations']['deja']['detected'])
        self.assertEqual(policy['retention_mode'],'aggressive');self.assertEqual(policy['retention_days'],30)
        self.assertEqual(file_hash(self.source),original)
        policy.update(minimum_free_gib_before_build=0,minimum_free_gib_before_temp=0,minimum_free_gib_during_build=0)
        (folder/'policy.json').write_text(json.dumps(policy),encoding='utf-8')
        report=folder/'report.json'
        for action in ('build','promote'):
            with contextlib.redirect_stdout(io.StringIO()):
                code=maintenance.main([action,'--policy',str(folder/'policy.json'),'--report',str(report),
                                       '--execute','--accept-no-full-backup'])
            self.assertEqual(code,0)
        with contextlib.closing(ro(self.source,True)) as db:
            self.assertEqual(db.execute('SELECT id FROM session ORDER BY id').fetchall(),[('boundary',),('old',),('recent',)])
            self.assertEqual(db.execute('SELECT count(*) FROM message').fetchone()[0],3)
            self.assertEqual(db.execute('SELECT id FROM part ORDER BY id').fetchall(),[('bash',),('read',),('text',)])
            self.assertEqual(db.execute('SELECT count(*) FROM event').fetchone()[0],0)
            old=json.loads(db.execute('SELECT data FROM message WHERE id="m_old"').fetchone()[0])
            self.assertEqual(old['summary']['diffs'],[])



    def test_real_path_discovery_finds_windows_cmd_shim(self):
        binary_dir=self.folder/'bin';binary_dir.mkdir()
        shim=binary_dir/'deja.cmd';shim.write_text('@echo off\nexit /b 0\n',encoding='utf-8')
        with patch('maintenance.shutil.which',side_effect=self.real_which), \
                patch.dict(os.environ,{'PATH':str(binary_dir),'PATHEXT':'.COM;.EXE;.BAT;.CMD'}):
            result=maintenance.discover_deja()
        self.assertTrue(result['detected'])
        self.assertEqual(Path(result['executable']),shim)

    def test_path_ps1_discovery_survives_legacy_which_not_recognizing_extension(self):
        binary_dir=self.folder/'ps1-bin';binary_dir.mkdir()
        shim=binary_dir/'deja.ps1';shim.write_text('exit 0\n',encoding='utf-8')
        # Python 3.11 + 常見 PATHEXT 對唯有 .ps1 的 PATH 回 None；保留真實檔案。
        with patch('maintenance.shutil.which',return_value=None), \
                patch.dict(os.environ,{'PATH':str(binary_dir),'PATHEXT':'.COM;.EXE;.BAT;.CMD'}):
            result=maintenance.discover_deja()
        self.assertTrue(result['detected']);self.assertEqual(Path(result['executable']),shim)


if __name__=='__main__':unittest.main(verbosity=2)


class PortableTests(SQLiteFixture):
    def test_30_days_is_720_hours_across_month_end_and_offset(self):
        now=datetime(2024,3,31,12,0,tzinfo=timezone(timedelta(hours=8)))
        ms,iso=maintenance.freeze_cutoff(now,30)
        self.assertEqual(iso,'2024-03-01T12:00:00.000+08:00')
        self.assertEqual(int(now.timestamp()*1000)-ms,2592000000)
        with self.assertRaises(RuntimeError):maintenance.freeze_cutoff(now,0)
    def test_plan_is_readonly_and_each_run_has_frozen_policy_and_unique_names(self):
        original=file_hash(self.source)
        with patch('maintenance.datetime',wraps=datetime) as clock:
            clock.now.return_value=datetime(2024,3,31,12,0,tzinfo=timezone.utc)
            first,audit,folder=maintenance.create_plan(self.source,self.folder/'runs',mode='aggressive',deja_executable=self.deja_executable)
            clock.now.return_value=datetime(2024,4,30,12,0,tzinfo=timezone.utc)
            second,_,_=maintenance.create_plan(self.source,self.folder/'runs',mode='aggressive',deja_executable=self.deja_executable)
        self.assertEqual(datetime.fromisoformat(first['cutoff_iso']),datetime(2024,3,1,12,0,tzinfo=timezone.utc))
        self.assertEqual(datetime.fromisoformat(second['cutoff_iso']),datetime(2024,3,31,12,0,tzinfo=timezone.utc))
        self.assertEqual(maintenance.load_policy(folder/'policy.json')['cutoff_ms'],first['cutoff_ms'])
        self.assertNotEqual(first['candidate_db'],second['candidate_db'])
        self.assertEqual(audit['tables']['message']['retained_rows'],3)
        self.assertEqual(audit['tables']['part']['retained_rows'],3)
        self.assertEqual(audit['tables']['event']['retained_rows'],0)
        self.assertGreater(audit['recommended_start_free_bytes'],8*2**30)
        self.assertEqual(file_hash(self.source),original)
        self.assertFalse(Path(first['candidate_db']).exists())
        self.assertFalse(Path(second['candidate_db']).exists())
    def test_deja_present_does_not_automatically_select_lossy_mode(self):
        with patch('maintenance.shutil.which',return_value=str(self.deja_executable)):
            policy,audit,_=maintenance.create_plan(self.source,self.folder/'present-runs')
        self.assertTrue(policy['integrations']['deja']['detected'])
        self.assertEqual(policy['retention_mode'],'compact')
        self.assertEqual(audit['tables']['part']['retained_rows'],8)
        self.assertEqual(audit['tables']['event']['retained_rows'],4)
    def test_existing_deja_cache_is_preserved_even_without_executable(self):
        cache=self.folder/'cache'/'deja'/'index.db';cache.parent.mkdir(parents=True)
        cache.write_bytes(b'old optional cache')
        policy,_,folder=maintenance.create_plan(self.source,self.folder/'cache-runs')
        self.assertIn(str(cache),policy['preserve_external_paths'])
        self.assertFalse(Path(policy['candidate_db']).exists())
        self.assertEqual(cache.read_bytes(),b'old optional cache')

    def test_old_or_missing_mode_policy_is_rejected_instead_of_assuming_deja(self):
        path=self.folder/'stale-policy.json'
        for stale in ({'format_version':1,'retention_mode':'deja-v1'}, {'format_version':2},
                      {'format_version':2,'retention_mode':'deja-v1'}):
            path.write_text(json.dumps(stale),encoding='utf-8')
            with self.assertRaises(RuntimeError):maintenance.load_policy(path)
        invalid=dict(self.policy);del invalid['retention_mode']
        with self.assertRaises(RuntimeError):build(invalid,self.report)
        self.assertFalse(self.candidate.exists());self.assertFalse(self.report.exists())

    def test_quick_audit_does_not_scan_history_and_reports_freelist_without_size_promise(self):
        before=file_hash(self.source)
        db=sqlite3.connect(self.source)
        db.execute('CREATE TABLE large_scratch(data BLOB)')
        db.execute('INSERT INTO large_scratch VALUES(zeroblob(2097152))')
        db.commit(); db.execute('DROP TABLE large_scratch');db.commit();db.close()
        before=file_hash(self.source)
        with patch('maintenance.profile',side_effect=AssertionError('full scan forbidden')):
            result=maintenance.quick_audit(self.source,min_reclaim_gib=0.001,min_free_ratio=0.1)
        self.assertGreater(result['freelist_bytes'],1048576)
        self.assertEqual(result['recommendation'],'estimate_compact')
        self.assertNotIn('estimated_candidate_bytes',result)
        self.assertEqual(file_hash(self.source),before)

    def test_schema_diagnostic_reports_added_and_changed_objects_without_sql_values(self):
        db=sqlite3.connect(self.source)
        db.execute("ALTER TABLE session ADD COLUMN note TEXT DEFAULT 'PRIVATE_LITERAL'")
        db.execute('CREATE TABLE newer_store(id TEXT)');db.commit();db.close()
        before=file_hash(self.source)
        out=io.StringIO()
        with contextlib.redirect_stdout(out):
            code=maintenance.main(['plan','--source',str(self.source),'--run-root',str(self.folder/'runs')])
        self.assertEqual(code,1)
        diagnostic=json.loads(out.getvalue())['schema_diagnostics']
        self.assertIn(['table','newer_store'],diagnostic['differences'][0]['added_objects'])
        self.assertIn(['table','session'],diagnostic['differences'][0]['changed_objects'])
        self.assertNotIn('PRIVATE_LITERAL',out.getvalue())
        self.assertEqual(file_hash(self.source),before)

    def test_inspect_partial_replace_never_opens_sqlite_or_pairs_source_wal_with_candidate(self):
        policy=dict(self.policy)
        original_identity=rebuild_opencode.identity(self.source)
        shutil.copyfile(self.source,self.candidate)
        report={'status':'promotion_started','policy_sha256':rebuild_opencode.policy_hash(policy),
                'source_identity':original_identity,'candidate_identity':rebuild_opencode.identity(self.candidate),
                'source_sha256':file_hash(self.source),'candidate_sha256':file_hash(self.candidate)}
        self.report.write_text(json.dumps(report),encoding='utf-8')
        self.source.rename(self.rollback)
        wal=Path(str(self.source)+'-wal');wal.write_bytes(b'preserve uncertain WAL')
        with patch('rebuild.ro',side_effect=AssertionError('must not open SQLite')):
            result=maintenance.inspect_run(policy,self.report,verify_hashes=True)
        self.assertEqual(result['files']['source_db']['exists'],False)
        self.assertEqual(result['files']['rollback_db']['matching_recorded_roles'],['original'])
        self.assertEqual(result['files']['source_db']['sidecars']['-wal'],22)
        self.assertEqual(result['next_action'],'manual_recovery_required_preserve_all_files')
        self.assertTrue(wal.exists());self.assertTrue(self.candidate.exists());self.assertTrue(self.rollback.exists())

    def test_published_schema_manifest_matches_its_real_sqlite_structure(self):
        manifest=json.loads((Path(__file__).parents[1]/'references'/'compatibility.json').read_text(encoding='utf-8'))
        target=self.folder/'published.db'
        db=sqlite3.connect(target)
        for kind,name,table,sql in manifest['supported_schemas'][0]['schema']:
            if kind=='table':db.execute(sql)
        for kind,name,table,sql in manifest['supported_schemas'][0]['schema']:
            if kind=='index':db.execute(sql)
        db.commit()
        with patch.dict(rebuild_opencode.COMPATIBILITY,manifest):
            self.assertTrue(rebuild_opencode.schema_diagnostics(db)['supported'])
            rebuild_opencode.check_schema(db)
        db.close()
