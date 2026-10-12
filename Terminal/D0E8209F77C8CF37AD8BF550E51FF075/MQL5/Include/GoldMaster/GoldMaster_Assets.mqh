//+──────────────────────────────────────────────────────────────────────────+
//│  GoldMaster_Assets.mqh — Parámetros multi-activo v2.0                   │
//│  Soporta:                                                                │
//│    ORO:    XAUUSD / XAUUSDmicro (tamaño lote automático)                │
//│    NASDAQ: US100 / NAS100 / NDX / USTEC / NAS100m                       │
//│    SP500:  US500 / SPX / SP500 / SPXUSD                                  │
//│    DOW:    US30 / DJI / DOW / DJ30                                       │
//│    BTC:    BTCUSD / Bitcoin                                               │
//│    ETH:    ETHUSD / Ethereum                                              │
//│    FOREX:  EURUSD / GBPUSD / USDJPY / AUDUSD (perfil genérico forex)    │
//│  Uso: GM_AssetProfile p = GM_GetProfile(_Symbol);                        │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_ASSETS_MQH
#define GOLDMASTER_ASSETS_MQH

enum ENUM_GM_ASSET {
   GM_ASSET_GOLD       = 0,
   GM_ASSET_GOLD_MICRO = 1,
   GM_ASSET_NASDAQ     = 2,
   GM_ASSET_SP500      = 3,
   GM_ASSET_DOW        = 4,
   GM_ASSET_BTCUSD     = 5,
   GM_ASSET_ETHUSD     = 6,
   GM_ASSET_FOREX      = 7,
   GM_ASSET_UNKNOWN    = 99,
};

struct GM_AssetProfile {
   ENUM_GM_ASSET asset;
   string name;
   string icon;
   string tf_scalp;
   string tf_daytrade;
   bool   is_micro;
   double lot_multiplier;
   double pip_value_usd;
   double atr_min;
   double atr_max;
   double spread_max_pts;
   double sl_default;
   double tp1_ratio;
   double tp2_ratio;
   double tp3_ratio;
   int    dema_fast;
   int    dema_slow;
   int    ema_trend;
   int    rsi_period;
   int    session_h[6];
   bool   trade_24h;
   string session_names[3];
   bool   use_dxy;
   double dxy_corr_min;
   double risk_pct_default;
   double risk_pct_max;
   color  panel_color;
};

ENUM_GM_ASSET GM_DetectAsset(string symbol) {
   string s = symbol;
   StringToUpper(s);
   // Micro oro - detectar ANTES que oro genérico
   if(StringFind(s,"XAUUSDM") >= 0 || StringFind(s,"XAUUSD.M") >= 0 ||
      StringFind(s,"XAU.MICRO") >= 0 || StringFind(s,"GOLDM") >= 0 ||
      (StringFind(s,"GOLD") >= 0 && StringFind(s,"MICRO") >= 0)) return GM_ASSET_GOLD_MICRO;
   // XAUUSDm (Deriv micro)
   if(StringFind(s,"XAU") >= 0 && StringFind(s,"USD") >= 0 &&
      StringSubstr(s,StringLen(s)-1) == "M") return GM_ASSET_GOLD_MICRO;
   // Oro estándar
   if(StringFind(s,"XAU") >= 0)  return GM_ASSET_GOLD;
   if(StringFind(s,"GOLD") >= 0) return GM_ASSET_GOLD;
   // SP500
   if(StringFind(s,"US500") >= 0)  return GM_ASSET_SP500;
   if(StringFind(s,"SPX") >= 0)    return GM_ASSET_SP500;
   if(StringFind(s,"SP500") >= 0)  return GM_ASSET_SP500;
   if(StringFind(s,"SPXUSD") >= 0) return GM_ASSET_SP500;
   // DOW
   if(StringFind(s,"US30") >= 0)  return GM_ASSET_DOW;
   if(StringFind(s,"DJ30") >= 0)  return GM_ASSET_DOW;
   if(StringFind(s,"DJI") >= 0)   return GM_ASSET_DOW;
   if(StringFind(s,"DOW") >= 0)   return GM_ASSET_DOW;
   // NASDAQ
   if(StringFind(s,"NAS") >= 0)    return GM_ASSET_NASDAQ;
   if(StringFind(s,"US100") >= 0)  return GM_ASSET_NASDAQ;
   if(StringFind(s,"NDX") >= 0)    return GM_ASSET_NASDAQ;
   if(StringFind(s,"USTEC") >= 0)  return GM_ASSET_NASDAQ;
   // BTC
   if(StringFind(s,"BTC") >= 0)     return GM_ASSET_BTCUSD;
   if(StringFind(s,"BITCOIN") >= 0) return GM_ASSET_BTCUSD;
   // ETH
   if(StringFind(s,"ETH") >= 0)    return GM_ASSET_ETHUSD;
   if(StringFind(s,"ETHER") >= 0)  return GM_ASSET_ETHUSD;
   // Forex genérico
   if(StringFind(s,"EUR") >= 0 || StringFind(s,"GBP") >= 0 ||
      StringFind(s,"JPY") >= 0 || StringFind(s,"AUD") >= 0 ||
      StringFind(s,"CHF") >= 0 || StringFind(s,"CAD") >= 0 ||
      StringFind(s,"NZD") >= 0) return GM_ASSET_FOREX;
   return GM_ASSET_UNKNOWN;
}

