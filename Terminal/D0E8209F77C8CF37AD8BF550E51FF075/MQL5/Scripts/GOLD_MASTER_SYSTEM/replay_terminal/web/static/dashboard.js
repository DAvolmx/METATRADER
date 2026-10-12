/**
 * dashboard.js — Gold Master Dashboard integrado
 * Panel en tiempo real: cuenta MT5 · reglas · hipótesis · EAs · analytics
 */
"use strict";

const Dashboard = (() => {
  let _timer = null;
  let _equityHistory = [];

  const qs  = (sel, root = document) => root.querySelector(sel);
  const fmt2 = v => (v == null ? "—" : Number(v).toFixed(2));
  const fmtPct = v => (v == null ? "—" : (Number(v)*100).toFixed(1)+"%");
  const scoreColor = s => s >= 0.75 ? "#26a69a" : s >= 0.55 ? "#f59e0b" : "#ef5350";
  const stateChip = st => ({
    TESTING:"🔬 Testing", VALIDATED:"✅ Validada",
    REJECTED:"❌ Rechazada", INSUFFICIENT:"⏳ Datos insuf.", PENDING:"⏳ Pendiente"
  }[st] || st);

  // ── equity mini-chart (Canvas 2D) ─────────────────────────────────
  function drawEquity(canvas, history) {
    if (!canvas || history.length < 2) return;
    const ctx = canvas.getContext("2d");
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);
    const vals = history.map(p => p.equity);
    const minV = Math.min(...vals), maxV = Math.max(...vals);
    const range = maxV - minV || 1;
    const pad = 4;
    const toY = v => H - pad - ((v - minV) / range) * (H - 2*pad);
    const toX = i => pad + (i / (history.length-1)) * (W - 2*pad);
    const lineCol = vals[vals.length-1] >= vals[0] ? "#26a69a" : "#ef5350";
    ctx.beginPath();
    ctx.moveTo(toX(0), H);
    history.forEach((p,i) => ctx.lineTo(toX(i), toY(p.equity)));
    ctx.lineTo(toX(history.length-1), H);
    ctx.closePath();
    ctx.fillStyle = lineCol + "22"; ctx.fill();
    ctx.beginPath();
    history.forEach((p,i) => i===0 ? ctx.moveTo(toX(i),toY(p.equity)) : ctx.lineTo(toX(i),toY(p.equity)));
    ctx.strokeStyle = lineCol; ctx.lineWidth = 1.5; ctx.stroke();
    const isDark = document.documentElement.dataset.theme === "dark";
    ctx.fillStyle = isDark ? "#9598a1" : "#6b7280"; ctx.font = "10px sans-serif";
    ctx.textAlign = "left";  ctx.fillText("$"+minV.toFixed(0), pad+1, H-pad-1);
    ctx.textAlign = "right"; ctx.fillText("$"+maxV.toFixed(0), W-pad-1, pad+10);
  }


  // ── render principal ──────────────────────────────────────────────
  function render(data, root) {
    const mt5   = {...(data.mt5 || {}), ...((data.mt5 || {}).account || {})};
    const research = data.research || {};
    const rules = data.active_rules || [];
    const hyps  = data.hypotheses   || [];
    const eas   = data.ea_status    || [];
    const ana   = data.analytics    || {};

    // track equity history
    if (mt5.equity != null) {
      _equityHistory.push({ t: data.ts, equity: mt5.equity });
      if (_equityHistory.length > 200) _equityHistory.shift();
    }

    root.innerHTML = `
<div class="db-section">
  <div class="db-title">📊 Cuenta MT5</div>
  <div class="db-cards">
    <div class="db-card"><span class="db-label">Balance</span><span class="db-val">${fmt2(mt5.balance)} ${mt5.currency||""}</span></div>
    <div class="db-card"><span class="db-label">Equity</span><span class="db-val">${fmt2(mt5.equity)} ${mt5.currency||""}</span></div>
    <div class="db-card"><span class="db-label">Margen libre</span><span class="db-val">${fmt2(mt5.margin_free)}</span></div>
    <div class="db-card"><span class="db-label">Drawdown</span><span class="db-val" style="color:${mt5.drawdown_pct>5?'#ef5350':'inherit'}">${mt5.drawdown_pct!=null?(mt5.drawdown_pct.toFixed(1)+'%'):'—'}</span></div>
    <div class="db-card"><span class="db-label">Modo</span><span class="db-val">${mt5.mode||'—'}</span></div>
    <div class="db-card"><span class="db-label">Servidor</span><span class="db-val db-small">${mt5.server||'—'}</span></div>
  </div>
  <canvas id="dbEquityCanvas" width="340" height="60" style="display:block;margin:6px 0 0;border-radius:4px;background:var(--bg2)"></canvas>
</div>

<div class="db-section">
  <div class="db-title">⚡ EAs compilados</div>
  <div class="db-eas">
    ${eas.map(ea => `
      <div class="db-ea ${ea.compiled?'ok':'err'}">
        <span class="db-ea-dot">${ea.compiled?'●':'○'}</span>
        <span class="db-ea-name">${ea.name.replace('GOLD_MASTER_','').replace('_EA','')}</span>
        ${ea.mtime ? `<span class="db-ea-ts">${new Date(ea.mtime*1000).toLocaleDateString()}</span>` : '<span class="db-ea-ts muted">—</span>'}
      </div>`).join('')}
  </div>
</div>

<div class="db-section">
  <div class="db-title">📐 Reglas activas <span class="db-badge">${rules.length}</span>
    <span class="db-fresh ${ana.fresh?'on':'off'}">${ana.fresh?'●':'○'} Analytics</span>
  </div>
  ${rules.length === 0
    ? '<p class="db-empty">Sin reglas — corre gm_rules_db.py para promover hipótesis validadas.</p>'
    : `<table class="db-table">
        <thead><tr><th>Regla</th><th>TF</th><th>Score</th><th>WR</th><th>PF</th><th>N</th></tr></thead>
        <tbody>
          ${rules.map(r=>`<tr>
            <td class="db-rulename" title="${r.asset}">${r.name}</td>
            <td>${r.tf||'—'}</td>
            <td><span class="db-score" style="background:${scoreColor(r.score)}">${(r.score*100).toFixed(0)}</span></td>
            <td>${fmtPct(r.win_rate)}</td>
            <td>${fmt2(r.profit_factor)}</td>
            <td>${r.evidence_trades}</td>
          </tr>`).join('')}
        </tbody>
       </table>`}
</div>

<div class="db-section">
  <div class="db-title">🔬 Hipótesis <span class="db-badge">${hyps.length}</span></div>
  ${hyps.length === 0
    ? '<p class="db-empty">Sin hipótesis — corre gm_hypothesis.py para inicializarlas.</p>'
    : `<div class="db-hyps">
        ${hyps.map(h=>`
          <div class="db-hyp">
            <div class="db-hyp-head">
              <span class="db-hyp-name">${h.name}</span>
              <span class="db-chip">${stateChip(h.state)}</span>
            </div>
            <div class="db-hyp-desc muted">${h.description}</div>
            <div class="db-hyp-stats">
              <span>Score <b style="color:${scoreColor(h.score)}">${(h.score*100).toFixed(0)}</b></span>
              <span>WR <b>${fmtPct(h.win_rate)}</b></span>
              <span>PF <b>${fmt2(h.profit_factor)}</b></span>
              <span>N <b>${h.n_trades}</b></span>
              <span class="muted">${h.tf}</span>
            </div>
          </div>`).join('')}
       </div>`}
</div>

<div class="db-footer muted">
  ${research.available ? `<div class="db-section"><div class="db-title">Archivo de estrategias</div>
    <p>${research.families} familias · ${research.datasets} conjuntos · ${(research.accepted||[]).length} candidatos que pasaron filtros históricos</p>
    <p>Costos modelados y pruebas pendientes en ticks nativos. Promoción a real deshabilitada.</p>
    <a href="${research.report_url}" target="_blank" rel="noopener">Abrir informe y ranking</a></div>` : ""}
  Actualizado: ${new Date(data.ts*1000).toLocaleTimeString()} · Ejecución: <b style="color:#ef5350">DESHABILITADA</b>
</div>`;

    // dibuja equity chart
    drawEquity(qs("#dbEquityCanvas", root), _equityHistory);
  }


  // ── ciclo de actualización ────────────────────────────────────────
  async function refresh(root) {
    try {
      const data = await fetch("/api/dashboard").then(r => r.json());
      render(data, root);
    } catch (e) {
      root.innerHTML = `<p class="db-empty" style="color:#ef5350">Error: ${e.message}</p>`;
    }
  }

  // ── API pública ───────────────────────────────────────────────────
  function mount(rootEl) {
    if (_timer) clearInterval(_timer);
    refresh(rootEl);
    _timer = setInterval(() => refresh(rootEl), 5000);
  }

  function unmount() {
    if (_timer) { clearInterval(_timer); _timer = null; }
  }

  return { mount, unmount };
})();
