(function () {
"use strict";
var cs = new CSInterface();
var fs = require("fs"), path = require("path"), http = require("http"), cp = require("child_process");

var LOG_DIR = (process.env.LOCALAPPDATA || "") + "\\PremiereExtensionLauncher\\logs";
try { fs.mkdirSync(LOG_DIR, { recursive: true }); } catch(e) {}
var LOG_FILE = path.join(LOG_DIR, "cep-bridge.log");

function log(msg) {
  var line = new Date().toISOString().replace("T"," ").slice(0,19) + "  " + msg + "\n";
  try { fs.appendFileSync(LOG_FILE, line); } catch(e) {}
}

function reply(res, code, obj) {
  var b = JSON.stringify(obj);
  res.writeHead(code, {"Content-Type":"application/json; charset=utf-8",
                       "Access-Control-Allow-Origin":"*",
                       "Access-Control-Allow-Headers":"Content-Type"});
  res.end(b);
}

function manifestInfo(file) {
  try {
    var s = fs.readFileSync(file, "utf8");
    var id = (s.match(/<Extension\s+Id="([^"]+)"/i)||[])[1] || "";
    var menu = (s.match(/<Menu>([\s\S]*?)<\/Menu>/i)||[])[1] || "";
    var name = (s.match(/ExtensionBundleName="([^"]*)"/i)||[])[1] || "";
    var ver = (s.match(/ExtensionBundleVersion="([^"]*)"/i)||[])[1] || "";
    return {id:id, name:(menu||name).trim(), version:ver};
  } catch(e) { return null; }
}

function scan() {
  var roots = [
    (process.env.APPDATA||"") + "\\Adobe\\CEP\\extensions",
    (process.env.ProgramFiles||"") + "\\Common Files\\Adobe\\CEP\\extensions",
    (process.env["ProgramFiles(x86)"]||"") + "\\Common Files\\Adobe\\CEP\\extensions"
  ];
  var out=[], seen={};
  roots.forEach(function(root) {
    try {
      var dirs = fs.readdirSync(root,{withFileTypes:true});
      dirs.forEach(function(d) {
        if(!d.isDirectory()) return;
        var folder=path.join(root,d.name), mf=path.join(folder,"CSXS","manifest.xml");
        if(!fs.existsSync(mf)) return;
        var m=manifestInfo(mf); if(!m || !m.id || seen[m.id]) return;
        seen[m.id]=1;
        out.push({kind:"CEP", id:m.id, name:m.name||d.name, version:m.version, folder:folder});
      });
    } catch(e) {}
  });
  return out.sort(function(a,b){return a.name.localeCompare(b.name);});
}

function tellCatalog() {
  var exts = scan();
  log("Catalog scan: " + exts.length + " extensions");
  try {
    var data=JSON.stringify({source:"cep", extensions:exts});
    var req=http.request({hostname:"127.0.0.1",port:17364,path:"/catalog/cep",method:"POST",
      headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(data)}});
    req.on("error",function(e){ log("tellCatalog error: " + e.message); });
    req.end(data);
  } catch(e) { log("tellCatalog error: " + e.message); }
}

// --- Ensure desktop launcher is running ---
var launcherStarted = false;
var launcherPath = (process.env.LOCALAPPDATA || "") + "\\PremiereExtensionLauncher\\launcher.ps1";

function checkLauncherRunning(callback) {
  var req = http.request({hostname:"127.0.0.1",port:17364,path:"/health",method:"GET",timeout:2000}, function(res) {
    var body = "";
    res.on("data", function(c) { body += c; });
    res.on("end", function() {
      try {
        var obj = JSON.parse(body);
        callback(obj.ok === true);
      } catch(e) { callback(false); }
    });
  });
  req.on("error", function() { callback(false); });
  req.on("timeout", function() { req.destroy(); callback(false); });
  req.end();
}

function startLauncher() {
  if (launcherStarted) return;
  checkLauncherRunning(function(running) {
    if (running) {
      log("Launcher already running.");
      launcherStarted = true;
      tellCatalog();
      return;
    }
    if (!fs.existsSync(launcherPath)) {
      log("Launcher script not found at " + launcherPath);
      return;
    }
    log("Starting launcher.");
    try {
      var child = cp.spawn("powershell.exe",
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", launcherPath],
        { windowsHide: true, detached: false, stdio: "ignore" });
      child.unref();
      launcherStarted = true;
      // Wait a moment then send catalog
      setTimeout(function() { tellCatalog(); }, 3000);
    } catch(e) {
      log("Launcher start exception: " + e.message);
    }
  });
}

// --- HTTP server for CEP bridge ---
var server=http.createServer(function(req,res) {
  if(req.method==="OPTIONS") return reply(res,204,{});
  if(req.url==="/ping") return reply(res,200,{ok:true,source:"cep"});
  if(req.url==="/extensions") return reply(res,200,{extensions:scan()});
  if(req.url.indexOf("/open?id=")===0) {
    var id=decodeURIComponent(req.url.slice(9).split("&")[0]);
    log("Open requested: " + id);
    try { cs.requestOpenExtension(id,""); return reply(res,200,{ok:true,id:id}); }
    catch(e){ log("Open error: " + e.message); return reply(res,500,{ok:false,error:String(e)}); }
  }
  reply(res,404,{ok:false,error:"not found"});
});

try {
  server.listen(17363,"127.0.0.1", function() {
    log("CEP bridge listening on 17363");
  });
} catch(e) { log("Server listen error: " + e.message); }

// Start launcher, send catalog once after startup
log("CEP bridge loaded.");
startLauncher();

})();