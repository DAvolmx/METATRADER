"use strict";
(function () {
  const target = document.getElementById("marketSummary");
  const names = {gold:"ORO", nasdaq:"NASDAQ", bitcoin:"BITCOIN", ethereum:"ETHEREUM", btceth:"BTC / ETH", dxy:"DÓLAR · DXY"};
  const format = (n,d=2) => Number.isFinite(n) ? n.toLocaleString("es-CO",{maximumFractionDigits:d}) : "—";
  function element(tag,cls,text){const n=document.createElement(tag);n.className=cls;n.textContent=text;return n;}
  async function update() {
    try {
      const response = await fetch("/api/analytics", {signal:AbortSignal.timeout(5000),cache:"no-store"});
      if(!response.ok) throw new Error("unavailable");
      const data = await response.json();
      target.replaceChildren();
      const ok=data.snapshot_fresh && data.status==="connected";
      const status=element("div","observer-health",ok ? "● DATOS CONECTADOS" : "○ DATOS NO DISPONIBLES");
      status.dataset.state=ok?"ok":"warning";
      status.append(element("span","muted",` Actualización ${format(data.snapshot_age_s,1)} s · Ciclo ${format(data.service?.cycle_ms,0)} ms · ${data.status || "sin servicio"}`));
      target.append(status);
      const grid=element("div","observer-grid","");
      for(const asset of Object.keys(names)) {
        const value=data.assets?.[asset] || {};
        const usable=ok && value.status==="fresh" && value.bars_fresh && value.tick_read_ok && !value.tick_gap;
        const card=element("article","observer-card","");
        card.dataset.state=usable?"ok":"warning";
        card.append(element("div","observer-label",`${names[asset]} · ${value.symbol || "sin resolver"}`));
        card.append(element("div","observer-price",format(value.bid,value.spec?.digits ?? 2)));
        card.append(element("div","observer-status",usable?"Datos actuales":"Datos insuficientes / atrasados"));
        const metrics=element("div","observer-metrics","");
        for(const [label,text] of [["Spread",format(value.spread,3)],["Variación 60 s",`${format(value.ret_60s_bp)} pb`],["Ticks 60 s",format(value.tick_count_60s,0)],["Edad cotización",`${format(value.quote_age_s,1)} s`],["Estructura M5",value.smc?.state || "—"],["Correlación DXY",format(value.dxy_corr_m5)]]){
          metrics.append(element("span","muted",label),element("strong","",text));
        }
        card.append(metrics);grid.append(card);
        if(value.small_account_10usd){
          const scenario=value.small_account_10usd;
          const badge=element("div","observer-status",`USD 10 · margen ${scenario.margin_within_hypothetical_balance?"ALCANZA":"NO ALCANZA"} (${format(scenario.minimum_lot_margin)} USD) · riesgo 1% ${scenario.status==="infeasible"?"EXCEDIDO":scenario.status==="preliminary_only"?"PRELIMINAR":"SIN DATOS"} · pérdida al SL ${format(scenario.minimum_lot_loss)} USD`);
          card.append(badge);
        }
        if(value.small_account_10usd_micro){
          const micro=value.small_account_10usd_micro;
          card.append(element("div","observer-status",`XAUUSDmicro · USD 10: margen ${micro.margin_within_hypothetical_balance?"ALCANZA":"NO ALCANZA"} · riesgo 1% ${micro.status==="infeasible"?"EXCEDIDO":micro.status==="preliminary_only"?"PRELIMINAR":"SIN DATOS"} · pérdida al SL ${format(micro.minimum_lot_loss)} USD`));
        }
        if(value.small_account_6usd && value.small_account_6usd_micro){
          const standard=value.small_account_6usd, micro=value.small_account_6usd_micro;
          card.append(element("div","observer-status",`USD 6 · XAUUSD margen ${standard.margin_within_hypothetical_balance?"ALCANZA":"NO ALCANZA"} (${format(standard.minimum_lot_margin)} USD); micro margen ${micro.margin_within_hypothetical_balance?"ALCANZA":"NO ALCANZA"} (${format(micro.minimum_lot_margin)} USD). Pérdida al SL: ${format(standard.minimum_lot_loss)} / ${format(micro.minimum_lot_loss)} USD.`));
        }
      }
      target.append(grid,element("div","observer-note","Investigación · Ninguna estrategia aprobada para ejecución real. El observatorio usa la hora actual; el replay utiliza su propio reloj histórico."));
    } catch (_) { target.replaceChildren(element("div","observer-health","Servicio analítico no disponible · señales suspendidas")); }
    finally { setTimeout(update,3000); }
  }
  update();
})();
