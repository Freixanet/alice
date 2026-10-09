import unittest
from pathlib import Path
from unittest import mock
import test_watchers as fixtures
from test_watchers import Script, Cheap, w

class EmailRepairTests(unittest.TestCase):
    setUp = fixtures.WatcherTests.setUp
    create = fixtures.WatcherTests.create
    def test_dormant_entrypoint_and_classifier_shadow_are_rejected(self):
        runner = w.sibling('watcher_runner.py')
        for code in ('def run(event):\n    ack(event["id"])\n',
                     'def classify(event, questions):\n    return {}\nack(event["id"])',
                     'classify = lambda event, questions: {}\nack(event["id"])'):
            with self.assertRaises(runner.RunnerError): runner.validate_code(code)

    def test_matching_email_uses_broker_then_notify_and_ack_even_with_empty_body(self):
        code = w.sibling('watcher_builtins.py').EMAIL_MATCH_CODE
        row = self.store.create('local','Forwarded email','email',{'query':'from:sender@example.com','every_minutes':30},code,'Notify every matching email')
        self.store.activate(row['id'],runner=Script())
        event={'id':'email','from':'Sender <sender@example.com>','subject':'Fwd: insurance','date':'2026-10-09','body':''}
        self.store.ingest(row['id'],event)
        classifier=mock.Mock()
        classifier.classify.return_value={'action':{'key':'notify','confidence':1,'probabilities':{'notify':1,'quiet':0}}}
        result=w.Engine(self.store,classifier=classifier,runner=Script()).run_event(row['id'],'email')
        self.assertTrue(result['notified']);self.assertTrue(result['acked'])
        classifier.classify.assert_called_once()
        self.assertEqual(self.store.pending(row['id']),[])
        self.assertIn('insurance',self.store.db.execute('SELECT content FROM inbox').fetchone()[0])

    def test_repaired_email_classifier_error_keeps_pending_and_never_notifies(self):
        code=w.sibling('watcher_builtins.py').EMAIL_MATCH_CODE
        row=self.store.create('local','Email','email',{'query':'from:sender@example.com'},code,'Notify matching emails')
        self.store.activate(row['id'],runner=Script())
        self.store.ingest(row['id'],{'id':'email','body':'','subject':'Fwd: insurance'})
        result=w.Engine(self.store,classifier=Cheap(TimeoutError()),runner=Script()).run_event(row['id'],'email')
        self.assertFalse(result['notified']);self.assertFalse(result['acked'])
        self.assertEqual(len(self.store.pending(row['id'])),1)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM inbox').fetchone()[0],0)
