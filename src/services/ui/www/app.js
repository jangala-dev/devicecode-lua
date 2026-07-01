const retained = new Map();
const $ = sel => document.querySelector(sel);
const pretty = value => value == null ? 'Not reported' : JSON.stringify(value, null, 2);
const topicKey = topic => Array.isArray(topic) ? topic.join('/') : '';

async function json(path, opts) {
  const res = await fetch(path, opts);
  if (!res.ok) throw new Error(`${path}: ${res.status}`);
  return res.json();
}

async function bootstrap() {
  const body = await json('/api/local-ui/bootstrap', { cache: 'no-store' });
  retained.clear();
  for (const [key, item] of Object.entries(body.items || {})) retained.set(key, item);
  renderOverview();
}

function connectEvents() {
  const es = new EventSource('/events');
  const apply = ev => {
    try {
      const msg = JSON.parse(ev.data);
      const key = topicKey(msg.topic);
      if (!key) return;
      const op = msg.op || msg.kind;
      if (op === 'delete' || op === 'unretain') retained.delete(key);
      else retained.set(key, { topic: msg.topic, payload: msg.payload, origin: msg.origin });
      renderOverview();
    } catch (err) {
      console.error(err);
    }
  };
  for (const name of ['set', 'retain', 'delete', 'unretain']) es.addEventListener(name, apply);
  es.onopen = () => { $('#connection').textContent = 'Live'; };
  es.onerror = () => { $('#connection').textContent = 'Offline'; };
}

function byPrefix(prefix) {
  return [...retained.entries()].filter(([key]) => key === prefix || key.startsWith(`${prefix}/`)).map(([, item]) => item);
}

function card(title, value) {
  return `<article class="card"><h3>${title}</h3><pre>${escapeHtml(pretty(value))}</pre></article>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));
}

function renderOverview() {
  const payload = key => retained.get(key)?.payload;
  $('#cards').innerHTML = [
    card('Network summary', payload('state/net/summary')),
    card('WAN runtime', payload('state/net/wan_runtime') || payload('state/net/wan')),
    card('GSM', Object.fromEntries(byPrefix('state/gsm').map(item => [item.topic.join('/'), item.payload]))),
    card('Updates', payload('state/update/summary')),
  ].join('');

  $('#components').innerHTML = byPrefix('state/device/component').map(item => `
    <div class="item"><strong>${escapeHtml(item.topic.join('/'))}</strong><pre>${escapeHtml(pretty(item.payload))}</pre></div>
  `).join('') || '<p>No component state reported.</p>';
}

async function loadApns() {
  const tbody = $('#apn-table');
  $('#apn-status').textContent = 'Loading APNs...';
  try {
    const records = await json('/api/gsm/apns/custom');
    window.__apns = Array.isArray(records) ? records : [];
    tbody.innerHTML = window.__apns.map((apn, index) => `
      <tr>
        <td>${escapeHtml(apn.carrier || '')}</td>
        <td>${escapeHtml(apn.mcc || '')}</td>
        <td>${escapeHtml(apn.mnc || '')}</td>
        <td>${escapeHtml(apn.apn || '')}</td>
        <td><button class="secondary" data-remove="${index}">Remove</button></td>
      </tr>
    `).join('');
    $('#apn-status').textContent = `${window.__apns.length} custom APN record(s).`;
  } catch (err) {
    $('#apn-status').textContent = `APN service unavailable: ${err.message}`;
  }
}

async function saveApns(records) {
  const res = await fetch('/api/gsm/apns/custom', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(records),
  });
  if (!res.ok) throw new Error(await res.text());
  await loadApns();
}

$('#apn-form').addEventListener('submit', async ev => {
  ev.preventDefault();
  const data = Object.fromEntries(new FormData(ev.currentTarget).entries());
  for (const key of Object.keys(data)) if (String(data[key]).trim() === '') delete data[key];
  try {
    await saveApns([...(window.__apns || []), data]);
    ev.currentTarget.reset();
  } catch (err) {
    alert(`Could not save APN: ${err.message}`);
  }
});

$('#apn-table').addEventListener('click', async ev => {
  const button = ev.target.closest('button[data-remove]');
  if (!button) return;
  const index = Number(button.dataset.remove);
  const next = [...(window.__apns || [])];
  next.splice(index, 1);
  try { await saveApns(next); } catch (err) { alert(`Could not remove APN: ${err.message}`); }
});

$('#run-diagnostics').addEventListener('click', async () => {
  $('#diagnostics-result').textContent = 'Running...';
  try { $('#diagnostics-result').textContent = pretty(await json('/api/diagnostics')); }
  catch (err) { $('#diagnostics-result').textContent = err.message; }
});

bootstrap().catch(err => { $('#connection').textContent = 'Error'; console.error(err); });
connectEvents();
loadApns();
