/* Real Chrome checks, using Node's built-in WebSocket/CDP. No npm packages or owner profile. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const http = require("node:http");
const {spawn} = require("node:child_process");
const {once} = require("node:events");
const root = path.resolve(__dirname, "..");
const site = path.join(root, "site");
const content = JSON.parse(fs.readFileSync(path.join(root, "docs/website/guides.json"), "utf8"));
const chromePath = process.env.PATHEM_DOCS_CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const artifacts = process.env.PATHEM_DOCS_CAPTURES || fs.mkdtempSync(path.join(os.tmpdir(), "pathem-docs-captures-"));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "pathem-docs-browser-"));
let chrome, socket, server;
let checks = 0, assertionsPassed = false;
function check(name, condition) { assert.ok(condition, name); checks++; console.log("DOCSBROWSER PASS " + name); }
function stopOwnedBrowser() {
  // Chrome gets a dedicated process group. Its network helper can outlive Browser.close;
  // never match a browser by name or touch an owner's existing profile/process group.
  if (!chrome?.pid) return;
  try { process.kill(-chrome.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
}
const timeout = setTimeout(() => { console.error("DOCSBROWSER FAIL 120-second bound exceeded"); stopOwnedBrowser(); process.exit(1); }, 120000);

async function run() {
  fs.mkdirSync(artifacts, {recursive: true});
  server = http.createServer((request, response) => {
    let filename = path.resolve(site, "." + decodeURIComponent(new URL(request.url, "http://localhost").pathname));
    if (!(filename === site || filename.startsWith(site + path.sep))) { response.writeHead(403).end(); return; }
    if (fs.existsSync(filename) && fs.statSync(filename).isDirectory()) filename = path.join(filename, "index.html");
    if (!fs.existsSync(filename)) { response.writeHead(404).end("Not found"); return; }
    const types = {".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp"};
    response.writeHead(200, {"Content-Type": types[path.extname(filename)] || "application/octet-stream"});
    fs.createReadStream(filename).pipe(response);
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const base = "http://127.0.0.1:" + server.address().port;
  chrome = spawn(chromePath, ["--headless=new", "--disable-gpu", "--remote-debugging-port=0", "--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-extensions", "about:blank"], {detached: true, stdio: ["ignore", "ignore", "pipe"]});
  const endpoint = await new Promise((resolve, reject) => {
    let stderr = "";
    const timer = setTimeout(() => reject(new Error("Chrome did not expose its test endpoint")), 15000);
    chrome.once("error", reject);
    chrome.stderr.on("data", chunk => {
      stderr += chunk;
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    chrome.once("exit", code => { clearTimeout(timer); reject(new Error("Chrome exited before connection: " + code)); });
  });
  socket = new WebSocket(endpoint); await once(socket, "open");
  let nextID = 0;
  const pending = new Map(), events = new Map(), exceptions = [];
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const request = pending.get(message.id); pending.delete(message.id); clearTimeout(request.timer);
      if (message.error) request.reject(new Error(JSON.stringify(message.error))); else request.resolve(message.result);
    } else if (message.method) {
      if (message.method === "Runtime.exceptionThrown") exceptions.push(message.params.exceptionDetails.text);
      const key = message.sessionId + ":" + message.method;
      for (const callback of events.get(key) || []) callback(message.params);
      events.delete(key);
    }
  });
  function send(method, params = {}, sessionId) {
    const id = ++nextID;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error("CDP timeout: " + method)); }, 10000);
      pending.set(id, {resolve, reject, timer}); socket.send(JSON.stringify({id, method, params, sessionId}));
    });
  }
  const {targetId} = await send("Target.createTarget", {url: "about:blank"});
  const {sessionId} = await send("Target.attachToTarget", {targetId, flatten: true});
  await send("Page.enable", {}, sessionId); await send("Runtime.enable", {}, sessionId); await send("Network.enable", {}, sessionId);
  async function evaluate(expression) {
    const result = await send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, sessionId);
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  async function navigate(url) {
    const loaded = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Page did not load: " + url)), 10000);
      events.set(sessionId + ":Page.loadEventFired", [() => { clearTimeout(timer); resolve(); }]);
    });
    await send("Page.navigate", {url: base + url}, sessionId); await loaded;
  }
  async function viewport(width, dark) {
    await send("Emulation.setDeviceMetricsOverride", {width, height: 900, deviceScaleFactor: 1, mobile: width < 700}, sessionId);
    await send("Emulation.setEmulatedMedia", {features: [{name: "prefers-color-scheme", value: dark ? "dark" : "light"}]}, sessionId);
  }
  async function waitFor(expression) {
    return evaluate(`new Promise((resolve, reject) => {
      const ready = () => { if (${expression}) { observer.disconnect(); clearTimeout(timer); resolve(true); } };
      const observer = new MutationObserver(ready);
      const timer = setTimeout(() => {observer.disconnect(); reject(new Error('Expected DOM state not delivered'));}, 5000);
      observer.observe(document, {subtree:true, attributes:true, childList:true, characterData:true}); ready();
    })`);
  }
  async function layout(name) {
    const state = await evaluate(`(() => {
      const h1 = document.querySelector('h1'); const box = h1.getBoundingClientRect();
      return {width:innerWidth, scroll:document.documentElement.scrollWidth, h1:!!h1,
        inside:box.left>=0 && box.right<=innerWidth+1,
        content:document.querySelector('main')?.innerText.length || 0,
        nav:innerWidth<700 ? getComputedStyle(document.querySelector('.sidebar')).display==='none'
          : getComputedStyle(document.querySelector('.mobile-nav')).display==='none'};
    })()`);
    check(name + " no horizontal overflow", state.scroll <= state.width + 1);
    check(name + " readable content and navigation", state.h1 && state.inside && state.content > 800 && state.nav);
  }
  async function capture(name) {
    const {data} = await send("Page.captureScreenshot", {format: "png", captureBeyondViewport: false}, sessionId);
    fs.writeFileSync(path.join(artifacts, name + ".png"), Buffer.from(data, "base64"));
  }

  for (const width of [1280, 390, 320]) {
    await viewport(width, true); await navigate("/");
    check("landing-page guide link visible at " + width, await evaluate(`(() => {
      const link = document.querySelector('.nav-links a[href="/docs/"]');
      const rect = link.getBoundingClientRect();
      return rect.width>20 && rect.height>10 && rect.left>=0 && rect.right<=innerWidth+1;
    })()`));
  }
  // Sample/control criteria are documented before the full page matrix. Stop on any failed control.
  await viewport(1280, true); await navigate("/docs/");
  await waitFor("document.getElementById('search-status').textContent.includes('21 guides')");
  await layout("desktop sample");
  await evaluate("document.body.style.minWidth='2000px'");
  check("instrument rejects synthetic clipping", await evaluate("document.documentElement.scrollWidth > innerWidth + 1"));
  await evaluate("document.body.style.minWidth=''"); await layout("restored good control");
  await capture("index-desktop-dark");
  for (const dark of [true, false]) {
    await viewport(1280, dark);
    check("body/link/secondary contrast " + (dark ? "dark" : "light"), await evaluate(`(() => {
      const luminance = color => {
        const rgb = color.match(/[\\d.]+/g).slice(0,3).map(Number).map(value => value/255)
          .map(value => value<=.04045 ? value/12.92 : ((value+.055)/1.055)**2.4);
        return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;
      };
      const background = luminance(getComputedStyle(document.body).backgroundColor);
      return ['main h1','main .lead','main a'].every(selector => {
        const foreground = luminance(getComputedStyle(document.querySelector(selector)).color);
        return (Math.max(background,foreground)+.05)/(Math.min(background,foreground)+.05)>=4.5;
      });
    })()`));
  }
  await viewport(390, false); await navigate("/docs/views-dates/"); await layout("mobile sample");
  check("mobile topics initially collapsed", await evaluate("!document.querySelector('.mobile-nav').open"));
  await evaluate("document.querySelector('.mobile-nav summary').click()");
  check("mobile topics expand with usable link", await evaluate("document.querySelector('.mobile-nav').open && document.querySelector('.mobile-nav a[href=\"/docs/copy-move/\"]').getBoundingClientRect().height > 20"));
  await evaluate("document.querySelector('.mobile-nav summary').click()");
  await capture("dates-mobile-light");
  console.log("DOCSBROWSER SAMPLE PASS: good/bad instrument and actual mobile treatment delivered; starting full page matrix");

  for (const width of [1280, 390, 320]) {
    await viewport(width, width === 1280);
    for (const guide of content.guides) { await navigate("/docs/" + guide.id + "/"); await layout(width + " " + guide.id); }
  }
  await viewport(1280, false); await navigate("/docs/views-dates/"); await capture("dates-desktop-light");
  await viewport(390, true); await navigate("/docs/");
  await waitFor("document.getElementById('search-status').textContent.includes('21 guides')");
  await capture("index-mobile-dark");
  for (const [query, wanted] of [["relative dates", "/docs/views-dates/"], ["Android", "/docs/cloud-devices/"], ["clipboard", "/docs/copy-move/"]]) {
    await evaluate(`document.getElementById('guide-query').value=${JSON.stringify(query)}; document.getElementById('guide-query').dispatchEvent(new Event('input',{bubbles:true}))`);
    check("real search " + query, await evaluate(`!document.getElementById('search-results').hidden && !!document.querySelector('#search-results a[href=${JSON.stringify(wanted)}]')`));
  }
  await evaluate("document.getElementById('guide-query').value='<img src=x onerror=alert(1)>'; document.getElementById('guide-query').dispatchEvent(new Event('input',{bubbles:true}))");
  check("no-result and injection control", await evaluate("document.getElementById('search-status').textContent==='0 guides found.' && !document.querySelector('img[src=x]')"));
  await evaluate("document.querySelector('#search-results button').click()");
  check("clear restores real directory", await evaluate("!document.getElementById('guide-directory').hidden && document.getElementById('guide-query').value==='' && !new URL(location.href).searchParams.has('q')"));
  await evaluate("document.getElementById('guide-query').blur()");
  await send("Input.dispatchKeyEvent", {type: "keyDown", key: "/", code: "Slash", text: "/"}, sessionId);
  check("slash keyboard focus", await evaluate("document.activeElement.id==='guide-query'"));
  await evaluate("document.getElementById('guide-query').value='Android'; document.getElementById('guide-query').dispatchEvent(new Event('input',{bubbles:true}))");
  await send("Input.dispatchKeyEvent", {type: "keyDown", key: "Escape", code: "Escape"}, sessionId);
  check("Escape clears search without hiding guides", await evaluate("document.getElementById('guide-query').value==='' && !document.getElementById('guide-directory').hidden"));
  await navigate("/docs/?q=Yesterday"); await waitFor("!document.getElementById('search-results').hidden");
  check("shareable search URL", await evaluate("!!document.querySelector('#search-results a[href=\"/docs/views-dates/\"]')"));
  await send("Network.setBlockedURLs", {urls: ["*/docs/search-index.json*"]}, sessionId);
  await navigate("/docs/"); await waitFor("document.getElementById('search-status').textContent.includes('unavailable')");
  check("failed search keeps guides browsable", await evaluate("!document.getElementById('guide-directory').hidden && document.querySelectorAll('#guide-directory .guide-card').length===21"));
  await send("Network.setBlockedURLs", {urls: []}, sessionId);
  await send("Emulation.setScriptExecutionDisabled", {value: true}, sessionId);
  await navigate("/docs/");
  const tree = await send("Accessibility.getFullAXTree", {}, sessionId);
  check("JavaScript disabled still exposes guide content", tree.nodes.some(node => node.name?.value === "Learn your way around.") && tree.nodes.some(node => node.name?.value === "Views, sorting, grouping, and relative dates"));
  await send("Emulation.setScriptExecutionDisabled", {value: false}, sessionId);
  check("no uncaught browser errors", exceptions.length === 0);
  await send("Browser.close");
  assertionsPassed = true;
}

