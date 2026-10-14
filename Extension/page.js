// Page-world half: adds a standard-mapping Xbox gamepad to navigator.getGamepads().
(() => {
  if (window.__rematchBridge) return;
  window.__rematchBridge = true;

  const realGetGamepads = navigator.getGamepads ? navigator.getGamepads.bind(navigator) : () => [];
  const ID = "Xbox 360 Controller (XInput STANDARD GAMEPAD)";
  let pad = null;          // our Gamepad-like object while the controller is connected
  let lastJSON = "";

  const toApp = (msg) =>
    document.dispatchEvent(new CustomEvent("rematchbridge:toapp", { detail: JSON.stringify(msg) }));

  const makeButton = (value) => {
    const b = Object.create(window.GamepadButton ? GamepadButton.prototype : Object.prototype);
    Object.defineProperties(b, {
      pressed: { value: value > 0.1, enumerable: true },
      touched: { value: value > 0, enumerable: true },
      value: { value, enumerable: true },
    });
    return b;
  };

  const actuator = {
    type: "dual-rumble",
    effects: ["dual-rumble", "trigger-rumble"],
    playEffect(type, p = {}) {
      toApp({ t: "r", strong: +p.strongMagnitude || 0, weak: +p.weakMagnitude || 0, duration: +p.duration || 0 });
      return Promise.resolve("complete");
    },
    reset() {
      toApp({ t: "r", strong: 0, weak: 0, duration: 0 });
      return Promise.resolve("complete");
    },
  };

  const freeIndex = () => {
    const real = Array.from(realGetGamepads() || []);
    for (let i = 0; i < 4; i++) if (!real[i]) return i;
    return real.length;
  };

  function build(index, buttons, axes) {
    const g = Object.create(window.Gamepad ? Gamepad.prototype : Object.prototype);
    Object.defineProperties(g, {
      id: { value: ID, enumerable: true },
      index: { value: index, enumerable: true },
      connected: { value: true, enumerable: true },
      mapping: { value: "standard", enumerable: true },
      timestamp: { value: performance.now(), enumerable: true },
      axes: { value: Object.freeze(axes.slice()), enumerable: true },
      buttons: { value: Object.freeze(buttons.map(makeButton)), enumerable: true },
      vibrationActuator: { value: actuator, enumerable: true },
      hapticActuators: { value: [], enumerable: true },
    });
    return g;
  }

  const fire = (type, g) => {
    const ev = new Event(type);
    Object.defineProperty(ev, "gamepad", { value: g });
    window.dispatchEvent(ev);
  };

  navigator.getGamepads = function getGamepads() {
    const out = Array.from(realGetGamepads() || []);
    if (pad) {
      while (out.length <= pad.index) out.push(null);
      out[pad.index] = pad;
    }
    return out;
  };

  document.addEventListener("rematchbridge:fromapp", (e) => {
    let msg;
    try { msg = JSON.parse(e.detail); } catch (_) { return; }
    if (msg.t === "s" && Array.isArray(msg.b) && Array.isArray(msg.a)) {
      const json = e.detail;
      const wasConnected = !!pad;
      const index = pad ? pad.index : freeIndex();
      // Keep the timestamp unchanged for identical heartbeat frames.
      if (wasConnected && json === lastJSON) return;
      lastJSON = json;
      pad = build(index, msg.b.slice(0, 18), msg.a.slice(0, 4));
      if (!wasConnected) fire("gamepadconnected", pad);
    } else if (msg.t === "c" && msg.connected === false && pad) {
      const gone = pad;
      pad = null;
      lastJSON = "";
      const g = Object.create(Object.getPrototypeOf(gone));
      Object.defineProperties(g, {
        id: { value: ID, enumerable: true },
        index: { value: gone.index, enumerable: true },
        connected: { value: false, enumerable: true },
      });
      fire("gamepaddisconnected", g);
    }
  });
})();
