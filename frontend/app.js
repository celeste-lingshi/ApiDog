"use strict";

const by = id => document.getElementById(id);
const escape = value => String(value ?? "").replace(/[&<>"']/g, c => ({
  "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"
})[c]);
const icons = {
  plus:'<path d="M12 5v14M5 12h14"/>', more:'<path d="M5 12h.1m6.9 0h.1m6.9 0h.1" stroke-width="3"/>',
  down:'<path d="m6 9 6 6 6-6"/>', right:'<path d="m9 6 6 6-6 6"/>',
  folder:'<path d="M3 19V6a1 1 0 0 1 1-1h5l3 3h8a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z"/>',
  copy:'<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
  trash:'<path d="M4 7h16m-10 4v6m4-6v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  check:'<path d="m5 12 4 4L19 6"/>', minus:'<path d="M5 12h14"/>', close:'<path d="m6 6 12 12M18 6 6 18"/>',
  expand:'<path d="M15 4h5v5m-7 2 7-7M9 20H4v-5m7-2-7 7"/>',
  import:'<path d="M12 3v11m-4-4 4 4 4-4M5 14v6h14v-6"/>',
  save:'<path d="M12 3v9m-4-4 4 4 4-4M4 13h5l1 3h4l1-3h5v7H4Z"/>',
  send:'<path d="M4 12h15m-6-6 6 6-6 6"/>', stop:'<rect x="6" y="6" width="12" height="12" rx="2"/>',
  key:'<circle cx="8" cy="15" r="4"/><path d="m11 12 7-7 3 3-2 2m-3-1 2 2"/>',
  edit:'<path d="m4 20 4-1L20 7l-3-3L5 16l-1 4ZM14 7l3 3"/>',
  terminal:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 8 4 4-4 4m6 0h4"/>',
  search:'<circle cx="10" cy="10" r="5"/><path d="m14 14 5 5"/>',
  clock:'<circle cx="12" cy="12" r="8"/><path d="M12 7v5l3 2"/>',
  warning:'<path d="m12 4 9 16H3L12 4Zm0 5v4m0 3v.1"/>',
  sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l2 2m10 10 2 2m0-14-2 2M7 17l-2 2"/>',
  moon:'<path d="M21 13.5A9 9 0 0 1 10.5 3 9 9 0 1 0 21 13.5Z"/>',
  system:'<circle cx="12" cy="12" r="8"/><path d="M12 4v16a8 8 0 1 0 0-16Z" fill="currentColor"/>'
};
const icon = name => icons[name] ? `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name]}</svg>` : "";
const methods = { GET:"accent", POST:"blue", PUT:"amber", PATCH:"amber", DELETE:"red", HEAD:"accent", OPTIONS:"purple" };
const palette = method => "var(--" + (methods[method] ?? "muted") + ")";
const authOptions = { none:"无认证", bearer:"Bearer Token", basic:"Basic", apiKey:"API Key", hmac:"HMAC-SHA256 签名", script:"自定义 JavaScript" };
const locations = { query:"URL 查询", header:"请求头", body:"JSON 请求体" };
const themes = { system:["跟随系统","system"], light:["浅色","sun"], dark:["深色","moon"] };
const requestTabs = { variables:"变量", query:"查询", headers:"请求头", authentication:"认证", body:"请求体", connection:"连接" };
const responseTabs = { curl:"cURL", body:"正文", headers:"响应头", extracted:"提取" };
const sidebarTabs = { directory:"请求目录", history:"请求历史" };
const scriptExample = 'if (!inputs.token) throw new Error("请填写 token");\nreturn { headers: { Authorization: "Bearer " + inputs.token } };';
const nextID = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6]=(bytes[6]&15)|64; bytes[8]=(bytes[8]&63)|128;
  const hex = Array.from(bytes,b=>b.toString(16).padStart(2,"0")).join("").toUpperCase();
  return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join("-");
};
const clone = value => JSON.parse(JSON.stringify(value));
const newDraft = () => ({method:"GET",url:"",headers:[],query:[],variables:{},auth:{mode:"none",name:""},followsRedirects:false});
const normalize = value => {
  const d = {...newDraft(),...clone(value)};
  d.headers ??= []; d.query ??= []; d.variables ??= {}; d.auth ??= {mode:"none",name:""};
  d.auth.mode ||= "none";
  return d;
};
const desktop = () => window.go?.main?.App;
const rpc = (name,...args) => {
  const method = desktop()?.[name];
  if (!method) return Promise.reject("ApiDog 正在启动。");
  return method(...args);
};
const message = error => String(error?.message ?? error);
const collapsed = new Set();
let state = {directory:{categories:[],requests:[]},history:[],locked:false,issue:""};
let draft = newDraft(), savedID = null, historyID = null, sidebar = "directory", requestTab = "variables", responseTab = "curl";
let theme = "dark", result = null, elapsed = 0, failure = "", cancelled = false, sending = false, migrating = false;
let preview = null, previewError = "", previewSequence = 0, previewTimer, previewTask, noticeTimer, copied = "";
let dragged = null, menuAnchor = null, menuItems = [], dialogSubmit = null;
const systemTheme = matchMedia("(prefers-color-scheme: dark)");

