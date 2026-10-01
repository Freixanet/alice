"""A persisted human request, independent of the model's prompt lifetime.

Text remains lossless. Structured fields are conservative extractions, never
silent guesses for brand, compatibility, allergy or negation. Offers retain the
request revision and source inventory so later corrections invalidate old work.
"""
import re
import time
from urllib.parse import urlsplit


def module(name):
    import importlib.util,sys
    from pathlib import Path
    key='alice_'+name
    if key not in sys.modules:
        spec=importlib.util.spec_from_file_location(key,Path(__file__).with_name(name+'.py'))
        sys.modules[key]=importlib.util.module_from_spec(spec);spec.loader.exec_module(sys.modules[key])
    return sys.modules[key]


def parse(text):
    flow=module('purchase_flow')
    urls=re.findall(r'https://[^\s<>"\]]+',text)
    store,store_only=flow.requested_identity(text)
    budget=re.search(r'(?:menos de|hasta|m[aá]ximo|max(?:imum)?|under)\s*(\d[\d.,]*\s*(?:€|EUR|USD|GBP|\$|£))',text,re.I)
    return {'request':text,'qty':next((flow.requested_quantity(t) for t in reversed(text.split('\nCorrección de la persona: ')) if re.search(r'\b(?:[0-9]+|un[oa]?|dos|tres|cuatro|cinco)\s+(?:unidades|botes|packs|bottles|items)\b',t,re.I)),flow.requested_quantity(text)),'identity':store,'store_only':store_only,
            'domains':sorted({urlsplit(url).hostname for url in urls if urlsplit(url).hostname}),
            'max_price':budget.group(1) if budget else '',
            'terms':re.findall(r'"([^"]+)"|«([^»]+)»',text)}


def current(home,session):
    flow=module('purchase_flow')
    rows=flow._read(flow._path(home).with_name('purchase-intents.json'))
    return next((r for r in reversed(rows) if r['session']==session and r.get('active')),None)


def remember(home,session,text,*,correction=False):
    flow=module('purchase_flow')
    with flow._locked(home) as base:
        path=base.with_name('purchase-intents.json')
        rows=flow._read(path)
        old=next((r for r in reversed(rows) if r['session']==session and r.get('active')),None)
        request=(old['request']+'\nCorrección de la persona: '+text) if correction and old else text
        for row in rows:
            if row['session']==session:row['active']=False
        item={'session':session,'revision':int((old or {}).get('revision',0))+1,'active':True,'at':time.time(),**parse(request)}
        rows=[r for r in rows if r.get('active') or time.time()-r.get('at',0)<3*86400]
        rows.append(item);flow._write(path,rows)
        return item


def close(home,session):
    flow=module('purchase_flow')
    with flow._locked(home) as base:
        path=base.with_name('purchase-intents.json');rows=flow._read(path)
        for row in rows:
            if row['session']==session:row['active']=False
        flow._write(path,rows)


def correction(text):
    return bool(re.match(r'^\s*(?:mejor|cambia|en vez|que sea|la quiero|lo quiero|talla|color|presupuesto|budget|actually|instead|make it)\b',text,re.I))


def accepts(intent,option):
    flow=module('purchase_flow');money=module('money')
    if not intent:return True
    host=urlsplit(option.get('url','')).hostname
    if intent.get('domains') and host not in intent['domains']:return False
    if intent.get('identity') and not flow.matches_identity(option,intent['identity'],intent['store_only']):return False
    if intent.get('max_price'):
        limit=money.parse(intent['max_price'],option.get('currency',''));price=money.parse(option.get('price'),option.get('currency',''))
        if not limit or not price or price[0]*intent.get('qty',1)>limit[0]:return False
    for alternatives in intent.get('terms') or []:
        term=next((t for t in alternatives if t),'')
        if term.casefold() not in (option.get('title','')+' '+option.get('variant','')).casefold():return False
    return True
