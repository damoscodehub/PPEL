const { pluginManager } = require("uxp");

const BASE = "http://127.0.0.1:17364";
let busy = false;

function buildCatalog() {
  const result = [];
  for (const p of Array.from(pluginManager.plugins || [])) {
    if (!p || p.id === "com.premiere.extensionlauncher.uxpbridge") continue;
    const m = p.manifest || {};
    const eps = Array.isArray(m.entrypoints) ? m.entrypoints : [];
    for (const ep of eps) {
      if (!ep || !ep.id) continue;
      let label = ep.label;
      if (label && typeof label === "object") label = label.default || Object.values(label)[0];
      result.push({
        kind: "UXP",
        pluginId: p.id,
        pluginName: p.name || m.name || p.id,
        enabled: !!p.enabled,
        entrypointId: ep.id,
        entrypointType: ep.type || "unknown",
        name: label || ep.id,
        version: p.version || m.version || ""
      });
    }
  }
  return result.sort((a,b)=>a.name.localeCompare(b.name));
}

async function post(path, body) {
  try {
    await fetch(BASE + path, {
      method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify(body)
    });
  } catch(e) {}
}

async function sync() {
  if (busy) return;
  busy = true;
  try {
    await post("/catalog/uxp", {source:"uxp", extensions:buildCatalog()});
    const r = await fetch(BASE + "/uxp/next");
    if (!r.ok) return;
    const cmd = await r.json();
    if (!cmd || !cmd.command) return;
    const p = Array.from(pluginManager.plugins || []).find(x=>x && x.id===cmd.pluginId);
    if (!p || !p.enabled) {
      await post("/uxp/result", {ok:false,error:"Plugin not available or disabled",command:cmd});
      return;
    }
    try {
      if (cmd.entrypointType === "panel") {
        await p.showPanel(cmd.entrypointId);
      } else {
        await p.invokeCommand(cmd.entrypointId);
      }
      await post("/uxp/result", {ok:true,command:cmd});
    } catch(e) {
      await post("/uxp/result", {ok:false,error:String(e),command:cmd});
    }
  } finally { busy = false; }
}
setInterval(sync, 250);
sync();