GM_AssetProfile GM_ProfileGold() {
   GM_AssetProfile p;
   p.asset=GM_ASSET_GOLD; p.name="XAUUSD"; p.icon="[ORO]";
   p.tf_scalp="M1,M5"; p.tf_daytrade="M15,H1";
   p.is_micro=false; p.lot_multiplier=1.0; p.pip_value_usd=1.0;
   p.atr_min=0.30; p.atr_max=8.00; p.spread_max_pts=40;
   p.sl_default=1.50; p.tp1_ratio=1.5; p.tp2_ratio=2.5; p.tp3_ratio=4.0;
   p.dema_fast=21; p.dema_slow=55; p.ema_trend=200; p.rsi_period=14;
   p.session_h[0]=7; p.session_h[1]=17; p.session_h[2]=0; p.session_h[3]=0; p.session_h[4]=0; p.session_h[5]=0;
   p.session_names[0]="Londres+NY"; p.session_names[1]=""; p.session_names[2]="";
   p.trade_24h=false;
   p.use_dxy=true; p.dxy_corr_min=-0.30;
   p.risk_pct_default=1.0; p.risk_pct_max=3.0;
   p.panel_color=C'40,30,5';
   return p;
}

GM_AssetProfile GM_ProfileGoldMicro() {
   GM_AssetProfile p=GM_ProfileGold();
   p.asset=GM_ASSET_GOLD_MICRO; p.name="XAUUSD micro"; p.icon="[ORO-m]";
   p.is_micro=true; p.lot_multiplier=0.1; p.pip_value_usd=0.1;
   p.sl_default=1.00; p.atr_min=0.20; p.spread_max_pts=50;
   p.risk_pct_default=1.5; p.risk_pct_max=5.0;
   p.panel_color=C'20,35,10';
   return p;
}

GM_AssetProfile GM_ProfileNasdaq() {
   GM_AssetProfile p;
   p.asset=GM_ASSET_NASDAQ; p.name="NASDAQ"; p.icon="[NAS]";
   p.tf_scalp="M5,M15"; p.tf_daytrade="M15,H1";
   p.is_micro=false; p.lot_multiplier=1.0; p.pip_value_usd=1.0;
   p.atr_min=10.0; p.atr_max=500.0; p.spread_max_pts=50;
   p.sl_default=30.0; p.tp1_ratio=1.5; p.tp2_ratio=2.5; p.tp3_ratio=4.0;
   p.dema_fast=21; p.dema_slow=55; p.ema_trend=200; p.rsi_period=14;
   p.session_h[0]=12; p.session_h[1]=20; p.session_h[2]=0; p.session_h[3]=0; p.session_h[4]=0; p.session_h[5]=0;
   p.session_names[0]="NY Open"; p.session_names[1]=""; p.session_names[2]="";
   p.trade_24h=false;
   p.use_dxy=true; p.dxy_corr_min=-0.20;
   p.risk_pct_default=0.75; p.risk_pct_max=2.0;
   p.panel_color=C'5,20,45';
   return p;
}

GM_AssetProfile GM_ProfileSP500() {
   GM_AssetProfile p;
   p.asset=GM_ASSET_SP500; p.name="SP500"; p.icon="[SPX]";
   p.tf_scalp="M5,M15"; p.tf_daytrade="M15,H1";
   p.is_micro=false; p.lot_multiplier=1.0; p.pip_value_usd=1.0;
   p.atr_min=3.0; p.atr_max=200.0; p.spread_max_pts=30;
   p.sl_default=15.0; p.tp1_ratio=1.5; p.tp2_ratio=2.5; p.tp3_ratio=4.0;
   p.dema_fast=21; p.dema_slow=55; p.ema_trend=200; p.rsi_period=14;
   p.session_h[0]=12; p.session_h[1]=20; p.session_h[2]=0; p.session_h[3]=0; p.session_h[4]=0; p.session_h[5]=0;
   p.session_names[0]="NY Open"; p.session_names[1]=""; p.session_names[2]="";
   p.trade_24h=false;
   p.use_dxy=true; p.dxy_corr_min=-0.20;
   p.risk_pct_default=0.75; p.risk_pct_max=2.0;
   p.panel_color=C'5,30,30';
   return p;
}

