// Alice host adapter for OpenIntelligentUI. Runs ONLY in the controlled main frame.
function mountInteractiveArtifact(artifact, theme, token, darkMode) {
  const frame = document.getElementById('widget');
  const safeJSON = value => JSON.stringify(value).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  const innerBridge = `
    const artifact = ${safeJSON(artifact)};
    const token = ${safeJSON(token)};
    function report(type, value) { parent.postMessage({token, type, value}, '*'); }
    window.Websandbox = {connection:{remote:{sendPrompt: async function(request) {
      if (!request || typeof request.text !== 'string' || !request.text.trim() || request.text.length > 4000) throw Error('Invalid draft');
      report('draft', request.text); return {status:'awaiting_native_review'};
    }}}};
    // Disable network APIs not governed consistently by CSP (notably WebRTC).
    for (const name of ['RTCPeerConnection','webkitRTCPeerConnection','WebSocket','EventSource','Worker','SharedWorker','BroadcastChannel']) {
      try {Object.defineProperty(window,name,{value:undefined,writable:false,configurable:false});} catch(_) {}
    }
    const content = document.getElementById('content');
    const baseTheme = ${safeJSON(theme)};
    const css = document.createElement('style'); document.head.append(css);
    function setTheme(dark) {
      document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
      css.textContent = baseTheme.replaceAll('@media (prefers-color-scheme: dark)', dark ? '@media all' : '@media not all') + '\\n' + artifact.css;
    }
    setTheme(${darkMode === true});
    window.addEventListener('message', event => {
      if (event.source === parent && event.data?.token === token && event.data.type === 'theme' && typeof event.data.value === 'boolean') setTheme(event.data.value);
    });
    content.innerHTML = artifact.html;
    function resize(){report('height', Math.max(180, Math.min(900, document.documentElement.scrollHeight)));}
    let resizePending = false;
    new ResizeObserver(() => { if (!resizePending) { resizePending=true; requestAnimationFrame(()=>{resizePending=false; resize();}); }}).observe(content);
    document.addEventListener('click', e => {if(e.target.closest('a'))e.preventDefault();}, true);
    window.addEventListener('error', () => report('error', 'No se pudo iniciar la parte interactiva. Puedes leer el resumen.'));
    window.addEventListener('unhandledrejection', () => report('error', 'No se pudo completar la interacción.'));
    try {
      const functions=document.createElement('script');functions.textContent=artifact.jsFunctions;document.body.append(functions);
      const expressions=document.createElement('script');expressions.textContent=artifact.jsExpressions;document.body.append(expressions);
    } catch(error) {report('error','No se pudo iniciar la interacción.');}
    resize();report('ready',true);
  `;
  const policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
  // Code/data are set with DOM APIs; none is interpolated as executable HTML.
  const doc = document.implementation.createHTMLDocument('');
  const meta=doc.createElement('meta');meta.httpEquiv='Content-Security-Policy';meta.content=policy;doc.head.append(meta);
  const viewport=doc.createElement('meta');viewport.name='viewport';viewport.content='width=device-width, initial-scale=1';doc.head.append(viewport);
  const content=doc.createElement('div');content.id='content';doc.body.append(content);
  const script=doc.createElement('script');script.textContent=innerBridge;doc.body.append(script);
  window.addEventListener('message', event => {
    if(event.source!==frame.contentWindow || event.origin!=='null' || !event.data || event.data.token!==token)return;
    const {type,value}=event.data;
    if(type==='height' && (typeof value!=='number' || !Number.isFinite(value)))return;
    if(type==='draft' && (typeof value!=='string' || !value.trim() || value.length>4000))return;
    if(!['height','draft','error','ready'].includes(type))return;
    if(type==='height')frame.style.height=Math.max(180,Math.min(900,value))+'px';
    window.webkit?.messageHandlers?.interactiveUI?.postMessage({type,value});
  });
  frame.srcdoc='<!DOCTYPE html>'+doc.documentElement.outerHTML;
  window.setInteractiveColorScheme = dark => {
    if (typeof dark === 'boolean') frame.contentWindow.postMessage({token,type:'theme',value:dark}, '*');
  };
}
