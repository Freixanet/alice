import unittest
from unittest import mock
import test_watchers as f

class ActivationBaselineTests(unittest.TestCase):
    def setUp(self):
        # These tests begin with a genuinely new, paused watch.
        self.temp = f.tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.now = 100000.
        self.store = f.w.Store(f.Path(self.temp.name), clock=lambda: self.now)
        self.addCleanup(self.store.close); self.store.configure('local', f.ROUTE)

    def create(self, code=f.CODE):
        return self.store.create('local','Invoice','feed',{'url':'https://feed.invalid/items','every_minutes':1},code,'Notify overdue invoices')['id']

    def activate(self, ident, classifier=None):
        return self.store.activate(ident, runner=f.Script(), classifier=classifier or f.Cheap(),
                                   sample={'id':'sample','body':'invoice overdue'})

    def test_noop_refused_and_reason_persisted(self):
        ident=self.create('pass')
        with self.assertRaisesRegex(f.w.WatcherError, 'Activation validation'):
            self.activate(ident)
        row=self.store.get(ident)
        self.assertEqual(row['status'],'paused')
        self.assertIn('classify',row['activation_error'])
        self.assertEqual(self.store.pending(ident),[])

    def test_classification_without_terminal_action_refused(self):
        ident=self.create(f.CODE.split('action =')[0])
        with self.assertRaisesRegex(f.w.WatcherError,'fully processed'):
            self.activate(ident)
        self.assertEqual(self.store.get(ident)['status'],'paused')

    def test_script_that_only_acks_quiet_cannot_pass_notify_path_probe(self):
        ident=self.create(f.CODE.split('action =')[0] + '\nack(event["id"])')
        with self.assertRaises(f.w.WatcherError): self.activate(ident)
        self.assertEqual(self.store.get(ident)['status'],'paused')

    def test_empty_notification_rejected_in_dry_run(self):
        ident=self.create(f.CODE.replace('notify(event["body"], event["id"])','notify("", event["id"])'))
        with self.assertRaisesRegex(f.w.WatcherError,'bounded message'): self.activate(ident)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM inbox').fetchone()[0],0)

    def test_classifier_error_cannot_activate_or_notify(self):
        ident=self.create()
        with self.assertRaisesRegex(f.w.WatcherError,'classifier_error'):
            self.activate(ident,f.Cheap(TimeoutError()))
        self.assertEqual(self.store.get(ident)['status'],'paused')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM inbox').fetchone()[0],0)

    def test_shadowing_parameters_and_capability_attributes_rejected(self):
        runner=f.w.sibling('watcher_runner.py')
        for cap in ('classify','notify','ack','state','log'):
            for code in (f'def helper({cap}):\n    pass\nhelper(None)', f'x = lambda {cap}: None\nx(None)'):
                with self.subTest(code=code), self.assertRaises(runner.RunnerError): runner.validate_code(code)
        with self.assertRaises(runner.RunnerError): runner.validate_code('state.get = lambda: {}')

    def test_pattern_binding_cannot_shadow_capabilities(self):
        runner=f.w.sibling('watcher_runner.py')
        for code in ('match event:\n    case {"x": classify}:\n        pass',
                     'match event:\n    case {"x": x, **state}:\n        pass'):
            with self.assertRaises(runner.RunnerError):runner.validate_code(code)

    def test_baseline_ignores_history_without_ack_then_processes_new_only(self):
        ident=self.create(); self.activate(ident)
        cheap=f.Cheap(); main=f.Main(); engine=f.w.Engine(self.store,cheap,f.Script())
        old={'id':'old','body':'invoice overdue'}
        f.service.tick(self.store.home,store=self.store,sources=f.Source([old]),engine=engine,delivery=main)
        self.assertEqual(cheap.calls,0); self.assertEqual(main.calls,0)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM events').fetchone()[0],0)
        self.assertEqual(self.store.get(ident)['baseline']['newest_id'],'old')
        self.now+=61
        new={'id':'new','body':'invoice overdue'}
        f.service.tick(self.store.home,store=self.store,sources=f.Source([new,old,{'id':'older','body':'invoice overdue'}]),engine=engine,delivery=main,force=True)
        self.assertEqual(cheap.calls,1);self.assertEqual(main.calls,1)
        self.assertEqual([r[0] for r in self.store.db.execute('SELECT id FROM events')],['new'])

    def test_gmail_poll_uses_server_arrival_cutoff_not_sender_date(self):
        source=f.w.sibling('watcher_sources.py').Sources(self.store.home)
        source.gmail=mock.Mock(return_value=[])
        source.items({'source':'email','config':{'query':'in:anywhere {from:barkibu barkibu}'},
                      'baseline':{'at':100000.5}},self.now)
        source.gmail.assert_called_once_with(['search','(in:anywhere {from:barkibu barkibu}) after:100001','--max','20'])

    def test_unanchored_historical_page_is_not_treated_as_new(self):
        ident=self.create();self.activate(ident)
        self.store.source_events(ident,[{'id':'newest','body':'invoice overdue'}])
        self.now+=61
        self.assertEqual(self.store.source_events(ident,[{'id':'older','body':'invoice overdue'}]),[])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM events').fetchone()[0],0)

    def test_failed_ingest_does_not_advance_baseline_past_unstored_events(self):
        ident=self.create();self.activate(ident)
        old={'id':'old','body':'invoice overdue'}
        self.store.source_events(ident,[old]);self.now+=61
        new={'id':'new','body':'invoice overdue'}
        with mock.patch.object(self.store,'ingest',side_effect=f.w.WatcherError('disk full')):
            f.service.tick(self.store.home,store=self.store,sources=f.Source([new,old]),
                           engine=f.w.Engine(self.store,f.Cheap(),f.Script()),delivery=f.Main())
        self.assertNotIn('new',self.store.get(ident)['baseline']['seen'])
        self.assertEqual(self.store.source_events(ident,[new,old]),[new])

    def test_builtin_future_trigger_does_not_need_previous_day_anchor(self):
        ident=self.store.create('local','Birthday','builtin',{'kind':'birthday'},f.CODE,'Notify birthdays')['id']
        self.activate(ident)
        old={'id':'birthday:old:2026-10-09','body':'invoice overdue'}
        self.store.source_events(ident,[old]);self.now+=86400
        new={'id':'birthday:new:2026-10-10','body':'invoice overdue'}
        self.assertEqual(self.store.source_events(ident,[new]),[new])
        self.assertEqual(self.store.source_events(ident,[old]),[])

    def test_valid_gate_is_dry_and_records_proof(self):
        ident=self.create(); row=self.activate(ident)
        self.assertEqual(row['status'],'active')
        self.assertTrue(row['activation_validation']['acked'])
        self.assertIn('classify',row['activation_validation']['capabilities'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM events').fetchone()[0],0)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM inbox').fetchone()[0],0)

if __name__=='__main__': unittest.main()
