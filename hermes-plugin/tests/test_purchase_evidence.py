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
    def test_unchecked_formats_are_said_never_a_reason_to_show_nothing(self):
        # Withholding the cards until every format was accounted for left the person with none.
        result = prices.present(self.home,'chat',self.options([self.quote()]),factory=Shop)
        self.assertTrue(result['ok'], result); self.assertEqual(len(result['options']),1)
        self.assertIn('Prozis Creapure 80 cápsulas',result['unchecked']); self.assertIn('Sin comprobar',result['next'])
        for candidate in self.search['candidates'][1:]:
            prices.verify(self.home,'chat',{'search_id':self.search['id'],'candidate_id':candidate['id'],'reject_reason':'Sin stock','recipe':{'unavailable':'#unavailable'}},factory=Shop)
        result = prices.present(self.home,'chat',self.options([self.quote()]),factory=Shop)
        self.assertTrue(result['ok']); self.assertNotIn('unchecked',result)
    def test_a_format_the_service_could_not_check_does_not_lock_the_others(self):
        original = Shop.read
        def flaky(shop, selector):
            return None if shop.url.endswith('80 cápsulas') and selector == 'h1' else original(shop, selector)
        with mock.patch.object(Shop,'read',flaky):
            with self.assertRaisesRegex(ValueError,'no comprobable'):
                self.quote(1)
        third = self.quote(2)
        result = prices.present(self.home,'chat',self.options([self.quote(),third]),factory=Shop)
        self.assertTrue(result['ok'], result)
    def test_discover_keeps_only_rows_naming_the_asked_words(self):
        search = prices.discover(self.home,'chat',{'url':'https://example.com/search','selector':'a','keywords':['80']},factory=Shop,now=self.now)
        self.assertEqual([c['title'] for c in search['candidates']],['Prozis Creapure 80 cápsulas'])
        other_language = prices.discover(self.home,'chat',{'url':'https://example.com/search','selector':'a','keywords':['mantequilla']},factory=Shop,now=self.now)
        self.assertEqual(len(other_language['candidates']),3)
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
    def test_the_applied_coupon_travels_with_the_quote_the_option_and_the_offer(self):
        accepted = self.quote(coupons=['PUBLIC10','BAD'])
        self.assertEqual(accepted['coupon'],'PUBLIC10')
        self.assertEqual(self.quote(index=1)['coupon'],'')
        shown = prices.present(self.home,'chat',self.options([accepted]),factory=Shop)
        self.assertTrue(shown['ok'], shown)
        flow = prices.module('purchase_flow')
        chosen = flow.choose(self.home,'chat',shown['options'][0]['id'])
        self.assertEqual(chosen['coupon'],'PUBLIC10')
        self.assertEqual(flow.offer(chosen)['coupon'],'PUBLIC10')
    def test_existing_inline_cart_is_not_lost_to_an_unneeded_url(self):
        q = self.quote(recipe={**self.recipe,'cart_url':'https://example.com/80 cápsulas'})
        self.assertEqual(q['variant'],'300 g')
        self.assertTrue(Shop.instances[-1].url.endswith('300 g'))

    def test_cart_lines_are_matched_by_words_not_letter_by_letter(self):
        self.assertTrue(prices.names('CREATINA MONOHIDRATO 500G x1  24,99 €','Creatina Monohidrato 500 g'))
        self.assertTrue(prices.names('Creatina Creapure® - 300 g - Neutro','Creatina Creapure','300 g'))
        self.assertTrue(prices.names('Pienso Acana Adult Dog 2kg','Acana Adult Dog','2 kg'))
        self.assertFalse(prices.names('Creatina Creapure 80 cápsulas','Creatina Creapure','300 g'))
        self.assertFalse(prices.names('Whey Protein 1 kg','Creatina Creapure'))
        # A listing title longer than the cart line is not a second product to spell out.
        original = Shop.read
        def shop_words(shop, selector):
            value = original(shop, selector)
            return value.upper().replace(' G','G') if selector == '#line' and value else value
        with mock.patch.object(Shop,'read',shop_words):
            q = self.quote(recipe={k:v for k,v in self.recipe.items() if k != 'variant'})
        self.assertEqual(q['price_cents'],3499)
    def test_coupons_without_a_coupon_field_are_reported_not_a_crash(self):
        q = self.quote(coupons=['PUBLIC10'], recipe={k:v for k,v in self.recipe.items() if k not in ('coupon','apply')})
        self.assertEqual(q['price'],'34,99 €')
        self.assertFalse(q['coupon_results'][0]['applied']); self.assertIn('sin campo',q['coupon_results'][0]['why'])
    def test_a_failed_check_names_its_selector(self):
        with mock.patch.object(Shop,'read',lambda shop,selector: None if selector == '#line' else Shop.read.__wrapped__(shop,selector) if hasattr(Shop.read,'__wrapped__') else {'h1':'Prozis Creapure','#variant':'300 g','#cart-qty':'1','#price':'34,99 €'}.get(selector)):
            with self.assertRaisesRegex(ValueError,'#line'):
                self.quote()
    def test_checking_the_remaining_formats_stops_within_the_tool_calls_time(self):
        first = self.quote()
        ticks = iter([0, 0, 1000, 1000, 1000])
        remaining = prices.verify_remaining(self.home,'chat',{'search_id':self.search['id'],'candidate_id':first['candidate_id'],
            'recipe':self.recipe,'currency':'EUR'},factory=Shop,budget=90,clock=lambda: next(ticks))
        self.assertEqual(len(remaining['other_formats']),1)
        self.assertEqual(len(remaining['unverified']),1); self.assertIn('sin tiempo',remaining['unverified'][0]['why'])
        # Said as unchecked, the cards can still be shown; the agent may check it on its own.
        result = prices.present(self.home,'chat',self.options([first]+remaining['other_formats']),factory=Shop)
        self.assertTrue(result['ok'], result)
    def test_a_www_redirect_is_the_same_shop(self):
        self.assertTrue(prices.same_site('https://www.prozis.com/es/es/p','https://prozis.com/es/es/p'))
        self.assertFalse(prices.same_site('https://www.prozis.com/p','https://sis.redsys.es/p'))
    def test_the_cards_go_up_from_the_evidence_and_the_models_call_only_decorates_them(self):
        # The model verified every format and then wrote «toca su tarjeta» without calling
        # purchase_options: the person saw no cards. Now the plugin shows them itself.
        self.assertIsNone(prices.auto_present(self.home,'chat',self.search['id'],now=self.now), 'formats still unchecked')
        quotes = [self.quote(i) for i in range(3)]
        shown = prices.auto_present(self.home,'chat',self.search['id'],now=self.now)
        self.assertTrue(shown['ok'], shown)
        stored = flow.options_set(self.home,shown['set'],session='chat')
        self.assertTrue(stored['auto']); self.assertEqual(len(stored['options']),3)
        self.assertEqual([o['recommended'] for o in stored['options']].count(True),1)
        # Shown once: asking again names the same set.
        self.assertEqual(prices.auto_present(self.home,'chat',self.search['id'],now=self.now)['set'],shown['set'])
        # The model's purchase_options (another search_id, a subset, its own recommendation) lands on
        # the same cards: its recommendation, and the key the app computes from its arguments.
        args = {'search_id':'wrong','options':[{**o,'recommended':i==2,'why':'Más cápsulas por euro'} for i,o in enumerate(self.options(quotes)['options'])]}
        out = prices.present(self.home,'chat',args,now=self.now,factory=Shop)
        self.assertTrue(out['ok'], out); self.assertEqual(out['set'],shown['set'])
        self.assertEqual(out['alias'],flow.set_key(args['options']))
        stored = flow.options_set(self.home,flow.set_key(args['options']),session='chat')
        self.assertEqual(stored['key'],shown['set'])
        self.assertEqual([o['recommended'] for o in stored['options']],[False,False,True])
        self.assertEqual(stored['options'][2]['why'],'Más cápsulas por euro')
        self.assertIn('ya ve las tarjetas',out['next'])
        # A tap on a card named by either key chooses the same option.
        chosen = flow.choose(self.home,'chat',shown['set']+'-3')
        self.assertEqual(chosen['quote_ref'],quotes[2]['id'])
    def test_a_models_call_with_a_wrong_search_id_or_a_missing_format_still_shows_cards(self):
        quotes = [self.quote(i) for i in range(3)]
        # Only one format named, the search id of another discover: every verified format is shown.
        out = prices.present(self.home,'chat',{'search_id':'stale','options':self.options(quotes[:1])['options']},now=self.now,factory=Shop)
        self.assertTrue(out['ok'], out); self.assertEqual(len(out['options']),3)
    def test_no_quantity_question_before_format_selection(self):
        self.assertIsNotNone(flow.ask_refusal([{'question':'¿Cuántos botes de 300 g quieres?','choices':['1','2']}],True))
    def test_same_amount_is_never_a_price_change(self):
        self.assertNotEqual(errands.blocked_by('cuesta 24,49 € en vez de 24,49 €',{'price':'24,49 €','currency':'EUR'})['kind'],'price')