function adopt(value) {
  state = value;
  state.directory ??= {};
  state.directory.categories ??= [];
  state.directory.requests ??= [];
  state.history ??= [];
}
const activeSaved = () => state.directory.requests.find(r=>r.id===savedID);
const methodAllowsBody = () => !["GET","HEAD"].includes(draft.method);
const hasAddress = () => draft.url.trim() !== "";
const generated = () => ["hmac","script"].includes(draft.auth.mode);
const authLocation = () => draft.auth.placement || (draft.auth.mode==="hmac" ? "query" : "header");

function variableNames() {
  const fields = [...draft.query, ...draft.headers].flatMap(f=>[f.name,f.value ?? ""]);
  const a = draft.auth;
  const values = [draft.url,...fields];
  if (a.mode!=="none") values.push(a.name,a.secret,a.signingURI);
  if (a.mode==="script") values.push(...(a.scriptInputs??[]).map(f=>f.value));
  values.push(draft.route?.resolve,draft.route?.noProxy);
  if (methodAllowsBody()) values.push(draft.body);
  return [...new Set(values.flatMap(text=>[...String(text??"").matchAll(/\{\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*\}\}|\{([A-Za-z_][A-Za-z0-9_.-]*)\}/g)].map(m=>m[1]??m[2])))];
}

function notify(text) {
  const view=by("notification");
  view.textContent=text; view.hidden=false;
  clearTimeout(noticeTimer);
  noticeTimer=setTimeout(()=>view.hidden=true,2500);
}

function selectDraft(next, existing=null, history=null) {
  draft=normalize(next); savedID=existing; historyID=history; result=null; elapsed=0; failure=""; cancelled=false;
  responseTab="curl"; copied="";
  requestTab=variableNames().length ? "variables" : draft.auth.mode!=="none" ? "authentication"
    : draft.headers.length ? "headers" : draft.query.length ? "query" : draft.body!=null ? "body" : "variables";
  by("address").value=draft.url;
  by("redirects").checked=draft.followsRedirects;
  schedulePreview();
  render();
}

function tabs(element, values, selected) {
  element.innerHTML=Object.entries(values).map(([key,label])=>
    `<button type="button" role="tab" aria-selected="${key===selected}" data-tab="${key}">${label}</button>`).join("");
}

function directoryRow(r) {
  const canEdit=!state.locked && !sending;
  return `<div class="saved-row ${r.categoryID?"indent":""} ${r.id===savedID?"selected":""}" data-request="${escape(r.id)}">
    <button type="button" class="saved-open" data-action="open" draggable="${canEdit}" style="--method:${palette(r.draft.method)}" title="${escape(r.draft.url || r.name)}">
      <span>${escape(r.draft.method)}</span><span>${escape(r.name)}</span>
    </button>
    <button type="button" class="icon-button" data-action="duplicate" title="复制请求" aria-label="复制请求「${escape(r.name)}」" ${canEdit?"":"disabled"}>${icon("copy")}</button>
    <button type="button" class="icon-button danger" data-action="delete" title="删除请求" aria-label="删除请求「${escape(r.name)}」" ${canEdit?"":"disabled"}>${icon("trash")}</button>
  </div>`;
}

function renderSidebar() {
  tabs(by("sidebar-tabs"),sidebarTabs,sidebar);
  const sidebarMenu=by("sidebar-menu");
  sidebarMenu.innerHTML=icon(sidebar==="directory"?"plus":"more");
  sidebarMenu.disabled=state.locked || (sending && sidebar==="directory");
  sidebarMenu.setAttribute("aria-label",sidebar==="directory"?"添加到请求目录":"历史操作");
  by("history-search").hidden=sidebar!=="history";
  const list=by("sidebar-list");
  if (sidebar==="directory") {
    const {requests,categories}=state.directory;
    if (!requests.length && !categories.length) {
      list.innerHTML='<p class="sidebar-empty">可新建分类，或把当前请求保存到目录。</p>';
      return;
    }
    const folders=categories.map(c=>{
      const closed=collapsed.has(c.id);
      return `<button class="folder" type="button" data-category="${escape(c.id)}" aria-expanded="${!closed}">${icon(closed?"right":"down")}${icon("folder")}<span class="ellipsis">${escape(c.name)}</span></button>`
        + (closed?"":requests.filter(r=>r.categoryID===c.id).map(directoryRow).join(""));
    });
    list.innerHTML=folders.join("") + '<div class="folder uncategorized" data-category="">未分类</div>'
      + requests.filter(r=>!r.categoryID).map(directoryRow).join("");
    return;
  }
  const search=by("history-query").value.trim().toLocaleLowerCase();
  const entries=state.history.filter(h=>[h.request.method,h.request.url,h.environment,h.status??"失败"]
    .some(v=>String(v??"").toLocaleLowerCase().includes(search)));
  list.innerHTML=entries.map(h=>{
    const date=new Date((h.date+978307200)*1000);
    const dateText=new Intl.DateTimeFormat("zh-CN",{month:"numeric",day:"numeric",hour:"2-digit",minute:"2-digit"}).format(date);
    return `<div class="history-row ${h.id===historyID?"selected":""}" data-history="${escape(h.id)}">
      <button class="history-open" type="button" data-action="history" style="--method:${palette(h.request.method)}" title="${escape(h.request.url)}" ${sending?"disabled":""}>
        <span class="history-meta"><b>${escape(h.request.method)}</b><span>${h.status??"失败"} · ${h.milliseconds} ms</span></span>
        <span class="history-address ellipsis">${escape(h.request.url || "未填地址")}</span>
        <span class="history-meta"><span>${escape(dateText)}</span><span>${escape(h.environment)}</span></span>
      </button>
      <button class="icon-button" type="button" data-action="copy-history" aria-label="复制请求地址">${icon("copy")}</button>
    </div>`;
  }).join("") || `<p class="sidebar-empty">${state.history.length?"找不到匹配的请求。":"发送过的请求会出现在这里。"}</p>`;
}

