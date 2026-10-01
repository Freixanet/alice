"""Authority regressions: observed order, exact consent and durable submission."""
import concurrent.futures
import copy
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

spec=importlib.util.spec_from_file_location('alice_purchase_controller',Path(__file__).resolve().parents[1]/'purchase_controller.py')
controller=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=controller
spec.loader.exec_module(controller)
errands=controller.module('errands')
purchases=controller.module('purchases')
intent=controller.module('purchase_intent')


class AuthorityTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name)
        self.offer={'option_id':'1234abcd-1','url':'https://example.com/p','title':'Creatina','variant':'300 g',
                    'qty':2,'price':'10,00 €','currency':'EUR','quote_ref':'pq-test'}
        self.entry=errands.create(self.home,'Compra dos botes de creatina',site='example.com',offer=self.offer)
        self.id=self.entry['id']
        self.context={'context':'ctx-1','target':'tab-1','url':'https://example.com/checkout'}
        self.origin='https://example.com'
        self.inspect=lambda e:(self.origin,self.context,lambda *args:{'cookies':[]})
        self.raw={'payment_method':{'kind':'bank_card','label':'Tarjeta','requires_card':True},'total_verified':True,'total':'23,99 €','delivery':'Envío 3,99 € · viernes',
                  'address':'Calle Ejemplo 1, 08001 Barcelona','email':'fixture@example.com',
                  'lines':[{'text':'Creatina 300 g','links':['https://example.com/p']}],
                  'qty':'2','price':'10,00 €','url':'https://example.com/checkout','recurring':False}
        self.page={'url':'https://example.com/checkout','title':'Resumen','text':'Resumen final 23,99 €','controls':[]}
        self.descriptor={'tag':'BUTTON','type':'button','text':'Pagar ahora','name':'  ','href':None,'form':'','submit':False}
        self.executed=0
        self.change_on_click=False
        self.lose_response=False
        self.saved_cards=lambda:[{'handle':'card-exact','label':'Visa ···4242','card':'Visa ···4242','origin':''}]
        self.selectors={'total_selector':'#total','delivery_selector':'#delivery','address_selector':'#address','email_selector':'#email'}
        errands.update(self.home,self.id,cart_evidence={'recipe':{'line':'#line','all_lines':'.cart-line','price':'#price','cart_quantity':'#qty'}})
    def evaluate(self,context,script):
        self.assertEqual(context['target'],'tab-1')
        if script.startswith('(()=>{const es='):
            if self.change_on_click:return {'changed':True}
            self.executed+=1
            if self.lose_response:raise TimeoutError('Response lost after the shop accepted')
            return {'ok':True}
        if "const controls=" in script:return copy.deepcopy(self.page)
        if "const s=" in script and "total_verified" in script:return copy.deepcopy(self.raw)
        if 'const nodes=' in script:return copy.deepcopy(self.descriptor)
        if script==errands.PAYMENT_STEP_JS:return True
        if 'const values=' in script:return ['23,99 €']
        raise AssertionError('Unexpected observation: '+script[:120])
    def review(self):
        return controller.review(self.home,self.id,self.selectors,inspect=self.inspect,evaluate=self.evaluate,saved_cards=self.saved_cards)
    def approve(self):
        self.review()
        current=errands.get(self.home,self.id)
        result=errands.decide_checkout(self.home,self.id,True,checkout_id=current['checkout']['id'],card_handle='card-exact')
        self.assertIsNotNone(result)
        return result
    def act(self):
        return controller.act(self.home,self.id,{'action':'click','selector':'#pay'},inspect=self.inspect,evaluate=self.evaluate)
    def test_an_observed_checkout_pays_once_and_confirms_one_order(self):
        self.approve();self.act()
        self.assertEqual(self.executed,1)
        with self.assertRaisesRegex(ValueError,'ya se envió'):self.act()
        self.page['text']='Gracias. Pedido confirmado A-123456. Total 23,99 €'
        result=controller.reconcile(self.home,self.id,{'outcome':'paid','order':'A-123456'},inspect=self.inspect,evaluate=self.evaluate)
        self.assertTrue(result['ok'])
        self.assertEqual(errands.get(self.home,self.id)['status'],'done')
        self.assertEqual(purchases._read(purchases._ledger(self.home))[0]['status'],'paid')
    def test_no_approval_no_submission_or_attempt(self):
        with self.assertRaises(ValueError):self.act()
        self.assertEqual(self.executed,0)
        self.assertFalse(purchases._ledger(self.home).exists())
    def test_total_subtotal_product_quantity_address_delivery_and_email_changes_invalidate(self):
        self.approve()
        original=copy.deepcopy(self.raw)
        changes={'total':'24,99 €','total_verified':False,'qty':'3','price':'11,00 €','address':'Otro destino',
                 'delivery':'Entrega mensual','email':'another@example.com','recurring':True,
                 'lines':[{'text':'Creatina 300 g','links':['https://example.com/another-sku']}]}
        for key,value in changes.items():
            with self.subTest(key=key):
                self.raw=copy.deepcopy(original);self.raw[key]=value
                with self.assertRaises(ValueError):self.act()
                self.assertEqual(self.executed,0)
    def test_identical_order_reuses_the_pending_approval(self):
        self.review();first=errands.get(self.home,self.id)['checkout']['id']
        self.review();self.assertEqual(errands.get(self.home,self.id)['checkout']['id'],first)
    def test_old_checkout_id_and_ambiguous_card_label_never_approve(self):
        self.review();current=errands.get(self.home,self.id)
        self.assertIsNone(errands.decide_checkout(self.home,self.id,True,checkout_id='old',card_handle='card-exact'))
        self.assertIsNone(errands.decide_checkout(self.home,self.id,True,card_handle='card-exact'))
        self.assertIsNone(errands.decide_checkout(self.home,self.id,True,checkout_id=current['checkout']['id'],card_handle='another'))
    def test_two_parallel_submissions_consume_only_one_stage(self):
        self.approve()
        def reserve(_):
            try:controller.reserve(self.home,self.id,'merchant',inspect=self.inspect,evaluate=self.evaluate);return True
            except ValueError:return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(reserve,range(8)))
        self.assertEqual(sum(results),1)
        self.assertEqual(len(purchases._read(purchases._ledger(self.home))),1)
    def test_lost_click_response_cannot_repeat_payment_even_after_restart(self):
        self.approve();self.lose_response=True
        with self.assertRaises(TimeoutError):self.act()
        self.lose_response=False
        with self.assertRaises(ValueError):self.act()
        self.assertEqual(self.executed,1)
        self.assertEqual(errands.get(self.home,self.id)['purchase']['submitted_stages'],['merchant'])
    def test_final_dom_change_consumes_authorization_without_clicking(self):
        self.approve();self.change_on_click=True
        with self.assertRaises(ValueError):self.act()
        self.assertEqual(self.executed,0)
        self.assertEqual(purchases._read(purchases._ledger(self.home))[0]['status'],'unknown')
        with self.assertRaises(ValueError):self.act()
    def test_generic_error_does_not_prove_no_charge(self):
        self.approve();self.act();self.page['text']='Payment failed. Network timeout'
        for outcome in ('declined','not_charged','paid'):
            with self.assertRaises(ValueError):controller.reconcile(self.home,self.id,{'outcome':outcome,'order':'123456'},inspect=self.inspect,evaluate=self.evaluate)
        self.assertEqual(purchases._read(purchases._ledger(self.home))[0]['status'],'pending')
    def test_an_explicit_bank_rejection_can_close_the_exact_attempt(self):
        self.approve();self.act();self.page['text']='Your card was declined. No payment was taken.'
        self.assertTrue(controller.reconcile(self.home,self.id,{'outcome':'declined'},inspect=self.inspect,evaluate=self.evaluate)['ok'])
    def test_retry_after_verified_rejection_requires_a_new_order_approval(self):
        old=self.approve()['checkout']['id'];self.act()
        self.page['text']='Your card was declined. No payment was taken.'
        controller.reconcile(self.home,self.id,{'outcome':'declined'},inspect=self.inspect,evaluate=self.evaluate)
        with mock.patch.object(errands,'context_file',return_value=self.home/'missing-context'),mock.patch.object(errands,'launch'),mock.patch.object(errands,'_goal_manager'):
            resumed=errands.go_on(self.home,self.id)
        self.assertEqual(resumed['status'],'working')
        self.assertIsNone(resumed['checkout']);self.assertIsNone(resumed['purchase']['attempt_id'])
        with self.assertRaises(ValueError):self.act()
        errands.update(self.home,self.id,cart_evidence={'recipe':{'line':'#line','all_lines':'.cart-line','price':'#price','cart_quantity':'#qty'}})
        new=self.approve()['checkout']['id']
        self.assertNotEqual(old,new);self.act()
        ledger=purchases._read(purchases._ledger(self.home))
        self.assertEqual([row['status'] for row in ledger],['declined','pending'])
        self.assertNotEqual(ledger[0]['id'],ledger[1]['id'])

    def test_a_claimed_decline_cannot_clear_an_uncertain_ledger(self):
        self.approve();self.act()
        old=errands.get(self.home,self.id)
        errands.update(self.home,self.id,status='stuck',purchase={**old['purchase'],'phase':'declined'})
        with mock.patch.object(errands,'release_context') as release:
            with self.assertRaises(ValueError):controller.retry_after_no_charge(self.home,self.id)
        release.assert_not_called()
        self.assertEqual(errands.get(self.home,self.id)['checkout']['id'],old['checkout']['id'])

    def test_retry_never_discards_an_unknown_gateway_submission(self):
        self.approve();self.act();self.page['text']='No payment was taken.'
        controller.reconcile(self.home,self.id,{'outcome':'not_charged'},inspect=self.inspect,evaluate=self.evaluate)
        submission={'key':'uncertain-run','text':'Compra original'}
        errands.update(self.home,self.id,run_submission=submission)
        with mock.patch.object(errands,'release_context') as release:
            with self.assertRaises(ValueError):controller.retry_after_no_charge(self.home,self.id)
        release.assert_not_called()
        self.assertEqual(errands.get(self.home,self.id)['run_submission'],submission)

    def test_failed_browser_cleanup_preserves_the_rejected_attempt(self):
        self.approve();self.act();self.page['text']='No payment was taken.'
        controller.reconcile(self.home,self.id,{'outcome':'not_charged'},inspect=self.inspect,evaluate=self.evaluate)
        old=errands.get(self.home,self.id);path=self.home/'context.json'
        path.write_text(json.dumps({'cdp':'http://127.0.0.1:12345','context':'ctx-1'}))
        with mock.patch.object(errands,'context_file',return_value=path),mock.patch.object(errands,'release_context',return_value=False):
            with self.assertRaises(ValueError):controller.retry_after_no_charge(self.home,self.id)
        self.assertEqual(errands.get(self.home,self.id)['purchase']['attempt_id'],old['purchase']['attempt_id'])

    @unittest.skipUnless(shutil.which('node'), 'Node is required for the bank DOM regression')
    def test_bank_submit_accepts_the_same_amount_in_another_decimal_format(self):
        self.approve();self.act();self.origin='https://sis.redsys.es'
        original=self.evaluate
        def evaluate(context, script):
            if 'const values=' in script:return ['23.99 EUR']
            if script.startswith('(()=>{const es='):
                # Execute the real action expression against a minimal visible DOM.
                setup = '''let clicked=0;
const button={tagName:'BUTTON',type:'button',innerText:'Pagar ahora',getAttribute:()=>null,getClientRects:()=>[1],click:()=>clicked++};
const document={querySelectorAll:s=>s==='#pay'?[button]:[{innerText:'23.99 EUR',getClientRects:()=>[1]}]};
const location={origin:'https://sis.redsys.es'};
'''
                program=setup+'const result='+script+';console.log(JSON.stringify({result,clicked}));'
                result=json.loads(subprocess.run(['node','-e',program],capture_output=True,text=True,check=True).stdout)
                self.executed+=result['clicked']
                return result['result']
            return original(context,script)
        self.assertTrue(controller.act(self.home,self.id,{'action':'click','selector':'#pay'},inspect=self.inspect,evaluate=evaluate)['ok'])
        self.assertEqual(self.executed,2)  # One merchant handoff, one bank submit.
        self.assertEqual(len(purchases._read(purchases._ledger(self.home))),1)
        with self.assertRaises(ValueError):controller.act(self.home,self.id,{'action':'click','selector':'#pay'},inspect=self.inspect,evaluate=evaluate)

    def test_before_submission_stop_revokes_approval(self):
        self.approve()
        with mock.patch.object(errands,'_goal_manager'),mock.patch.object(errands,'release_context'):
            errands.stop(self.home,self.id)
        self.assertIsNone(errands.approved_checkout(errands.get(self.home,self.id)))
        with self.assertRaises(ValueError):self.act()
    def test_after_submission_stop_retains_context_checkout_and_attempt(self):
        self.approve();self.act()
        with mock.patch.object(errands,'_goal_manager'),mock.patch.object(errands,'release_context') as dispose:
            stopped=errands.stop(self.home,self.id)
        dispose.assert_not_called();self.assertEqual(stopped['status'],'stuck')
        self.assertEqual(stopped['checkout']['status'],'approved')
        with mock.patch.object(errands,'launch'),mock.patch.object(errands,'_goal_manager'):
            resumed=errands.go_on(self.home,self.id)
        self.assertEqual(resumed['checkout']['id'],stopped['checkout']['id'])
        self.assertEqual(resumed['purchase']['attempt_id'],stopped['purchase']['attempt_id'])
    def test_unrelated_context_product_and_extra_lines_are_not_the_chosen_order(self):
        for value in ([{'text':'Creatina 300 g','links':['https://example.com/wrong']}],self.raw['lines']*2):
            self.raw['lines']=value
            with self.assertRaises(ValueError):self.review()
    def test_another_open_bank_cannot_borrow_the_authorization(self):
        self.approve();self.origin='https://sis.redsys.es'
        with self.assertRaises(ValueError):self.act()
        self.assertEqual(self.executed,0)
    def test_confirmed_ledger_is_immutable_and_scoped_to_session_and_attempt(self):
        self.approve();attempt=controller.reserve(self.home,self.id,'merchant',inspect=self.inspect,evaluate=self.evaluate)
        self.assertFalse(purchases.settle(self.home,'example.com','paid','123456',session='other',attempt_id=attempt['id'])['ok'])
        self.assertTrue(purchases.settle(self.home,'example.com','paid','123456',session=self.entry['session_id'],attempt_id=attempt['id'])['ok'])
        self.assertFalse(purchases.settle(self.home,'example.com','not_charged',session=self.entry['session_id'],attempt_id=attempt['id'])['ok'])
    def test_secrets_are_not_resolved_for_a_different_handle(self):
        self.approve();backend=mock.Mock()
        with self.assertRaises(ValueError):controller.fill_card(self.home,self.id,'other',inspect=self.inspect,evaluate=self.evaluate,backend=backend)
        backend.resolve_secret.assert_not_called()
    def test_unreadable_errand_evidence_is_never_overwritten(self):
        path=self.home/'.alice'/'errands.json';path.write_text('{truncated')
        with self.assertRaises(ValueError):self.review()
        self.assertEqual(path.read_text(),'{truncated')
    def test_request_revision_preserves_full_text_and_corrected_quantity(self):
        first=intent.remember(self.home,'chat','Compra 3 botes de creatina '+('compatibilidad exacta '*100))
        second=intent.remember(self.home,'chat','mejor 2 botes',correction=True)
        self.assertEqual(first['qty'],3);self.assertEqual(second['qty'],2)
        self.assertIn(first['request'],second['request']);self.assertEqual(second['revision'],2)
    def test_cash_on_delivery_does_not_ask_for_or_fill_a_card(self):
        self.raw['payment_method']={'kind':'cod','label':'Contra reembolso','requires_card':False}
        self.saved_cards=lambda:[]
        self.review();current=errands.get(self.home,self.id)
        self.assertEqual(current['status'],'needs_approval')
        self.assertIsNotNone(errands.decide_checkout(self.home,self.id,True,checkout_id=current['checkout']['id']))
        self.act();self.assertEqual(self.executed,1)
        self.assertEqual(purchases._read(purchases._ledger(self.home))[0]['card_handle'],'')

    def test_a_payment_method_change_invalidates_the_approval(self):
        self.approve()
        self.raw['payment_method']={'kind':'invoice','label':'Factura','requires_card':False}
        with self.assertRaises(ValueError):self.act()
        self.assertEqual(self.executed,0)

    def test_unknown_or_stored_merchant_method_is_not_silently_paid(self):
        self.raw['payment_method']={'kind':'unknown','label':'Saved account','requires_card':True}
        with self.assertRaisesRegex(ValueError,'método de pago'):self.review()

    def test_storage_permissions_are_private_and_no_secret_is_persisted(self):
        self.approve();self.act()
        for path in (self.home/'.alice').glob('*.json'):
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            self.assertNotIn('4242424242424242',path.read_text())
            def inspect_keys(value):
                if isinstance(value,dict):
                    self.assertNotIn('card_number',value);self.assertNotIn('cvc',value)
                    for item in value.values():inspect_keys(item)
                elif isinstance(value,list):
                    for item in value:inspect_keys(item)
            inspect_keys(json.loads(path.read_text()))


if __name__=='__main__':unittest.main()
