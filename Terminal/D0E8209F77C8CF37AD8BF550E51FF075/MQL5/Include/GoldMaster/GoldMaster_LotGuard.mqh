//+------------------------------------------------------------------+
//|  GoldMaster_LotGuard.mqh                                         |
//|                                                                  |
//|  Guarda de lote: impide que el SUELO DE LOTE MINIMO haga que una |
//|  operacion arriesgue mucho mas de lo planeado, en silencio.      |
//|                                                                  |
//|  EL PROBLEMA QUE RESUELVE                                        |
//|  El patron habitual de dimensionado es:                          |
//|      lote = riesgo_objetivo / (distancia_SL * valor_por_punto)   |
//|      lote = MathMax(lote, lote_minimo);   // <-- aqui            |
//|  Esa ultima linea parece inofensiva y es la que arruina cuentas  |
//|  pequenas: cuando el lote calculado sale POR DEBAJO del minimo   |
//|  del broker, se sube al minimo y el riesgo REAL pasa a ser el    |
//|  que imponga ese minimo, no el que pedia el usuario. Con oro y   |
//|  una cuenta de 50 USD eso puede significar arriesgar el 8% en    |
//|  vez del 3.5%; con 10 USD, mas del 40%. Y no avisa.              |
//|                                                                  |
//|  COMO LO RESUELVE                                                |
//|  Calcula el riesgo que de verdad implica el lote minimo y, si se |
//|  pasa de los limites, DEVUELVE 0 para que el EA no opere. Es     |
//|  deliberado que bloquee en vez de recortar: por debajo del lote  |
//|  minimo no hay nada que recortar, asi que la unica alternativa   |
//|  honesta a no operar es operar con mas riesgo del planeado.      |
//|                                                                  |
//|  Misma logica que gm_guardian.py y GoldMaster_Guardian.mqh, para |
//|  que el EA, el panel y la investigacion no discrepen.            |
//+------------------------------------------------------------------+
#ifndef GOLDMASTER_LOTGUARD_MQH
#define GOLDMASTER_LOTGUARD_MQH

//--- valores por defecto; cada EA los expone como input ------------
#define GM_LG_DEF_MAX_EQUITY_PCT   5.0   // techo duro: % de equity por operacion
#define GM_LG_DEF_OVER_TARGET_MAX  2.0   // multiplo maximo del riesgo objetivo

//+------------------------------------------------------------------+
//| USD que mueve 1.0 lote por cada unidad de PRECIO del simbolo.    |
//| Devuelve 0 si el broker no da los datos (y entonces no se opera).|
//+------------------------------------------------------------------+
double GMLG_UsdPerPricePerLot(const string sym)
  {
   double tick_val = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val <= 0.0 || tick_sz <= 0.0)
      return(0.0);
   return(tick_val / tick_sz);
  }

//+------------------------------------------------------------------+
//| Normaliza un volumen al paso del simbolo, hacia ABAJO.           |
//+------------------------------------------------------------------+
double GMLG_FloorToStep(const string sym, const double vol)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   double v = MathFloor(vol / step + 1e-9) * step;
   int dg = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   return(NormalizeDouble(v, dg));
  }

