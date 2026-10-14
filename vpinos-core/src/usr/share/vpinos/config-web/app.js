"use strict";
// VPinOS Configuration UI. No build step, no dependencies -- same pattern
// as vpxconfig's own web/app.js (h() hyperscript builder, full-DOM-replace
// render()), right-sized for one flat page instead of a multi-step wizard.

const HEADERS = { "Content-Type": "application/json", "X-VPinOS-Config": "1" };
const api = {
  get: (p) => fetch(p).then((r) => r.json()),
  send: (method, p, body) => fetch(p, { method, headers: HEADERS, body: JSON.stringify(body || {}) }).then((r) => r.json()),
};

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, "");
    else if (v !== false && v != null) el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid != null) el.append(kid);
  return el;
}

let meta = null;
let monitors = [];   // last /api/state fetch's monitor list: [{name,id,description,geometry,rates,rate,role}]
let draft = null;    // editable snapshot, exactly the /api/save body shape
let lastSaved = null; // JSON string of draft right after a load/save, to detect unsaved edits
let identifying = false;
let statusMsg = null; // {text, kind: "ok" | "err"}

function draftFromState(state) {
  const roles = {}, rates = {};
  for (const m of state.monitors) {
    roles[m.name] = m.role || "";
    rates[m.name] = m.rate;
  }
  return {
    roles,
    rates,
    vpinballMode: state.vpinballMode,
    cabinetAutofitMode: state.cabinetAutofitMode,
    screenFields: { ...state.screenFields },
    fulldmd: state.fulldmd,
    syncMode: state.syncMode,
    maxFramerate: state.maxFramerate,
    maxPrerenderedFrames: state.maxPrerenderedFrames,
  };
}

async function load() {
  const state = await api.get("/api/state");
  monitors = state.monitors;
  draft = draftFromState(state);
  lastSaved = JSON.stringify(draft);
}

function isDirty() {
  return JSON.stringify(draft) !== lastSaved;
}

// ---- sections ---------------------------------------------------------------

function header() {
  return h("div", { class: "header" },
    h("h1", {}, "VPinOS Configuration"),
    h("p", { class: "muted" }, "Press SHOW to identify a screen, then select its role."));
}

function optionRow(opt, selected, onSelect, groupName) {
  return h("label", { class: "option" },
    h("input", {
      type: "radio", name: groupName, value: opt.value, checked: selected === opt.value,
      onchange: () => { onSelect(opt.value); render(); },
    }),
    h("div", { class: "text-col" },
      h("div", { class: "option-name" }, opt.name),
      opt.description ? h("p", { class: "muted" }, opt.description) : null));
}

function monitorRow(m) {
  const roleOpts = meta.roles.map((role) => h("label", { class: "radio" },
    h("input", {
      type: "radio", name: "role-" + m.name, value: role, checked: draft.roles[m.name] === role,
      onchange: () => { draft.roles[m.name] = role; render(); },
    }),
    h("span", {}, role)));
  const rateOpts = m.rates.map((rate) => h("label", { class: "radio" },
    h("input", {
      type: "radio", name: "rate-" + m.name, value: String(rate), checked: draft.rates[m.name] === rate,
      onchange: () => { draft.rates[m.name] = rate; render(); },
    }),
    h("span", {}, String(rate))));
  return h("div", { class: "row card-row" },
    h("div", { class: "col monitor" },
      h("div", { class: "mon-name" }, m.name, h("span", { class: "muted small" }, ` (ID ${m.id})`)),
      h("div", { class: "muted small" }, `${m.description || ""}   |   ${m.geometry}`)),
    h("div", { class: "col show" },
      h("button", { class: "show", type: "button", disabled: identifying, onclick: () => onShow(m.name) }, "SHOW")),
    h("div", { class: "col role" }, roleOpts),
    h("div", { class: "col rate" }, rateOpts));
}

function monitorTable() {
  return h("div", { class: "table" },
    h("div", { class: "row head" },
      h("div", { class: "col monitor" }, "MONITOR"),
      h("div", { class: "col show" }, "IDENTIFY"),
      h("div", { class: "col role" }, "ROLE"),
      h("div", { class: "col rate" }, "REFRESH RATE")),
    monitors.map(monitorRow));
}

function modeSection() {
  return h("div", { class: "mode-card" },
    h("div", { class: "section-title" }, "VPinball Mode"),
    h("div", { class: "mode-radios" },
      ["Desktop", "Cabinet"].map((mode) => h("label", { class: "radio mode" },
        h("input", {
          type: "radio", name: "vpinballMode", value: mode, checked: draft.vpinballMode === mode,
          onchange: () => { draft.vpinballMode = mode; render(); },
        }),
        h("span", {}, mode)))));
}