GM_AssetProfile GM_ProfileDow() {
   GM_AssetProfile p;
   p.asset=GM_ASSET_DOW; p.name="DOW"; p.icon="[DJ]";
   p.tf_scalp="M5,M15"; p.tf_daytrade="M15,H1";
   p.is_micro=false; p.lot_multiplier=1.0; p.pip_value_usd=1.0;
   p.atr_min=20.0; p.atr_max=1000.0; p.spread_max_pts=40;
   p.sl_default=60.0; p.tp1_ratio=1.5; p.tp2_ratio=2.5; p.tp3_ratio=4.0;
   p.dema_fast=21; p.dema_slow=55; p.ema_trend=200; p.rsi_period=14;
   p.session_h[0]=12; p.session_h[1]=20; p.session_h[2]=0; p.session_h[3]=0; p.session_h[4]=0; p.session_h[5]=0;
   p.session_names[0]="NY Open"; p.session_names[1]=""; p.session_names[2]="";
   p.trade_24h=false;
   p.use_dxy=true; p.dxy_corr_min=-0.15;
   p.risk_pct_default=0.75; p.risk_pct_max=2.0;
   p.panel_color=C'30,10,30';
   return p;
}

GM_AssetProfile GM_ProfileBTCUSD() {
   GM_AssetProfile p;
   p.asset=GM_ASSET_BTCUSD; p.name="BTCUSD"; p.icon="[BTC]";
   p.tf_scalp="M5,M15"; p.tf_daytrade="M15,H1,H4";
   p.is_micro=false; p.lot_multiplier=1.0; p.pip_value_usd=1.0;
   p.atr_min=50.0; p.atr_max=5000.0; p.spread_max_pts=100;
   p.sl_default=200.0; p.tp1_ratio=1.5; p.tp2_ratio=2.5; p.tp3_ratio=5.0;
   p.dema_fast=21; p.dema_slow=55; p.ema_trend=200; p.rsi_period=14;
   p.session_h[0]=0; p.session_h[1]=24; p.session_h[2]=0; p.session_h[3]=0; p.session_h[4]=0; p.session_h[5]=0;
   p.session_names[0]="24/7"; p.session_names[1]=""; p.session_names[2]="";
   p.trade_24h=true;
   p.use_dxy=false; p.dxy_corr_min=-0.15;
   p.risk_pct_default=0.5; p.risk_pct_max=1.5;
   p.panel_color=C'40,20,0';
   return p;
}

GM_AssetProfile GM_ProfileETHUSD() {
   GM_AssetProfile p;
   p.asset=GM_ASSET_ETHUSD; p.name="ETHUSD"; p.icon="[ETH]";
   p.tf_scalp="M5,M15"; p.tf_daytrade="M15,H1,H4";
   p.is_micro=false; p.lot_multiplier=1.0; p.pip_value_usd=1.0;
   p.atr_min=5.0; p.atr_max=500.0; p.spread_max_pts=80;
   p.sl_default=30.0; p.tp1_ratio=1.5; p.tp2_ratio=2.5; p.tp3_ratio=5.0;
   p.dema_fast=21; p.dema_slow=55; p.ema_trend=200; p.rsi_period=14;
   p.session_h[0]=0; p.session_h[1]=24; p.session_h[2]=0; p.session_h[3]=0; p.session_h[4]=0; p.session_h[5]=0;
   p.session_names[0]="24/7"; p.session_names[1]=""; p.session_names[2]="";
   p.trade_24h=true;
   p.use_dxy=false; p.dxy_corr_min=-0.10;
   p.risk_pct_default=0.5; p.risk_pct_max=1.5;
   p.panel_color=C'15,10,45';
   return p;
}

