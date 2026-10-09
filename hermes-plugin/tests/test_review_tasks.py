import importlib.util
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
r, g = load('review_tasks'), load('review_task_guard')

class ReviewTasksTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store = r.Store(self.temp.name); self.addCleanup(self.store.close)
        self.task = self.store.create('Reply to invoice', 'Prepare a reply, check the amount, then ask before sending.', 'session', 'default')
    def review(self, task=None, **changes):
        t = task or self.task
        args = dict(session='session', profile='default', checks=['Compared amount and recipient with original invoice'],
                    summary='Prepared the reply.', decision='send', proposal={'tool':'gmail_send_draft','args':{'id':'draft-1'},'description':'Send the prepared reply to the invoice sender'},
                    result=[{'type':'draft','channel':'email','to':['person@example.com'],'body':'The amount is correct.'}])
        args.update(changes)
        return self.store.update(t['id'], t['version'], 'needs_review', **args)
    def test_stale_accept_rejected_and_current_version_preserved(self):
        first = self.review()
        newer = self.review(first, summary='Corrected the amount.')
        with self.assertRaises(r.Conflict): self.store.respond(first['id'], first['version'], 'accept')
        self.assertEqual(self.store.get(first['id'])['version'], newer['version'])
        self.assertFalse(self.store.consume('gmail_send_draft', {'id':'draft-1'}, 'session', 'default'))
    def test_exact_single_use_owner_and_session_bound_approval(self):
        t = self.review(); approved = self.store.respond(t['id'], t['version'], 'accept')
        self.assertEqual(approved['status'], 'in_progress')
        self.assertFalse(self.store.consume('gmail_send_draft', {'id':'draft-2'}, 'session', 'default'))
        self.assertFalse(self.store.consume('gmail_send_draft', {'id':'draft-1'}, 'other-session', 'default'))
        self.assertFalse(self.store.consume('gmail_send_draft', {'id':'draft-1'}, 'session', 'other-profile'))
        self.assertTrue(self.store.consume('gmail_send_draft', {'id':'draft-1'}, 'session', 'default'))
        self.assertFalse(self.store.consume('gmail_send_draft', {'id':'draft-1'}, 'session', 'default'))
        row=self.store.db.execute('SELECT approver,approved_at FROM approvals').fetchone()
        self.assertEqual(row['approver'],'local'); self.assertGreater(row['approved_at'],0)
    def test_check_required_and_routine_progress_not_review(self):
        with self.assertRaises(ValueError): self.review(checks=[])
        with self.assertRaises(ValueError): self.review(decision='progress')
        t=self.store.update(self.task['id'],1,'in_progress',session='session',profile='default',summary='Reading the invoice')
        self.assertIsNone(t['attention_id'])
    def test_attention_cards_retire_and_new_round_gets_new_id(self):
        t=self.review(); first=t['attention_id']
        t=self.store.respond(t['id'],t['version'],'change','Correct the recipient')
        self.assertIsNone(t['attention_id'])
        t=self.review(t)
        self.assertNotEqual(first,t['attention_id'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM attention WHERE task=? AND live=1',(t['id'],)).fetchone()[0],1)
    def test_task_change_invalidates_acceptance(self):
        t=self.review(); t=self.store.respond(t['id'],t['version'],'accept')
        self.store.update(t['id'],t['version'],'in_progress',session='session',profile='default',summary='Changed plan')
        self.assertFalse(self.store.consume('gmail_send_draft',{'id':'draft-1'},'session','default'))
    def test_blocked_requires_input_and_answer_retires_card(self):
        with self.assertRaises(ValueError): self.store.update(self.task['id'],1,'blocked',session='session',profile='default')
        t=self.store.update(self.task['id'],1,'blocked',session='session',profile='default',question='Which recipient?')
        t=self.store.respond(t['id'],t['version'],'answer','person@example.com')
        self.assertEqual(t['feedback'],['person@example.com']); self.assertIsNone(t['attention_id'])
    def test_draft_only_gates_every_nonpreparation_tool_without_calling_it(self):
        self.store.configure('draft_only')
        for tool,args in [('gmail_send_draft',{'id':'d'}),('gmail_create_draft',{}),('pay',{}),('book',{}),('delete_file',{}),('publish',{}),('update_event',{}),('unknown_extension',{}),('terminal',{'command':'python -c "send()"'}),('browser_click',{'target':'Send'}),('browser_navigate',{'url':'javascript:send()'}),('browser_navigate',{'url':'https://example.com/unsubscribe'}),('google_workspace',{'action':'get','method':'DELETE'})]:
            with self.subTest(tool=tool): self.assertEqual(g.check(self.temp.name,tool,args,'untracked','default')['action'],'block')
        for tool,args in [('web_search',{'query':'invoice'}),('terminal',{'command':'ls -la'})]:
            self.assertIsNone(g.check(self.temp.name,tool,args,'session','default'))
    def test_accepted_draft_only_action_executes_once(self):
        self.store.configure('draft_only'); t=self.review(); self.store.respond(t['id'],t['version'],'accept')
        self.assertIsNone(g.check(self.temp.name,'gmail_send_draft',{'id':'draft-1'},'session','default'))
        self.assertEqual(g.check(self.temp.name,'gmail_send_draft',{'id':'draft-1'},'session','default')['action'],'block')
    def test_agent_cannot_accept_or_change_autonomy(self):
        tools=load('review_task_tools')
        for action in ('accept','configure'):
            with self.assertRaises(ValueError): tools.run(self.temp.name,{'action':action},'session','default')
        with self.assertRaises(ValueError): self.store.get(self.task['id'],session='other',profile='default')
        with self.assertRaises(ValueError): self.store.get(self.task['id'],owner='other')
    def test_results_reject_code_and_unsafe_links(self):
        for value in ([{'type':'html','text':'<script>send()</script>'}],[{'type':'link_card','title':'Click','url':'javascript:send()'}],[{'type':'table','columns':['A'],'rows':[['one','two']]}]):
            with self.assertRaises(ValueError): r.blocks(value)

    def test_closing_a_task_cannot_bypass_its_action_guard(self):
        self.store.update(self.task['id'], 1, 'done', session='session', profile='default', checks=['Result checked'])
        self.assertEqual(g.check(self.temp.name, 'send', {}, 'session', 'default')['action'], 'block')
        self.assertIsNone(g.check(self.temp.name, 'send', {}, 'legacy-chat', 'default'))
        self.store.configure('draft_only')
        self.assertEqual(g.check(self.temp.name, 'send', {}, 'legacy-chat', 'default')['action'], 'block')

    def test_malformed_native_fields_do_not_poison_the_board(self):
        for value in ([{'type':'draft', 'channel':'email', 'body':'Hi', 'to':[42]}],
                      [{'type':'event', 'title':'Meeting', 'startIso': {}}],
                      [{'type':'checklist', 'items':[42]}],
                      [{'type':'text', 'text':'Safe', 'script':'execute()'}]):
            with self.assertRaises(ValueError): r.blocks(value)

    def test_ambiguous_continuation_is_never_claimed_twice(self):
        t = self.review(); t = self.store.respond(t['id'], t['version'], 'accept')
        self.store.claim_resume(t['id'], t['version'], ['live', 'session'])
        self.store.finish_resume(t['id'], t['version'], 'unknown')
        with self.assertRaises(r.Conflict): self.store.claim_resume(t['id'], t['version'], ['live', 'session'])
        self.assertTrue(self.store.consume('gmail_send_draft', {'id':'draft-1'}, 'live', 'default'))
        self.assertFalse(self.store.consume('gmail_send_draft', {'id':'draft-1'}, 'live', 'default'))

    def test_progress_checks_and_summary_are_native_safe(self):
        for changes in ({'checks':[42]}, {'summary': {'invalid':'text'}}):
            with self.assertRaises(ValueError):
                self.store.update(self.task['id'], 1, 'in_progress', session='session', profile='default', **changes)

    def test_watcher_scripts_cannot_bypass_draft_only(self):
        self.store.configure('draft_only')
        for action in ('create', 'activate', 'retry', 'dry_run'):
            self.assertEqual(g.check(self.temp.name, 'watchers', {'action':action, 'code':'send_email()'}, 'untracked', 'default')['action'], 'block')
        self.assertIsNone(g.check(self.temp.name, 'watchers', {'action':'list'}, 'untracked', 'default'))
