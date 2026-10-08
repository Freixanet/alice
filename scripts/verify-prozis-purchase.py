"""Real Chrome / optional GPT-6 Luna regression against an intercepted fictitious shop.

Every browser request is intercepted; only five synthetic product pages, a cart,
and a misleading homepage are served. No real shop, account, checkout or payment.
"""
import argparse
import base64
import importlib.util
import json
import os
import socket
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://www.prozis.com/es/es'
CATEGORY = BASE + '/nutricion-deportiva/desarrollo-muscular/creatina'
FORMATS = [('creatina-creapure-300-g','Creatina Creapure® 300 g'),
           ('creatina-creapure-80-capsulas','Creatina Creapure® 80 cápsulas'),
           ('creatina-creapure-professional-150-g','Creatina Creapure® Professional 150 g'),
           ('creatina-creapure-90-comprimidos-masticables','Creatina Creapure® 90 comprimidos masticables'),
           ('creatine-creapure-320-caps','Creatine Creapure® 320 caps')]


def load(name):
    spec = importlib.util.spec_from_file_location('alice_' + name, ROOT/'hermes-plugin'/f'{name}.py')
    m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
    return m


def shop_page(url):
    path = urlsplit(url).path
    if url == CATEGORY or path.endswith('/search'):
        return ''.join(f'<a href="{BASE}/prozis/{slug}">€24.49<br>€34.99<br>30%<br>{title}</a>' for slug,title in FORMATS)
    if path.endswith('/checkout/index'):
        return '''<section id="chkLists"><div class="chk-prod-card"></div></section>
<form class="coupon-code" onsubmit="event.preventDefault();document.querySelector('#login').hidden=false"><label>Código promocional<input id="promoCode" name="promoCode"></label><button type="submit">Aplicar</button></form>
<form id="login" hidden><label>Email<input type="email"></label></form>
<section class="step-summary"><ul class="summary-list"><li class="summary-item">Subtotal</li><li class="summary-item">Envío Gratis</li></ul></section>
<script>const c=JSON.parse(sessionStorage.cart);document.querySelector('.chk-prod-card').innerHTML='<h3>'+c.title+'</h3><p>'+c.variant+'</p><span class="item-qty">'+c.qty+'</span><div class="item-price-info"><span class="price">'+(34.99*c.qty).toFixed(2)+' €</span></div>';</script>'''
    item = next(((slug,title) for slug,title in FORMATS if path.endswith('/' + slug)),None)
    if not item:
        return '<a href="'+BASE+'/prozis/micronpure">Creatina MicronPure 300 g</a>'
    slug,title = item
    # The 80-caps picker lists 320 first: selecting the first result is wrong.
    options = [('320','320 cápsulas veg.'),('80','80 cápsulas veg.')] if '80-capsulas' in slug else [('1','Cola'),('2','Neutro')]
    return f'''<h1 class="product-name">{title}</h1><p>Precio anunciado 24,49 €</p><span class="coupon-name">IMBACK</span>
<a aria-label="Prozis cart summary" href="{BASE}/checkout/index">Cesta</a>
<div id="addToCartSection"><div class="option-slide-container">{''.join(f'<div class="snap-slider-item" data-id="{n}"><div class="item-description">{label}</div></div>' for n,label in options)}</div>
<div class="quantity-picker-wrapper"><div class="item-counter"><i class="prz-minus">−</i><div class="item-qty">1</div><i class="prz-plus">+</i></div></div><button class="cart-buy-button">Añadir a la cesta</button></div>
<div class="top-mini-cart-container"><div class="cart-item"></div></div>
<script>let qty=1,variant=null;
for(const e of document.querySelectorAll('.snap-slider-item'))e.onclick=()=>{{document.querySelector('.option-active')?.classList.remove('option-active');e.classList.add('option-active');variant=e.innerText;}};
document.querySelector('.prz-plus').onclick=()=>{{if(variant)document.querySelector('#addToCartSection .item-qty').innerText=++qty;}};
document.querySelector('.prz-minus').onclick=()=>{{if(variant&&qty>1)document.querySelector('#addToCartSection .item-qty').innerText=--qty;}};
document.querySelector('.cart-buy-button').onclick=()=>{{if(!variant)return;let title={json.dumps(title)};if(title.includes('80 cápsulas')&&variant.startsWith('320'))title='Creatine Creapure® 320 caps';
const shown=variant.includes('cápsulas')?title.match(/\\d+.*/)[0]:variant;
sessionStorage.cart=JSON.stringify({{title,variant:shown,qty}});document.querySelector('.cart-item').innerHTML=title+' '+shown+'<span class="item-qty">'+qty+'</span>';}};
</script>'''


