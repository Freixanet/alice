"""Trusted cart evidence, selection and secure continuity, with fictitious stores only."""
import importlib.util
import json
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

PATH = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('alice_purchase_prices', PATH / 'purchase_prices.py')
prices = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = prices
spec.loader.exec_module(prices)
flow, access, errands = (prices.module(n) for n in ('purchase_flow','errand_access','errands'))


class Shop:
    amount = '34,99 €'
    instances = []
    def __init__(self, home):
        self.qty = 1
        self.closed = False
        self.amount = type(self).amount
        self.instances.append(self)
    def goto(self, url): self.url = url
    def evaluate(self, code):
        if 'Array.from' in code:
            return [{'url':f'https://example.com/{n}', 'title':f'Prozis Creapure {n}'} for n in ('300 g','80 cápsulas','90 cápsulas')]
        return True
    def read(self, selector):
        variant = self.url.rsplit('/',1)[1]
        return {'h1':'Prozis Creapure', '#variant':variant, '#line':f'Prozis Creapure {variant}',
                '#price':self.amount,'#cart-qty':str(self.qty),'#shipping':'3,99 €',
                '#condition':'24,49 € requiere alta; no aplicado', '#unavailable':'Agotado'}.get(selector)
    def units(self, selector, qty): self.qty = qty
    def click(self, selector, action='add'): pass
    def coupon(self, selector, code): self.amount = '31,49 €' if code == 'PUBLIC10' else type(self).amount
    def close(self): self.closed = True


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.now = time.time()
        Shop.instances = []
        Shop.amount = '34,99 €'
        self.safe = mock.patch.object(prices,'https',side_effect=lambda url:url)
        self.safe.start(); self.addCleanup(self.safe.stop)
        self.search = prices.discover(self.home,'chat',{'url':'https://example.com/search','selector':'a'},factory=Shop,now=self.now)
        self.recipe = {'title':'h1','variant':'#variant','quantity':'#qty','add':'#add','line':'#line','price':'#price',
                       'cart_quantity':'#cart-qty','shipping':'#shipping','condition':'#condition','coupon':'#coupon','apply':'#apply'}
    def quote(self,index=0,qty=1,**kw):
        return prices.verify(self.home,'chat',{'search_id':self.search['id'],'candidate_id':self.search['candidates'][index]['id'],
            'recipe':self.recipe,'currency':'EUR','qty':qty,**kw},factory=Shop,now=self.now)
    def options(self,quotes):
        return {'search_id':self.search['id'],'options':[{'quote_ref':q['id'],'merchant':'Prozis','title':'Inventado',
            'url':q['url'],'variant':q['variant'],'price':'24,49 €','currency':'EUR','in_stock':True,'channel':'browser'} for q in quotes]}
    def test_conditional_price_cannot_replace_actual_cart_amount(self):
        q = self.quote()
        self.assertEqual(q['price_cents'],3499)
        self.assertEqual(q['shipping'],'3,99 €')
        self.assertIn('no aplicado',q['condition'])
        self.assertTrue(all(p.closed for p in Shop.instances))
    def test_all_found_formats_must_be_accounted_for(self):
        result = prices.present(self.home,'chat',self.options([self.quote()]),factory=Shop)
        self.assertFalse(result['ok']); self.assertIn('80 cápsulas',result['error'])
        for candidate in self.search['candidates'][1:]:
            prices.verify(self.home,'chat',{'search_id':self.search['id'],'candidate_id':candidate['id'],'reject_reason':'Sin stock','recipe':{'unavailable':'#unavailable'}},factory=Shop)
        result = prices.present(self.home,'chat',self.options([self.quote()]),factory=Shop)
        self.assertTrue(result['ok'])
    def test_unattempted_formats_cannot_be_discarded_as_unverifiable(self):
        with self.assertRaises(ValueError):
            prices.verify(self.home,'chat',{'search_id':self.search['id'],
                'candidate_id':self.search['candidates'][1]['id'],'reject_reason':'No pude verificar'},factory=Shop)
        first = self.quote()
        remaining = prices.verify_remaining(self.home,'chat',{'search_id':self.search['id'],
            'candidate_id':first['candidate_id'],'recipe':self.recipe,'currency':'EUR'},factory=Shop)
        self.assertEqual(len(remaining['other_formats']),2)
        self.assertFalse(remaining['unverified'])

    def test_model_price_is_ignored_and_cards_keep_quote_and_argument_key(self):
        quotes = [self.quote(i) for i in range(3)]
        args = self.options(quotes)
        out = prices.present(self.home,'chat',args,now=self.now,factory=Shop)
        self.assertTrue(out['ok'])
        self.assertEqual(out['set'],flow.set_key(args['options']))
        stored = flow.options_set(self.home,out['set'],session='chat')
        self.assertEqual([o['price'] for o in stored['options']],['34,99 €']*3)
        self.assertTrue(all(o['quote_ref'] for o in stored['options']))
    def test_fabricated_and_cross_chat_quote_refs_fail(self):
        q = self.quote()
        with self.assertRaises(ValueError): prices.resolve(self.home,'other',q['id'])
        with self.assertRaises(ValueError): prices.resolve(self.home,'chat','pq-fake')
    def test_quantity_expiry_and_session_change_revalidate(self):
        q = self.quote()
        before = len(Shop.instances)
        self.assertEqual(prices.resolve(self.home,'chat',q['id'],now=self.now+899,factory=Shop)['id'],q['id'])
        self.assertEqual(len(Shop.instances),before)
        self.assertEqual(prices.resolve(self.home,'chat',q['id'],qty=2,factory=Shop)['qty'],2)
        Shop.amount = '35,99 €'
        self.assertEqual(prices.resolve(self.home,'chat',q['id'],now=self.now+901,factory=Shop)['price'],'35,99 €')
        self.assertNotEqual(prices.resolve(self.home,'chat',q['id'],revalidate=True,factory=Shop)['id'],q['id'])
    def test_public_coupon_applied_and_rejected_coupon_uses_cart_price(self):
        rejected = self.quote(coupons=['MEMBERS'])
        self.assertEqual(rejected['price'],'34,99 €')
        self.assertFalse(rejected['coupon_results'][0]['applied'])
        accepted = self.quote(coupons=['PUBLIC10','BAD'])
        self.assertEqual(accepted['price'],'31,49 €')
    def test_existing_inline_cart_is_not_lost_to_an_unneeded_url(self):
        q = self.quote(recipe={**self.recipe,'cart_url':'https://example.com/80 cápsulas'})
        self.assertEqual(q['variant'],'300 g')
        self.assertTrue(Shop.instances[-1].url.endswith('300 g'))

    def test_no_quantity_question_before_format_selection(self):
        self.assertIsNotNone(flow.ask_refusal([{'question':'¿Cuántos botes de 300 g quieres?','choices':['1','2']}],True))
    def test_same_amount_is_never_a_price_change(self):
        self.assertNotEqual(errands.blocked_by('cuesta 24,49 € en vez de 24,49 €',{'price':'24,49 €','currency':'EUR'})['kind'],'price')


class AccessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.entry = errands.create(self.home,'Comprar creatina',profile='test',offer={'url':'https://example.com/p'})
        self.context = {'context':'context-test','target':'target-test'}
        self.inspect = lambda entry:('https://example.com',self.context,None)
        self.saved,self.resumed = [],[]
        self.save = lambda payload,origin:(self.saved.append((payload.copy(),origin)) or 'vault-fixture')
        self.resume = lambda home,id,message:self.resumed.append((id,message))
    def pending(self,kind='vault.save_login'):
        return access.request(self.home,self.entry['id'],kind,inspect=self.inspect)
    def respond(self,pending,**kw):
        return access.answer(self.home,self.entry['id'],pending['request_id'],
            json.dumps({'identifier':'fixture@example.com','password':'FAKE-test-password'}),inspect=self.inspect,
            save=self.save,resume=self.resume,**kw)
    def test_pending_survives_restart_and_does_not_expose_browser_context(self):
        p = self.pending()
        self.assertEqual(self.pending()['request_id'],p['request_id'])
        public = errands.public(errands.get(self.home,self.entry['id']))
        self.assertEqual(public['status'],'needs_login')
        self.assertNotIn('context',public['secure_request'])
    def test_secrets_only_go_to_vault_and_resume_same_errand_once(self):
        p = self.pending(); self.respond(p); self.respond(p)
        self.assertEqual(len(self.saved),1); self.assertEqual(len(self.resumed),1)
        self.assertEqual(self.resumed[0][0],self.entry['id'])
        for path in self.home.rglob('*.json'):
            self.assertNotIn('FAKE-test-password',path.read_text())
            self.assertNotIn('fixture@example.com',path.read_text())
        self.assertNotIn('FAKE-test-password',str(self.resumed))
    def test_explicit_create_account_mode_reaches_server(self):
        p = self.pending(); out = self.respond(p,account_action='create')
        self.assertEqual(out['account_action'],'create')
        self.assertIn('create',self.resumed[0][1])
    def test_cancel_preserves_offer_without_any_payment_or_vault_write(self):
        p = self.pending()
        out = access.answer(self.home,self.entry['id'],p['request_id'],'',inspect=self.inspect,save=self.save,resume=self.resume)
        self.assertEqual(out['status'],'stopped'); self.assertEqual(out['offer']['url'],'https://example.com/p')
        self.assertFalse(self.saved); self.assertFalse(self.resumed)
    def test_changed_origin_or_context_cannot_receive_access(self):
        p = self.pending(); self.context['target'] = 'different'
        with self.assertRaises(ValueError):self.respond(p)
        self.assertFalse(self.saved)
        with self.assertRaises(ValueError):access.request(self.home,self.entry['id'],inspect=lambda e:('https://other.example',self.context,None))
    def test_otp_is_filled_directly_without_transcript_value(self):
        p = self.pending('vault.code'); codes=[]
        access.answer(self.home,self.entry['id'],p['request_id'],'987654',inspect=self.inspect,
            fill_code=lambda e,code:codes.append(code),resume=self.resume)
        self.assertEqual(codes,['987654']); self.assertNotIn('987654',str(self.resumed))
        self.assertNotIn('987654',str(errands.public(errands.get(self.home,self.entry['id']))))
    def test_otp_redaction_restored_in_another_process_without_persistence(self):
        from agent.redact import clear_vault_redaction_values, redact_sensitive_text
        clear_vault_redaction_values()
        self.addCleanup(clear_vault_redaction_values)
        descriptors = [{'index':0,'name':'otp','type':'text','autocomplete':'one-time-code'}]
        scripts = []
        def evaluate(context,script):
            scripts.append(script)
            return descriptors if 'flatMap' in script else {'passwords':[], 'otp':['654321']}
        before = list(self.home.rglob('*.json'))
        snapshots = [p.read_bytes() for p in before]
        self.assertIsNone(access.protect_browser_secrets(self.entry,inspect=self.inspect,evaluate=evaluate))
        self.assertNotIn('654321',redact_sensitive_text('value: 654321',force=True))
        self.assertIn('-webkit-text-security',scripts[-1])
        self.assertNotIn('654321',str(scripts))
        self.assertEqual([p.read_bytes() for p in before],snapshots)

    def test_split_otp_is_redacted_without_erasing_prices_or_control_indices(self):
        from agent.redact import clear_vault_redaction_values, redact_sensitive_text
        clear_vault_redaction_values()
        self.addCleanup(clear_vault_redaction_values)
        rows = [{'index':i,'name':'otp'+str(i),'type':'text','autocomplete':'one-time-code',
                 'maxLength':1,'formIndex':0} for i in range(6)]
        digits = ['1','2','3','4','5','6']
        evaluate = lambda ctx,script: rows if 'flatMap' in script else {'passwords':['FAKE-hidden-password'], 'otp':digits.copy()}
        access.protect_browser_secrets(self.entry,inspect=self.inspect,evaluate=evaluate)
        for value in ('123456','1 2 3 4 5 6','1-2-3-4-5-6',str(digits),json.dumps(digits),json.dumps(digits,separators=(',',':')),'FAKE-hidden-password'):
            self.assertNotIn(value,redact_sensitive_text(value,force=True))
        self.assertEqual(redact_sensitive_text('Control 3: 34,99 € × 2',force=True),'Control 3: 34,99 € × 2')

    def test_secret_shield_never_reads_a_different_origin(self):
        evaluate = mock.Mock()
        access.protect_browser_secrets(self.entry,inspect=lambda e:('https://payment.example',self.context,None),evaluate=evaluate)
        evaluate.assert_not_called()

    def test_otp_preserves_explicit_account_creation_choice(self):
        p = self.pending();self.respond(p,account_action='create')
        p = self.pending('vault.code')
        access.answer(self.home,self.entry['id'],p['request_id'],'987654',inspect=self.inspect,
                      fill_code=lambda e,v:None,resume=self.resume)
        self.assertEqual(errands.get(self.home,self.entry['id'])['account_action'],'create')

    def test_changed_page_creates_a_fresh_request_and_rejects_old_answer(self):
        first = self.pending()
        self.context['target'] = 'recovered-target'
        second = self.pending()
        self.assertNotEqual(first['request_id'],second['request_id'])
        with self.assertRaises(ValueError):self.respond(first)
        self.assertFalse(self.saved)

    def test_visible_empty_login_recovers_a_prose_only_agent_turn(self):
        descriptors = [{'index':0,'name':'password','type':'password','autocomplete':'current-password'}]
        evaluate = lambda ctx,script: json.dumps(descriptors) if 'flatMap' in script else True
        pending = access.detect_pending(self.home,self.entry['id'],inspect=self.inspect,evaluate=evaluate)
        self.assertEqual(pending['kind'],'vault.save_login')
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'needs_login')
        self.assertFalse(self.saved)

    def test_other_origin_credentials_are_rejected_before_secret_resolution(self):
        backend = mock.Mock();backend.get_meta.return_value=types.SimpleNamespace(kind='login',origin='https://other.example')
        with self.assertRaises(ValueError):access.fill_login(self.home,self.entry['id'],'vault-other',inspect=self.inspect,backend=backend)
        backend.resolve_password.assert_not_called()

