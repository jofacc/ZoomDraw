import AppKit
import WebKit

/// 显示一次 AI 对话：问题、搜索来源卡片、思考过程、流式 Markdown 回答、来源角标、相关问题
final class AIResultView: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    /// 代码块的「复制」按钮
    var onCopyText: ((String) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    /// 回答下方的按钮：copy / copymd / retry / shelf / settings
    var onAction: ((String) -> Void)?
    /// 点击了相关问题（已经开始追问）
    var onAsked: (() -> Void)?

    private(set) var conversation: AIConversation?
    private let webView: AIWebView
    private var loaded = false
    private var pending: [String] = []
    private var thumbCache: [UUID: String] = [:]

    override init(frame: NSRect) {
        let cfg = WKWebViewConfiguration()
        let proxy = WeakScriptHandler()
        cfg.userContentController.add(proxy, name: "zd")
        cfg.suppressesIncrementalRendering = false
        webView = AIWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
        super.init(frame: frame)
        proxy.target = self
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        addSubview(webView)
        webView.loadHTMLString(Self.page, baseURL: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 对话

    func attach(_ c: AIConversation?) {
        conversation?.onUpdate = nil
        conversation = c
        c?.onUpdate = { [weak self, weak c] k in
            guard let self = self, let c = c, self.conversation === c else { return }
            if k < 0 { self.renderAll() } else { self.render(k) }
        }
        renderAll()
    }

    private func renderAll() {
        guard let c = conversation else { run("zd.reset([])"); return }
        let list = c.turns.indices.map { payload($0) }
        run("zd.reset(\(json(list)))")
    }

    private func render(_ k: Int) {
        guard let c = conversation, k < c.turns.count else { return }
        run("zd.turn(\(k), \(json(payload(k))), \(c.turns.count))")
    }

    // MARK: 滚动 / 选中文字

    func scroll(by dy: CGFloat) { run("window.scrollBy(0, \(Int(dy)))") }
    func page(_ dir: Int) { run("zd.page(\(dir))") }
    func scrollToEdge(top: Bool) { run("zd.edge(\(top))") }

    func selectedText(_ cb: @escaping (String) -> Void) {
        guard loaded else { cb(""); return }
        webView.evaluateJavaScript("String(window.getSelection())") { r, _ in cb(r as? String ?? "") }
    }

    func focusWeb() { window?.makeFirstResponder(webView) }

    // MARK: 数据

    private func payload(_ k: Int) -> [String: Any] {
        guard let c = conversation else { return [:] }
        let t = c.turns[k], e = c.engine
        var d: [String: Any] = [:]
        d["chip"] = k == 0 ? e.name : ""
        d["kind"] = e.kind.rawValue
        d["query"] = k == 0 && (e.kind == .aiPrompt || (t.hasImage && t.query.isEmpty)) ? "" : t.query
        d["input"] = k == 0 ? (t.input ?? "") : ""
        d["image"] = k == 0 && t.hasImage ? (thumb(t.imageClipID) ?? "missing") : ""
        d["status"] = status(t, engine: e)
        d["running"] = t.isRunning
        d["sources"] = t.sources.enumerated().map { i, s -> [String: Any] in
            let host = s.host
            return ["n": i + 1, "title": s.title, "host": host, "url": s.url, "snippet": s.snippet,
                    "hue": Self.hue(host), "letter": String(host.first.map { String($0).uppercased() } ?? "•")]
        }
        if t.offline && t.phase != .searching {
            d["notice"] = "联网搜索没有拿到结果，以下回答未参考网页，内容可能过时"
            d["noticeDetail"] = t.searchErrors.joined(separator: "\n")
        }
        if !t.reasoning.isEmpty {
            d["thinking"] = MarkdownRenderer.escape(t.reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
            d["thinkingDone"] = !t.answer.isEmpty || !t.isRunning
        }
        d["answer"] = t.answer.isEmpty ? "" : MarkdownRenderer.html(t.answer, citations: t.sources)
        d["related"] = t.phase == .done ? t.related : []
        d["error"] = t.error ?? ""
        d["auth"] = t.isAuthError
        d["isLast"] = k == c.turns.count - 1
        return d
    }

    private func status(_ t: AITurn, engine e: WebSearchEngine) -> String {
        let srcNames = (AISettings.sources.isEmpty ? [.sogou, .so360] : AISettings.sources).map(\.title)
        switch t.phase {
        case .searching:
            return "正在联网搜索（\(srcNames.joined(separator: "、"))）…"
        case .answering:
            if !t.reasoning.isEmpty && t.answer.isEmpty { return "正在思考…" }
            if t.hasImage && t.answer.isEmpty { return "正在识别图片…" }
            if t.searched {
                return t.sources.isEmpty ? "联网搜索失败，正在直接回答…" : "已找到 \(t.sources.count) 个网页，正在整理回答…"
            }
            return "正在生成…"
        case .done, .stopped, .failed:
            var parts: [String] = []
            if t.phase == .stopped { parts.append("已停止") }
            if t.phase == .failed { parts.append("未完成") }
            if t.searched { parts.append(t.sources.isEmpty ? "未联网" : "参考 \(t.sources.count) 个网页") }
            if let d = t.duration { parts.append(String(format: "用时 %.1f 秒", d)) }
            if let m = t.model, !m.isEmpty { parts.append(m) }
            return parts.joined(separator: " · ")
        }
    }

    private func thumb(_ id: UUID?) -> String? {
        guard let id = id else { return nil }
        if let s = thumbCache[id] { return s }
        let store = ClipboardStore.shared
        let url = FileManager.default.fileExists(atPath: store.thumbURL(id).path) ? store.thumbURL(id) : store.imageURL(id)
        guard let img = NSImage(contentsOf: url), let data = AIClient.jpegData(img, maxSide: 480) else { return nil }
        let s = "data:image/jpeg;base64," + data.base64EncodedString()
        thumbCache[id] = s
        return s
    }

    private static func hue(_ s: String) -> Int {
        var h: UInt32 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Int(h % 360)
    }

    private func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else {
            return "null"
        }
        return s
    }

    private func run(_ js: String) {
        guard loaded else { pending.append(js); return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let r = Int(accent.redComponent * 255), g = Int(accent.greenComponent * 255), b = Int(accent.blueComponent * 255)
        webView.evaluateJavaScript("zd.accent(\(r),\(g),\(b))", completionHandler: nil)
        let js = pending
        pending = []
        js.forEach { webView.evaluateJavaScript($0, completionHandler: nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            onOpenURL?(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "open":
            if let s = m["url"] as? String, let url = URL(string: s) { onOpenURL?(url) }
        case "copy":
            if let s = m["text"] as? String { onCopyText?(s) }
        case "ask":
            if let q = m["q"] as? String { conversation?.ask(q); onAsked?() }
        case "act":
            if let a = m["act"] as? String { onAction?(a) }
        default: break
        }
    }

    // MARK: 页面

    private static let page: String = #"""
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
    :root{color-scheme:light dark;--accent:#0a84ff;--accent-soft:rgba(10,132,255,.14);--fg:#1d1d1f;--fg2:#6e6e73;--fg3:#a1a1a6;
      --card:rgba(0,0,0,.035);--card-h:rgba(0,0,0,.065);--border:rgba(0,0,0,.09);--code:rgba(0,0,0,.04);--tip:#fff;
      --kw:#ad3da4;--str:#c41a16;--num:#1c00cf;--com:#707f8c;--warn:#a05a00;--warn-bg:rgba(255,149,0,.12);
      --err:#c9001a;--err-bg:rgba(255,59,48,.08)}
    @media (prefers-color-scheme:dark){:root{--fg:#f2f2f7;--fg2:#a1a1a6;--fg3:#6e6e73;--card:rgba(255,255,255,.055);
      --card-h:rgba(255,255,255,.1);--border:rgba(255,255,255,.1);--code:rgba(255,255,255,.055);--tip:#2c2c2e;
      --kw:#fc5fa3;--str:#fc6a5d;--num:#d0bf69;--com:#7f8c98;--warn:#ffb340;--warn-bg:rgba(255,159,10,.14);
      --err:#ff6961;--err-bg:rgba(255,69,58,.13)}}
    *{box-sizing:border-box}
    html,body{margin:0;background:transparent}
    body{font:14px/1.72 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;color:var(--fg);
      padding:16px 24px 44px;-webkit-font-smoothing:antialiased;overflow-wrap:break-word;cursor:default}
    [hidden]{display:none!important}
    .turn+.turn{margin-top:24px;padding-top:20px;border-top:1px solid var(--border)}
    .q{display:flex;flex-direction:column;align-items:flex-start;gap:6px;margin-bottom:10px}
    .chip{font-size:11px;font-weight:600;line-height:18px;padding:0 9px;border-radius:999px;color:var(--accent);background:var(--accent-soft)}
    h1{font-size:19px;line-height:1.42;font-weight:650;margin:0;letter-spacing:.2px;user-select:text}
    .input{position:relative;margin:0 0 12px;padding:9px 12px;border-radius:10px;background:var(--card);border:1px solid var(--border);
      font-size:13px;color:var(--fg2)}
    .input-text{white-space:pre-wrap;max-height:7.2em;overflow:hidden;line-height:1.6}
    .input.expanded .input-text{max-height:none}
    .input.clamped{cursor:pointer}
    .input.clamped:not(.expanded)::after{content:"展开 ▾";position:absolute;right:8px;bottom:6px;font-size:11px;color:var(--accent);
      padding:0 6px;border-radius:6px;background:var(--tip)}
    .thumb{display:block;max-width:100%;max-height:170px;border-radius:7px}
    .thumb+.input-text{margin-top:8px}
    .img-missing{font-size:12px;color:var(--fg3)}
    .status{display:flex;align-items:center;gap:7px;font-size:12px;color:var(--fg2);margin:2px 0 10px}
    .spin{flex:none;width:12px;height:12px;border-radius:50%;border:2px solid var(--border);border-top-color:var(--accent);animation:spin .75s linear infinite}
    @keyframes spin{to{transform:rotate(360deg)}}
    .sources{display:flex;gap:8px;overflow-x:auto;padding:1px 1px 8px;margin:0 0 6px}
    .src{flex:0 0 170px;display:block;padding:7px 10px 8px;border-radius:10px;background:var(--card);border:1px solid var(--border);
      color:inherit;text-decoration:none;transition:background .15s,border-color .15s;animation:fadein .25s ease both}
    .src:hover,.src.hl{background:var(--card-h);border-color:var(--accent)}
    @keyframes fadein{from{opacity:0;transform:translateY(3px)}to{opacity:1;transform:none}}
    .src-top{display:flex;align-items:center;gap:6px;font-size:11px;color:var(--fg2);margin-bottom:2px}
    .fav{flex:none;width:16px;height:16px;border-radius:4px;color:#fff;font-size:10px;font-weight:700;display:grid;place-items:center;line-height:1}
    .host{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .num{flex:none;font-size:10px;color:var(--fg3)}
    .src-title{font-size:12px;line-height:1.45;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
    .notice{font-size:12px;color:var(--warn);background:var(--warn-bg);padding:6px 11px;border-radius:8px;margin:0 0 12px}
    .think{margin:0 0 12px;font-size:12.5px;color:var(--fg2)}
    .think summary{cursor:pointer;list-style:none;display:inline-flex;align-items:center;gap:6px;padding:1px 11px;border-radius:999px;
      background:var(--card);border:1px solid var(--border);user-select:none;line-height:22px}
    .think summary::-webkit-details-marker{display:none}
    .think summary::before{content:"›";font-weight:700;transition:transform .15s}
    .think[open] summary::before{transform:rotate(90deg)}
    .think-body{margin-top:8px;padding:0 0 0 12px;border-left:2px solid var(--border);max-height:240px;overflow:auto;white-space:pre-wrap;line-height:1.62;user-select:text}
    .md{user-select:text;cursor:auto}
    .md>:first-child{margin-top:0}
    .md>:last-child{margin-bottom:0}
    .md p{margin:0 0 .8em}
    .md h1,.md h2,.md h3,.md h4,.md h5,.md h6{line-height:1.4;margin:1.15em 0 .45em;font-weight:650}
    .md h1{font-size:18px}.md h2{font-size:16.5px}.md h3{font-size:15px}.md h4,.md h5,.md h6{font-size:14px}
    .md ul,.md ol{margin:0 0 .8em;padding-left:1.45em}
    .md li{margin:.22em 0}
    .md li>ul,.md li>ol{margin:.2em 0}
    .md li::marker{color:var(--fg3)}
    .md li.task{list-style:none;margin-left:-1.25em}
    .md .box{display:inline-block;width:13px;height:13px;border:1.5px solid var(--fg3);border-radius:4px;margin-right:7px;vertical-align:-1px;position:relative}
    .md li.done>.box{background:var(--accent);border-color:var(--accent)}
    .md li.done>.box::after{content:"";position:absolute;left:3px;top:0;width:3px;height:7px;border:solid #fff;border-width:0 2px 2px 0;transform:rotate(45deg)}
    .md strong{font-weight:650}
    .md a{color:var(--accent);text-decoration:none}
    .md a:hover{text-decoration:underline}
    .md code{font:12.5px/1.5 "SF Mono",Menlo,monospace;background:var(--code);padding:.1em .38em;border-radius:5px;border:1px solid var(--border)}
    .md blockquote{margin:0 0 .8em;padding:.1em 0 .1em 12px;border-left:3px solid var(--border);color:var(--fg2)}
    .md hr{border:0;border-top:1px solid var(--border);margin:1.2em 0}
    .md del{color:var(--fg3)}
    .table-wrap{overflow-x:auto;margin:0 0 .9em;border:1px solid var(--border);border-radius:9px}
    .md table{border-collapse:collapse;width:100%;font-size:13px;line-height:1.55}
    .md th,.md td{padding:6px 11px;border-bottom:1px solid var(--border);text-align:left;vertical-align:top}
    .md th{background:var(--card);font-weight:600;white-space:nowrap}
    .md tr:last-child td{border-bottom:0}
    .md td+td,.md th+th{border-left:1px solid var(--border)}
    .md tbody tr:hover td{background:var(--card)}
    .code{margin:0 0 .9em;border-radius:9px;background:var(--code);border:1px solid var(--border);overflow:hidden}
    .code-head{display:flex;justify-content:space-between;align-items:center;padding:3px 5px 3px 12px;font-size:11px;color:var(--fg3);
      border-bottom:1px solid var(--border);user-select:none}
    .code pre{margin:0;padding:10px 12px;overflow-x:auto}
    .code pre code{background:none;border:0;padding:0;font-size:12.5px;line-height:1.58;white-space:pre}
    .hl-k{color:var(--kw)}.hl-s{color:var(--str)}.hl-n{color:var(--num)}.hl-c{color:var(--com);font-style:italic}
    sup.cite{display:inline-block;min-width:15px;height:15px;padding:0 4px;margin:0 1px;border-radius:8px;font:600 9.5px/15px -apple-system,sans-serif;
      text-align:center;vertical-align:3px;color:var(--accent);background:var(--accent-soft);cursor:pointer;user-select:none;transition:background .12s,color .12s}
    sup.cite:hover{background:var(--accent);color:#fff}
    .md.streaming>:last-child::after{content:"";display:inline-block;width:7px;height:14px;margin-left:3px;vertical-align:-2px;border-radius:2px;
      background:var(--accent);animation:blink 1s steps(2) infinite}
    @keyframes blink{50%{opacity:0}}
    .error{margin:4px 0 10px;padding:10px 12px;border-radius:9px;background:var(--err-bg);color:var(--err);font-size:13px;user-select:text}
    .err-btns{margin-top:8px;display:flex;gap:8px}
    button{font:inherit;font-size:12px;line-height:20px;color:var(--fg);background:var(--card);border:1px solid var(--border);border-radius:7px;
      padding:1px 10px;cursor:pointer}
    button:hover{background:var(--card-h)}
    .copy-code{font-size:11px;line-height:18px;padding:0 8px;background:transparent;border-color:transparent;color:var(--fg2)}
    .related{margin-top:16px}
    .rel-title{font-size:12px;font-weight:600;color:var(--fg2);margin:0 0 4px 2px}
    .rel{display:flex;align-items:center;gap:9px;width:100%;text-align:left;padding:6px 10px;margin:0;border-radius:8px;background:transparent;
      border:0;font-size:13px;line-height:1.5}
    .rel+.rel{border-top:1px solid var(--border);border-radius:0}
    .rel:hover{background:var(--card-h);border-radius:8px}
    .rel-icon{color:var(--accent);font-weight:700}
    .actions{display:flex;gap:2px;margin:12px 0 0 -8px}
    .actions button{background:transparent;border-color:transparent;color:var(--fg2);padding:1px 8px}
    .actions button:hover{background:var(--card-h);color:var(--fg)}
    .tip{position:absolute;z-index:10;width:320px;padding:10px 12px;border-radius:10px;background:var(--tip);border:1px solid var(--border);
      box-shadow:0 8px 28px rgba(0,0,0,.18);font-size:12px;opacity:0;pointer-events:none;transition:opacity .12s}
    .tip.show{opacity:1}
    .tip-host{display:flex;gap:6px;align-items:center;color:var(--fg2);font-size:11px}
    .tip-title{font-weight:600;margin:5px 0 3px;line-height:1.42}
    .tip-snippet{color:var(--fg2);line-height:1.52;display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical;overflow:hidden}
    .more{position:fixed;left:50%;bottom:10px;transform:translateX(-50%);font-size:11px;line-height:22px;padding:0 12px;border-radius:999px;
      background:var(--tip);border:1px solid var(--border);box-shadow:0 2px 10px rgba(0,0,0,.14);color:var(--fg2);cursor:pointer;display:none}
    .more.show{display:block}
    ::-webkit-scrollbar{width:8px;height:7px}
    ::-webkit-scrollbar-thumb{background:var(--border);border-radius:4px}
    ::selection{background:var(--accent-soft)}
    </style></head><body><main id="app"></main><div class="tip" id="tip"></div><div class="more" id="more">▾ 正在生成，点击查看</div>
    <script>
    const app=document.getElementById('app'),tip=document.getElementById('tip'),more=document.getElementById('more');
    const post=m=>window.webkit.messageHandlers.zd.postMessage(m);
    const esc=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    const TPL='<header class="q" hidden></header><div class="input" hidden></div><div class="status" hidden></div><div class="sources" hidden></div>'+
      '<div class="notice" hidden></div><details class="think" hidden><summary></summary><div class="think-body"></div></details>'+
      '<article class="md" hidden></article><div class="error" hidden></div><div class="related" hidden></div><div class="actions" hidden></div>';
    let state=[];
    const docH=()=>document.documentElement.scrollHeight;
    const nearBottom=()=>window.innerHeight+window.scrollY>=docH()-60;
    function set(el,html){if(el._h!==html){el.innerHTML=html;el._h=html}el.hidden=!html}
    function fav(s){return '<span class="fav" style="background:hsl('+s.hue+',52%,50%)">'+esc(s.letter)+'</span>'}
    function section(i){
      let s=document.getElementById('t'+i);
      if(!s){s=document.createElement('section');s.className='turn';s.id='t'+i;s.innerHTML=TPL;app.appendChild(s);
        const d=s.querySelector('.think');d.addEventListener('toggle',()=>{if(d._auto){d._auto=false;return}d._user=true})}
      return s}
    function updateMore(){more.classList.toggle('show',!!document.querySelector('.turn.running')&&!nearBottom())}
    window.addEventListener('scroll',updateMore,{passive:true});
    more.addEventListener('click',()=>window.scrollTo({top:docH(),behavior:'smooth'}));
    window.zd={
      accent(r,g,b){const st=document.documentElement.style;st.setProperty('--accent','rgb('+r+','+g+','+b+')');st.setProperty('--accent-soft','rgba('+r+','+g+','+b+',.15)')},
      reset(list){app.innerHTML='';state=[];list.forEach((t,i)=>this.turn(i,t,list.length,true));
        const last=document.getElementById('t'+(list.length-1));
        if(list.length>1&&last)last.scrollIntoView({block:'start'});else window.scrollTo(0,0);updateMore()},
      turn(i,t,count,silent){
        for(let k=count;document.getElementById('t'+k);k++)document.getElementById('t'+k).remove();
        const isNew=!document.getElementById('t'+i),s=section(i);
        state[i]=t.sources||[];
        s.classList.toggle('running',!!t.running);
        let q='';if(t.chip)q+='<span class="chip">'+esc(t.chip)+'</span>';if(t.query)q+='<h1>'+esc(t.query)+'</h1>';
        set(s.querySelector('.q'),q);
        const ie=s.querySelector('.input');let inp='';
        if(t.image)inp+=t.image==='missing'?'<div class="img-missing">🖼 图片（原图已不在剪贴板历史中）</div>':'<img class="thumb" src="'+t.image+'">';
        if(t.input)inp+='<div class="input-text">'+esc(t.input)+'</div>';
        const changed=ie._h!==inp;set(ie,inp);
        if(changed&&t.input)requestAnimationFrame(()=>{const tx=ie.querySelector('.input-text');ie.classList.toggle('clamped',!!tx&&tx.scrollHeight>tx.clientHeight+4)});
        set(s.querySelector('.status'),t.status?(t.running?'<span class="spin"></span>':'')+'<span>'+esc(t.status)+'</span>':'');
        set(s.querySelector('.sources'),state[i].map(src=>'<a class="src" data-n="'+src.n+'" href="'+esc(src.url)+'"><div class="src-top">'+fav(src)+
          '<span class="host">'+esc(src.host)+'</span><span class="num">'+src.n+'</span></div><div class="src-title">'+esc(src.title)+'</div></a>').join(''));
        const nt=s.querySelector('.notice');set(nt,t.notice?'⚠︎ '+esc(t.notice):'');nt.title=t.noticeDetail||'';
        const d=s.querySelector('.think');
        if(t.thinking){d.hidden=false;const sm=d.querySelector('summary'),sum=t.thinkingDone?'思考过程':'正在思考…';if(sm.textContent!==sum)sm.textContent=sum;
          const b=d.querySelector('.think-body');if(b._h!==t.thinking){b.innerHTML=t.thinking;b._h=t.thinking;if(!t.thinkingDone)b.scrollTop=b.scrollHeight}
          if(!d._user){const want=!t.thinkingDone;if(d.open!==want){d._auto=true;d.open=want}}}else d.hidden=true;
        const md=s.querySelector('.md');set(md,t.answer||'');md.classList.toggle('streaming',!!t.running&&!!t.answer);
        set(s.querySelector('.error'),t.error?'<div>'+esc(t.error)+'</div><div class="err-btns"><button data-act="retry">重试</button>'+
          (t.auth?'<button data-act="settings">打开 AI 设置</button>':'')+'</div>':'');
        set(s.querySelector('.related'),(t.related||[]).length&&t.isLast?'<div class="rel-title">相关问题</div>'+
          t.related.map(r=>'<button class="rel" data-q="'+esc(r)+'"><span class="rel-icon">↳</span><span>'+esc(r)+'</span></button>').join(''):'');
        set(s.querySelector('.actions'),!t.running&&t.answer?'<button data-act="copy">复制</button><button data-act="copymd">复制 Markdown</button>'+
          (t.isLast?'<button data-act="retry">重新生成</button>':'')+'<button data-act="shelf">存入暂存板</button>':'');
        if(isNew&&!silent&&i>0)s.scrollIntoView({block:'start',behavior:'smooth'});
        updateMore()},
      page(dir){window.scrollBy(0,dir*(window.innerHeight-60))},
      edge(top){window.scrollTo(0,top?0:docH())}
    };
    function srcOf(el){const sec=el.closest('.turn');if(!sec)return null;const n=+el.dataset.cite;return {sec,n,src:(state[+sec.id.slice(1)]||[])[n-1]}}
    document.addEventListener('click',e=>{
      const c=e.target.closest('sup.cite');if(c){const r=srcOf(c);if(r&&r.src)post({type:'open',url:r.src.url});return}
      const a=e.target.closest('a');if(a){e.preventDefault();post({type:'open',url:a.href});return}
      const b=e.target.closest('button');
      if(b){if(b.classList.contains('copy-code')){const code=b.closest('.code').querySelector('code');post({type:'copy',text:code.innerText});
          b.textContent='已复制 ✓';setTimeout(()=>b.textContent='复制',1300);return}
        if(b.dataset.q){post({type:'ask',q:b.dataset.q});return}
        if(b.dataset.act){post({type:'act',act:b.dataset.act});return}}
      const ie=e.target.closest('.input');if(ie&&ie.classList.contains('clamped')&&!String(window.getSelection()))ie.classList.toggle('expanded')});
    let hl=null;
    document.addEventListener('mouseover',e=>{
      const c=e.target.closest('sup.cite');if(!c)return;const r=srcOf(c);if(!r||!r.src)return;
      tip.innerHTML='<div class="tip-host">'+fav(r.src)+'<span>'+esc(r.src.host)+'</span><span style="margin-left:auto">['+r.n+']</span></div><div class="tip-title">'+
        esc(r.src.title)+'</div><div class="tip-snippet">'+esc(r.src.snippet)+'</div>';
      const rc=c.getBoundingClientRect(),w=320;
      tip.style.left=Math.max(8,Math.min(rc.left-24,window.innerWidth-w-12))+'px';
      tip.classList.add('show');
      const th=tip.offsetHeight;const below=rc.bottom+8+th<window.innerHeight;
      tip.style.top=(window.scrollY+(below?rc.bottom+6:rc.top-th-6))+'px';
      hl=r.sec.querySelector('.src[data-n="'+r.n+'"]');if(hl)hl.classList.add('hl')});
    document.addEventListener('mouseout',e=>{if(!e.target.closest('sup.cite'))return;tip.classList.remove('show');if(hl){hl.classList.remove('hl');hl=null}});
    </script></body></html>
    """#
}

/// 去掉右键菜单里的「重新载入」等无用项
final class AIWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let drop: Set<String> = ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierOpenLinkInNewWindow",
                                 "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierOpenImageInNewWindow",
                                 "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierGoBack",
                                 "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierInspectElement"]
        menu.items.filter { drop.contains($0.identifier?.rawValue ?? "") }.forEach { menu.removeItem($0) }
        super.willOpenMenu(menu, with: event)
    }
}

/// WKUserContentController 会强引用 handler，用弱引用中转避免循环引用
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
