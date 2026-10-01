"""Synthetic shop and optional real GPT-6 Luna agent, isolated from personal Hermes.

All browser requests are intercepted in a disposable Chrome on a random port.
Only the provider's existing access token is read, never refreshed or copied to disk.
The fixture agent has no terminal, filesystem, messaging or real-shop tools.
"""
from __future__ import annotations
import argparse
import base64
import importlib.util
import json
import os
import socket
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name,path)
    result = importlib.util.module_from_spec(spec);sys.modules[name]=result;spec.loader.exec_module(result)
    return result


def page(url):
    path = urlsplit(url).path
    if path == '/search':
        return '<h1>Prozis Creapure formatos</h1>' + ''.join(f'<a class="product" href="https://example.com/{kind}">Creatina Creapure {variant}</a>' for kind,variant in [('300','300 g'),('80','80 cápsulas'),('90','90 cápsulas')])
    variant = {'/300':'300 g','/80':'80 cápsulas','/90':'90 cápsulas'}.get(path,'300 g')
    base = '34,99' if path in ('/300','/90') else '29,99'
    return f'''<h1>Creatina Creapure</h1><span id="variant">{variant}</span>
<div>Oferta <s>34,99 €</s> 24,49 €</div><p id="condition">24,49 € requiere suscripción, no aplicada.</p>
<input id="qty" type="number" value="1" min="1"><button id="add" onclick="add()">Añadir al carrito</button>
<section id="cart" hidden><div id="line">Creatina Creapure {variant} · Unidades <input id="cart-qty" readonly value="1"><b id="price">{base} €</b></div>
<p id="shipping">Envío 3,99 €</p><input id="coupon" name="coupon"><button id="apply" onclick="apply()">Aplicar cupón</button>
<button id="checkout" onclick="document.querySelector('#login').hidden=false">Continuar con el pedido</button></section>
<form id="login" hidden onsubmit="event.preventDefault();if(this.querySelector('input[type=email]').value && this.querySelector('input[type=password]').value){{document.querySelector('#otp').hidden=false;this.hidden=true}}">
<label>Email<input type="email" name="email" autocomplete="username"></label><label>Password<input type="password" name="password" autocomplete="current-password"></label><button>Iniciar sesión</button></form>
<form id="otp" hidden onsubmit="event.preventDefault();if(this.querySelector('input').value.length===6){{document.querySelector('#summary').hidden=false;this.hidden=true}}"><label>Verification code<input autocomplete="one-time-code" name="otp"></label><button>Verificar</button></form>
<section id="summary" hidden><h2>Resumen final</h2><span id="total"></span><button id="pay" onclick="window.fixturePaid=true">Pagar ahora</button></section>
<script>window.fixturePaid=false;const base={float(base.replace(',','.'))};let units=1;
function add(){{units=Number(document.querySelector('#qty').value);document.querySelector('#cart-qty').value=units;document.querySelector('#cart').hidden=false;total();}}
function apply(){{document.querySelector('#price').textContent=(document.querySelector('#coupon').value==='PUBLIC10'?base*.9:base).toFixed(2).replace('.',',')+' €';total();}}
function total(){{document.querySelector('#total').textContent=(Number(document.querySelector('#price').textContent.replace(',','.').replace(' €',''))*units+3.99).toFixed(2).replace('.',',')+' €';}}
</script>'''