function renderAddress() {
  const saved=activeSaved();
  const disabled=state.locked||sending;
  const category=state.directory.categories.find(c=>c.id===saved?.categoryID);
  const trail=by("breadcrumb");
  trail.hidden=!saved;
  trail.innerHTML=!saved?"":(category?`<span class="category">${icon("folder")} ${escape(category.name)}</span>${icon("right")}`:"")
      + `<strong class="ellipsis">${escape(saved.name)}</strong>`
      + (JSON.stringify(normalize(saved.draft))!==JSON.stringify(draft)?'<span class="modified">有修改</span>':"");
  const button=by("method");
  button.innerHTML=escape(draft.method)+icon("down");
  button.style.setProperty("--method",palette(draft.method));
  button.setAttribute("aria-label","请求方法 "+draft.method);
  button.disabled=disabled;
  by("address").disabled=disabled;
  by("redirects").disabled=disabled;
  by("save").disabled=disabled||(!saved&&!hasAddress());
  by("save-as").hidden=!saved;
  by("save-as").disabled=disabled;
  by("import").disabled=disabled;
  by("send").innerHTML=(sending?icon("stop")+"取消":icon("send")+"发送 <span class=\"shortcut\">⌘↩</span>");
  by("send").disabled=state.locked||(!sending&&!hasAddress());
}

function input(id, val, label, placeholder="",password=false) {
  return `<input class="input" id="${id}" type="${password?"password":"text"}" value="${escape(val)}" aria-label="${escape(label)}" placeholder="${escape(placeholder)}" autocomplete="off" spellcheck="false">`;
}
function pair(id,label,value,placeholder="",password=false) {
  return `<div class="subrow"><label for="${id}">${escape(label)}</label>${input(id,value,label,placeholder,password)}</div>`;
}
function picker(id,label,caption,labelIcon) {
  return `<button type="button" class="picker" id="${id}" aria-label="${escape(label)}" aria-haspopup="menu">${icon(labelIcon)}<span>${escape(caption)}</span>${icon("down")}</button>`;
}
function fieldList(fields,group) {
  const nameHint=group==="headers"?"Content-Type":group==="script"?"名称":"limit";
  const valueHint=group==="headers"?"application/json":group==="script"?"值":"20";
  const title=group==="headers"?"请求头":group==="script"?"输入":"参数";
  let text='<div class="field-grid label"><span>名称</span><span>值</span>'
    + '<button class="button small" type="button" data-edit="add" aria-label="添加'+title+'">'+icon("plus")+' '+title+'</button></div>';
  if (!fields.length) text+='<p>可用「＋ '+title+'」添加一行。</p>';
  for (const [i,f] of fields.entries()) {
    text+='<div class="field-grid" data-row="'+i+'">'
      +input("field-name-"+i,f.name,"第 "+(i+1)+" 行名称",nameHint)
      +input("field-value-"+i,f.value,"第 "+(i+1)+" 行值",valueHint,group==="script")
      +'<button class="icon-button" type="button" data-edit="remove" aria-label="删除第 '+(i+1)+' 行">'+icon("close")+'</button></div>';
  }
  return text;
}

function authEditor() {
  const a=draft.auth;
  let view=picker("auth-mode","认证方式",authOptions[a.mode],"key")+'<div style="height:8px"></div>';
  const chooseLocation=()=>`<div class="subrow"><label>位置</label>${picker("auth-location","认证字段位置",locations[authLocation()])}</div>`;
  switch (a.mode) {
    case "none": return view+"<p>选择认证方式后，按字段填写。</p>";
    case "bearer": return view+pair("auth-secret","Token",a.secret,"填 Token",true);
    case "basic": return view+pair("auth-name","用户名",a.name,"填用户名")+pair("auth-secret","密码",a.secret,"填密码",true);
    case "apiKey": return view+pair("auth-name","字段名",a.name,"X-API-Key")+pair("auth-secret","值",a.secret,"填 API Key",true)+chooseLocation();
    case "hmac": return view
      +pair("auth-name","API Key",a.name,a.signingKeyInput||"填 apikey")
      +pair("auth-secret","Secure Key",a.secret,a.signingSecretInput||"填 securekey")
      +pair("auth-key-field","Key 字段",a.signingKeyField,"apikey")
      +pair("auth-uri","签名 URI",a.signingURI,"默认使用请求路径")
      +chooseLocation()+"<p>Key 和 sign 使用所选位置。timestamp 自动填入 URL 查询。</p>";
    case "script": return view+fieldList(a.scriptInputs??[],"script")
      +`<p style="margin-top:9px">可以使用 inputs、request、timestamp 和 crypto。</p>
         <textarea class="text-editor" id="script-text" aria-label="认证脚本" spellcheck="false">${escape(a.script??scriptExample)}</textarea>`;
    default: return view;
  }
}