if __name__ == '__main__': unittest.main()

class CartRevalidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.entry = errands.create(self.home,'Comprar creatina',profile='test')
        self.context = {'context':'context-test','target':'target-test'}
        self.offer = {'url':'https://example.com/p','quote_ref':'pq-test','title':'Creatina','variant':'300 g','qty':2,'price':'34,99 €','currency':'EUR'}
        errands.update(self.home,self.entry['id'],offer=self.offer)
        self.cookies = []
        self.inspect = lambda e:('https://example.com',self.context,lambda *a:{'cookies':self.cookies})
        self.amount = '34,99 €'; self.qty = '2'
        self.recipe = {'line':'#line','price':'#price','cart_quantity':'#qty'}
        def evaluate(ctx,script):
            if 'line.contains' in script:return True
            if '"#line"' in script:return 'Creatina 300 g'
            if '"#price"' in script:return self.amount
            if '"#qty"' in script:return self.qty
            if '"#total"' in script:return '73,97 €'
        self.evaluate = evaluate
    def check(self):
        return prices.check_cart(self.home,self.entry['id'],self.recipe,inspect=self.inspect,evaluate=self.evaluate)
    def test_same_price_after_session_change_needs_no_acceptance(self):
        self.assertTrue(self.check()['ok'])
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'working')
        self.cookies.append({'domain':'example.com','name':'session','value':'fictional-new-session'})
        self.assertFalse(prices.fresh_cart(self.home,errands.get(self.home,self.entry['id']),inspect=self.inspect))
        self.assertTrue(self.check()['ok'])
    def test_real_price_change_exposes_both_amounts(self):
        self.amount='39,99 €'
        changed=self.check()
        self.assertEqual((changed['old'],changed['price']),('34,99 €','39,99 €'))
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'stuck')
    def test_wrong_units_cannot_reach_approval(self):
        self.qty='1'
        with self.assertRaises(ValueError):self.check()
    def test_checkout_total_read_from_final_page(self):
        total=prices.checkout_amount(errands.get(self.home,self.entry['id']),'#total',inspect=self.inspect,evaluate=self.evaluate)
        self.assertEqual(total,'73,97 €')

    def test_payment_requires_the_exact_approved_visible_total(self):
        self.check()
        now=time.time()
        checkout={'id':'ck-test','status':'approved','total':'73,97 €','currency':'EUR','decided_at':now,'site':'example.com'}
        errands.update(self.home,self.entry['id'],checkout=checkout,checkout_evidence={'checkout_id':'ck-test','selector':'#total'})
        entry=errands.get(self.home,self.entry['id'])
        self.assertTrue(prices.payment_ready(self.home,entry,inspect=self.inspect,evaluate=self.evaluate))
        changed=lambda ctx,script:'79,97 €'
        self.assertFalse(prices.payment_ready(self.home,entry,inspect=self.inspect,evaluate=changed))
        self.assertFalse(prices.payment_ready(self.home,{**entry,'checkout_evidence':None},inspect=self.inspect,evaluate=self.evaluate))