run().catch(error => { console.error("DOCSBROWSER RESULT FAIL", error); process.exitCode = 1; }).finally(async () => {
  clearTimeout(timeout); socket?.close();
  if (chrome && chrome.exitCode === null) {
    await Promise.race([once(chrome, "exit"), new Promise(resolve => setTimeout(resolve, 3000))]);
    if (chrome.exitCode === null) stopOwnedBrowser();
  }
  stopOwnedBrowser();
  server?.closeAllConnections(); server?.close();
  if (chrome?.pid) {
    await new Promise((resolve, reject) => {
      const deadline = Date.now() + 3000;
      function verifyClosed() {
        try { process.kill(-chrome.pid, 0); } catch (error) {
          if (error.code === "ESRCH") { resolve(); return; }
          reject(error); return;
        }
        if (Date.now() >= deadline) { reject(new Error("Owned Chrome group did not close")); return; }
        setTimeout(verifyClosed, 25);
      }
      verifyClosed();
    }).catch(error => { console.error("DOCSBROWSER RESULT FAIL", error); process.exitCode = 1; });
  }
  // Only our unique, disposable browser profile. Never an owner Chrome profile.
  fs.rmSync(profile, {recursive: true, force: true});
  if (assertionsPassed && !process.exitCode) {
    check("owned browser group actually closed", true);
    console.log("DOCSBROWSER RESULT PASS " + checks + " checks; captures " + artifacts);
  }
});