def main(agent_test=False):
    # Read inference access only; the test never points to a personal gateway/home.
    token = None
    if agent_test:
        from hermes_cli.auth import _load_provider_state
        personal_auth = json.loads((Path.home()/'.hermes/auth.json').read_text())
        state = _load_provider_state(personal_auth,'openai-codex')
        token = state['tokens']['access_token']
        personal_auth.clear();state=None
    with tempfile.TemporaryDirectory(prefix='alice-complete-',dir='/tmp') as folder:
        home=Path(folder)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        assert port != 9222
        endpoint=f'http://127.0.0.1:{port}'
        os.environ.update(HERMES_HOME=str(home),BU_CDP_URL=endpoint,BROWSER_CDP_URL=endpoint,
                          BH_HOME=str(home/'harness'),BH_RUNTIME_DIR=str(home/'runtime'),ANONYMIZED_TELEMETRY='false')
        (home/'config.yaml').write_text(f'browser:\n  cdp_url: {endpoint}\nmodel:\n  provider: openai-codex\n  model: gpt-6-luna\n')
        live=load('alice_browser_live',ROOT/'hermes-plugin/browser_live.py')
        prices=load('alice_purchase_prices',ROOT/'hermes-plugin/purchase_prices.py')
        access,flow,errands=(prices.module(n) for n in ('errand_access','purchase_flow','errands'))
        assert live.launch(home,port=port)
        for _ in range(40):
            if live.reachable(endpoint):break
            time.sleep(.2)
        assert live.reachable(endpoint)
        class FixtureProbe(prices.Probe):
            def __init__(self,root):
                super().__init__(root,endpoint)
                self.call('Fetch.enable',{'patterns':[{'urlPattern':'*','requestStage':'Request'}]},page=True)
            def call(self,method,params=None,page=False):
                # Handle intercepted traffic while waiting for any CDP command.
                self.sequence+=1;current=self.sequence
                message={'id':current,'method':method,'params':params or {}}
                if page:message['sessionId']=self.session
                self.socket.send(json.dumps(message))
                while True:
                    reply=json.loads(self.socket.recv(timeout=20))
                    if reply.get('method')=='Fetch.requestPaused':
                        self.sequence+=1
                        request=reply['params'];url=request['request']['url']
                        if urlsplit(url).netloc=='example.com':
                            body=base64.b64encode(page_html(url).encode()).decode()
                            operation='Fetch.fulfillRequest';data={'requestId':request['requestId'],'responseCode':200,'responseHeaders':[{'name':'Content-Type','value':'text/html; charset=utf-8'}],'body':body}
                        else:
                            operation='Fetch.failRequest';data={'requestId':request['requestId'],'errorReason':'BlockedByClient'}
                        self.socket.send(json.dumps({'id':self.sequence,'sessionId':self.session,'method':operation,'params':data}))
                    if reply.get('id')==current:
                        if reply.get('error'):raise ValueError('Fixture CDP operation failed')
                        return reply.get('result') or {}
        page_html=page
        recipe={'title':'h1','variant':'#variant','quantity':'#qty','add':'#add','line':'#line','price':'#price',
                'cart_quantity':'#cart-qty','shipping':'#shipping','condition':'#condition','coupon':'#coupon','apply':'#apply'}
        browser=None
        try:
            search=prices.discover(home,'fixture-chat',{'url':'https://example.com/search','selector':'a.product'},factory=FixtureProbe)
            quotes=[]
            for candidate in search['candidates']:
                quotes.append(prices.verify(home,'fixture-chat',{'search_id':search['id'],'candidate_id':candidate['id'],'currency':'EUR','recipe':recipe},factory=FixtureProbe))
            assert [q['price'] for q in quotes]==['34,99 €','29,99 €','34,99 €']
            bad=prices.verify(home,'fixture-chat',{'search_id':search['id'],'candidate_id':search['candidates'][0]['id'],'currency':'EUR','recipe':recipe,'coupons':['MEMBERS']},factory=FixtureProbe)
            assert bad['price']=='34,99 €' and not bad['coupon_results'][0]['applied']
            public=prices.verify(home,'fixture-chat',{'search_id':search['id'],'candidate_id':search['candidates'][0]['id'],'currency':'EUR','recipe':recipe,'coupons':['PUBLIC10','BAD']},factory=FixtureProbe)
            assert public['price']=='31,49 €'
            args={'search_id':search['id'],'options':[{'quote_ref':q['id'],'title':q['title'],'variant':q['variant'],'url':q['url'],'price':'24,49 €','currency':'EUR','merchant':'Prozis','in_stock':True,'channel':'browser'} for q in quotes]}
            shown=prices.present(home,'fixture-chat',args,factory=FixtureProbe)
            assert shown['ok'] and all(o['price']!='24,49 €' for o in shown['options'])
            chosen=flow.choose(home,'fixture-chat',shown['options'][0]['id'],qty=2)
            revalidated=prices.resolve(home,'fixture-chat',chosen['quote_ref'],qty=2,factory=FixtureProbe)
            assert revalidated['qty']==2 and revalidated['price']=='34,99 €'
            chosen.update(qty=2,price=revalidated['price'])
            entry=errands.create(home,'Compra la creatina de Prozis',offer=flow.offer(chosen),origin_session='fixture-chat',profile='default')
            browser=FixtureProbe(home);browser.goto(chosen['url']);browser.units('#qty',2);browser.click('#add')
            context={'context':browser.context,'target':browser.target,'cdp':endpoint}
            inspect=lambda e:('https://example.com',context,lambda method,params:browser.call(method,params))
            evaluate=lambda ctx,script:browser.evaluate(script)
            checked=prices.check_cart(home,entry['id'],{'line':'#line','price':'#price','cart_quantity':'#cart-qty'},inspect=inspect,evaluate=evaluate)
            assert checked['ok'] and prices.fresh_cart(home,errands.get(home,entry['id']),inspect=inspect)
            try:
                prices.checkout_amount(errands.get(home,entry['id']),'#total',inspect=inspect,evaluate=evaluate)
                raise AssertionError('A hidden total must never become final approval')
            except ValueError:pass
            browser.evaluate("document.querySelector('#checkout').click()")
            pending=access.request(home,entry['id'],inspect=inspect)
            from agent.vault_store import VaultStore
            store=VaultStore(home/'vault')
            resume=[]
            answer=json.dumps({'identifier':'fictional@example.com','password':'FAKE-ONLY-shop-test'})
            saver=lambda payload,origin:store.add_item('login','Fixture',payload,origin=origin)
            access.answer(home,entry['id'],pending['request_id'],answer,inspect=inspect,save=saver,resume=lambda *a:resume.append(a))
            access.answer(home,entry['id'],pending['request_id'],answer,inspect=inspect,save=saver,resume=lambda *a:resume.append(a))
            assert len(resume)==1 and len(store.list_items())==1
            meta=store.list_items()[0]
            backend=type('Backend',(),{'get_meta':lambda self,id:store.get_meta(id),'resolve_password':lambda self,id:store.resolve_secret(id)['password']})()
            access.fill_login(home,entry['id'],meta.id,inspect=inspect,backend=backend)
            browser.evaluate("document.querySelector('#login').requestSubmit()")
            pending=access.request(home,entry['id'],'vault.code',inspect=inspect)
            access.answer(home,entry['id'],pending['request_id'],'123456',inspect=inspect,
                          resume=lambda *a:resume.append(a))
            from agent.redact import clear_vault_redaction_values
            clear_vault_redaction_values()
            access.protect_browser_secrets(errands.get(home,entry['id']),inspect=inspect,evaluate=evaluate)
            from tools.browser_use_cli import browser_exec
            errands.context_file(entry['id']).write_text(json.dumps({'context':browser.context,'target':browser.target,'daemon':'0'}))
            result=browser_exec(errands.context_preamble(entry['id']) + "print(page_info())", session=entry['session_id'],timeout_s=45,task_id='fixture-redaction')
            if isinstance(result,str):result=json.loads(result)
            assert '123456' not in json.dumps(result)
            print('PASS: OTP stays redacted in ordinary browser output after process restart',flush=True)
            result=browser_exec(errands.context_preamble(entry['id']) + "print(js(\"document.querySelector('input[name=otp]').value\"))",session=entry['session_id'],timeout_s=45,task_id='fixture-redaction')
            if isinstance(result,str):result=json.loads(result)
            assert '123456' not in json.dumps(result)
            assert browser.evaluate("document.querySelector('input[name=otp]').style.getPropertyValue('-webkit-text-security')") == 'disc'
            print('PASS: OTP explicit field read and screenshot protected after process restart',flush=True)
            # Exercise a six-slot OTP with the official control classifier.
            browser.evaluate("""(()=>{const f=document.querySelector('#otp');f.innerHTML=Array.from({length:6},(_,i)=>'<input name="otp'+i+'" autocomplete="one-time-code" maxlength="1">').join('')+'<button>Verificar</button>';f.onsubmit=e=>{e.preventDefault();if(Array.from(f.querySelectorAll('input')).map(x=>x.value).join('').length===6){document.querySelector('#summary').hidden=false;f.hidden=true}}})()""")
            split_pending=access.request(home,entry['id'],'vault.code',inspect=inspect)
            access.answer(home,entry['id'],split_pending['request_id'],'123456',inspect=inspect,resume=lambda *a:resume.append(a))
            clear_vault_redaction_values()
            access.protect_browser_secrets(errands.get(home,entry['id']),inspect=inspect,evaluate=evaluate)
            result=browser_exec(errands.context_preamble(entry['id']) + "print(js(\"Array.from(document.querySelectorAll('#otp input')).map(e=>e.value)\"));print(js(\"document.querySelector('#price').textContent\"))",session=entry['session_id'],timeout_s=45,task_id='fixture-redaction')
            if isinstance(result,str):result=json.loads(result)
            assert str(list('123456')) not in json.dumps(result) and '123456' not in json.dumps(result)
            assert '34,99' in json.dumps(result)
            assert browser.evaluate("Array.from(document.querySelectorAll('#otp input')).every(e=>e.style.getPropertyValue('-webkit-text-security')==='disc')")
            print('PASS: real split OTP is filled, redacted and masked while unrelated prices remain readable',flush=True)
            browser.evaluate("document.querySelector('#otp').requestSubmit()")
            assert not browser.evaluate('window.fixturePaid')
            total=browser.read('#total');assert total=='73,97 €'
            cart={'merchant':'Prozis','site':'example.com','currency':'EUR','total':total,
                  'items':[{'name':chosen['title'],'variant':chosen['variant'],'qty':2,'price':'34,99 €'}], 'delivery':'Envío 3,99 €'}
            result=errands.request_checkout(home,entry['id'],cart,fetch=lambda *a:(_ for _ in ()).throw(OSError('offline')))
            assert result['ok'] and errands.pay_gate(home,entry['session_id'],tool_name='browser_click',args={'text':'Pagar ahora'})['action']=='block'
            # The payment capability re-reads the same approved visible total.
            # No payment button is ever operated, even in this synthetic test.
            prices.check_cart(home,entry['id'],{'line':'#line','price':'#price','cart_quantity':'#cart-qty'},inspect=inspect,evaluate=evaluate)
            approved=errands.get(home,entry['id'])['checkout']
            approved.update(status='approved',decided_at=time.time())
            errands.update(home,entry['id'],checkout=approved,checkout_evidence={'checkout_id':approved['id'],'selector':'#total'})
            assert prices.payment_ready(home,errands.get(home,entry['id']),inspect=inspect,evaluate=evaluate)
            browser.evaluate("document.querySelector('#total').textContent='79,97 €'")
            assert not prices.payment_ready(home,errands.get(home,entry['id']),inspect=inspect,evaluate=evaluate)
            assert not browser.evaluate('window.fixturePaid')
            print('PASS: real isolated Chrome, all formats, conditional/rejected/public coupons, units, login vault, OTP, duplicate answers, exact total and unapproved pay blocked',flush=True)
            for path in (home/'.alice').rglob('*.json'):
                assert 'FAKE-ONLY-shop-test' not in path.read_text() and '123456' not in path.read_text()
            if agent_test:
                run_agent(home,token,prices,access,errands,flow,FixtureProbe,recipe)
        finally:
            if browser:browser.close()
            from websockets.sync.client import connect
            try:
                with __import__('urllib.request',fromlist=['urlopen']).urlopen(endpoint+'/json/version') as r:ws=json.load(r)['webSocketDebuggerUrl']
                with connect(ws) as sock:sock.send(json.dumps({'id':1,'method':'Browser.close'}))
            except Exception:pass
            for _ in range(50):
                if not live.reachable(endpoint):
                    time.sleep(.3)
                    break
                time.sleep(.1)