def main(luna=False):
    token = None
    if luna:
        from hermes_cli.auth import _load_provider_state
        state = _load_provider_state(json.loads((Path.home()/'.hermes/auth.json').read_text()),'openai-codex')
        token = state['tokens']['access_token']; state = None
    with tempfile.TemporaryDirectory(prefix='alice-prozis-fixture-',dir='/tmp',ignore_cleanup_errors=True) as folder:
        home = Path(folder)
        with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        assert port != 9222
        endpoint=f'http://127.0.0.1:{port}'
        os.environ.update(HERMES_HOME=str(home), BROWSER_CDP_URL=endpoint, BU_CDP_URL=endpoint,
                          BH_HOME=str(home/'harness'),BH_RUNTIME_DIR=str(home/'runtime'),ANONYMIZED_TELEMETRY='false')
        (home/'config.yaml').write_text(f'browser:\n  cdp_url: {endpoint}\n')
        live,prices=load('browser_live'),load('purchase_prices')
        assert live.launch(home,port=port)
        class Fixture(prices.Probe):
            def __init__(self,root):
                super().__init__(root,endpoint)
                self.call('Fetch.enable',{'patterns':[{'urlPattern':'*'}]},page=True)
            def call(self,method,params=None,page=False):
                self.sequence+=1; wanted=self.sequence
                msg={'id':wanted,'method':method,'params':params or {}}
                if page:msg['sessionId']=self.session
                self.socket.send(json.dumps(msg))
                while True:
                    reply=json.loads(self.socket.recv(timeout=15))
                    if reply.get('method')=='Fetch.requestPaused':
                        request=reply['params'];self.sequence+=1
                        if urlsplit(request['request']['url']).netloc=='www.prozis.com':
                            operation='Fetch.fulfillRequest';data={'requestId':request['requestId'],'responseCode':200,
                                'responseHeaders':[{'name':'Content-Type','value':'text/html; charset=utf-8'}],
                                'body':base64.b64encode(shop_page(request['request']['url']).encode()).decode()}
                        else:
                            operation='Fetch.failRequest';data={'requestId':request['requestId'],'errorReason':'BlockedByClient'}
                        self.socket.send(json.dumps({'id':self.sequence,'sessionId':self.session,'method':operation,'params':data}))
                    if reply.get('id')==wanted:
                        if reply.get('error'):raise ValueError('Fixture CDP failed')
                        return reply.get('result') or {}
        try:
            # This exercise also proves the service survives a wrong recipe from the model.
            search=prices.discover(home,'fixture',{'url':CATEGORY,'selector':'a[href*="creatina-creapure"]'},factory=Fixture)
            assert len(search['candidates'])==5
            quotes=[prices.verify(home,'fixture',{'search_id':search['id'],'candidate_id':c['id'],'currency':'EUR','recipe':{'quantity':'.quantity-picker-wrapper','variant':'.missing'}},factory=Fixture) for c in search['candidates']]
            assert all(q['price']=='34,99 €' and 'requiere iniciar sesión' in q['condition'] for q in quotes)
            assert all('Gratis' in q['shipping'] for q in quotes)
            q=prices.resolve(home,'fixture',quotes[0]['id'],qty=2,factory=Fixture)
            assert q['price']=='34,99 €' and q['qty']==2
            print('PASS: five formats, 80/320 selection, observed flavour, rejected conditional coupon, line totals and two units',flush=True)
            if luna:run_luna(home,token,prices,Fixture)
        finally:
            with urllib.request.urlopen(endpoint+'/json/version') as r:ws=json.load(r)['webSocketDebuggerUrl']
            from websockets.sync.client import connect
            with connect(ws) as sock:sock.send(json.dumps({'id':1,'method':'Browser.close'}))
            time.sleep(.5)


def run_luna(home, token, prices, Fixture):
    plugin=load('__init__')
    plugin._hermes_root=lambda:home
    plugin._session_id=lambda *args:'luna-search'
    plugin._conversation_key=lambda:'luna-search'
    plugin._purchase_locale=lambda:('ES','EUR')
    plugin._purchase_context=lambda:'[Alice] país ES; moneda EUR.'
    registered={}
    class Context:
        def register_tool(self,**kw):registered[kw['name']]=kw
    plugin._register_task_tools(Context());plugin._register_ask_tools(Context())
    for name in ('discover','verify','verify_remaining','present','resolve'):
        original=getattr(prices,name)
        setattr(prices,name,lambda *a,_fn=original,**kw:_fn(*a,**{**kw,'factory':Fixture}))
    plugin._errands().page_picture=lambda *a:''
    allowed=['purchase_discover','purchase_verify','purchase_options','ask_person','catalog_search']
    registered['catalog_search']['handler']=lambda *a,**kw:json.dumps({'status':'ok','products':[{'title':'Creatina MicronPure 300 g','merchant':'Prozis'}], 'note':'Partial catalog; inspect the real category.'})
    from tools.registry import registry
    for name in allowed:
        registry.register(name=name,toolset='fixture',schema=registered[name]['schema'],handler=registered[name]['handler'],check_fn=lambda:True)
    prompt=plugin._errand_turn(session_id='luna-search',user_message='Compra la creatina creapure de prozis')['context']
    from run_agent import AIAgent
    agent=AIAgent(provider='openai-codex',api_key=token,base_url='https://chatgpt.com/backend-api/codex',model='gpt-6-luna',
        enabled_toolsets=[],max_iterations=15,quiet_mode=True,skip_context_files=True,load_soul_identity=False,
        session_id='luna-search',gateway_session_key='luna-search',skip_memory=True)
    agent.tools=[{'type':'function','function':registered[name]['schema']} for name in allowed]
    agent.valid_tool_names=set(allowed)
    calls=[]
    agent.tool_start_callback=lambda call_id,name,args,*rest:calls.append(name)
    result=agent.run_conversation('Compra la creatina creapure de prozis\n'+prompt)
    flow=prices.module('purchase_flow')
    sets=flow._read(flow._path(home));shown=next(s for s in reversed(sets) if s['session']=='luna-search')
    assert len(shown['options'])==5 and all('creapure' in o['title'].lower() and o['price']=='34,99 €' for o in shown['options'])
    assert 'ask_person' not in calls and not prices.module('errands').listing(home)
    print('PASS: GPT-6 Luna discovered all five formats and presented verified cards without a substitution or premature choice',flush=True)
    print(json.dumps({'tools':calls,'options':[{'title':o['title'],'variant':o['variant'],'price':o['price']} for o in shown['options']],
                      'reply':result.get('final_response')},ensure_ascii=False),flush=True)
    agent.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--luna',action='store_true')
    main(parser.parse_args().luna)