function renderEditor() {
  tabs(by("request-tabs"),requestTabs,requestTab);
  const editor=by("editor");
  let view="";
  switch (requestTab) {
    case "variables": {
      const variables=variableNames();
      view=variables.length?variables.map((name,i)=>`<div class="variable-row"><label for="variable-${i}">${escape(name)}</label>${input("variable-"+i,draft.variables[name],name,"输入变量值")}</div>`).join("")
        : "<p>在请求中写 {变量名}，即可在这里填写值。用双括号保留完整 URL 或路径。</p>";
      break;
    }
    case "query": {
      const a=draft.auth;
      const names=a.mode==="hmac"?(authLocation()==="query"?[a.signingKeyField?.trim()||"apikey","timestamp","sign"]:["timestamp"])
        :a.mode==="apiKey"&&authLocation()==="query"&&a.name?[a.name]:[];
      view="<p>查询参数会拼到 URL 的 ? 后面。</p>"+fieldList(draft.query,"query")
        +(names.length?`<div class="generated">由认证自动添加 ${names.map(name=>`<code>${escape(name)}</code>`).join("")}</div>`:"");
      break;
    }
    case "headers": view=fieldList(draft.headers,"headers"); break;
    case "body": view=methodAllowsBody()
      ?`<textarea class="text-editor" id="body-text" aria-label="请求体" spellcheck="false" placeholder='{"name":"ApiDog"}'>${escape(draft.body)}</textarea>`
      :`<p>${draft.method==="GET"?"GET 的参数填在「查询」，例如 cURL 的 --get --data-urlencode。":escape(draft.method)+" 请求没有正文。"}</p>`; break;
    case "authentication": view=authEditor(); break;
    case "connection": view=pair("resolve","指定解析",draft.route?.resolve,"域名:端口:IP")
      +pair("no-proxy","不走代理",draft.route?.noProxy,"主机名，多个用逗号分隔")
      +pair("projection","响应提取",draft.projection,".reason[]?.port")
      +"<p>指定解析和代理决定请求怎么连接。响应提取只影响返回结果的显示。</p>"; break;
  }
  editor.innerHTML=view;
  if (sending||state.locked) editor.querySelectorAll("input,button,textarea").forEach(e=>e.disabled=true);
}

function renderResponse() {
  const choices={...responseTabs};
  if (!result?.extracted && result?.extracted!=="" && !result?.extractionError && !(sending&&draft.projection) && responseTab!=="extracted") delete choices.extracted;
  tabs(by("response-tabs"),choices,responseTab);
  const heading=by("response-heading");
  heading.innerHTML=icon("terminal")+(responseTab==="curl"?"cURL 预览":"响应");
  const history=state.history.find(entry=>entry.id===historyID);
  const status=result?.status??history?.status;
  const milliseconds=result||failure?elapsed:history?.milliseconds;
  by("status").innerHTML=responseTab!=="curl"&&(result||failure||history)
    ?'<b style="--status:var(--'+(status==null?"red":status<300?"accent":status<400?"amber":"red")+')">'
      +(status==null?"请求失败":"HTTP "+status)+'</b><span>'+(milliseconds??0)+' ms</span>':"";
  by("response-size").textContent=responseTab!=="curl"&&result?(result.truncated?"前 256 KiB":result.byteCount+" B"):"";
  const box=by("response-content");
  const copy=by("copy-result");
  let text="",warning="",title="",emptyIcon="terminal";
  if (responseTab==="curl") {
    text=preview?.command??"";
    warning=previewError;
    title=hasAddress()?"等待补全请求":"等待输入请求";
  } else if (responseTab==="extracted") {
    text=result?.extracted??""; warning=result?.extractionError??failure;
    title=result?"没有匹配的字段":"等待响应";
  } else {
    text=(responseTab==="headers"?result?.headers:result?.body)??"";
    warning=failure;
    title=cancelled?"已取消请求":result?(responseTab==="headers"?"没有响应头":"没有响应正文"):"等待响应";
  }
  if (sending && responseTab!=="curl") {
    box.innerHTML='<div class="empty"><span class="spinner"></span><h3>正在等待响应</h3></div>';
  } else if (text) {
    box.innerHTML=`<pre>${escape(text)}</pre>`+(responseTab==="curl"&&draft.auth.mode!=="none"
      ?`<p class="hint">${icon("key")} ${generated()?"含认证信息，复制和发送会重新生成":"预览包含认证信息"}</p>`:"");
    if (responseTab==="curl" && preview?.firstHopOnly) {
      box.insertAdjacentHTML("beforeend",'<p class="hint">含认证的 cURL 只发送首跳。应用内可继续跟随同源跳转。</p>');
    }
  } else {
    const responseFailure=warning&&responseTab!=="curl";
    if (responseFailure) {title="请求或提取失败";emptyIcon="warning";}
    box.innerHTML=`<div class="empty ${responseFailure?"error":""}">${icon(emptyIcon)}<h3>${escape(title)}</h3>${warning?`<p>${escape(warning)}</p>`:""}</div>`;
  }
  if (responseTab!=="curl" && result?.redirectBlocked) {
    box.insertAdjacentHTML("afterbegin",`<p class="redirect-notice">${icon("warning")} 已停止跨站跳转，目标为 ${escape(result.redirectBlocked)}</p>`);
  }
  copy.hidden=!text||sending&&responseTab!=="curl";
  copy.disabled=!text;
  copy.innerHTML=icon(copied===responseTab?"check":"copy")+(copied===responseTab?"已复制":responseTab==="curl"?"复制命令":"复制");
}
function renderBanner() {
  by("storage-banner").hidden=!state.issue;
  by("storage-issue").textContent=state.issue;
  by("migrate").hidden=!state.locked;
  by("migrate").disabled=migrating;
  by("migrate").textContent=migrating?"等待钥匙串授权":"迁移认证";
}
function render() {renderAddress();renderSidebar();renderEditor();renderResponse();renderBanner();}
function stopPreview() {
  ++previewSequence;
  clearTimeout(previewTimer);
  if (previewTask) {
    previewTask=null;
    rpc("CancelPreview").catch(()=>{});
  }
}
async function requestPreview(snapshot) {
  const task=rpc("Preview",snapshot);
  previewTask=task;
  try { return await task; }
  finally { if (previewTask===task) previewTask=null; }
}
function schedulePreview() {
  stopPreview();
  const sequence=previewSequence;
  preview=null;previewError="";
  if (copied==="curl") copied="";
  if (responseTab!=="curl") return;
  if (!hasAddress()||state.locked) { renderResponse();return; }
  by("copy-result").disabled=true;
  previewTimer=setTimeout(async()=>{
    try {
      const command=await requestPreview(clone(draft));
      if (sequence!==previewSequence) return;
      preview=command;
    } catch (error) {
      if (sequence!==previewSequence) return;
      previewError=message(error);
    }
    if (responseTab==="curl") renderResponse();
  },generated()?180:90);
}
function changed() {renderAddress();schedulePreview();}


