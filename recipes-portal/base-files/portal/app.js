async function loadSsids() {
  const response = await fetch('/scan');
  const data = await response.json();
  const list = document.getElementById('ssid-list');
  list.innerHTML = '';
  data.ssids.forEach((ssid) => {
    const option = document.createElement('option');
    option.value = ssid;
    list.appendChild(option);
  });

  if (!data.ssids.length) {
    document.getElementById('result').textContent = data.message || 'No SSIDs discovered. You can still enter SSID manually.';
  }
}

const STREAM_STATUS_LABELS = {
  streaming: 'Live',
  starting: 'Starting',
  retrying: 'Retrying',
  recovering: 'Recovering',
  error: 'Error',
  idle: 'Idle',
};

const STREAM_STATUS_COLORS = {
  streaming: '#0f766e',
  starting: '#1d4ed8',
  retrying: '#d97706',
  recovering: '#7c3aed',
  error: '#dc2626',
  idle: '#64748b',
};

async function loadState() {
  const response = await fetch('/state');
  const data = await response.json();
  document.getElementById('device-id').textContent = data.device_id || '-';
  document.getElementById('pair-status').textContent = data.paired ? 'Paired' : 'Not paired';
  document.getElementById('pair-code').textContent = data.pair_code || '-';
  document.getElementById('pair-expiry').textContent = data.pair_code_expires_at || '-';
  const backendLink = document.getElementById('backend-link');
  backendLink.textContent = data.backend_http || '-';
  backendLink.href = data.backend_http || '#';
  const status = data.stream_status || '';
  const badge = document.getElementById('stream-status-badge');
  badge.textContent = status ? (STREAM_STATUS_LABELS[status] || status) : '-';
  badge.style.color = STREAM_STATUS_COLORS[status] || '#94a3b8';
  document.getElementById('stream-detail-el').textContent = data.stream_detail || '';
  return data;
}

function hydrateConfigFields(data) {
  document.getElementById('backend_http').value = data.backend_http || '';
  document.getElementById('name').value = data.name || '';
  document.getElementById('video_device').value = data.video_device || '/dev/video0';
}

loadSsids();
loadState().then(hydrateConfigFields).catch(() => {});
setInterval(() => {
  loadState().catch(() => {});
}, 5000);
document.getElementById('refresh').addEventListener('click', loadSsids);

document.getElementById('download-logs').addEventListener('click', async () => {
  const resultEl = document.getElementById('result');
  resultEl.textContent = 'Preparing log bundle...';
  try {
    const response = await fetch('/logs/download');
    if (!response.ok) {
      const err = await response.json().catch(() => ({}));
      throw new Error(err.message || 'Failed to generate logs');
    }
    const blob = await response.blob();
    const disposition = response.headers.get('Content-Disposition') || '';
    const match = disposition.match(/filename=\"?([^\";]+)\"?/);
    const filename = match ? match[1] : 'spektrum-logs.tar.gz';
    const linkUrl = window.URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = linkUrl;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.URL.revokeObjectURL(linkUrl);
    resultEl.textContent = 'Logs downloaded.';
  } catch (err) {
    resultEl.textContent = 'Log download failed: ' + err.message;
  }
});

async function confirmAction(question, endpoint, successMsg) {
  if (!confirm(question)) return;
  const resultEl = document.getElementById('result');
  try {
    const response = await fetch(endpoint, { method: 'POST' });
    const data = await response.json().catch(() => ({}));
    resultEl.textContent = data.message || successMsg;
    await loadState().catch(() => {});
  } catch (err) {
    resultEl.textContent = 'Error: ' + err.message;
  }
}

document.getElementById('unpair').addEventListener('click', () =>
  confirmAction(
    'Clear local pairing state? Wi-Fi settings are kept. The device will re-register and show a new pairing code. To also remove the device from the web app, use the Unpair button there.',
    '/unpair',
    'Local pairing cleared. Device will re-register on next connection.'
  )
);

document.getElementById('factory-reset').addEventListener('click', () =>
  confirmAction(
    'Factory reset? This will erase ALL settings including Wi-Fi and backend URL. The device will restart in provisioning (AP) mode.',
    '/factory-reset',
    'Factory reset complete. Device will restart in provisioning mode.'
  )
);

const form = document.getElementById('provision-form');
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const payload = {
    ssid: document.getElementById('ssid').value,
    password: document.getElementById('password').value,
    backend_http: document.getElementById('backend_http').value,
    name: document.getElementById('name').value,
    video_device: document.getElementById('video_device').value,
  };

  const response = await fetch('/configure', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  const result = await response.json().catch(() => ({}));
  document.getElementById('result').textContent = result.message || 'Saved';
  await loadState().catch(() => {});
});
