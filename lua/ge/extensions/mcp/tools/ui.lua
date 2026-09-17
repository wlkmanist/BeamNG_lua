-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- UI tools: read/navigate UI state, dump the Vue/Pinia state, show user messages.

local shared = require('mcp/shared')
local M = {}

-- JS injected into the UI (CEF) to snapshot route + Pinia stores and send it back.
local VUE_DUMP_JS = [[(function(){try{
var out={route:null,stores:{}};
try{out.route=window.bngVue&&window.bngVue.getCurrentRoute&&window.bngVue.getCurrentRoute();}catch(e){}
var app=window.bngVue&&window.bngVue.app;
var pinia=app&&app.config&&app.config.globalProperties&&app.config.globalProperties.$pinia;
if(pinia&&pinia._s){pinia._s.forEach(function(s,id){try{out.stores[id]=s.$state;}catch(e){out.stores[id]="[err]";}});}
var seen=new WeakSet();
var json=JSON.stringify(out,function(k,v){if(typeof v==="function")return undefined;if(v&&typeof v==="object"){if(seen.has(v))return "[circular]";seen.add(v);}return v;});
window.beamng.sendEngineLua("extensions.mcp_tools._cb.vueDump("+bngApi.serializeToLua(json)+")");
}catch(e){window.beamng.sendEngineLua("extensions.mcp_tools._cb.vueDump("+bngApi.serializeToLua("error: "+e)+")");}})();]]

-- Wrap a JS body so its return value comes back to GE as _cb.uiEval. Uses a depth/breadth
-- bounded serializer (Vue reactive proxies defeat cycle detection and overflow JSON.stringify).
local UI_EVAL_JS = [[(function(){function clean(v,d){if(v==null)return v;var t=typeof v;if(t==='function')return undefined;if(t!=='object')return v;if(typeof Node!=='undefined'&&v instanceof Node)return '<'+(v.tagName||v.nodeName)+(v.id?'#'+v.id:'')+(v.className&&v.className.baseVal===undefined&&typeof v.className==='string'&&v.className?'.'+v.className.trim().split(/\s+/).join('.'):'')+'>';if(d>=5)return Array.isArray(v)?'[array]':'[object]';var out,i;if(Array.isArray(v)){out=[];for(i=0;i<v.length&&i<200;i++)out.push(clean(v[i],d+1));return out;}out={};var n=0;for(var k in v){if(n++>=100)break;try{out[k]=clean(v[k],d+1);}catch(e){out[k]='[err]';}}return out;}
try{var __r=(function(){%s})();window.beamng.sendEngineLua('extensions.mcp_tools._cb.uiEval('+bngApi.serializeToLua(__r===undefined?'undefined':JSON.stringify(clean(__r,0)))+')');}catch(e){window.beamng.sendEngineLua('extensions.mcp_tools._cb.uiEval('+bngApi.serializeToLua('error: '+e)+')');}})();]]

local function jstr(s) return jsonEncode(tostring(s)) end -- a safe JS string literal
local function selVar(selector, nth) return "var els=document.querySelectorAll(" .. jstr(selector) .. ");var el=els[" .. ((tonumber(nth) or 1) - 1) .. "];" end
local function fire(js) be:executeJS("(function(){try{" .. js .. "}catch(e){}})();") end

M.cb = {
  vueDump = function(s) shared.asyncResults.vue = s end,
  uiEval = function(s) shared.asyncResults.ui = s end,
}

function M.get_ui_state()
  local route = extensions.ui_router and extensions.ui_router.getState and extensions.ui_router.getState()
  local gs = core_gamestate and core_gamestate.getGameState and core_gamestate.getGameState()
  return jsonEncode({ route = route, gameState = gs }), false
end

function M.set_ui_state(args)
  local route = args and args.route
  if type(route) ~= "string" then return "missing 'route' (e.g. 'menu', 'menu.vehicles')", true end
  if not (extensions.ui_router and extensions.ui_router.navigate) then return "ui_router unavailable", true end
  extensions.ui_router.navigate(route, args.params)
  return "navigated to " .. route, false
end

function M.dump_vue_state()
  local prev = shared.asyncResults.vue
  be:executeJS(VUE_DUMP_JS)
  if prev then shared.asyncResults.vue = nil; return prev, false end
  return "vue state requested (async); call again in a moment to get it", false
end

-- Show/hide the game UI (like Alt+U). show=true/false sets explicitly; omit to toggle.
function M.toggle_ui(args)
  local uv = extensions.ui_visibility
  if not (uv and uv.toggle) then return "ui_visibility unavailable", true end
  if args and args.show ~= nil then uv.set(args.show == true) else uv.toggle() end
  return "ui visible: " .. tostring(uv.get()), false
end