//+------------------------------------------------------------------+
//| GUARDA PRINCIPAL. Devuelve el lote a usar, o 0.0 si NO se opera. |
//|                                                                  |
//|  sl_price_dist   distancia del stop en PRECIO (no en puntos)     |
//|  risk_target_usd riesgo objetivo en USD. Pasa 0 cuando el EA     |
//|                  opera a lote fijo minimo a proposito: entonces  |
//|                  solo se aplica el techo de equity.              |
//|  max_equity_pct  techo duro, en % de equity. <=0 lo desactiva.   |
//|  over_target_max multiplo maximo del objetivo que se tolera      |
//|                  cuando el lote minimo obliga a pasarse.         |
//|                  <=0 lo desactiva.                               |
//|  tag             etiqueta para el log                            |
//|  quiet           true = no imprime (util en optimizaciones)      |
//+------------------------------------------------------------------+
//  min_lot_override  minimo efectivo si el EA impone uno mayor que el del
//                  broker (p.ej. un input "MinLotManual"). 0 = usar el del broker.
//  symbol          simbolo a dimensionar. Por omision el del grafico, pero
//                  hay EA que operan un simbolo configurable distinto del
//                  grafico: pasarselo es obligatorio en ese caso, o se
//                  calcularia el lote minimo y el tick value del instrumento
//                  equivocado.
double GMLotGuard(const double sl_price_dist,
                  const double risk_target_usd,
                  const double max_equity_pct   = GM_LG_DEF_MAX_EQUITY_PCT,
                  const double over_target_max  = GM_LG_DEF_OVER_TARGET_MAX,
                  const string tag              = "LotGuard",
                  const bool   quiet            = false,
                  const string symbol           = "",
                  const double min_lot_override = 0.0)
  {
   string sym = (symbol == "" ? _Symbol : symbol);

   if(sl_price_dist <= 0.0)
     {
      if(!quiet) PrintFormat("[%s] bloqueado: distancia de stop invalida (%.5f). "
                             "Operar sin stop valido no es operar.", tag, sl_price_dist);
      return(0.0);
     }

   double ppl = GMLG_UsdPerPricePerLot(sym);
   if(ppl <= 0.0)
     {
      if(!quiet) PrintFormat("[%s] bloqueado: el broker no publica tick value/size de %s. "
                             "Sin eso no se puede saber cuanto se arriesga.", tag, sym);
      return(0.0);
     }

   double min_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(min_lot <= 0.0)
      min_lot = 0.01;
   // Hay EA con un "lote minimo manual" configurable POR ENCIMA del minimo
   // del broker. Si la guarda no lo tuviera en cuenta, aprobaria un lote y
   // luego el EA lo subiria a ese minimo manual, saltandose el techo por la
   // puerta de atras. El minimo efectivo es el mayor de los dos.
   if(min_lot_override > min_lot)
      min_lot = min_lot_override;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double min_risk = min_lot * sl_price_dist * ppl;   // lo que cuesta el minimo

   //--- 1) techo duro sobre el equity -----------------------------
   if(max_equity_pct > 0.0 && equity > 0.0)
     {
      double cap = equity * max_equity_pct / 100.0;
      if(min_risk > cap)
        {
         if(!quiet)
            PrintFormat("[%s] BLOQUEADO: ni el lote minimo (%.2f) cabe. Arriesga %.2f USD "
                        "= %.1f%% del equity (%.2f), por encima del techo del %.1f%%. "
                        "Usa cuenta cent, un stop mas ajustado, o capitaliza mas.",
                        tag, min_lot, min_risk, min_risk / equity * 100.0, equity, max_equity_pct);
         return(0.0);
        }
     }

   //--- 2) a lote fijo minimo solo se aplica el techo de equity ----
   // Los EA que operan SIEMPRE al volumen minimo no tienen nada que
   // recortar: o cabe bajo el techo (y ya ha pasado el punto 1), o no
   // se opera. Aqui simplemente se devuelve el minimo del broker.
   if(risk_target_usd <= 0.0)
      return(min_lot);

   //--- 3) multiplo maximo del riesgo objetivo ---------------------
   if(over_target_max > 0.0 && min_risk > risk_target_usd * over_target_max)
     {
      if(!quiet)
         PrintFormat("[%s] BLOQUEADO: el lote minimo (%.2f) fuerza %.2f USD de riesgo, "
                     "%.1fx el objetivo de %.2f USD (maximo %.1fx). El riesgo lo impondria "
                     "el broker, no tu plan.",
                     tag, min_lot, min_risk, min_risk / risk_target_usd,
                     risk_target_usd, over_target_max);
      return(0.0);
     }

   //--- 4) dimensionado normal ------------------------------------
   double lot = GMLG_FloorToStep(sym, risk_target_usd / (sl_price_dist * ppl));

   if(lot < min_lot)
     {
      // Cabe bajo los limites, pero hay que DECIR que el riesgo real sube.
      lot = min_lot;
      if(!quiet)
         PrintFormat("[%s] aviso: el lote minimo eleva el riesgo de %.2f a %.2f USD "
                     "(%.1fx el objetivo, %.1f%% del equity). Lo impone el lote minimo, "
                     "no la senal.",
                     tag, risk_target_usd, min_risk,
                     (risk_target_usd > 0.0 ? min_risk / risk_target_usd : 0.0),
                     (equity > 0.0 ? min_risk / equity * 100.0 : 0.0));
     }
   if(max_lot > 0.0 && lot > max_lot)
      lot = GMLG_FloorToStep(sym, max_lot);

   return(lot);
  }

#endif // GOLDMASTER_LOTGUARD_MQH
