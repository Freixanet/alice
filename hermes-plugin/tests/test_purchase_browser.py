import copy
import importlib.util
import json
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

BASE = Path(__file__).parents[1]

def load(name):
    spec = importlib.util.spec_from_file_location('purchase_loop_test_' + name, BASE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

browser, errands = load('purchase_browser'), load('errands')


class PurchaseBrowserTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.entry = errands.create(self.home, 'Buy socks', offer={'title':'Socks','url':'https://shop.example/product'})
        self.snapshot = {'url':'https://shop.example/checkout','document':'doc','headings':['Delivery'],
                         'errors':[],'busy':False,'controls':[{'id':'button','label':'Continue','kind':'button',
                           'type':'button','disabled':False,'secret':False,'filled':False,'checked':False,
                           'value':None,'options':[],'invalid':False}]}
        self.clicks = 0
        self.behavior = 'advance'

    def inspect(self, entry):
        return 'https://shop.example', {}, None

    def evaluate(self, ctx, script):
        if script == browser.SNAPSHOT_JS:
            return copy.deepcopy(self.snapshot)
        if script == errands.PAYMENT_STEP_JS:
            return False
        self.clicks += 1
        if self.behavior == 'advance':
            self.snapshot['headings'] = ['Summary']
        elif self.behavior == 'validation':
            self.snapshot['errors'] = ['Postal code required']
        elif self.behavior == 'disconnect':
            raise OSError('connection lost after click')
        return {'acted':True}

    def step(self, args):
        return browser.run(self.home, errands.get(self.home,self.entry['id']), args, errands, self.inspect,self.evaluate,sleep=lambda _:None)

    def action(self):
        result = self.step({'action':'observe'})
        return {'action':'click','observation_id':result['observation_id'],'control_id':'button'}

    def test_one_action_returns_verified_state_on_same_url(self):
        args = self.action()
        after = self.step(args)
        self.assertTrue(after['changed'])
        self.assertEqual(after['headings'], ['Summary'])
        self.assertEqual(after['url'], self.snapshot['url'])
        self.assertEqual(self.clicks, 1)
        self.assertEqual(errands.get(self.home,self.entry['id'])['browser_observation']['action']['outcome'], 'changed')

    def test_stale_observation_does_not_click(self):
        args = self.action()
        self.snapshot['headings'] = ['New document']
        self.assertEqual(self.step(args)['outcome'], 'stale')
        self.assertEqual(self.clicks, 0)

    def test_no_effect_does_not_create_blind_retries(self):
        self.behavior = 'nothing'
        args = self.action()
        self.assertEqual(self.step(args)['outcome'], 'unchanged')
        self.assertEqual(self.step(args)['outcome'], 'duplicate')
        self.assertEqual(self.clicks, 1)

    def test_lost_response_is_unknown_and_retry_never_clicks_again(self):
        self.behavior = 'disconnect'
        args = self.action()
        self.assertEqual(self.step(args)['outcome'], 'unknown')
        self.assertEqual(self.step(args)['outcome'], 'duplicate')
        self.assertEqual(self.clicks, 1)

    def test_validation_errors_are_returned_and_do_not_mean_success(self):
        self.behavior = 'validation'
        after = self.step(self.action())
        self.assertEqual(after['stage'], 'validation_error')
        self.assertEqual(after['errors'], ['Postal code required'])
        self.assertNotEqual(errands.get(self.home,self.entry['id'])['status'], 'done')

    def test_payment_secret_disabled_and_unknown_controls_are_refused(self):
        for field, value in (('label','Pagar ahora'),('secret',True),('disabled',True)):
            with self.subTest(field=field):
                self.snapshot['controls'][0][field] = value
                args = self.action()
                with self.assertRaises(ValueError):self.step(args)
                self.snapshot['controls'][0][field] = {'label':'Continue','secret':False,'disabled':False}[field]
        self.assertEqual(self.clicks, 0)

    def test_progress_on_single_page_is_not_mistaken_for_circling(self):
        now=time.time()
        for i in range(errands.CIRCLE_STEPS):
            errands.add_step(self.home,self.entry['id'],str(i),'https://shop.example/checkout',now=now-500+i*30)
        self.assertIsNotNone(errands.circling(errands.get(self.home,self.entry['id'])))
        self.step({'action':'observe'})
        self.assertIsNone(errands.circling(errands.get(self.home,self.entry['id'])))
        errands.update(self.home,self.entry['id'],browser_observation={'progress_at':now-500,'unchanged':errands.CIRCLE_STEPS})
        self.assertIsNotNone(errands.circling(errands.get(self.home,self.entry['id'])))

    def test_secret_values_are_not_in_action_metadata(self):
        control=self.snapshot['controls'][0]
        control.update(kind='input',type='text',label='Address',filled=False)
        args=self.action()
        args.update(action='fill',value='Private shipping address')
        self.step(args)
        state=errands.get(self.home,self.entry['id'])['browser_observation']
        self.assertNotIn('Private shipping address',json.dumps(state))


    def test_parallel_identical_actions_execute_once(self):
        self.behavior = 'nothing'
        args = self.action()
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(lambda _:self.step(args)['outcome'],range(2)))
        self.assertEqual(sorted(outcomes), ['duplicate','unchanged'])
        self.assertEqual(self.clicks, 1)


    def test_lost_response_after_page_change_does_not_repeat_the_side_effect(self):
        original = self.evaluate
        def lost(ctx, script):
            if script not in (browser.SNAPSHOT_JS, errands.PAYMENT_STEP_JS):
                original(ctx, script)
                raise OSError('response lost after remote action')
            return original(ctx, script)
        args=self.action()
        self.evaluate=lost
        self.assertEqual(self.step(args)['outcome'], 'unknown')
        self.assertEqual(self.step(args)['outcome'], 'stale')
        self.assertEqual(self.clicks,1)

    def test_read_only_no_progress_loop_is_detected_without_agent_comments(self):
        now=time.time()
        errands.update(self.home,self.entry['id'],browser_observation={
            'progress_at':now-500,'unchanged':errands.CIRCLE_STEPS,'url':'https://shop.example/checkout'})
        self.assertEqual(errands.circling(errands.get(self.home,self.entry['id'])), 'shop.example/checkout')


    def test_recovery_plan_uses_only_exact_choice_and_saved_shipping(self):
        snapshot={'observation_id':'o','stage':'validation_error','controls':[
            {'id':'postal','label':'Postal code','kind':'input','secret':False,'disabled':False,'filled':False,'invalid':True},
            {'id':'quantity','label':'Quantity','kind':'input','secret':False,'disabled':False,'filled':True,'value':'1'},
            {'id':'password','label':'Password','kind':'input','secret':True,'disabled':False,'filled':False},
            {'id':'variant','label':'Size','kind':'select','secret':False,'disabled':False,'value':'',
             'options':[{'value':'M','label':'Medium'},{'value':'L','label':'Large'}]}]}
        chosen={'offer':{'qty':2,'variant':'Medium'}}
        plans=browser.plan(chosen,snapshot,{'postcode':'12345'})
        self.assertEqual({p['control_id']:p['value'] for p in plans}, {'postal':'12345','quantity':'2','variant':'M'})
        self.assertNotIn('postal',{p['control_id'] for p in browser.plan(chosen,snapshot,{})})
        chosen['offer']['variant']='Unknown'
        self.assertNotIn('variant',{p['control_id'] for p in browser.plan(chosen,snapshot,{})})


    def test_waiting_for_person_never_mutates_the_checkout(self):
        args=self.action()
        errands.update(self.home,self.entry['id'],status='needs_approval')
        with self.assertRaises(ValueError):self.step(args)
        self.assertEqual(self.clicks,0)
        self.assertTrue(self.step({'action':'observe'})['ok'])

    def test_old_server_error_after_correction_can_be_validated_once(self):
        self.snapshot['errors']=['Postal code rejected; enter again']
        self.snapshot['controls'][0].update(kind='input',type='text',label='Postal code',filled=False,required=True,invalid=True)
        args=self.action()
        args.update(action='fill',value='12345')
        original=self.evaluate
        def correction(ctx,script):
            if script not in (browser.SNAPSHOT_JS,errands.PAYMENT_STEP_JS):
                self.snapshot['controls'][0].update(filled=True,invalid=False,edit='2')
                return {'acted':True}
            return original(ctx,script)
        self.evaluate=correction
        after=self.step(args)
        self.assertEqual(after['stage'],'validation_error')
        self.assertEqual(after['fields_to_fix'],[])
        self.assertIn('envía una vez',after['next'])
        self.assertIn('envía una vez',self.step({'action':'observe'})['next'])
        self.assertNotEqual(errands.get(self.home,self.entry['id'])['status'],'done')