def run_agent(home,token,prices,access,errands,flow,Probe,recipe):
    # Function schemas/handlers come from the production plugin. Only the shop/browser
    # transport is substituted, and no real engine/gateway can be launched.
    plugin=load('alice_fixture_plugin',ROOT/'hermes-plugin/__init__.py')
    plugin._hermes_root=lambda:home
    import types
    plugin._cards_module=lambda:types.SimpleNamespace(cards=lambda:[{'label':'Visa ficticia ···4242'}])
    current={'session':'agent-fixture-chat'}
    plugin._session_id=lambda *a:current['session']
    registered={}
    class Ctx:
        def register_tool(self,**kw):registered[kw['name']]=kw
    plugin._register_task_tools(Ctx())
    originals={name:getattr(prices,name) for name in ('discover','verify','present','resolve','verify_remaining')}
    for name,fn in originals.items():
        setattr(prices,name,lambda *a,_fn=fn,**kw:_fn(*a,**{**kw,'factory':Probe}))
    errands.launch=lambda *a,**kw:True
    errands.open_goal=lambda *a:None
    errands.page_picture=lambda *a,**kw:''
    errands._fetch=lambda *a,**kw:(_ for _ in ()).throw(OSError('fixture has no network fetch'))
    owned={'browser':None,'entry':None}
    def inspect(e):
        b=owned['browser'];return 'https://example.com',{'context':b.context,'target':b.target},lambda method,params:b.call(method,params)
    access.target=inspect
    def evaluate(ctx,script):
        try:return owned['browser'].evaluate(script)
        except ValueError:
            if 'String(e.value' in script or 'line.contains' in script:
                print('Cart DOM expression:',script,flush=True)
            raise
    access.page_evaluate=evaluate
    original_request,original_fill=access.request,access.fill_login
    access.request=lambda *a,**kw:original_request(*a,**{**kw,'inspect':inspect})
    access.fill_login=lambda *a,**kw:original_fill(*a,**{**kw,'inspect':inspect,'evaluate':access.page_evaluate})
    originals['check_cart']=prices.check_cart
    prices.check_cart=lambda *a,**kw:originals['check_cart'](*a,**{**kw,'inspect':inspect,'evaluate':access.page_evaluate})
    original_amount=prices.checkout_amount
    prices.checkout_amount=lambda *a,**kw:original_amount(*a,**{**kw,'inspect':inspect,'evaluate':access.page_evaluate})
    original_fresh=prices.fresh_cart
    prices.fresh_cart=lambda *a,**kw:original_fresh(*a,**{**kw,'inspect':inspect})
    def shop(args,**kw):
        if owned['browser'] is None:
            return json.dumps({'ok':False,'error':'Search first with purchase_discover at https://example.com/search and selector a.product. The person has not chosen a format yet.'})
        operation=args.get('operation','read')
        if operation=='read':return json.dumps({'url':owned['browser'].evaluate('location.href'),'html':owned['browser'].evaluate('document.body.innerText'),'selectors':recipe})
        if operation=='add':owned['browser'].units('#qty',owned['entry']['offer']['qty']);owned['browser'].click('#add')
        elif operation=='checkout':owned['browser'].evaluate("document.querySelector('#checkout').click()")
        elif operation=='signin':owned['browser'].evaluate("document.querySelector('#login').requestSubmit()")
        elif operation=='verify':owned['browser'].evaluate("document.querySelector('#otp').requestSubmit()")
        else: return json.dumps({'ok':False,'error':'No fixture operation permits payment'})
        return shop({'operation':'read'})
    registered['fixture_shop']={'name':'fixture_shop','toolset':'fixture','schema':{'name':'fixture_shop','description':'Read or operate the isolated shop. Available after a product has been explicitly chosen. add fills cart; checkout opens login; signin submits the already-filled login; verify submits the already-filled OTP; read inspects the page. Never permits payment.', 'parameters':{'type':'object','properties':{'operation':{'type':'string','enum':['read','add','checkout','signin','verify']}}}},'handler':shop}
    allowed=['purchase_discover','purchase_verify','purchase_options','purchase_check_cart','login_request','login_fill','checkout_request','fixture_shop']
    from tools.registry import registry
    for name in allowed:
        kw=registered[name];registry.register(name=name,toolset='fixture',schema=kw['schema'],handler=kw['handler'],check_fn=lambda:True)
    from run_agent import AIAgent
    agent=AIAgent(provider='openai-codex',api_key=token,base_url='https://chatgpt.com/backend-api/codex',model='gpt-6-luna',
                  enabled_toolsets=[],max_iterations=20,quiet_mode=True,skip_context_files=True,load_soul_identity=False,
                  session_id='fixture-luna',gateway_session_key='fixture-luna',skip_memory=True)
    agent.tools=[{'type':'function','function':registered[n]['schema']} for n in allowed]
    agent.valid_tool_names=set(allowed)
    calls=[]
    def record(call_id,name,args,*rest):
        calls.append({'tool':name,'selectors':args if name in ('purchase_check_cart','purchase_verify') else None})
        if name in ('purchase_check_cart','purchase_verify'):
            print('Luna request:',name,json.dumps(args),flush=True)
    agent.tool_start_callback=record
    system=(ROOT/'hermes-plugin/skills/comprar/SKILL.md').read_text()+'\nTEST ISOLATED SHOP ONLY. Merchant is Prozis; search https://example.com/search selector a.product. Currency EUR. No secrets in chat. Recipe DOM selectors: '+json.dumps(recipe)
    first=agent.run_conversation('Compra la creatina Creapure de Prozis',system_message=system)
    sets=flow._read(flow._path(home));found=next((s for s in reversed(sets) if s['session']==current['session']),None)
    if not found or len(found['options']) != 3:
        print('Luna first-turn diagnostic:', json.dumps({k:v for k,v in first.items() if k not in ('messages',)},default=str)[:2400],flush=True)
        print('Luna first-turn calls:',calls,flush=True)
        print('Luna first-turn tool results:',json.dumps([m for m in first.get('messages',[]) if m.get('role')=='tool'],default=str)[-6000:],flush=True)
    assert found and len(found['options'])==3,'Luna did not present all formats'
    assert not found.get('chosen'),'Luna selected a format prematurely'
    chosen=flow.choose(home,current['session'],next(o['id'] for o in found['options'] if o['variant']=='300 g'),qty=2)
    quote=prices.resolve(home,current['session'],chosen['quote_ref'],qty=2);chosen.update(qty=2,price=quote['price'])
    entry=errands.create(home,flow.task(chosen),offer=flow.offer(chosen),origin_session=current['session'],profile='default')
    owned['entry']=entry;owned['browser']=Probe(home);owned['browser'].goto(chosen['url']);current['session']=entry['session_id']
    history=first['messages']
    try:
        result=agent.run_conversation(errands.brief(entry)+' En esta tienda de prueba usa fixture_shop para añadir, continuar, iniciar sesión y verificar, y leer la página; el servicio no permite pagar.',system_message=system,conversation_history=history)
        access.detect_pending(home,entry['id'],inspect=inspect,evaluate=access.page_evaluate)
        pending=errands.get(home,entry['id']).get('secure_request')
        if not pending or pending['kind']!='vault.save_login':
            print('Luna preparation reply:',result.get('final_response'),flush=True)
            print('Luna preparation diagnostic:',json.dumps({'reply':result.get('final_response'),'completed':result.get('completed'),'tools':[m for m in result.get('messages',[]) if m.get('role')=='tool']},default=str)[-6000:],flush=True)
        assert pending and pending['kind']=='vault.save_login','Luna did not request secure shop access'
        answers=[]
        access.answer(home,entry['id'],pending['request_id'],json.dumps({'identifier':'fake-agent@example.com','password':'FAKE-Luna-password'}),inspect=inspect,resume=lambda *a:answers.append(a))
        result=agent.run_conversation(answers[-1][-1],system_message=system,conversation_history=result['messages'])
        access.detect_pending(home,entry['id'],inspect=inspect,evaluate=access.page_evaluate)
        pending=errands.get(home,entry['id']).get('secure_request')
        if not pending or pending['kind']!='vault.code':
            print('Luna access reply:',result.get('final_response'),flush=True)
            diagnostic=json.dumps({'reply':result.get('final_response'),'tools':[m for m in result.get('messages',[]) if m.get('role')=='tool']},default=str)
            print('Luna access diagnostic:',diagnostic[-7000:].replace('FAKE-Luna-password','[redacted]').replace('654321','[redacted]'),flush=True)
        assert pending and pending['kind']=='vault.code','Luna did not request secure OTP'
        access.answer(home,entry['id'],pending['request_id'],'654321',inspect=inspect,fill_code=lambda e,v:owned['browser'].evaluate("document.querySelector('#otp input').value='654321'"),resume=lambda *a:answers.append(a))
        result=agent.run_conversation(answers[-1][-1],system_message=system,conversation_history=result['messages'])
        final=errands.get(home,entry['id'])
        if final['status']!='needs_approval' or (final.get('checkout') or {}).get('total')!='73,97 €':
            diagnostic=json.dumps({'status':final['status'],'checkout':final.get('checkout'),'reply':result.get('final_response'),'tools':[m for m in result.get('messages',[]) if m.get('role')=='tool']},default=str)
            print('Luna cart selectors:',json.dumps(calls),flush=True)
            print('Luna final diagnostic:',diagnostic[-7000:].replace('FAKE-Luna-password','[redacted]').replace('654321','[redacted]'),flush=True)
        assert final['status']=='needs_approval' and final['checkout']['total']=='73,97 €','Luna did not reach exact final approval'
        assert not owned['browser'].evaluate('window.fixturePaid')
        transcript=json.dumps(result['messages'],ensure_ascii=False)
        assert 'FAKE-Luna-password' not in transcript and '654321' not in transcript
        print('PASS: real GPT-6 Luna agent presented three verified formats, waited for choice, used 2 units, secure login and OTP, and reached approval 73,97 € with no payment',flush=True)
        report={'model':agent.model,'provider':agent.provider,'status':'needs_approval','total':final['checkout']['total'],'paid':False,'calls':calls}
        (ROOT.parent.parent/'outputs/alice-luna-fixture.json').write_text(json.dumps(report,indent=2))
    finally:
        print('Luna tool selectors:',json.dumps(calls),flush=True)
        owned['browser'].close()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--agent',action='store_true');args=parser.parse_args();main(args.agent)
