// Isolated-world half: owns the WebSocket to the RematchBridge app (not subject to the
// page's Content-Security-Policy) and relays messages to page.js via DOM events.
(() => {
  const URL = "ws://127.0.0.1:37121";
  let ws = null;
  let retry = 500;

  const toPage = (msg) =>
    document.dispatchEvent(new CustomEvent("rematchbridge:fromapp", { detail: JSON.stringify(msg) }));

  const send = (msg) => {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  };

  const focused = () => document.visibilityState === "visible" && document.hasFocus();
  let lastFocus = null;
  const reportFocus = () => {
    const f = focused();
    if (f !== lastFocus) { lastFocus = f; send({ t: "f", focused: f }); }
  };

  function connect() {
    ws = new WebSocket(URL);
    ws.onopen = () => { retry = 500; lastFocus = null; reportFocus(); };
    ws.onmessage = (e) => { try { toPage(JSON.parse(e.data)); } catch (_) {} };
    ws.onclose = () => {
      toPage({ t: "c", connected: false });
      setTimeout(connect, retry);
      retry = Math.min(retry * 2, 5000);
    };
    ws.onerror = () => {};
  }

  document.addEventListener("rematchbridge:toapp", (e) => {
    try { send(JSON.parse(e.detail)); } catch (_) {}
  });
  for (const ev of ["visibilitychange", "focus", "blur"]) window.addEventListener(ev, reportFocus, true);
  document.addEventListener("visibilitychange", reportFocus);
  setInterval(reportFocus, 1000);

  connect();
})();