-- Show a message in the in-game message app (reuse a category for progress updates).
function M.show_message(args)
  local text = args and args.text
  if type(text) ~= "string" then return "missing 'text'", true end
  ui_message(text, tonumber(args and args.ttl) or 5, (args and args.category) or "mcp", (args and args.icon) or "info")
  return "shown: " .. text, false
end

-- Run JS in the UI (CEF) and return its value as JSON. The Swiss-army UI-test tool:
-- query the DOM, read component state, assert results. Async: call again for the result.
-- Provide a JS body; use 'return X' for a value (a bare expression is auto-returned).
function M.ui_eval(args)
  local js = args and args.js
  if type(js) ~= "string" or js == "" then return "missing 'js'", true end
  if shared.asyncResults.ui ~= nil then
    local r = shared.asyncResults.ui; shared.asyncResults.ui = nil
    return r, false
  end
  local body = js:find("return") and js or ("return (" .. js .. ")")
  be:executeJS(string.format(UI_EVAL_JS, body))
  return "ui_eval dispatched (async); call again in a moment for the result", false
end

-- Click an element (CSS selector, nth match 1-based): full pointer+mouse+click sequence at its center.
function M.ui_click(args)
  args = args or {}
  if type(args.selector) ~= "string" then return "missing 'selector'", true end
  local b = (args.button == "right" or args.button == 2) and 2 or ((args.button == "middle" or args.button == 1) and 1 or 0)
  local seq = args.doubleClick and "['pointerdown','mousedown','pointerup','mouseup','click','dblclick']" or "['pointerdown','mousedown','pointerup','mouseup','click']"
  fire(selVar(args.selector, args.nth) ..
    "if(!el)return;el.scrollIntoView&&el.scrollIntoView({block:'center'});var r=el.getBoundingClientRect();" ..
    "var o={bubbles:true,cancelable:true,view:window,clientX:r.left+r.width/2,clientY:r.top+r.height/2,button:" .. b .. "};" ..
    "el.focus&&el.focus();" .. seq .. ".forEach(function(t){var C=t.indexOf('pointer')===0?PointerEvent:MouseEvent;el.dispatchEvent(new C(t,o));});" ..
    (b == 2 and "el.dispatchEvent(new MouseEvent('contextmenu',o));" or ""))
  return "click dispatched to '" .. args.selector .. "'" .. (args.nth and (" [#" .. args.nth .. "]") or "") .. " (verify with ui_eval)", false
end

-- Scroll-wheel an element. deltaY>0 scrolls down; default 120 if no delta given.
function M.ui_scroll(args)
  args = args or {}
  if type(args.selector) ~= "string" then return "missing 'selector'", true end
  local dx, dy = tonumber(args.deltaX) or 0, tonumber(args.deltaY) or 0
  if dx == 0 and dy == 0 then dy = 120 end
  fire(selVar(args.selector, args.nth) .. "if(!el)return;el.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,view:window,deltaX:" .. dx .. ",deltaY:" .. dy .. "}));")
  return "wheel(" .. dx .. "," .. dy .. ") dispatched to '" .. args.selector .. "'", false
end

-- Type into an input/textarea/contenteditable: sets the value and fires input+change (drives v-model).
function M.ui_type(args)
  args = args or {}
  if type(args.selector) ~= "string" then return "missing 'selector'", true end
  if type(args.text) ~= "string" then return "missing 'text'", true end
  local v = args.clear == false and ("(el.value||'')+" .. jstr(args.text)) or jstr(args.text)
  local ce = args.clear == false and ("(el.textContent||'')+" .. jstr(args.text)) or jstr(args.text)
  fire(selVar(args.selector, args.nth) .. "if(!el)return;el.focus&&el.focus();if('value' in el){el.value=" .. v .. ";}else{el.textContent=" .. ce .. ";}el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));")
  return "typed into '" .. args.selector .. "'", false
end

-- Dispatch a keyboard event (default keydown+keyup) to a selector, else the active element.
function M.ui_key(args)
  args = args or {}
  if type(args.key) ~= "string" then return "missing 'key' (e.g. 'Enter','Escape','ArrowDown','a')", true end
  local types = args.event == "down" and "['keydown']" or args.event == "up" and "['keyup']" or args.event == "press" and "['keydown','keypress','keyup']" or "['keydown','keyup']"
  local target = args.selector and (selVar(args.selector, args.nth) .. "el=el||document.activeElement||document.body;") or "var el=document.activeElement||document.body;"
  fire(target .. "if(!el)return;var k={key:" .. jstr(args.key) .. ",code:" .. jstr(args.key) .. ",bubbles:true,cancelable:true};" .. types .. ".forEach(function(t){el.dispatchEvent(new KeyboardEvent(t,k));});")
  return "key '" .. args.key .. "' dispatched" .. (args.selector and (" to '" .. args.selector .. "'") or " to active element"), false