def classifier_stub():
    """Hermes' `agent.vault_login_classifier`, reduced to what detect_pending needs: a password
    field is a current-password control, a one-time-code field is an OTP control."""
    control = lambda raw: types.SimpleNamespace(index=raw.get('index',0), type=raw.get('type',''), autocomplete=raw.get('autocomplete',''))
    module = types.SimpleNamespace(
        LoginControl=types.SimpleNamespace(from_dict=control),
        build_inspection_js=lambda nonce: 'flatMap ' + nonce,
        classify_login_control=lambda c: types.SimpleNamespace(token='current-password', control=c) if c.type == 'password' else None,
        classify_otp_controls=lambda controls: [types.SimpleNamespace(control=c) for c in controls if 'one-time-code' in c.autocomplete])
    # Only the submodule: tests that need the whole runtime still see `import agent` fail and skip.
    return {'agent.vault_login_classifier': module}


class AccessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        if 'agent.vault_login_classifier' not in sys.modules:
            stub = mock.patch.dict(sys.modules, classifier_stub()); stub.start(); self.addCleanup(stub.stop)
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
    def test_a_declined_login_goes_on_as_a_guest_not_to_a_stop(self):
        # «Ahora no» used to stop the whole purchase; most shops sell to guests.
        p = self.pending()
        out = access.answer(self.home,self.entry['id'],p['request_id'],'',inspect=self.inspect,save=self.save,resume=self.resume)
        self.assertEqual(out['status'],'working'); self.assertEqual(out['offer']['url'],'https://example.com/p')
        self.assertTrue(out['login_declined']); self.assertIsNone(out['secure_request'])
        self.assertFalse(self.saved); self.assertIn('invitado',self.resumed[0][1])
        # And the empty password field on that page is not asked about again.
        descriptors = [{'index':0,'name':'password','type':'password','autocomplete':'current-password'}]
        evaluate = lambda ctx,script: json.dumps(descriptors) if 'flatMap' in script else True
        self.assertIsNone(access.detect_pending(self.home,self.entry['id'],inspect=self.inspect,evaluate=evaluate))
    def test_changed_origin_or_context_cannot_receive_access(self):
        # The tab may be reloaded or replaced while the person types (the agent did not end its
        # turn at once): only another shop or another browser context refuses the answer.
        p = self.pending(); self.context['context'] = 'different'
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
        evaluate = lambda ctx,script: json.dumps(descriptors) if 'flatMap' in script else 'invitado' not in script
        pending = access.detect_pending(self.home,self.entry['id'],inspect=self.inspect,evaluate=evaluate)
        self.assertEqual(pending['kind'],'vault.save_login')
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'needs_login')
        self.assertFalse(self.saved)
    def test_a_guest_checkout_with_an_optional_login_asks_for_nothing(self):
        descriptors = [{'index':0,'name':'password','type':'password','autocomplete':'current-password'}]
        # The page offers «Continuar como invitado» beside the login: the errand takes that way.
        evaluate = lambda ctx,script: json.dumps(descriptors) if 'flatMap' in script else True
        self.assertIsNone(access.detect_pending(self.home,self.entry['id'],inspect=self.inspect,evaluate=evaluate))
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'working')
        # An OTP field is always the person's, guest button or not.
        otp = [{'index':0,'name':'otp','type':'text','autocomplete':'one-time-code'}]
        evaluate = lambda ctx,script: json.dumps(otp) if 'flatMap' in script else True
        pending = access.detect_pending(self.home,self.entry['id'],inspect=self.inspect,evaluate=evaluate)
        self.assertEqual(pending['kind'],'vault.code')

    def test_a_login_the_vault_already_holds_is_used_not_asked_again(self):
        # The account was created in an earlier errand; the next one went to «Crear cuenta» again.
        self.addCleanup(setattr, access, 'vault_logins', access.vault_logins)
        access.vault_logins = lambda origin: [{'handle': 'login-prozis', 'origin': 'https://example.com'}]
        with self.assertRaisesRegex(ValueError, 'login-prozis'):
            self.pending()
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'working')
        # A code is still the person's, and a replacement after a failed fill is allowed.
        self.assertEqual(self.pending('vault.code')['kind'],'vault.code')
        errands.update(self.home,self.entry['id'],status='working',secure_request=None)
        self.assertEqual(access.request(self.home,self.entry['id'],inspect=self.inspect,replace=True)['kind'],'vault.save_login')

    def test_a_login_already_given_is_not_asked_again(self):
        p = self.pending(); self.respond(p, account_action='create')
        with self.assertRaisesRegex(ValueError, 'no se lo pidas otra vez'):
            self.pending()
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'working')
        self.assertEqual(self.pending('vault.code')['kind'],'vault.code')
    def test_two_step_login_fills_the_email_first(self):
        try:
            import agent.vault_login_classifier  # noqa: F401
        except ImportError:
            self.skipTest('Hermes is not importable here')
        backend = mock.Mock()
        backend.get_meta.return_value = types.SimpleNamespace(kind='login',origin='https://example.com',identifier='fixture@example.com')
        backend.resolve_password.return_value = 'FAKE-test-password'
        written = []
        def evaluate(ctx, script):
            if 'flatMap' in script:  # the inspection: a two-step login shows only the email
                return json.dumps([{'index':0,'name':'email','type':'email','autocomplete':'username','label':'Email'}])
            written.append(script)
            return {'filled':1}
        with mock.patch('agent.redact.register_vault_redaction_value'):
            out = access.fill_login(self.home,self.entry['id'],'vault-fixture',inspect=self.inspect,evaluate=evaluate,backend=backend)
        self.assertEqual(out['step'],'identifier')
        self.assertIn('segundo paso',out['next'])
        self.assertIn('fixture@example.com',written[0])
        self.assertNotIn('FAKE-test-password',written[0])

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
    def test_the_cart_check_survives_new_cookies_and_other_pages_but_not_another_context(self):
        # Shops rewrite cookies on every page (session expiry, bot checks, analytics) and the errand
        # moves from the basket to login, address and the bank: none of that is another cart.
        self.assertTrue(self.check()['ok'])
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'working')
        self.cookies.append({'domain':'example.com','name':'session','value':'fictional-new-session'})
        entry = errands.get(self.home,self.entry['id'])
        self.assertTrue(prices.fresh_cart(self.home,entry,inspect=self.inspect))
        elsewhere = lambda e:('https://sis.redsys.es',self.context,lambda *a:{'cookies':[]})
        self.assertTrue(prices.fresh_cart(self.home,entry,inspect=elsewhere))
        other = lambda e:('https://example.com',{**self.context,'context':'other-context'},lambda *a:{'cookies':[]})
        self.assertFalse(prices.fresh_cart(self.home,entry,inspect=other))
        self.assertFalse(prices.fresh_cart(self.home,entry,inspect=self.inspect,now=time.time()+prices.CART_TTL+1))
        self.assertTrue(prices.fresh_cart(self.home,entry,inspect=self.inspect,now=time.time()+prices.TTL+60))
    def test_an_accepted_new_price_needs_no_second_cart_check(self):
        self.amount='39,99 €'
        self.assertTrue(self.check()['price_changed'])
        with mock.patch.object(errands,'launch'), mock.patch.object(errands,'_goal_manager'):
            went = errands.go_on(self.home,self.entry['id'],accept_price=True)
        self.assertEqual(went['offer']['price'],'39,99 €')
        self.assertTrue(prices.fresh_cart(self.home,went,inspect=self.inspect))
        self.assertIn('purchase_check_cart',went['resume_message'])
    def test_real_price_change_exposes_both_amounts(self):
        self.amount='39,99 €'
        changed=self.check()
        self.assertEqual((changed['old'],changed['price']),('34,99 €','39,99 €'))
        self.assertEqual(errands.get(self.home,self.entry['id'])['status'],'stuck')
    def test_a_lower_basket_price_goes_on_without_asking(self):
        self.amount='24,49 €'
        out=self.check()
        self.assertTrue(out['ok']); self.assertIn('menos',out['next'])
        entry=errands.get(self.home,self.entry['id'])
        self.assertEqual(entry['status'],'working'); self.assertEqual(entry['offer']['price'],'24,49 €')
    def test_a_stuck_purchase_can_be_cancelled(self):
        self.amount='39,99 €'; self.check()
        self.assertEqual(errands.stop(self.home,self.entry['id'])['status'],'stopped')
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

    def test_the_banks_payment_page_is_where_the_approved_order_is_paid(self):
        # The shop sent the errand to Redsys: its own total is no longer on screen. With the
        # approval fresh and the cart checked in this context, the card goes in there.
        self.check()
        checkout={'id':'ck-test','status':'approved','total':'73,97 €','currency':'EUR','decided_at':time.time(),'site':'example.com'}
        errands.update(self.home,self.entry['id'],checkout=checkout,checkout_evidence={'checkout_id':'ck-test','selector':'#total'})
        entry=errands.get(self.home,self.entry['id'])
        bank = lambda e:('https://sis.redsys.es',self.context,lambda *a:{'cookies':[]})
        nothing = lambda ctx,script: None
        self.assertTrue(prices.payment_ready(self.home,entry,inspect=bank,evaluate=nothing,gateways={'sis.redsys.es'}))
        # The shop's www twin is the shop: its total is read again there.
        twin = lambda e:('https://www.example.com',self.context,lambda *a:{'cookies':[]})
        self.assertTrue(prices.payment_ready(self.home,entry,inspect=twin,evaluate=self.evaluate,gateways=set()))
        self.assertFalse(prices.payment_ready(self.home,entry,inspect=twin,evaluate=lambda c,s:'79,97 €',gateways=set()))
        # An unknown origin counts only when it shows a payment step (card fields, a provider's frame).
        unknown = lambda e:('https://pay.unknown-provider.example',self.context,lambda *a:{'cookies':[]})
        self.assertTrue(prices.payment_ready(self.home,entry,inspect=unknown,evaluate=lambda c,s:True,gateways=set()))
        self.assertFalse(prices.payment_ready(self.home,entry,inspect=unknown,evaluate=lambda c,s:False,gateways=set()))
        # Another browser context is never this errand's payment, bank or not.
        other = lambda e:('https://sis.redsys.es',{**self.context,'context':'other'},lambda *a:{'cookies':[]})
        self.assertFalse(prices.payment_ready(self.home,entry,inspect=other,evaluate=nothing,gateways={'sis.redsys.es'}))