GM_AssetProfile GM_ProfileForex() {
   GM_AssetProfile p;
   p.asset=GM_ASSET_FOREX; p.name="FOREX"; p.icon="[FX]";
   p.tf_scalp="M5,M15"; p.tf_daytrade="M15,H1";
   p.is_micro=false; p.lot_multiplier=1.0; p.pip_value_usd=10.0;
   p.atr_min=0.0005; p.atr_max=0.0200; p.spread_max_pts=15;
   p.sl_default=0.0020; p.tp1_ratio=1.5; p.tp2_ratio=2.5; p.tp3_ratio=4.0;
   p.dema_fast=21; p.dema_slow=55; p.ema_trend=200; p.rsi_period=14;
   p.session_h[0]=7; p.session_h[1]=12; p.session_h[2]=12; p.session_h[3]=17; p.session_h[4]=0; p.session_h[5]=0;
   p.session_names[0]="Londres"; p.session_names[1]="NY"; p.session_names[2]="";
   p.trade_24h=false;
   p.use_dxy=true; p.dxy_corr_min=-0.35;
   p.risk_pct_default=1.0; p.risk_pct_max=2.0;
   p.panel_color=C'10,10,10';
   return p;
}

GM_AssetProfile GM_GetProfile(string symbol = "") {
   if(StringLen(symbol) == 0) symbol = _Symbol;
   ENUM_GM_ASSET asset = GM_DetectAsset(symbol);
   switch(asset) {
      case GM_ASSET_GOLD:       return GM_ProfileGold();
      case GM_ASSET_GOLD_MICRO: return GM_ProfileGoldMicro();
      case GM_ASSET_NASDAQ:     return GM_ProfileNasdaq();
      case GM_ASSET_SP500:      return GM_ProfileSP500();
      case GM_ASSET_DOW:        return GM_ProfileDow();
      case GM_ASSET_BTCUSD:     return GM_ProfileBTCUSD();
      case GM_ASSET_ETHUSD:     return GM_ProfileETHUSD();
      case GM_ASSET_FOREX:      return GM_ProfileForex();
      default:
         Print("[GoldMaster][Assets] Simbolo no reconocido: "+symbol+" — usando perfil Gold.");
         return GM_ProfileGold();
   }
}

bool GM_InSession(GM_AssetProfile &p) {
   if(p.trade_24h) return true;
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt); int h=dt.hour;
   for(int i=0;i<3;i++) {
      int h0=p.session_h[i*2], h1=p.session_h[i*2+1];
      if(h0==0&&h1==0) continue;
      if(h>=h0&&h<h1) return true;
   }
   return false;
}

string GM_CurrentSessionName(GM_AssetProfile &p) {
   if(p.trade_24h) return "24/7";
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt); int h=dt.hour;
   for(int i=0;i<3;i++) {
      int h0=p.session_h[i*2], h1=p.session_h[i*2+1];
      if(h0==0&&h1==0) continue;
      if(h>=h0&&h<h1) return (p.session_names[i]!=""?p.session_names[i]:StringFormat("S%d",i+1));
   }
   return "Cerrada";
}

bool GM_ATRValid(GM_AssetProfile &p, double atr_val) {
   return (atr_val >= p.atr_min && atr_val <= p.atr_max);
}

string GM_AssetName(ENUM_GM_ASSET a) {
   switch(a) {
      case GM_ASSET_GOLD:       return "XAUUSD (Oro)";
      case GM_ASSET_GOLD_MICRO: return "XAUUSD micro";
      case GM_ASSET_NASDAQ:     return "NASDAQ (US100)";
      case GM_ASSET_SP500:      return "S&P 500 (US500)";
      case GM_ASSET_DOW:        return "DOW (US30)";
      case GM_ASSET_BTCUSD:     return "Bitcoin (BTC)";
      case GM_ASSET_ETHUSD:     return "Ethereum (ETH)";
      case GM_ASSET_FOREX:      return "Forex";
      default:                  return "Desconocido";
   }
}

void GM_LogProfile(GM_AssetProfile &p) {
   static string s_last="";
   string key=p.name+_Symbol;
   if(s_last==key) return;
   s_last=key;
   PrintFormat("[GoldMaster][Assets] %s Activo: %s | TF scalp: %s | TF day: %s | SL: %.4f | Riesgo: %.1f%%-%.1f%%",
      p.icon,p.name,p.tf_scalp,p.tf_daytrade,p.sl_default,p.risk_pct_default,p.risk_pct_max);
   PrintFormat("[GoldMaster][Assets] ATR: %.4f-%.4f | Spread max: %d | 24h: %s | DXY: %s | Micro: %s",
      p.atr_min,p.atr_max,(int)p.spread_max_pts,
      p.trade_24h?"SI":"NO",p.use_dxy?"SI":"NO",
      p.is_micro?"SI (x"+DoubleToString(p.lot_multiplier,2)+")":"NO");
}

#endif