end

-- Hover an element (pointer/mouse over + move), e.g. to reveal tooltips or hover menus.
function M.ui_hover(args)
  args = args or {}
  if type(args.selector) ~= "string" then return "missing 'selector'", true end
  fire(selVar(args.selector, args.nth) .. "if(!el)return;var r=el.getBoundingClientRect();var o={bubbles:true,cancelable:true,view:window,clientX:r.left+r.width/2,clientY:r.top+r.height/2};['pointerover','mouseover','pointerenter','mouseenter','pointermove','mousemove'].forEach(function(t){var C=t.indexOf('pointer')===0?PointerEvent:MouseEvent;el.dispatchEvent(new C(t,o));});")
  return "hover dispatched to '" .. args.selector .. "'", false
end

M.schemas = {
  ui_eval = {
    description = "Run JavaScript in the UI (CEF) and return its value as JSON (the main UI-test/assert tool: query the DOM, read component state). Provide a JS body; use 'return X' (a bare expression is auto-returned). Async: call again in a moment for the result. Examples: \"document.querySelectorAll('.bng-button').length\", \"return [...document.querySelectorAll('button')].map(b=>b.textContent.trim())\".",
    inputSchema = { type = "object", properties = { js = { type = "string", description = "JS body to evaluate in the UI" } }, required = { "js" } },
  },
  ui_click = {
    description = "Click a UI element by CSS selector (full pointerdown/mousedown/up/click sequence at its center). Fire-and-forget; assert the effect with ui_eval or dump_vue_state.",
    inputSchema = { type = "object", properties = {
      selector = { type = "string", description = "CSS selector" },
      nth = { type = "integer", description = "1-based index when the selector matches several (default 1)" },
      button = { description = "'left'(0)/'middle'(1)/'right'(2); right also fires contextmenu" },
      doubleClick = { type = "boolean", description = "Also fire dblclick" },
    }, required = { "selector" } },
  },
  ui_scroll = {
    description = "Dispatch a mouse wheel event to an element. deltaY>0 scrolls down (default 120 if no delta given).",
    inputSchema = { type = "object", properties = {
      selector = { type = "string" }, deltaY = { type = "number" }, deltaX = { type = "number" }, nth = { type = "integer" },
    }, required = { "selector" } },
  },
  ui_type = {
    description = "Type text into an input/textarea/contenteditable: sets the value and fires input+change (drives Vue v-model). clear=false appends instead of replacing.",
    inputSchema = { type = "object", properties = {
      selector = { type = "string" }, text = { type = "string" }, clear = { type = "boolean", description = "Replace existing value (default true)" }, nth = { type = "integer" },
    }, required = { "selector", "text" } },
  },
  ui_key = {
    description = "Dispatch a keyboard event to a selector (or the active element if none). Default keydown+keyup.",
    inputSchema = { type = "object", properties = {
      key = { type = "string", description = "KeyboardEvent.key, e.g. 'Enter','Escape','ArrowDown','a'" },
      selector = { type = "string", description = "Target element (default: active element)" },
      event = { type = "string", description = "'down'/'up'/'press'/both (default both)" },
      nth = { type = "integer" },
    }, required = { "key" } },
  },
  ui_hover = {
    description = "Hover an element (pointer/mouse over + move), e.g. to reveal tooltips or hover menus.",
    inputSchema = { type = "object", properties = { selector = { type = "string" }, nth = { type = "integer" } }, required = { "selector" } },
  },
  get_ui_state = { description = "Current UI state as JSON: router route/scope (ui_router) plus gameplay mode (core_gamestate)." },
  set_ui_state = {
    description = "Navigate the UI to a route (ui_router.navigate).",
    inputSchema = { type = "object", properties = {
      route = { type = "string", description = "Route name, e.g. 'menu' or 'menu.vehicles'" },
      params = { type = "object", description = "Optional route params" },
    }, required = { "route" } },
  },
  dump_vue_state = { description = "Dump the UI Vue state (current route + Pinia stores) as JSON. Async: call again in a moment to receive the snapshot." },
  toggle_ui = {
    description = "Show/hide the game UI (like Alt+U). Pass show=true/false to set explicitly, or omit to toggle.",
    inputSchema = { type = "object", properties = { show = { type = "boolean", description = "true=show, false=hide, omit=toggle" } } },
  },
  show_message = {
    description = "Show a message in the in-game message app. Reuse the same category for progress updates (replaces the previous message).",
    inputSchema = { type = "object", properties = {
      text = { type = "string" },
      ttl = { type = "number", description = "Seconds to show (default 5)" },
      category = { type = "string", description = "Group id; same category replaces the prior message (default 'mcp')" },
      icon = { type = "string", description = "Material icon name (default 'info')" },
    }, required = { "text" } },
  },
}

return M
