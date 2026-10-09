import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

class TaskAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        spec=importlib.util.spec_from_file_location('review_task_api_test',Path(__file__).resolve().parents[1]/'dashboard/plugin_api.py')
        cls.api=importlib.util.module_from_spec(spec);sys.modules[spec.name]=cls.api;spec.loader.exec_module(cls.api)
        app=FastAPI();app.include_router(cls.api.router,prefix=cls.api.PLUGIN_PREFIX);cls.client=TestClient(app)
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        p=mock.patch.object(self.api,'_hermes_root',return_value=Path(self.temp.name));p.start();self.addCleanup(p.stop)
        self.store=self.api._sibling('review_tasks.py','alice_review_tasks').Store(self.temp.name);self.addCleanup(self.store.close)
        self.root='/api/plugins/alice/review-tasks'
    def task(self):
        t=self.store.create('Reply','Reply to an invoice','session','default')
        return self.store.update(t['id'],1,'needs_review',session='session',profile='default',summary='Draft ready',checks=['Checked recipient'],decision='send',proposal={'tool':'gmail_send_draft','args':{'id':'draft'},'description':'Send reply'})
    def test_stale_accept_returns_conflict_with_current_version(self):
        t=self.task();newer=self.store.update(t['id'],t['version'],'in_progress',session='session',profile='default',summary='Correcting recipient')
        result=self.client.post(self.root+f"/{t['id']}/decision",json={'action':'accept','version':t['version']})
        self.assertEqual(result.status_code,409);self.assertEqual(result.json()['tasks'][0]['version'],newer['version'])
    def test_autonomy_and_single_claim_keep_original_profile(self):
        self.assertEqual(self.client.put(self.root+'/autonomy',json={'autonomy':'draft_only'}).status_code,200)
        self.assertEqual(self.client.get(self.root).json()['autonomy'],'draft_only')
        t=self.task();accepted=self.client.post(self.root+f"/{t['id']}/decision",json={'action':'accept','version':t['version']}).json()['task']
        route=self.root+f"/{t['id']}/continue"
        body={'version':accepted['version'],'aliases':['live','session']}
        self.assertEqual(self.client.post(route,json=body).status_code,200)
        self.assertEqual(self.client.post(route,json=body).status_code,409)
        self.assertEqual(self.store.get(t['id'])['profile'],'default')
        self.assertTrue(self.store.consume('gmail_send_draft',{'id':'draft'},'live','default'))
    def test_version_is_strict_and_owner_remains_local(self):
        t=self.task();route=self.root+f"/{t['id']}/decision"
        for version in (True,'2'):
            self.assertEqual(self.client.post(route,json={'action':'accept','version':version}).status_code,422)
        self.assertEqual(self.client.post(route,json={'action':'accept','version':t['version'],'owner':'other'}).status_code,422)