function closeMenu({restore=false}={}) {
  if (!menuAnchor) return;
  const anchor=menuAnchor;
  anchor.setAttribute("aria-expanded","false");
  menuAnchor=null;
  by("menu").hidden=true;
  if (restore && anchor.isConnected) anchor.focus();
}
function openMenu(anchor,options,{align="left",width=166}={}) {
  if (anchor===menuAnchor) {closeMenu();return;}
  closeMenu();
  menuAnchor=anchor;menuItems=options;
  const menu=by("menu");
  menu.style.width=width+"px";
  const bounds=anchor.getBoundingClientRect();
  menu.style.left=Math.max(8,Math.min(innerWidth-width-8,align==="right"?bounds.right-width:bounds.left))+"px";
  menu.style.top=Math.max(8,Math.min(innerHeight-options.length*34-20,bounds.bottom+6))+"px";
  menu.innerHTML=options.map((o,i)=>`<button type="button" role="menuitemradio" aria-checked="${!!o.selected}" data-option="${i}" ${o.choose?"":"disabled"} ${o.tone?`style="color:${o.tone}"`:""}>${o.dot?'<span class="dot"></span>':icon(o.icon)}<span>${escape(o.title)}</span>${o.selected?`<span class="tail">${icon("check")}</span>`:""}</button>`).join("");
  menu.hidden=false;
  anchor.setAttribute("aria-haspopup","menu");
  anchor.setAttribute("aria-expanded","true");
  (menu.querySelector('[aria-checked="true"]:not(:disabled)')??menu.querySelector("button:not(:disabled)"))?.focus();
}
by("menu").addEventListener("click",event=>{
  const option=event.target.closest("[data-option]");
  if (!option) return;
  const choose=menuItems[Number(option.dataset.option)]?.choose;
  closeMenu({restore:true}); choose?.();
});
by("menu").addEventListener("keydown",event=>{
  if (!["ArrowDown","ArrowUp","Home","End"].includes(event.key)) return;
  event.preventDefault();
  const buttons=[...by("menu").querySelectorAll("button:not(:disabled)")];
  const i=buttons.indexOf(document.activeElement);
  const target=event.key==="Home"?0:event.key==="End"?buttons.length-1
    : (i+(event.key==="ArrowDown"?1:-1)+buttons.length)%buttons.length;
  buttons[target]?.focus();
});
document.addEventListener("pointerdown",event=>{
  if (menuAnchor && !by("menu").contains(event.target) && !menuAnchor.contains(event.target)) closeMenu();
});
window.addEventListener("resize",()=>closeMenu());
function applyTheme() {
  document.documentElement.dataset.theme=theme==="system"?(systemTheme.matches?"dark":"light"):theme;
  by("theme-menu").innerHTML=icon(themes[theme][1])+"主题 "+icon("down");
  by("theme-menu").setAttribute("aria-label","主题，"+themes[theme][0]);
}
systemTheme.addEventListener("change",()=>{if(theme==="system")applyTheme();});
by("theme-menu").addEventListener("click",()=>{
  openMenu(by("theme-menu"),Object.entries(themes).map(([id,[title,glyph]])=>({
    title,icon:glyph,selected:id===theme,choose:async()=>{
      try{await rpc("SetTheme",id);theme=id;applyTheme();}
      catch(error){notify(message(error));}
    }
  })),{align:"right"});
});
by("method").addEventListener("click",()=>{
  openMenu(by("method"),Object.keys(methods).map(method=>({
    title:method,tone:palette(method),dot:true,selected:method===draft.method,
    choose:()=>{draft.method=method;renderEditor();changed();}
  })),{width:144});
});
by("minimize").addEventListener("click",()=>window.runtime?.WindowMinimise());
by("fullscreen").addEventListener("click",()=>rpc("ToggleFullscreen").catch(error=>notify(message(error))));
by("close-window").addEventListener("click",()=>window.runtime?.Quit());