function renderingOptions() {
  const mf = meta.maxFramerateField;
  return h("div", { class: "card section" },
    h("div", { class: "section-title" }, "Rendering Options"),
    h("div", { class: "sub" }, "Synchronization"),
    meta.syncModeOptions.map((opt) => optionRow(opt, draft.syncMode, (v) => { draft.syncMode = v; }, "syncMode")),
    h("div", { class: "sub" }, mf.name),
    h("div", { class: "card-row field" },
      h("div", { class: "text-col" }, h("p", { class: "muted" }, mf.description)),
      h("input", {
        type: "text", class: "num-input", value: draft.maxFramerate,
        oninput: (e) => { draft.maxFramerate = e.target.value; },
      })),
    h("div", { class: "sub" }, "Max. Prerendered Frames"),
    meta.maxPrerenderedFramesOptions.map((opt) =>
      optionRow(opt, draft.maxPrerenderedFrames, (v) => { draft.maxPrerenderedFrames = v; }, "maxPrerenderedFrames")));
}

function cabinetExtras() {
  if (draft.vpinballMode !== "Cabinet") return null;
  return h("div", { class: "card section" },
    h("div", { class: "section-title" }, "Cabinet Autofit Mode"),
    meta.cabinetAutofitOptions.map((opt) =>
      optionRow(opt, draft.cabinetAutofitMode, (v) => { draft.cabinetAutofitMode = v; }, "cabinetAutofitMode")),
    h("div", { class: "section-title", style: "margin-top:24px;" }, "Screen Dimensions"),
    h("p", { class: "muted", style: "margin:0 4px 10px;" },
      'Needed for Autofit ("Fit Table"/"Fit Screen") -- Manual mode ignores these.'),
    meta.screenDimensionFields.map((f) => h("div", { class: "card-row field" },
      h("div", { class: "text-col" },
        h("div", { class: "option-name" }, f.name),
        h("p", { class: "muted" }, f.description)),
      h("input", {
        type: "text", class: "num-input", value: draft.screenFields[f.key] || "",
        oninput: (e) => { draft.screenFields[f.key] = e.target.value; },
      }))),
    h("div", { class: "section-title", style: "margin-top:24px;" }, "Full DMD"),
    h("label", { class: "option" },
      h("input", {
        type: "checkbox", checked: draft.fulldmd,
        onchange: (e) => { draft.fulldmd = e.target.checked; render(); },
      }),
      h("div", { class: "text-col" },
        h("div", { class: "option-name" }, "Full DMD"),
        h("p", { class: "muted" }, meta.fulldmdDescription))));
}

function statusLine() {
  if (!statusMsg) return h("div", { class: "status" });
  return h("div", { class: "status " + statusMsg.kind }, statusMsg.text);
}

function buttons() {
  return h("div", { class: "button-row" },
    h("button", { class: "save", type: "button", onclick: onSave }, "Save"),
    h("button", { class: "quit", type: "button", onclick: onQuit }, "Quit"));
}

function render() {
  const root = document.getElementById("app");
  root.replaceChildren(...[
    header(),
    monitorTable(),
    modeSection(),
    renderingOptions(),
    cabinetExtras(),
    statusLine(),
    buttons(),
  ].filter(Boolean));
}

// ---- actions -----------------------------------------------------------------

async function onShow(name) {
  if (identifying) return;
  identifying = true;
  render();
  let result;
  try {
    result = await api.send("POST", "/api/show", { name });
  } catch (e) {
    result = { error: String(e) };
  }
  if (result.error) {
    identifying = false;
    statusMsg = { text: result.error, kind: "err" };
    render();
    return;
  }
  setTimeout(() => { identifying = false; render(); }, (result.seconds || 0) * 1000);
}

async function onSave() {
  let result;
  try {
    result = await api.send("POST", "/api/save", draft);
  } catch (e) {
    statusMsg = { text: String(e), kind: "err" };
    render();
    return;
  }
  if (result.error) {
    statusMsg = { text: result.error, kind: "err" };
    render();
    return;
  }
  await load();
  statusMsg = { text: result.message, kind: "ok" };
  render();
}

async function onQuit() {
  if (isDirty() && !confirm("You have unsaved changes -- quit anyway?")) return;
  document.getElementById("app").replaceChildren(
    h("div", { class: "stopped" }, "VPinOS Configuration stopped. You can close this window."));
  try { await api.send("POST", "/api/shutdown", {}); } catch (e) { /* server may already be closing */ }
}

document.addEventListener("keydown", (e) => { if (e.key === "Escape") onQuit(); });

(async function init() {
  meta = await api.get("/api/meta");
  await load();
  render();
})();
