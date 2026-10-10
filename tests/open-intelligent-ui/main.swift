import Cocoa
import WebKit

final class Probe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView!
    var finished = false
    var failed = false
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let data=m.body as? [String:Any], data["type"] as? String == "ready", m.frameInfo.isMainFrame {
            web.evaluateJavaScript("window.setInteractiveColorScheme(false)", completionHandler:nil)
        }
        guard m.frameInfo.isMainFrame, let data=m.body as? [String:Any], data["type"] as? String == "draft", let value=data["value"] as? String,
              let bytes=value.data(using:.utf8), let results=try? JSONSerialization.jsonObject(with:bytes) as? [String:Bool] else{return}
        print("WK sandbox:", results)
        failed = !["parentBlocked","storageBlocked","cookieBlocked","networkBlocked","rtcBlocked","ran","darkTheme","liveLightTheme","controlsPreserved"].allSatisfy {results[$0] == true}
        finished=true
    }
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy)->Void) {
        decisionHandler(a.request.url?.scheme=="about" && a.navigationType == .other ? .allow : .cancel)
    }
}
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
let probe=Probe()
let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
config.userContentController.add(probe,name:"interactiveUI")
config.userContentController.addUserScript(WKUserScript(source:"window.addEventListener('error',e=>window.webkit.messageHandlers.interactiveUI.postMessage({debug:String(e.message)}));window.addEventListener('securitypolicyviolation',e=>window.webkit.messageHandlers.interactiveUI.postMessage({debug:e.violatedDirective+' '+e.blockedURI}));",injectionTime:.atDocumentStart,forMainFrameOnly:false))
probe.web=WKWebView(frame:NSRect(x:0,y:0,width:390,height:500),configuration:config)
probe.web.navigationDelegate=probe
var payload:[String:Any]=[
 "title":"Probe", "summary":"Sandbox contract check", "initialHeight":300,
 "placeholderMessages":["One","Two"], "css":"", "html":"<p id='sample'>Sandbox</p>",
 "jsFunctions":"""
 async function probe() {
  const results={ran:true};
  const themeCheck=document.createElement('div');themeCheck.style.cssText='color:var(--c-foreground,#171717);background:var(--c-background,#fff)';document.body.append(themeCheck);
  results.darkTheme=getComputedStyle(themeCheck).color==='rgb(232, 230, 222)' && getComputedStyle(themeCheck).backgroundColor==='rgb(26, 26, 24)' && document.documentElement.style.colorScheme==='dark';
  const before=document.getElementById('people').value;
  try {parent.document.body.textContent='escape';results.parentBlocked=false;}catch(e){results.parentBlocked=true;}
  try {localStorage.setItem('x','y');results.storageBlocked=false;}catch(e){results.storageBlocked=true;}
  try {document.cookie='test=1';results.cookieBlocked=document.cookie==='';}catch(e){results.cookieBlocked=true;}
  results.rtcBlocked=typeof RTCPeerConnection==='undefined';
  try {await fetch('https://example.com/should-never-be-requested');results.networkBlocked=false;}catch(e){results.networkBlocked=true;}
  const attack="</script><script>parent.document.body.textContent='escaped'</script>";
  await new Promise(resolve=>setTimeout(resolve,300));
  results.liveLightTheme=getComputedStyle(themeCheck).color==='rgb(26, 26, 26)' && getComputedStyle(themeCheck).backgroundColor==='rgb(255, 255, 255)' && document.documentElement.style.colorScheme==='light';
  results.controlsPreserved=document.getElementById('people').value===before;
  await Websandbox.connection.remote.sendPrompt({text:JSON.stringify(results)});
 }
 """, "jsExpressions":"probe();"
]
let demoURL=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("openintelligentui-demos.json")
let demos=try JSONSerialization.jsonObject(with:Data(contentsOf:demoURL)) as! [[String:Any]]
for value in demos {
    _ = try InteractiveArtifact(json:String(decoding:JSONSerialization.data(withJSONObject:value),as:UTF8.self))
}
let originalFunctions=payload["jsFunctions"] as! String
payload["html"]=(demos[0]["html"] as! String)+(demos[1]["html"] as! String)
payload["jsFunctions"]=(demos[0]["jsFunctions"] as! String)+(demos[1]["jsFunctions"] as! String)+originalFunctions
// Exercise the actual bundled controls, including clearing invalid/stale outputs.
payload["jsExpressions"] = """
function verifyControls(){
 resetBill();if(calculateBill().amount!==10)throw Error('split');
 document.getElementById('tip').value=10;if(calculateBill().amount!==11)throw Error('tip');
 for(const invalid of ['', '0', '1.5', '1001']){document.getElementById('people').value=invalid;if(calculateBill()!==null || document.getElementById('result').textContent!=='')throw Error('invalid people');}
 resetBill();document.getElementById('total').value='';if(calculateBill()!==null)throw Error('blank total');
 resetBill();if(document.getElementById('problem').textContent!=='')throw Error('reset');
 resetComparison();if(!document.getElementById('comparison').textContent.includes('60 €'))throw Error('comparison');
 document.getElementById('months').value=12;updateComparison();if(!document.getElementById('comparison').textContent.includes('120 €'))throw Error('slider');
 resetComparison();
}
verifyControls();probe();
"""
for key in InteractiveArtifact.fields {
    var invalid=payload;invalid.removeValue(forKey:key)
    do {_ = try InteractiveArtifact(json:String(decoding:JSONSerialization.data(withJSONObject:invalid),as:UTF8.self));fatalError("Missing field accepted: \(key)")}catch{}
}
for (key,value) in [("initialHeight",true as Any),("initialHeight",901),("html","<iframe>"),("title",String(repeating:"x",count:161))] {
    var invalid=payload;invalid[key]=value
    do {_ = try InteractiveArtifact(json:String(decoding:JSONSerialization.data(withJSONObject:invalid),as:UTF8.self));fatalError("Invalid field accepted: \(key)")}catch{}
}
print("Swift contract: demos and missing/invalid-field rejection passed")
var chatVariant = payload
chatVariant["type"] = "alice-interactive"
chatVariant["placeholderMessages"] = ["Preparando presupuesto"]
let compatible = try InteractiveArtifact.fromChatJSON(String(decoding: JSONSerialization.data(withJSONObject:chatVariant),as:UTF8.self))
assert(compatible.html == payload["html"] as? String && compatible.jsFunctions == payload["jsFunctions"] as? String)
assert(compatible.placeholderMessages.count == 2)
for (key,value) in [("type","other" as Any),("unexpected",true),("html","<script>send()</script>"),("placeholderMessages",[""]),("placeholderMessages",[]),("initialHeight",true),("css",String(repeating:"x",count:20001))] {
    var invalid=chatVariant;invalid[key]=value
    do {_ = try InteractiveArtifact.fromChatJSON(String(decoding:JSONSerialization.data(withJSONObject:invalid),as:UTF8.self));fatalError("Unsafe chat variant accepted: \(key)")}catch{}
}
print("Chat compatibility: exact type/single loading message accepted; unsafe variants rejected")
let artifact=try InteractiveArtifact(json:String(decoding:JSONSerialization.data(withJSONObject:payload),as:UTF8.self))
let document=try InteractiveDocument.make(artifact,resourceRoot:URL(fileURLWithPath:CommandLine.arguments[1]),darkMode:true)
try document.write(toFile:"/private/tmp/alice-openui-probe.html",atomically:true,encoding:.utf8)
probe.web.loadHTMLString(document,baseURL:nil)
let deadline=Date().addingTimeInterval(20)
while !probe.finished && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.05))}
if !probe.finished {print("FAIL: sandbox never finished");exit(1)}
exit(probe.failed ? 1:0)