function dialog(title,body,confirm,submit,{wide=false,destructive=false}={}) {
  closeMenu();
  const modal=by("dialog");
  dialogSubmit=submit;
  modal.className=wide?"wide":"";
  modal.innerHTML=`<h2 id="dialog-title">${escape(title)}</h2><form>
    ${body}<p class="dialog-error" aria-live="polite" hidden></p>
    <div class="dialog-actions"><button type="button" class="button" data-dismiss>取消</button>
    <button type="submit" class="button ${destructive?"destructive":"primary"}">${escape(confirm)}</button></div>
  </form>`;
  modal.setAttribute("aria-labelledby","dialog-title");
  modal.showModal();
  (modal.querySelector("textarea, input")??modal.querySelector("[data-dismiss]")).focus();
}
by("dialog").addEventListener("click",event=>{
  if (event.target.closest("[data-dismiss]")) by("dialog").close();
});
by("dialog").addEventListener("submit",async event=>{
  event.preventDefault();
  const form=event.target;
  const confirm=form.querySelector('[type="submit"]');
  if (confirm.disabled) return;
  const errorView=form.querySelector(".dialog-error");
  errorView.hidden=true;confirm.disabled=true;
  try {
    await dialogSubmit();
    by("dialog").close();
  } catch(error) {
    errorView.textContent=message(error);errorView.hidden=false;
  } finally {confirm.disabled=false;}
});
function confirm(title,body,button,action) {
  dialog(title,"<p>"+escape(body)+"</p>",button,action,{destructive:true});
}
function editRequest(kind, source=null) {
  let name="",categoryID=source?.categoryID??null, payload;
  let title;
  switch (kind) {
    case "new": title="新建请求";payload=newDraft();break;
    case "edit":title="改名或移动请求";name=source.name;payload=source.draft;break;
    case "duplicate":
      title="复制请求";name=source.name+" 副本";payload=source.id===savedID?draft:source.draft;break;
    default:
      title=source?"另存为":"保存请求";
      name=source?source.name+" 副本":draft.url.replace(/[?#].*$/,"").split("/").filter(Boolean).at(-1)??"";
      payload=draft;
  }
  const categories=[{id:null,name:"未分类"},...state.directory.categories];
  const categoryRows=categories.map((c,i)=>`<button type="button" class="folder" role="radio" data-category-choice="${i}" aria-checked="${c.id===categoryID}">${icon("folder")} ${escape(c.name)}</button>`).join("");
  const base=clone(payload);
  const before=activeSaved();
  const openCopy=kind!=="duplicate"||source.id===savedID||JSON.stringify(draft)===JSON.stringify(normalize(before?.draft??newDraft()));
  dialog(title,input("request-name",name,"请求名称","请求名称")+
    `<p style="margin:10px 0 0">分类</p><div class="category-options" role="radiogroup" aria-label="分类">${categoryRows}</div>`,
    "保存", async()=>{
      const title=by("request-name").value.trim();
      if (!title) throw Error("请输入请求名称。");
      const id=kind==="edit"?source.id:nextID();
      adopt(await rpc("SaveRequest",{id,name:title,categoryID,draft:base}));
      if (categoryID) collapsed.delete(categoryID);
      sidebar="directory";
      if (["new","duplicate"].includes(kind)&&openCopy) selectDraft(base,id);
      else {
        if (kind!=="duplicate") savedID=id;
        render();
      }
    }
  );
  by("dialog").querySelectorAll("[data-category-choice]").forEach(button=>button.addEventListener("click",()=>{
    categoryID=categories[Number(button.dataset.categoryChoice)].id;
    button.parentElement.querySelectorAll("button").forEach(node=>node.setAttribute("aria-checked",String(node===button)));
  }));
}
function newCategory() {
  dialog("新建分类",input("category-name","","分类名称","分类名称"),"保存",async()=>{
    adopt(await rpc("NewCategory",by("category-name").value));render();
  });
}
function importCurl() {
  dialog("导入 cURL",'<p>粘贴 cURL 命令，也支持带签名和响应提取的命令片段。</p><textarea id="curl-source" class="text-editor" aria-label="cURL 命令" spellcheck="false" placeholder="curl https://example.com"></textarea>',
    "导入",async()=>{
      if (!by("curl-source").value.trim()) throw Error("请粘贴以 curl 开头的命令。");
      selectDraft(await rpc("ImportCurl",by("curl-source").value));
    },{wide:true});
}
by("import").addEventListener("click",importCurl);

by("sidebar-menu").addEventListener("click",()=>{
  if (sidebar==="history") {
    const options=state.history.length ? [{
      title:sending?"发送中，稍后清空":"清空历史",icon:"trash",tone:"var(--red)",choose:sending?null:()=>{
        confirm("清空全部请求历史？","历史请求将被删除，请求目录里的项目会保留。","清空历史",async()=>{
          adopt(await rpc("ClearHistory"));if (!result) historyID=null;render();
        });
      }
    }] : [{title:"暂无请求历史",icon:"clock"}];
    openMenu(by("sidebar-menu"),options,{align:"right"});return;
  }
  const options=[{title:"新建分类",icon:"folder",choose:newCategory},{title:"新建请求",icon:"plus",choose:()=>editRequest("new")}];
  const saved=activeSaved();
  if(saved) options.push({title:"改名或移动请求",icon:"edit",choose:()=>editRequest("edit",saved)});
  openMenu(by("sidebar-menu"),options,{align:"right"});
});

by("sidebar-tabs").addEventListener("click",event=>{
  const button=event.target.closest("[data-tab]");
  if(button){sidebar=button.dataset.tab;closeMenu();renderSidebar();}
});
by("sidebar-list").addEventListener("click",async event=>{
  const folder=event.target.closest("button[data-category]");
  if (folder) {
    if (collapsed.has(folder.dataset.category)) collapsed.delete(folder.dataset.category);
    else collapsed.add(folder.dataset.category);
    renderSidebar();return;
  }
  const trigger=event.target.closest("[data-action]");
  if(!trigger)return;
  const row=trigger.closest("[data-request],[data-history]");
  const saved=state.directory.requests.find(r=>r.id===row.dataset.request);
  const entry=state.history.find(h=>h.id===row.dataset.history);
  switch(trigger.dataset.action) {
    case "open": if(saved&&!sending)selectDraft(saved.draft,saved.id);break;
    case "duplicate":if(saved)editRequest("duplicate",saved);break;
    case "delete":
      if(saved)confirm("删除「"+saved.name+"」？","这条请求将从目录移除，发送历史会保留。","删除请求",async()=>{
        adopt(await rpc("DeleteRequest",saved.id));
        if(savedID===saved.id)savedID=null;
        render();
      });
      break;
    case "history": {
      if(!entry||sending)break;
      selectDraft(entry.request,null,entry.id);
      if(!entry.environment)break;
      const opened=draft;
      const snapshot=JSON.stringify(draft);
      try{
        const restored=await rpc("OpenHistory",entry.id);
        if(!sending&&draft===opened&&snapshot===JSON.stringify(draft))selectDraft(restored,null,entry.id);
      }catch(error){notify(message(error));}
      break;
    }
    case "copy-history":if(entry)copyText(entry.request.url).then(()=>notify("已复制请求地址")).catch(error=>notify(message(error)));break;
  }
});
by("history-query").addEventListener("input",renderSidebar);
by("sidebar-list").addEventListener("dragstart",event=>{
  const row=event.target.closest("[data-request]");
  if(!row || sending || state.locked){event.preventDefault();return;}
  dragged=row.dataset.request;
  event.dataTransfer.setData("application/x-apidog-request",dragged);
  event.dataTransfer.effectAllowed="move";
  row.classList.add("dragging");
});
function clearDrag() {
  dragged=null;
  by("sidebar-list").querySelectorAll(".folder.target,.saved-row.dragging").forEach(node=>node.classList.remove("target","dragging"));
}
by("sidebar-list").addEventListener("dragover",event=>{
  const folder=event.target.closest("[data-category]");
  if(!dragged || !folder)return;
  event.preventDefault();
  event.dataTransfer.dropEffect="move";
  by("sidebar-list").querySelectorAll(".folder.target").forEach(node=>node.classList.toggle("target",node===folder));
  folder.classList.add("target");
});
by("sidebar-list").addEventListener("dragleave",event=>{
  const folder=event.target.closest("[data-category]");
  if(folder&&!folder.contains(event.relatedTarget))folder.classList.remove("target");
});
by("sidebar-list").addEventListener("drop",async event=>{
  const folder=event.target.closest("[data-category]");
  if(!dragged || !folder)return;
  event.preventDefault();
  const id=dragged, category=folder.dataset.category||null;
  clearDrag();
  try{adopt(await rpc("MoveRequest",id,category));collapsed.delete(category);render();}
  catch(error){notify(message(error));}
});
by("sidebar-list").addEventListener("dragend",clearDrag);

let saving=false;
async function saveCurrent() {
  if(state.locked||sending||saving||by("dialog").open)return;
  const saved=activeSaved();
  if(!saved){if(hasAddress())editRequest("save");return;}
  saving=true;
  try{adopt(await rpc("SaveRequest",{...saved,draft:clone(draft)}));sidebar="directory";render();}
  catch(error){notify(message(error));}
  finally{saving=false;}
}
by("save").addEventListener("click",saveCurrent);
by("save-as").addEventListener("click",()=>editRequest("save",activeSaved()));
by("address").addEventListener("input",event=>{
  draft.url=event.target.value;
  if(variableNames().length){
    requestTab="variables";renderEditor();
  }else if(requestTab==="variables")renderEditor();
  changed();
});
by("redirects").addEventListener("change",event=>{draft.followsRedirects=event.target.checked;changed();});
by("request-tabs").addEventListener("click",event=>{
  const button=event.target.closest("[data-tab]");
  if(button){requestTab=button.dataset.tab;closeMenu();renderEditor();}
});
by("response-tabs").addEventListener("click",event=>{
  const button=event.target.closest("[data-tab]");
  if(!button || responseTab===button.dataset.tab)return;
  responseTab=button.dataset.tab;
  copied="";
  if(responseTab!=="curl")stopPreview();
  renderResponse();
  if(responseTab==="curl"&&!preview&&!previewError&&!sending)schedulePreview();
});

function currentFields() {
  if(requestTab==="query")return draft.query;
  if(requestTab==="headers")return draft.headers;
  return (draft.auth.scriptInputs??=[]);
}
by("editor").addEventListener("input",event=>{
  const {id,value}=event.target;
  let type;
  if(id.startsWith("variable-")){
    const name=variableNames()[Number(id.slice(9))];
    if(name)draft.variables[name]=value;
  } else if ((type=/^field-(name|value)-(\d+)$/.exec(id))) {
    currentFields()[Number(type[2])][type[1]]=value;
  } else if (id==="body-text") {
    if(value==="")delete draft.body;else draft.body=value;
  } else if (id==="projection") {
    draft.projection=value.trim();
  } else if (id==="resolve" || id==="no-proxy") {
    draft.route??={};draft.route[id==="resolve"?"resolve":"noProxy"]=value.trim();
    if(!draft.route.resolve&&!draft.route.noProxy)delete draft.route;
  } else {
    const key={"auth-name":"name","auth-secret":"secret","auth-key-field":"signingKeyField","auth-uri":"signingURI","script-text":"script"}[id];
    if(!key)return;
    draft.auth[key]=value;
  }
  changed();
});
by("editor").addEventListener("click",event=>{
  const button=event.target.closest("button");
  if(!button)return;
  if(button.id==="auth-mode"){
    openMenu(button,Object.entries(authOptions).map(([mode,title])=>({
      title,icon:"key",selected:mode===draft.auth.mode,choose:()=>{
        if(mode===draft.auth.mode)return;
        draft.auth={mode,name:mode==="apiKey"?"X-API-Key":""};
        if(mode==="script")draft.auth.scriptInputs=[{id:nextID(),name:"token"}];
        renderEditor();changed();
      }
    })),{width:188});return;
  }
  if(button.id==="auth-location"){
    openMenu(button,Object.entries(locations).map(([key,title])=>({title,selected:key===authLocation(),choose:()=>{
      draft.auth.placement=key;renderEditor();changed();
    }})),{width:188});return;
  }
  if(!button.dataset.edit)return;
  const fields=currentFields();
  const index=Number(button.closest("[data-row]")?.dataset.row);
  switch(button.dataset.edit){
    case "add":fields.push({id:nextID(),name:"",value:""});break;
    case "remove":fields.splice(index,1);break;
  }
  renderEditor();changed();
  if(button.dataset.edit==="add")by("field-name-"+(fields.length-1)).focus();
});

async function copyText(text) {
  if(window.runtime?.ClipboardSetText) {
    if(await window.runtime.ClipboardSetText(text)===false)throw Error("无法复制文本。");
  } else await navigator.clipboard.writeText(text);
}
by("copy-result").addEventListener("click",async()=>{
  const tab=responseTab;
  const sequence=previewSequence;
  try{
    let text=tab==="curl"?preview?.command:tab==="headers"?result?.headers:tab==="extracted"?result?.extracted:result?.body;
    if(tab==="curl"&&generated()){
      const current=await requestPreview(clone(draft));
      if(sequence!==previewSequence||responseTab!==tab)return;
      preview=current;
      text=current.command;
    }
    if(!text)return;
    await copyText(text);
    if(responseTab===tab&&(tab!=="curl"||sequence===previewSequence)){copied=tab;renderResponse();}
  } catch(error){if(tab!=="curl"||sequence===previewSequence)notify(message(error));}
});

async function sendOrCancel() {
  if(sending){await rpc("Cancel");return;}
  if(!hasAddress()||state.locked||by("dialog").open)return;
  closeMenu();
  stopPreview();
  sending=true;cancelled=false;failure="";result=null;elapsed=0;copied="";
  responseTab=draft.projection?"extracted":"body";
  render();
  try {
    const reply=await rpc("Send",clone(draft));
    adopt(reply.state);
    historyID=reply.historyID??null;
    result=reply.response;
    elapsed=reply.milliseconds;
    failure=reply.error??"";
    cancelled=!!reply.cancelled;
    if(reply.curl){++previewSequence;preview=reply.curl;previewError="";}
    if(cancelled||result?.redirectBlocked)responseTab="body";
  }catch(error){failure=message(error);}
  finally{sending=false;render();}
}
by("address-bar").addEventListener("submit",event=>{event.preventDefault();sendOrCancel().catch(error=>notify(message(error)));});
by("migrate").addEventListener("click",async()=>{
  if(migrating)return;
  migrating=true;renderBanner();
  try{
    adopt(await rpc("Migrate"));
    const saved=activeSaved();
    if(saved)selectDraft(saved.draft,saved.id);
  }catch(error){state.issue="迁移认证失败。"+message(error);}
  finally{migrating=false;render();}
});
document.addEventListener("keydown",event=>{
  if(event.key==="Escape"&&menuAnchor){closeMenu({restore:true});return;}
  if(by("dialog").open||!event.metaKey)return;
  if(event.key==="Enter"){event.preventDefault();sendOrCancel().catch(error=>notify(message(error)));}
  if(event.key.toLowerCase()==="s"){
    event.preventDefault();
    if(event.shiftKey&&activeSaved()&&!state.locked&&!sending)editRequest("save",activeSaved());else saveCurrent();
  }
});

by("save").innerHTML=icon("save")+"保存";
by("import").innerHTML=icon("import")+"导入 cURL";
by("minimize").innerHTML=icon("minus");
by("fullscreen").innerHTML=icon("expand");
by("close-window").innerHTML=icon("close");
by("request-heading").innerHTML=icon("edit")+"请求参数";
by("search-icon").innerHTML=icon("search");
applyTheme();
render();
Promise.all([rpc("State"),rpc("Theme")]).then(([data,mode])=>{
  adopt(data);
  if(themes[mode])theme=mode;
  applyTheme();render();
}).catch(error=>{
  state.issue=message(error);renderBanner();
});
