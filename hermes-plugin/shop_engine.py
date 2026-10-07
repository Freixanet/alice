"""Any shop, without the model guessing selectors: the engine finds the product, its price, the
add-to-cart control, the cart line and the order total itself.

Three tiers, tried in order, each saying how it answered (``how``) so tests and the person's
report can tell them apart:

1. **The platform's own endpoints** — Shopify (``/products/<handle>.js``, ``/cart/add.js``,
   ``/cart.js``, ``/search/suggest.json``) and WooCommerce (the Store API under
   ``/wp-json/wc/store/v1/``). Deterministic: prices in minor units, stock, variants, no DOM.
2. **Structured data** — JSON-LD ``Product``/``Offer``, microdata ``itemprop``, ``og:price``.
3. **DOM heuristics** — the search form, product links on a results page, the add button, the
   cart link, the cart line that names the product, the amount next to «Total», cookie banners.

When all three fail to put the product in a basket, the engine still answers with the page's own
price (``basis: 'page'``) so the person gets their cards; the errand confirms that price in its
real basket before anything is approved (purchase_prices.check_cart), and the total the person
approves is always the one read from the checkout page. Prozis keeps its observed adapter
(purchase_prozis.py) behind the same interface; it is the test bench, not a special case.

Everything here runs in the page as JavaScript through a ``page`` object with ``evaluate(js)``
(a disposable Probe in the chat, the errand's own tab in the errand) and, where navigation is
allowed, ``goto(url)``. Nothing here pays, logs in or reads personal data.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional
from urllib.parse import quote as url_quote, urlsplit, urlunsplit, urlencode

PLATFORMS = ("shopify", "woocommerce", "magento", "prestashop", "prozis", "generic")


def module(name):
    key = "alice_" + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, Path(__file__).with_name(name + ".py"))
        value = importlib.util.module_from_spec(spec)
        sys.modules[key] = value
        spec.loader.exec_module(value)
    return sys.modules[key]


# ── JavaScript run in the page ───────────────────────────────────────────────────
# Shared helpers, prepended to every snippet: visibility, normalised text, amounts.
HELPERS = r"""
const seen=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden'&&getComputedStyle(e).display!=='none';
const struck=e=>!!e&&(!!e.closest('del,s,strike')||getComputedStyle(e).textDecorationLine.includes('line-through'));
const squash=s=>String(s||'').replace(/\s+/g,' ').trim();
const norm=s=>squash(String(s||'').normalize('NFKD').replace(/[̀-ͯ]/g,'').toLowerCase().replace(/(\d)\s+(?=(g|gr|kg|ml|l|cl|caps|capsulas|comprimidos|tabs|uds?|unidades)\b)/g,'$1').replace(/[^0-9a-z]+/g,' '));
const words=s=>norm(s).split(' ').filter(w=>w.length>1||/\d/.test(w));
const names=(line,...parts)=>{const l=norm(line);const ws=l.split(' ');return parts.every(p=>{const pw=words(p);return !pw.length||pw.every(w=>ws.includes(w)||l.includes(w));});};
const AMOUNT=/(?:(?:€|EUR|US\$|\$|USD|£|GBP|CHF|MXN|ARS|CLP|COP)\s?\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{1,2})?)|(?:\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{1,2})?\s?(?:€|EUR|US\$|\$|USD|£|GBP|CHF|MXN|ARS|CLP|COP))/g;
const amounts=t=>(squash(t).match(AMOUNT)||[]).map(a=>a.trim());
const fire=e=>{e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));};
const text=e=>squash([e.innerText,e.value,e.getAttribute&&e.getAttribute('aria-label'),e.title].filter(Boolean).join(' '));
const PAY=/pagar|\bpay\b|place.?order|comprar ahora|buy now|confirmar|checkout|finalizar|tramitar|realizar pedido|suscri|subscri/i;
"""

DETECT_JS = r"""(()=>{%s
const r={platform:'generic',how:''};
const S=window.Shopify;
if((S&&S.shop)||document.querySelector('script[src*="cdn.shopify.com"],link[href*="cdn.shopify.com"]')||document.querySelector('form[action*="/cart/add"]')){r.platform='shopify';r.how=S&&S.shop?'Shopify.shop':'markup';r.root=(S&&S.routes&&S.routes.root)||'/';}
else if((document.body&&/\bwoocommerce\b/.test(document.body.className))||document.querySelector('link[href*="/plugins/woocommerce/"],script[src*="/plugins/woocommerce/"]')||window.wc_add_to_cart_params||window.wc){r.platform='woocommerce';r.how='markup';}
else if(document.querySelector('body.catalog-product-view,body[class*="page-products"],[data-mage-init],script[src*="/static/version"]')||(window.requirejs&&document.querySelector('script[src*="mage/"]'))){r.platform='magento';r.how='markup';}
else if(window.prestashop||document.querySelector('meta[name=generator][content*="PrestaShop" i],body#product,body#category,body#search')){r.platform='prestashop';r.how='markup';}
return r;})()"""

COOKIES_JS = r"""(()=>{%s
const picks=['#CybotCookiebotDialogBodyButtonDecline','#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll','#onetrust-accept-btn-handler','#onetrust-reject-all-handler','#didomi-notice-agree-button','.didomi-continue-without-agreeing','button[data-testid="uc-accept-all-button"]','button[data-testid="uc-deny-all-button"]','.cc-btn.cc-dismiss','.cc-accept','#cookie-accept','.js-cookie-consent-agree','button[id*="cookie" i][id*="accept" i]','button[class*="cookie" i][class*="accept" i]'];
for(const q of picks){const e=document.querySelector(q);if(e&&seen(e)){e.click();return {ok:true,how:q};}}
const uc=document.querySelector('#usercentrics-root');if(uc&&uc.shadowRoot){const b=uc.shadowRoot.querySelector('button[data-testid="uc-accept-all-button"],button[data-testid="uc-deny-all-button"]');if(b){b.click();return {ok:true,how:'usercentrics'};}}
const box=Array.from(document.querySelectorAll('[id*="cookie" i],[class*="cookie" i],[id*="consent" i],[class*="consent" i],[id*="gdpr" i],[class*="gdpr" i],[aria-label*="cookie" i]')).filter(seen);
for(const b of box){for(const e of b.querySelectorAll('button,a[role=button],[role=button],input[type=button]')){if(seen(e)&&/^(aceptar|accept|agree|consent|entendido|de acuerdo|ok|allow|permitir|rechazar|reject|decline|continuar|close|cerrar)\b/i.test(text(e))&&!/manage|gestionar|configurar|settings|preferenc/i.test(text(e))){e.click();return {ok:true,how:'banner:'+text(e).slice(0,20)};}}}
return {ok:false};})()"""

PRODUCT_JS = r"""(()=>{%s
const out={how:'',name:'',price:'',currency:'',available:null,image:'',sku:'',variants:[]};
const nodes=[];for(const s of document.querySelectorAll('script[type="application/ld+json"]')){try{const walk=x=>{if(Array.isArray(x))x.forEach(walk);else if(x&&typeof x==='object'){nodes.push(x);for(const k of ['@graph','mainEntity','hasVariant','itemListElement'])if(x[k])walk(x[k]);}};walk(JSON.parse(s.textContent));}catch(e){}}
const isType=(x,t)=>{const v=x&&x['@type'];return Array.isArray(v)?v.includes(t):v===t;};
const prod=nodes.find(x=>isType(x,'Product'))||nodes.find(x=>isType(x,'ProductGroup'));
const offerList=p=>[].concat(p&&p.offers||[]).flatMap(o=>o&&(isType(o,'AggregateOffer')&&o.offers)?[].concat(o.offers):[o]).filter(Boolean);
const avail=v=>v==null?null:/InStock|LimitedAvailability|OnlineOnly|PreOrder|BackOrder|InStoreOnly/i.test(String(v));
if(prod){const offers=offerList(prod);const first=offers[0]||{};out.how='jsonld';out.name=squash(prod.name);out.sku=squash(prod.sku||first.sku||'');
 const img=[].concat(prod.image||[]).map(i=>typeof i==='string'?i:(i&&(i.url||i.contentUrl))||'').find(Boolean);out.image=img||'';
 const price=first.price!=null?first.price:(first.lowPrice!=null?first.lowPrice:(first.priceSpecification&&first.priceSpecification.price));
 out.price=price!=null?String(price):'';out.currency=squash(first.priceCurrency||(first.priceSpecification&&first.priceSpecification.priceCurrency)||'');out.available=avail(first.availability);
 const variants=[].concat(prod.hasVariant||[]).map(v=>{const o=offerList(v)[0]||{};return {label:squash(v.name||v.sku||''),price:o.price!=null?String(o.price):'',currency:squash(o.priceCurrency||out.currency),available:avail(o.availability),url:o.url||v.url||'',id:String(v.sku||o.sku||'')};});
 out.variants=variants.length?variants:(offers.length>1?offers.map(o=>({label:squash(o.name||o.sku||o.description||''),price:o.price!=null?String(o.price):'',currency:squash(o.priceCurrency||''),available:avail(o.availability),url:o.url||'',id:String(o.sku||'')})):[]);}
if(!out.price){const p=document.querySelector('[itemprop=price]');const c=document.querySelector('[itemprop=priceCurrency]');if(p&&(seen(p)||p.getAttribute('content'))){out.how='microdata';out.price=p.getAttribute('content')||squash(p.textContent);out.currency=c?(c.getAttribute('content')||squash(c.textContent)):'';}}
if(!out.price){const m=document.querySelector('meta[property="product:price:amount"],meta[property="og:price:amount"],meta[itemprop=price]');const c=document.querySelector('meta[property="product:price:currency"],meta[property="og:price:currency"],meta[itemprop=priceCurrency]');if(m&&m.content){out.how='og';out.price=m.content;out.currency=c?c.content:'';}}
if(!out.name){const n=document.querySelector('h1');const og=document.querySelector('meta[property="og:title"]');out.name=squash((n&&n.innerText)||(og&&og.content)||document.title);}
// Metadata often appends marketing/store text absent from the basket. Use the actual heading
// only for an unambiguous product, retaining every numeric format qualifier from the metadata.
const heading=Array.from(document.querySelectorAll('h1')).find(e=>seen(e)&&!e.closest('header,nav'));
const headingName=heading?squash(heading.innerText):'';
const optionControls=Array.from(document.querySelectorAll('select,input[type=radio],[role=radio],[role=option],[data-variant],[data-option],[class*="swatch" i]')).some(e=>seen(e)&&!e.closest('header,nav')&&!/qty|quant|cantidad|cookie|consent/i.test(e.name+' '+e.id+' '+e.className));
const numbers=s=>norm(s).match(/\d+/g)||[];
if(headingName&&out.name&&!out.variants.length&&!optionControls&&norm(out.name).startsWith(norm(headingName))&&names(out.name,headingName)&&numbers(out.name).every(n=>numbers(headingName).includes(n)))out.name=headingName;
if(!out.price){const h1=document.querySelector('h1');const top=h1?h1.getBoundingClientRect().bottom:0;const cands=[];
 for(const e of document.querySelectorAll('[class*="price" i],[id*="price" i],[data-price],[itemprop=offers] *,span,b,strong,p,div,dd')){if(!seen(e)||struck(e)||e.children.length>3)continue;const t=squash(e.innerText);if(!t||t.length>60)continue;const found=amounts(t);if(!found.length)continue;if(/\/\s*(kg|l|100|ud|unidad|mes|month)|por (kg|litro|unidad)|per (kg|l|unit)|desde|from|ahorr|saving|descuento|discount|env[ií]o|shipping|antes|was\b|rrp|pvp/i.test(t))continue;const r=e.getBoundingClientRect();const fs=parseFloat(getComputedStyle(e).fontSize)||12;const near=/price|precio|amount|importe/i.test(e.className+' '+e.id);cands.push({t:found[found.length-1],score:fs*3+(near?40:0)-Math.abs(r.top-top)/40,area:r.width*r.height});}
 cands.sort((a,b)=>b.score-a.score);if(cands.length){out.how='dom';out.price=cands[0].t;}}
if(!out.available&&out.available!==false){const t=squash(document.body?document.body.innerText.slice(0,20000):'');if(/agotad|sin stock|out of stock|sold out|no disponible|unavailable|discontinued|ya no (se )?vende/i.test(t)&&!/en stock|in stock|disponible\b/i.test(t))out.available=false;}
if(!out.image){const og=document.querySelector('meta[property="og:image"]');out.image=og?og.content:'';}
return (out.price||out.name)?out:null;})()"""

SELECTED_VARIANT_JS = r"""(()=>{%s
const parts=[];
for(const s of document.querySelectorAll('select')){if(!seen(s)||/qty|quant|cantidad|units/i.test(s.name+' '+s.id+' '+s.className)||s.options.length<2)continue;const o=s.options[s.selectedIndex];if(o&&!/^(selecciona|elige|choose|select|--)/i.test(squash(o.textContent)))parts.push(squash(o.textContent));}
for(const r of document.querySelectorAll('input[type=radio]:checked')){const l=r.closest('label')||document.querySelector('label[for="'+r.id+'"]');const t=squash(l?l.innerText:r.value);if(t&&t.length<60&&!/tarjeta|card|paypal|bizum|envío|shipping|delivery/i.test(t))parts.push(t);}
if(!parts.length){for(const e of document.querySelectorAll('[aria-pressed=true],[aria-checked=true],[aria-selected=true],.active,.selected,.is-active,.is-selected,.option-active')){if(seen(e)&&e.children.length<=2){const t=squash(e.innerText);if(t&&t.length<60&&!/menu|nav|tab|slide/i.test(e.className)&&!e.closest('nav,header,footer'))parts.push(t);}}}
return parts.filter((p,i)=>parts.indexOf(p)===i).join(' / ');})()"""

VARIANT_JS = r"""((label)=>{%s
const want=norm(label);if(!want)return {ok:false,why:'sin variante'};
const fits=t=>{const n=norm(t);return n===want||(n.includes(want)&&n.length<=want.length+12)||names(n,want);};
// The closest wording wins, and a select in the add-to-cart form over one elsewhere on the page
// (HSN lists «Análisis … 500g» lab reports in a select of its own above the sizes).
const score=t=>{const n=norm(t);return n===want?0:(n.includes(want)&&n.length<=want.length+12)?1:names(n,want)?2+n.length/1000:null;};
let best=null;
for(const sel of document.querySelectorAll('select')){if(!seen(sel)||/qty|quant|cantidad|units/i.test(sel.name+' '+sel.id))continue;const inForm=!!sel.closest('form[action*="cart" i],form[action*="cesta" i],form[id*="product" i],[class*="add-to-cart" i]');for(const o of sel.options){const s0=norm(o.value)===want?0:score(o.textContent);if(s0===null)continue;const s1=s0+(inForm?0:0.5);if(!best||s1<best.s)best={s:s1,sel,o};}}
if(best){const {sel,o}=best;if(o.disabled||/agotad|sold out|out of stock|no disponible/i.test(o.textContent))return {ok:false,why:'agotada'};sel.value=o.value;fire(sel);sel.setAttribute('data-alice-chosen','1');return {ok:true,how:'select',label:squash(o.textContent)};}
for(const r of document.querySelectorAll('input[type=radio]')){const l=r.closest('label')||document.querySelector('label[for="'+r.id+'"]');const t=squash(l?l.innerText:r.value);if(fits(t)){if(r.disabled)return {ok:false,why:'agotada'};r.setAttribute('data-alice-chosen','1');(l||r).click();if(!r.checked){r.checked=true;fire(r);}return {ok:true,how:'radio',label:t};}}
const els=Array.from(document.querySelectorAll('button,a,li,span,div,label,option')).filter(e=>seen(e)&&e.children.length<=2&&!e.closest('nav,header,footer')&&squash(e.innerText).length<=60&&squash(e.innerText).length>0);
let hit=els.find(e=>norm(e.innerText)===want)||els.find(e=>fits(e.innerText));
if(hit){if(hit.disabled||/disabled|sold-?out|agotad|unavailable/i.test(hit.className+' '+(hit.getAttribute('aria-disabled')||'')))return {ok:false,why:'agotada'};hit.setAttribute('data-alice-chosen','1');hit.click();return {ok:true,how:'button',label:squash(hit.innerText)};}
return {ok:false,why:'no encontrada'};})(%s)"""

UNITS_JS = r"""((qty)=>{%s
const inputs=Array.from(document.querySelectorAll('input[type=number],input[name*="quant" i],input[name*="qty" i],input[id*="quant" i],input[id*="qty" i],input[class*="qty" i],input[class*="quant" i],select[name*="quant" i],select[name*="qty" i]')).filter(e=>seen(e)&&!e.closest('[class*="cart" i],[id*="cart" i],[class*="cesta" i],[class*="carrito" i]'));
const e=inputs[0];
if(e){if(e.tagName==='SELECT'){const o=Array.from(e.options).find(o=>squash(o.textContent)===String(qty)||o.value===String(qty));if(!o)return {ok:false,why:'cantidad no disponible'};e.value=o.value;fire(e);return {ok:true,how:'select'};}
 const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value');if(setter&&setter.set)setter.set.call(e,String(qty));else e.value=String(qty);fire(e);return {ok:String(e.value)===String(qty),how:'input'};}
const plus=Array.from(document.querySelectorAll('button,a,span,i,div')).filter(x=>seen(x)&&/^\+$|plus|increase|incrementar|más|more/i.test(squash(x.innerText)+' '+x.className+' '+(x.getAttribute('aria-label')||''))&&squash(x.innerText).length<=6);
if(plus.length&&qty>1){for(let i=1;i<qty;i++)plus[0].click();return {ok:true,how:'plus',unverified:true};}
return qty===1?{ok:true,how:'default'}:{ok:false,why:'sin control de cantidad'};})(%s)"""

ADD_JS = r"""(()=>{%s
const add=/añadir|anadir|agregar|adicionar|add to|cesta|carrito|basket|\bbag\b|\bcart\b|acheter|aggiungi|carrello|panier|warenkorb|in den|comprar/i;
const picks=['button[name=add]','form[action*="/cart/add"] [type=submit]','form[action*="/cart/add"] button','.single_add_to_cart_button','#product-addtocart-button','button.add-to-cart','.add-to-cart button','[data-action*="add-to-cart" i]','[data-action*="addtocart" i]','#AddToCart','button[id*="AddToCart" i]','.product-form__submit','button[class*="add-to-cart" i]','button[class*="addtocart" i]','button[class*="add_to_cart" i]','button[data-button-action="add-to-cart"]','.cart-buy-button'];
// The product's own form: the one holding the variant just chosen. Product pages carry other
// add buttons (HSN's Evowhey offer above the creatine); those are never pressed for this one.
const chosen=document.querySelector('[data-alice-chosen]');const own=chosen&&chosen.closest('form');
if(own){const b=Array.from(own.querySelectorAll('[type=submit],button')).find(e=>seen(e)&&!e.disabled&&!PAY.test(text(e)));if(b){b.click();return {ok:true,how:'variant-form',label:text(b).slice(0,40)};}}
// Magento: the page's product form names this very page in its «uenc» (the others carry a
// «%uenc%» placeholder) and holds the quantity; its button may live outside the form.
const forms=Array.from(document.querySelectorAll('form[action*="/cart/add"]'));
const mine=forms.find(f=>/\/uenc\//.test(f.action)&&!/%25uenc%25|%uenc%/.test(f.action))||forms.find(f=>f.querySelector('[name*="qty" i],[name*="quant" i]'));
if(mine&&!own){const b=Array.from(document.querySelectorAll('[type=submit],button')).find(e=>(e.form===mine||mine.contains(e))&&seen(e)&&!e.disabled&&!PAY.test(text(e)));if(b){b.click();return {ok:true,how:'page-form',label:text(b).slice(0,40)};}
 if(mine.requestSubmit){mine.requestSubmit();return {ok:true,how:'page-form-submit',label:''};}}
const ELSEWHERE='[class*="promo" i],[class*="banner" i],[class*="offer" i],[class*="recommend" i],[class*="related" i],[class*="upsell" i],[class*="cross" i],[class*="carousel" i],[class*="slider" i],[class*="recent" i],[class*="widget" i],[role=dialog]';
for(const q of picks){for(const e of document.querySelectorAll(q)){if(seen(e)&&!e.disabled&&!PAY.test(text(e))&&!e.closest(ELSEWHERE)){e.click();return {ok:true,how:'selector:'+q,label:text(e).slice(0,40)};}}}
const all=Array.from(document.querySelectorAll('button,input[type=submit],input[type=button],a[role=button],[role=button],a.btn,a.button')).filter(e=>seen(e)&&!e.disabled&&!e.closest('nav,header,footer,[class*="cart" i][class*="mini" i]'));
const strong=all.find(e=>/añadir|anadir|agregar|adicionar|add to (cart|bag|basket)|aggiungi|ajouter|in den warenkorb/i.test(text(e))&&!PAY.test(text(e)));
if(strong){strong.click();return {ok:true,how:'text:'+text(strong).slice(0,30),label:text(strong).slice(0,40)};}
const weak=all.find(e=>add.test(text(e))&&!PAY.test(text(e))&&text(e).length<40);
if(weak){weak.click();return {ok:true,how:'text:'+text(weak).slice(0,30),label:text(weak).slice(0,40)};}
return {ok:false,why:'sin botón de añadir'};})()"""

CART_LINK_JS = r"""(()=>{%s
const rx=/\/(cart|cesta|carrito|basket|bag|checkout\/cart|panier|warenkorb|carrello|shopping-?cart)(\/|$|\?|#)/i;
const links=Array.from(document.querySelectorAll('a[href]')).filter(a=>rx.test(new URL(a.href,location.href).pathname)&&!/\/checkout\/?$|\/pay/i.test(a.href)&&new URL(a.href,location.href).hostname===location.hostname);
const vis=links.find(seen)||links[0];
return vis?new URL(vis.href,location.href).href:null;})()"""

CART_LINE_JS = r"""((title,variant,scoped)=>{%s
// Still on the product page, only a cart drawer counts: the page's own description names the
// product too, with other amounts in it (HSN: «8,75 €» read as the price of a 27,98 € tub).
const CARTISH='[class*="cart" i],[id*="cart" i],[class*="cesta" i],[class*="carrito" i],[class*="basket" i],[class*="bag" i],[role=dialog]';
// An empty basket has no line, whatever «recently viewed» or offer blocks show under it with the same name.
if(/(carrito|cesta|cart|basket|bag)[^.]{0,40}(est[aá] vac[ií][oa]|is empty)|no tienes (ning[uú]n )?productos en tu (carrito|cesta)|your (cart|basket|bag) is empty/i.test(squash(document.body.innerText)))return null;
const RECO='[class*="recent" i],[class*="viewed" i],[class*="recommend" i],[class*="related" i],[class*="upsell" i],[class*="crosssell" i],[class*="cross-sell" i],[class*="suggest" i],[class*="carousel" i],[class*="slider" i]';
const blocks=Array.from(document.querySelectorAll('li,tr,article,div,section,[class*="item" i],[class*="line" i],[class*="product" i]')).filter(e=>seen(e)&&!e.closest('nav,header>*:not([class*="cart" i]),footer')&&!e.closest(RECO)&&(!scoped||e.closest(CARTISH)));
const fits=blocks.filter(e=>{const t=squash(e.innerText);return t.length>0&&t.length<1200&&names(t,title,variant||'')&&amounts(t).length>0;});
if(!fits.length)return null;
fits.sort((a,b)=>squash(a.innerText).length-squash(b.innerText).length);
const line=fits.find(e=>{const t=squash(e.innerText);return /cantidad|qty|quantity|unidades|units|×|\bx\s?\d|\d\s?x\b/i.test(t)||e.querySelector('input[type=number],select,[class*="qty" i],[class*="quant" i]');})||fits[0];
let qty=null;const qi=line.querySelector('input[type=number],input[name*="quant" i],input[name*="qty" i],select[name*="quant" i],select[name*="qty" i],[class*="qty" i] input,input[class*="qty" i]');
if(qi&&seen(qi))qty=String(qi.value).trim();
if(!qty){const t=squash(line.innerText);const m=t.match(/(?:cantidad|qty|quantity|unidades|units)\s*[:\s]\s*(\d+)/i)||t.match(/(?:×|x)\s*(\d+)\b/i)||t.match(/\b(\d+)\s*(?:×|x|uds?\b|unidades|units)/i);if(m)qty=m[1];else{const q=line.querySelector('[class*="qty" i],[class*="quant" i],[class*="count" i]');if(q&&/^\d+$/.test(squash(q.innerText)))qty=squash(q.innerText);}}
const priced=[];for(const e of line.querySelectorAll('*')){if(!seen(e)||struck(e)||e.children.length>2)continue;const t=squash(e.innerText);if(t.length>40)continue;for(const a of amounts(t))priced.push({text:a,tagged:/price|precio|amount|importe|total|subtotal/i.test(e.className+' '+e.id)});}
const prices=priced.length?priced:amounts(line.innerText).map(a=>({text:a,tagged:false}));
const uniq=[];for(const p of prices){if(!uniq.some(u=>u.text===p.text))uniq.push(p);}
return {line:squash(line.innerText).slice(0,300),qty:qty||'1',qty_how:qi?'input':(qty?'text':'assumed'),prices:uniq.map(u=>u.text),tagged:uniq.filter(u=>u.tagged).map(u=>u.text),how:'dom'};})(%s,%s,%s)"""

ORDER_TOTAL_JS = r"""(()=>{%s
const rows=[];
for(const e of document.querySelectorAll('tr,li,div,p,dl,dd,span,strong,b,td,th,h2,h3,h4')){if(!seen(e)||struck(e))continue;const t=squash(e.innerText);if(t.length<5||t.length>140)continue;
 const label=t.replace(AMOUNT,' ');if(!/\btotal\b|a pagar|to pay|grand total|order total|importe total|total pedido|total del pedido|total order|montant total|gesamt/i.test(label))continue;
 if(/sub-?total|total de art|items? total|total products|total productos|total art|descuento|discount|ahorr|saving|\biva\b|\btax|impuesto|env[ií]o|shipping|delivery|entrega|parcial|antes|estimated|estimado|ahorras|sin iva|excl/i.test(label))continue;
 const found=amounts(t);if(!found.length)continue;rows.push({text:found[found.length-1],len:t.length,bottom:e.getBoundingClientRect().bottom,label:label.slice(0,60)});}
if(!rows.length)return null;
rows.sort((a,b)=>a.len-b.len||b.bottom-a.bottom);
return {text:rows[0].text,label:rows[0].label,how:'dom'};})()"""

SEARCH_FORM_JS = r"""(()=>{%s
const inputs=Array.from(document.querySelectorAll('input[type=search],input[name=q],input[name=s],input[name=text],input[name=search],input[name=query],input[name=keyword],input[name=keywords],input[name=term],input[name=search_query],input[name=searchTerm],input[name=SearchTerm],input[name=search_term],input[name=k],input[name=w],input[name=words],input[role=searchbox],input[role=combobox],input[aria-label*="search" i],input[aria-label*="buscar" i],input[placeholder*="search" i],input[placeholder*="buscar" i],input[placeholder*="busca" i],form[role=search] input:not([type=hidden])'));
for(const i of inputs){const f=i.form||i.closest('form');if(!f)continue;const method=(f.getAttribute('method')||'get').toLowerCase();const name=i.getAttribute('name');if(method!=='get'||!name)continue;const action=f.getAttribute('action')||location.pathname;const hidden=Array.from(f.querySelectorAll('input[type=hidden]')).filter(h=>h.name&&h.name!==name).map(h=>[h.name,h.value]);return {action:new URL(action,location.href).href,name,hidden,how:'form'};}
return null;})()"""

PRODUCT_LINKS_JS = r"""(()=>{%s
const out=[];const taken=new Set();
const picks=['a[href*="/products/"]','.product a.woocommerce-LoopProduct-link','li.product a[href]','.product-item-link','a.product-item-link','.product-title a[href]','.product-name a[href]','[class*="product-card" i] a[href]','[class*="productcard" i] a[href]','[class*="product-tile" i] a[href]','[class*="product-item" i] a[href]','[class*="product" i] a[href]','[class*="producto" i] a[href]','[class*="result" i] a[href]','[class*="card" i] a[href]','a[href*="/product"]','a[href*="/producto"]','a[href*="/p/"]','a[href*="/item/"]','a[href*="/dp/"]','a[href*="/prozis/"]'];
const titleOf=(a,card)=>{let t=squash(a.getAttribute('title')||a.innerText||'');if(!t||/^[€$£\d.,\s%-]+$/.test(t)){const h=card.querySelector('h1,h2,h3,h4,[class*="title" i],[class*="name" i]');t=h?squash(h.innerText):'';}return t.split('\n').map(s=>s.trim()).filter(s=>s&&!/^[€$£\d.,\s%-]+$/.test(s)).join(' ');};
const here=location.href.split('#')[0];
for(const q of picks){for(const a of document.querySelectorAll(q)){let href;try{href=new URL(a.href,location.href);}catch(e){continue;}if(href.protocol!=='https:'||href.hostname!==location.hostname)continue;const key=href.href.split('#')[0];if(taken.has(key)||key===here)continue;
 if(a.closest('nav,header,footer,[role=navigation],[role=banner],[role=contentinfo],[class*="menu" i],[class*="minicart" i],[class*="breadcrumb" i]'))continue;
 const card=a.closest('li,article,[class*="product" i],[class*="item" i],[class*="card" i],[class*="result" i]')||a.parentElement||a;const t=squash(card.innerText);if(!amounts(t).length)continue;
 if(/\/(cart|cesta|carrito|checkout|account|login|wishlist|compare)\b/i.test(href.pathname))continue;
 const title=titleOf(a,card);if(!title||title.length<3)continue;taken.add(key);out.push({url:key,title:title.slice(0,160),how:q});if(out.length>=40)return out;}}
return out;})()"""

COUPON_JS = r"""((code)=>{%s
const inputs=Array.from(document.querySelectorAll('input')).filter(e=>seen(e)&&!/password|email|tel|number/i.test(e.type)&&/coupon|cup[oó]n|promo|discount|descuento|voucher|gift|c[oó]digo|code/i.test([e.name,e.id,e.placeholder,e.getAttribute('aria-label'),e.className].join(' ')));
const e=inputs[0];if(!e)return {ok:false,why:'sin campo de descuento observado en la cesta'};
const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value');if(setter&&setter.set)setter.set.call(e,code);else e.value=code;fire(e);
const scope=e.form||e.closest('div,section,fieldset,li,tr')||document;
const btn=Array.from(scope.querySelectorAll('button,input[type=submit],input[type=button],a[role=button],[role=button]')).find(b=>seen(b)&&/apply|aplicar|validar|canjear|redeem|activar|añadir|add|ok|→|>/i.test(text(b))&&!PAY.test(text(b)));
if(btn)btn.click();else if(e.form)e.form.requestSubmit?e.form.requestSubmit():e.form.submit();else e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
return {ok:true,how:btn?'button':'submit'};})(%s)"""

SHOPIFY_PRODUCT_JS = r"""(async()=>{const root=(window.Shopify&&Shopify.routes&&Shopify.routes.root)||'/';const r=await fetch(root+'products/'+%s+'.js',{headers:{Accept:'application/json'},credentials:'same-origin'});if(!r.ok)return {error:r.status};return await r.json();})()"""
SHOPIFY_ADD_JS = r"""(async()=>{const root=(window.Shopify&&Shopify.routes&&Shopify.routes.root)||'/';const r=await fetch(root+'cart/add.js',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify({items:[{id:%d,quantity:%d}]})});const body=await r.text();if(!r.ok)return {error:r.status,text:body.slice(0,300)};try{return JSON.parse(body);}catch(e){return {error:'json'};}})()"""
SHOPIFY_CART_JS = r"""(async()=>{const root=(window.Shopify&&Shopify.routes&&Shopify.routes.root)||'/';const r=await fetch(root+'cart.js',{headers:{Accept:'application/json'},credentials:'same-origin'});if(!r.ok)return {error:r.status};return await r.json();})()"""
SHOPIFY_SUGGEST_JS = r"""(async()=>{const root=(window.Shopify&&Shopify.routes&&Shopify.routes.root)||'/';const r=await fetch(root+'search/suggest.json?q='+encodeURIComponent(%s)+'&resources[type]=product&resources[limit]=10&resources[options][unavailable_products]=hide',{headers:{Accept:'application/json'},credentials:'same-origin'});if(!r.ok)return {error:r.status};return await r.json();})()"""

WOO_PRODUCTS_JS = r"""(async()=>{const r=await fetch('/wp-json/wc/store/v1/products?'+%s,{headers:{Accept:'application/json'},credentials:'same-origin'});if(!r.ok)return {error:r.status};return await r.json();})()"""
WOO_ADD_JS = r"""(async()=>{const c=await fetch('/wp-json/wc/store/v1/cart',{credentials:'same-origin'});const nonce=c.headers.get('Nonce')||c.headers.get('X-WC-Store-API-Nonce')||'';const r=await fetch('/wp-json/wc/store/v1/cart/add-item',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json',Accept:'application/json','Nonce':nonce},body:JSON.stringify({id:%d,quantity:%d})});const body=await r.text();if(!r.ok)return {error:r.status,text:body.slice(0,300)};try{return JSON.parse(body);}catch(e){return {error:'json'};}})()"""
WOO_CART_JS = r"""(async()=>{const r=await fetch('/wp-json/wc/store/v1/cart',{headers:{Accept:'application/json'},credentials:'same-origin'});if(!r.ok)return {error:r.status};return await r.json();})()"""


def js(template: str, *args: Any) -> str:
    """A snippet with the shared helpers and its JSON-encoded arguments."""
    values = [HELPERS] + [str(a) if isinstance(a, int) and not isinstance(a, bool) else json.dumps(a) for a in args]
    pieces = template.split("%s")
    if len(pieces) != len(values) + 1:
        raise ValueError("snippet placeholders do not match its arguments")
    # Only «%s» is a placeholder: a «%» in a regular expression stays as written.
    return "".join(piece + (values[i] if i < len(values) else "") for i, piece in enumerate(pieces))


# ── The page ─────────────────────────────────────────────────────────────────────


class Page:
    """What the engine needs of a browser: run JavaScript in the page and, when allowed, open
    another address. Wraps a Probe (chat) or the errand's own tab (``evaluate`` bound to its
    context). ``goto`` is None where navigation is not this code's to do (the errand's page)."""

    def __init__(self, evaluate: Callable[[str], Any], goto: Optional[Callable[[str], None]] = None,
                 url: Optional[Callable[[], str]] = None, sleep: Callable[[float], None] = time.sleep):
        self.evaluate = evaluate
        self._goto = goto
        self._url = url
        self.sleep = sleep

    @classmethod
    def of(cls, browser) -> "Page":
        return cls(browser.evaluate, getattr(browser, "goto", None), lambda: browser.evaluate("location.href"),
                   getattr(browser, "sleep", time.sleep))

    def goto(self, url: str) -> None:
        if self._goto is None:
            raise ValueError("Esta página no se puede navegar desde aquí.")
        self._goto(url)

    @property
    def url(self) -> str:
        try:
            return str((self._url or (lambda: self.evaluate("location.href")))() or "")
        except Exception:  # noqa: BLE001
            return ""

    def run(self, template: str, *args: Any) -> Any:
        return self.evaluate(js(template, *args))

    def settle(self, seconds: float = 0.6) -> None:
        self.sleep(seconds)


# ── Tiers ────────────────────────────────────────────────────────────────────────


def detect(page: Page, url: str = "") -> Dict[str, Any]:
    """Which platform the page runs on: Prozis by its adapter, the rest by what the page says."""
    url = url or page.url
    if module("purchase_prozis").supports(url):
        return {"platform": "prozis", "how": "adapter"}
    try:
        found = page.run(DETECT_JS) or {}
    except Exception:  # noqa: BLE001
        found = {}
    platform = str(found.get("platform") or "generic")
    return {"platform": platform if platform in PLATFORMS else "generic", "how": str(found.get("how") or ""),
            "root": str(found.get("root") or "/")}


def dismiss_cookies(page: Page) -> bool:
    try:
        out = page.run(COOKIES_JS) or {}
    except Exception:  # noqa: BLE001
        return False
    if out.get("ok"):
        page.settle(0.3)
    return bool(out.get("ok"))


def _cents(value: Any, currency: str) -> Optional[tuple]:
    money = module("money")
    text = str(value if value is not None else "").strip()
    if not text:
        return None
    if re.fullmatch(r"\d+(\.\d+)?", text) and currency:
        # A bare number from structured data: decimal, in the offer's currency.
        try:
            return (int(round(float(text) * 100)), currency.upper())
        except ValueError:
            return None
    return money.parse(text, currency)


def product(page: Page, currency: str = "") -> Optional[Dict[str, Any]]:
    """The product on this page: name, price, currency, stock, picture, variants; ``how`` says
    which tier read it (jsonld, microdata, og, dom)."""
    try:
        found = page.run(PRODUCT_JS)
    except Exception:  # noqa: BLE001
        found = None
    if not found:
        return None
    money = _cents(found.get("price"), str(found.get("currency") or currency or ""))
    out = {"name": str(found.get("name") or "").strip()[:160], "how": str(found.get("how") or ""),
           "available": found.get("available"), "image": str(found.get("image") or ""), "sku": str(found.get("sku") or ""),
           "currency": (money[1] if money else str(found.get("currency") or currency or "").upper()),
           "price_cents": money[0] if money else None,
           "price": module("money").text(*money) if money else str(found.get("price") or "")}
    out["variants"] = [{**v, "price_cents": (_cents(v.get("price"), v.get("currency") or out["currency"]) or (None,))[0]}
                       for v in found.get("variants") or [] if isinstance(v, dict)]
    return out


def selected_variant(page: Page) -> str:
    try:
        return str(page.run(SELECTED_VARIANT_JS) or "").strip()[:120]
    except Exception:  # noqa: BLE001
        return ""


def select_variant(page: Page, label: str) -> Dict[str, Any]:
    """Picks the variant the person chose, by its words, among selects, radios and chips."""
    if not str(label or "").strip():
        return {"ok": True, "how": "none"}
    try:
        out = page.run(VARIANT_JS, str(label)) or {}
    except Exception:  # noqa: BLE001
        out = {"ok": False, "why": "no se pudo leer la ficha"}
    if out.get("ok"):
        page.settle(0.5)
    return out


def set_units(page: Page, qty: int) -> Dict[str, Any]:
    try:
        return page.run(UNITS_JS, int(qty)) or {"ok": False}
    except Exception:  # noqa: BLE001
        return {"ok": False, "why": "no se pudo leer la ficha"}


def add_to_cart(page: Page) -> Dict[str, Any]:
    try:
        out = page.run(ADD_JS) or {"ok": False}
    except Exception:  # noqa: BLE001
        out = {"ok": False, "why": "no se pudo leer la ficha"}
    if out.get("ok"):
        page.settle(1.2)
    return out


def cart_link(page: Page) -> str:
    try:
        return str(page.run(CART_LINK_JS) or "")
    except Exception:  # noqa: BLE001
        return ""


def cart_line(page: Page, title: str, variant: str = "", scoped: bool = False) -> Optional[Dict[str, Any]]:
    """The cart's line for this product on the page as it is (a drawer or the cart page).
    ``scoped``: still on the product page, so only a block inside a cart drawer counts."""
    try:
        found = page.run(CART_LINE_JS, str(title or ""), str(variant or ""), bool(scoped))
    except Exception:  # noqa: BLE001
        return None
    if not found and variant:
        # Carts spell variants their own way («Neutro» vs «Sin sabor»): the title alone names the line.
        try:
            found = page.run(CART_LINE_JS, str(title or ""), "", bool(scoped))
        except Exception:  # noqa: BLE001
            return None
    return found or None


def unit_price(line: Dict[str, Any], currency: str, qty: int, expected_cents: Optional[int] = None) -> Optional[tuple]:
    """The unit price among a cart line's amounts: the one that is the expected price, or the
    expected line total, else the smallest tagged amount (the line total divided by units when it
    divides evenly)."""
    money = module("money")
    parsed = []
    for text in (line.get("tagged") or []) + (line.get("prices") or []):
        amount = money.parse(text, currency)
        if amount and amount[0] > 0 and amount not in parsed:
            parsed.append(amount)
    if not parsed:
        return None
    qty = max(1, int(qty or 1))
    if expected_cents is not None:
        for amount in parsed:
            if amount[0] == expected_cents or amount[0] == expected_cents * qty:
                return (expected_cents, amount[1])
    if len(parsed) == 1 and qty > 1 and str(line.get("qty_how") or "") != "assumed":
        # One amount for several units: a line total, unless it is the unit price shown alone.
        # Which one is unknowable here; the caller's expected price decides above, and without one
        # the smaller reading is the safe one (a higher real price is caught by the checkout total).
        only = parsed[0]
        return (only[0] // qty, only[1]) if only[0] % qty == 0 else only
    return min(parsed, key=lambda a: a[0])


def order_total(page: Page) -> Optional[Dict[str, Any]]:
    try:
        return page.run(ORDER_TOTAL_JS) or None
    except Exception:  # noqa: BLE001
        return None


def apply_coupon(page: Page, code: str) -> Dict[str, Any]:
    try:
        out = page.run(COUPON_JS, str(code)) or {"ok": False}
    except Exception:  # noqa: BLE001
        out = {"ok": False, "why": "no se pudo leer la cesta"}
    if out.get("ok"):
        page.settle(1.5)
    return out


# ── Platform endpoints (tier 1) ──────────────────────────────────────────────────


def shopify_handle(url: str) -> str:
    path = urlsplit(url).path
    if "/products/" not in path:
        return ""
    return path.split("/products/", 1)[1].split("/", 1)[0].split("?", 1)[0]


def shopify_product(page: Page, url: str) -> Optional[Dict[str, Any]]:
    handle = shopify_handle(url)
    if not handle:
        return None
    try:
        data = page.evaluate(SHOPIFY_PRODUCT_JS % json.dumps(handle))
    except Exception:  # noqa: BLE001
        return None
    if not isinstance(data, dict) or data.get("error") or not data.get("variants"):
        return None
    return data


def shopify_variant(data: Dict[str, Any], label: str) -> Optional[Dict[str, Any]]:
    """The variant whose title says ``label`` (any order of words); with no label, the first
    available one (the page's default)."""
    variants = [v for v in data.get("variants") or [] if isinstance(v, dict)]
    if not variants:
        return None
    if not str(label or "").strip():
        return next((v for v in variants if v.get("available")), variants[0])
    prozis_norm = module("purchase_prices")._norm
    want = prozis_norm(label)
    for v in variants:
        title = prozis_norm(v.get("title") or " / ".join(str(x) for x in (v.get("options") or [])))
        if title == want or module("purchase_prices").names(title, want):
            return v
    return None


def shopify_add(page: Page, variant_id: int, qty: int) -> Dict[str, Any]:
    try:
        out = page.evaluate(SHOPIFY_ADD_JS % (int(variant_id), int(qty)))
    except Exception:  # noqa: BLE001
        return {"error": "fetch"}
    return out if isinstance(out, dict) else {"error": "shape"}


def shopify_cart(page: Page) -> Optional[Dict[str, Any]]:
    try:
        out = page.evaluate(SHOPIFY_CART_JS)
    except Exception:  # noqa: BLE001
        return None
    return out if isinstance(out, dict) and not out.get("error") else None


def shopify_search(page: Page, query: str) -> List[Dict[str, str]]:
    try:
        out = page.evaluate(SHOPIFY_SUGGEST_JS % json.dumps(str(query)))
    except Exception:  # noqa: BLE001
        return []
    products = ((((out or {}).get("resources") or {}).get("results") or {}).get("products") or []) if isinstance(out, dict) else []
    base = page.url
    rows = []
    for p in products:
        if not isinstance(p, dict) or not p.get("url") or not p.get("title"):
            continue
        parts = urlsplit(base)
        url = str(p["url"]) if str(p["url"]).startswith("https://") else urlunsplit((parts.scheme, parts.netloc, str(p["url"]), "", ""))
        rows.append({"url": url.split("#")[0], "title": str(p["title"])[:160], "how": "shopify-suggest"})
    return rows


def woo_products(page: Page, **params: Any) -> List[Dict[str, Any]]:
    try:
        out = page.evaluate(WOO_PRODUCTS_JS % json.dumps(urlencode({k: v for k, v in params.items() if v is not None})))
    except Exception:  # noqa: BLE001
        return []
    return [p for p in out if isinstance(p, dict)] if isinstance(out, list) else []


def woo_price(entry: Dict[str, Any]) -> Optional[tuple]:
    prices = entry.get("prices") or {}
    try:
        minor = int(prices.get("currency_minor_unit", 2))
        raw = int(str(prices.get("price") or ""))
    except (TypeError, ValueError):
        return None
    cents = raw if minor == 2 else int(round(raw * (100 / (10 ** minor))))
    return (cents, str(prices.get("currency_code") or "").upper())


def woo_add(page: Page, product_id: int, qty: int) -> Dict[str, Any]:
    try:
        out = page.evaluate(WOO_ADD_JS % (int(product_id), int(qty)))
    except Exception:  # noqa: BLE001
        return {"error": "fetch"}
    return out if isinstance(out, dict) else {"error": "shape"}


def woo_cart(page: Page) -> Optional[Dict[str, Any]]:
    try:
        out = page.evaluate(WOO_CART_JS)
    except Exception:  # noqa: BLE001
        return None
    return out if isinstance(out, dict) and not out.get("error") else None


# ── Search ───────────────────────────────────────────────────────────────────────

SEARCH_PATTERNS = ("/search?q={q}", "/search?text={q}", "/buscar?q={q}", "/catalogsearch/result/?q={q}",
                   "/search?controller=search&s={q}", "/?s={q}&post_type=product", "/?s={q}", "/busqueda?q={q}",
                   "/search/?q={q}", "/search?query={q}", "/search?keywords={q}")


def shop_home(shop: str) -> str:
    """``https://<shop>/`` from a domain or any address on it."""
    text = str(shop or "").strip()
    parts = urlsplit(text if "//" in text else "https://" + text)
    if parts.scheme != "https" or not parts.hostname:
        raise ValueError("Di la tienda como dominio o dirección https.")
    if "." not in parts.hostname:
        # «HSN» is a name, not an address: said plainly, not «la dirección no es segura».
        raise ValueError("«" + text + "» es el nombre de la tienda: pásala como dominio (p. ej. hsnstore.com).")
    return urlunsplit(("https", parts.netloc, "/", "", ""))


def search(page: Page, shop: str, query: str, platform: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Product pages for ``query`` on ``shop``: the platform's suggest endpoint, else the shop's
    own search form, else the usual search addresses, read for product links each time."""
    home = shop_home(shop)
    query = " ".join(str(query or "").split())[:120]
    if not query:
        raise ValueError("Di qué buscar en la tienda.")
    page.goto(home)
    dismiss_cookies(page)
    platform = platform or detect(page, home)
    tried: List[str] = []
    if platform["platform"] == "prozis":
        prozis = module("purchase_prozis")
        url = "https://www.prozis.com/es/es/search?text=" + url_quote(query)
        page.goto(url)
        rows = product_links(page)
        return {"url": url, "links": rows, "how": "prozis-search", "platform": platform}
    if platform["platform"] == "shopify":
        rows = shopify_search(page, query)
        if rows:
            return {"url": home, "links": rows, "how": "shopify-suggest", "platform": platform}
        tried.append("shopify-suggest")
    if platform["platform"] == "woocommerce":
        rows = []
        for p in woo_products(page, search=query, per_page=12):
            if p.get("permalink") and p.get("name"):
                rows.append({"url": str(p["permalink"]).split("#")[0], "title": str(p["name"])[:160], "how": "woo-store-api",
                             "available": bool(p.get("is_in_stock", True))})
        if rows:
            return {"url": home, "links": rows, "how": "woo-store-api", "platform": platform}
        tried.append("woo-store-api")
    form = None
    try:
        form = page.run(SEARCH_FORM_JS)
    except Exception:  # noqa: BLE001
        form = None
    candidates: List[str] = []
    if form and form.get("action") and form.get("name"):
        params = [(str(form["name"]), query)] + [(str(k), str(v)) for k, v in (form.get("hidden") or []) if k]
        action = str(form["action"])
        joiner = "&" if "?" in action else "?"
        candidates.append(action + joiner + urlencode(params))
    parts = urlsplit(home)
    for pattern in SEARCH_PATTERNS:
        candidates.append(urlunsplit((parts.scheme, parts.netloc, "", "", "")) + pattern.format(q=url_quote(query)))
    for url in candidates[:6]:
        if not module("purchase_prices").same_site(url, home):
            continue
        try:
            page.goto(url)
        except Exception:  # noqa: BLE001
            tried.append(url)
            continue
        rows = product_links(page)
        if rows:
            return {"url": url, "links": rows, "how": "form" if url == candidates[0] and form else "pattern",
                    "platform": platform}
        tried.append(url)
    # The shop's own search found nothing (HSN's answers every query «minimum length 128»): its
    # product pages, as a web search restricted to the shop lists them.
    rows = web_search_links(page, home, query)
    if rows:
        return {"url": home, "links": rows, "how": "web-search", "platform": platform}
    tried.append("web-search")
    raise ValueError("No se encontró el buscador de la tienda ni resultados con productos para «" + query + "».")


WEB_RESULTS_JS = r"""((host)=>{%s
const out=[];const got=new Set();
for(const a of document.querySelectorAll('a.result__a,a[data-testid="result-title-a"],h2 a[href]')){let url=a.href;try{const u=new URL(url);const real=u.searchParams.get('uddg');if(real)url=real;}catch(e){continue;}
 let h;try{h=new URL(url);}catch(e){continue;}if(h.protocol!=='https:'||h.hostname.replace(/^www\./,'')!==host)continue;
 const key=h.href.split('#')[0];if(got.has(key))continue;got.add(key);out.push({url:key,title:(a.innerText||'').trim().slice(0,160),how:'web-search'});if(out.length>=12)break;}
return out;})(%s)"""


def web_search_links(page: Page, home: str, query: str) -> List[Dict[str, str]]:
    """Pages of the shop a web search finds for ``query``: product pages, not its listings."""
    host = urlsplit(home).hostname or ""
    host = host[4:] if host.startswith("www.") else host
    if not host:
        return []
    try:
        page.goto("https://html.duckduckgo.com/html/?q=" + url_quote(f"site:{host} {query}"))
        rows = page.run(WEB_RESULTS_JS, host) or []
    except Exception:  # noqa: BLE001
        return []
    listing = re.compile(r"/(catalogsearch|search|buscar|busqueda|categor|marcas/?$|blog|ingredientes)\b", re.I)
    return [r for r in rows if isinstance(r, dict) and r.get("url") and r.get("title")
            and not listing.search(urlsplit(r["url"]).path)]


def product_links(page: Page) -> List[Dict[str, str]]:
    try:
        rows = page.run(PRODUCT_LINKS_JS) or []
    except Exception:  # noqa: BLE001
        rows = []
    return [r for r in rows if isinstance(r, dict) and r.get("url") and r.get("title")]


# ── A quote: the product in a disposable basket ──────────────────────────────────


def quote(page: Page, url: str, *, variant: str = "", qty: int = 1, currency: str = "",
          coupons: Optional[List[str]] = None, title_hint: str = "") -> Dict[str, Any]:
    out = _quote(page, url, variant=variant, qty=qty, currency=currency, coupons=coupons, title_hint=title_hint)
    blocks = out.pop('_promotion_blocks', [])
    out.update(module('purchase_promotions').fields(blocks, coupons or [], out.get('price_cents'),
               out.get('currency'), applied=bool(out.get('coupon')) or any(r.get('applied') for r in out.get('coupon_results', []))))
    return out


def _quote(page: Page, url: str, *, variant: str = "", qty: int = 1, currency: str = "",
          coupons: Optional[List[str]] = None, title_hint: str = "") -> Dict[str, Any]:
    """Opens the product page, picks the variant, adds ``qty`` to the basket and reads the basket
    line. Returns what was read and how; ``basis`` is ``cart`` when the basket confirmed the price,
    ``page`` when only the product page could be read (the errand confirms it in its own basket)."""
    page.goto(url)
    dismiss_cookies(page)
    platform = detect(page, url)
    info = product(page, currency) or {}
    title = info.get("name") or title_hint
    if not title:
        raise ValueError("La página no nombra ningún producto.")
    if info.get("available") is False:
        raise ValueError("La ficha dice que no está disponible: " + title)
    out: Dict[str, Any] = {"title": title[:160], "platform": platform["platform"], "image": info.get("image") or "",
                           "page_price_cents": info.get("price_cents"), "currency": info.get("currency") or currency.upper(),
                           "how": {"product": info.get("how") or ""}, "variant": "", "coupon_results": [],
                           "qty": int(qty), "basis": "page", "unverified": ""}
    promotions = module('purchase_promotions')
    out['_promotion_blocks'] = promotions.product_coupon_blocks(page)
    codes = promotions.public_codes(out['_promotion_blocks'], coupons or [])
    # Tier 1: the platform's own basket.
    if platform["platform"] == "shopify":
        data = shopify_product(page, url)
        chosen = shopify_variant(data, variant) if data else None
        if data and chosen is None and variant:
            raise ValueError("Esa variante no existe en la ficha: " + variant)
        if chosen is not None:
            if not chosen.get("available", True):
                raise ValueError("Esa variante está agotada: " + str(chosen.get("title") or variant))
            out["catalog_id"] = "gid://shopify/ProductVariant/" + str(int(chosen["id"]))
            added = shopify_add(page, int(chosen["id"]), qty)
            cart = shopify_cart(page) if not added.get("error") else None
            item = next((i for i in (cart or {}).get("items") or [] if int(i.get("variant_id") or 0) == int(chosen["id"])), None)
            if item and int(item.get("quantity") or 0) == int(qty):
                money_code = str((cart or {}).get("currency") or out["currency"] or "").upper()
                cents = int(item.get("final_price") if item.get("final_price") is not None else item.get("price") or 0)
                out.update({"variant": str(chosen.get("title") or "")[:120] if len(data["variants"]) > 1 else "",
                            "price_cents": cents, "currency": money_code, "basis": "cart",
                            "line": str(item.get("product_title") or item.get("title") or "")[:200]})
                out["how"].update({"variant": "shopify", "add": "shopify-cart-add", "cart": "shopify-cart-js"})
                if codes:
                    out["coupon_results"] = [{"code": c, "applied": False, "price": module("money").text(cents, money_code),
                                              "why": "los descuentos de esta tienda se aplican en el checkout"} for c in codes]
                return out
            out["unverified"] = "la cesta de la tienda no confirmó el artículo (" + str(added.get("error") or "sin línea") + ")"
    elif platform["platform"] == "woocommerce":
        slug = urlsplit(url).path.rstrip("/").rsplit("/", 1)[-1]
        found = woo_products(page, slug=slug) if slug else []
        entry = found[0] if found else None
        if entry:
            target = entry
            if variant and str(entry.get("type") or "") == "variable":
                prices_mod = module("purchase_prices")
                want = prices_mod._norm(variant)
                for v in woo_products(page, type="variation", parent=entry.get("id"), per_page=50):
                    label = " ".join(str(a.get("value") or "") for a in v.get("attributes") or [] if isinstance(a, dict))
                    if prices_mod._norm(label) == want or prices_mod.names(label, variant):
                        target = v
                        break
                else:
                    raise ValueError("Esa variante no existe en la ficha: " + variant)
            if target.get("is_in_stock") is False:
                raise ValueError("Esa variante está agotada: " + str(target.get("name") or title))
            added = woo_add(page, int(target["id"]), qty)
            cart = woo_cart(page) if not added.get("error") else None
            item = next((i for i in (cart or {}).get("items") or [] if int(i.get("id") or 0) == int(target["id"])), None)
            if item and int(item.get("quantity") or 0) == int(qty):
                amount = woo_price(item)
                if amount:
                    out.update({"variant": variant[:120] if variant else "", "price_cents": amount[0], "currency": amount[1],
                                "basis": "cart", "line": str(item.get("name") or "")[:200]})
                    out["how"].update({"variant": "woo", "add": "woo-store-api", "cart": "woo-store-api"})
                    if codes:
                        out["coupon_results"] = [{"code": c, "applied": False, "price": module("money").text(*amount),
                                                  "why": "los cupones de esta tienda se aplican en la cesta o el checkout"} for c in codes]
                    return out
            out["unverified"] = "la Store API no confirmó el artículo (" + str(added.get("error") or "sin línea") + ")"
    # Tiers 2 and 3: the page itself.
    picked = select_variant(page, variant)
    if variant and not picked.get("ok"):
        if picked.get("why") == "agotada":
            raise ValueError("Esa variante está agotada: " + variant)
        raise ValueError("Esa variante no se encontró en la ficha: " + variant + " (" + str(picked.get("why") or "") + ")")
    out["how"]["variant"] = picked.get("how", "none")
    if variant:
        # The price belongs to the variant now selected: read the page again.
        info_after = product(page, currency) or {}
        prices_mod = module("purchase_prices")
        named = next((v for v in info_after.get("variants") or []
                      if v.get("price_cents") is not None and v.get("label")
                      and (prices_mod._norm(v["label"]) == prices_mod._norm(variant) or prices_mod.names(v["label"], variant))), None)
        if named is not None:
            # Structured data lists each variant's own offer: the chosen one's price, not the first.
            if named.get("available") is False:
                raise ValueError("Esa variante está agotada: " + variant)
            out["page_price_cents"] = named["price_cents"]
            out["how"]["product"] = (info_after.get("how") or "") + ":variant"
        elif info_after.get("price_cents") is not None:
            out["page_price_cents"], out["currency"] = info_after["price_cents"], info_after.get("currency") or out["currency"]
        out["variant"] = str(picked.get("label") or variant)[:120]
    else:
        out["variant"] = selected_variant(page)
    out['_promotion_blocks'] = promotions.product_coupon_blocks(page)
    codes = promotions.public_codes(out['_promotion_blocks'], coupons or [])
    out['_promotion_blocks'] = promotions.product_coupon_blocks(page)
    codes = promotions.public_codes(out['_promotion_blocks'], coupons or [])
    units = set_units(page, qty) if qty != 1 else {"ok": True, "how": "default"}
    out["how"]["units"] = units.get("how", "")
    if qty != 1 and not units.get("ok"):
        out["unverified"] = out["unverified"] or "sin control de cantidad en la ficha"
        return _page_basis(out)
    added = add_to_cart(page)
    out["how"]["add"] = added.get("how", "")
    if not added.get("ok"):
        out["unverified"] = out["unverified"] or "sin botón de añadir a la cesta reconocible"
        return _page_basis(out)
    before = page.url
    # The cart page first: after «añadir» shops open drawers full of other products (HSN's offers a
    # whey and a protein pack, each «500g»), and the cart page lists only what is in the basket.
    line = None
    link = cart_link(page)
    if link and module("purchase_prices").same_site(link, url):
        try:
            page.goto(link)
            line = cart_line(page, title, out["variant"])
        except Exception:  # noqa: BLE001
            line = None
    if line is None and page.url == before:
        line = cart_line(page, title, out["variant"], scoped=True)
    if line is None:
        out["unverified"] = out["unverified"] or "la cesta no muestra una línea con ese producto"
        return _page_basis(out)
    amount = unit_price(line, out["currency"], qty, out.get("page_price_cents"))
    if amount is None:
        out["unverified"] = out["unverified"] or "la línea de la cesta no muestra un importe legible"
        return _page_basis(out)
    out["how"]["cart"] = "dom" + ("" if page.url == before else ":cart-page")
    out.update({"price_cents": amount[0], "currency": amount[1], "basis": "cart", "line": str(line.get("line") or "")[:300],
                "cart_qty": str(line.get("qty") or "1")})
    if str(line.get("qty") or "1") != str(qty):
        out["unverified"] = "la cesta muestra " + str(line.get("qty")) + " unidades, no " + str(qty)
        out["basis"] = "page"
        out["price_cents"] = out.get("page_price_cents")
        return _page_basis(out)
    if codes:
        out["coupon_results"] = _coupons(page, codes, title, out["variant"], qty, out)
    return out


def _page_basis(out: Dict[str, Any]) -> Dict[str, Any]:
    if out.get("page_price_cents") is None:
        raise ValueError("No se pudo leer el precio de la ficha ni de la cesta: " + str(out.get("unverified") or ""))
    out["price_cents"] = out["page_price_cents"]
    out["basis"] = "page"
    return out


def _coupons(page: Page, codes: List[str], title: str, variant: str, qty: int, out: Dict[str, Any]) -> List[Dict[str, Any]]:
    money = module("money")
    results = []
    base = int(out["price_cents"])
    best = base
    for code in codes:
        applied = apply_coupon(page, code)
        if not applied.get("ok"):
            results.append({"code": code, "applied": False, "price": money.text(base, out["currency"]),
                            "why": applied.get("why") or "sin campo de descuento observado en la cesta"})
            continue
        line = cart_line(page, title, variant)
        amount = unit_price(line, out["currency"], qty) if line else None
        now = amount[0] if amount else base
        results.append({"code": code, "applied": now < base, "price": money.text(now, out["currency"])})
        best = min(best, now)
    if best < base:
        out["price_cents"] = best
        out["coupon"] = next(r["code"] for r in results if r["applied"] and money.parse(r["price"], out["currency"])[0] == best)
    return results


# ── The errand's own basket and checkout ─────────────────────────────────────────


def errand_cart(evaluate: Callable[[str], Any], title: str, variant: str, qty: int, currency: str,
                expected_cents: Optional[int]) -> Dict[str, Any]:
    """The errand's basket as its page shows it now: the line naming the product, its units and
    unit price. Says where the cart is when this page has no such line."""
    page = Page(evaluate)
    line = cart_line(page, title, variant)
    if line is None:
        link = cart_link(page)
        raise ValueError("La cesta no muestra una línea con «" + title + "» en esta página"
                         + (": abre la cesta (" + link + ") y vuelve a llamar." if link else ". Abre la cesta y vuelve a llamar."))
    amount = unit_price(line, currency, qty, expected_cents)
    if amount is None:
        raise ValueError("La línea de la cesta no muestra un importe legible: " + str(line.get("line") or "")[:200])
    money = module("money")
    seen = [money.parse(t, currency) for t in (line.get("prices") or [])]
    if str(line.get("qty_how")) == "assumed" and int(qty) > 1 and not any(
            a and a[0] == amount[0] * int(qty) for a in seen):
        # The basket shows no units: several of them are only believed when the line's own total
        # is there to prove them.
        raise ValueError("La cesta no muestra cuántas unidades lleva «" + title + "». Abre la cesta completa y vuelve a llamar.")
    return {"line": line.get("line") or "", "qty": str(line.get("qty") or "1") if line.get("qty_how") != "assumed" else str(qty),
            "qty_how": line.get("qty_how"), "price_cents": amount[0], "currency": amount[1], "how": "dom"}


def errand_total(evaluate: Callable[[str], Any]) -> Optional[Dict[str, Any]]:
    return order_total(Page(evaluate))
