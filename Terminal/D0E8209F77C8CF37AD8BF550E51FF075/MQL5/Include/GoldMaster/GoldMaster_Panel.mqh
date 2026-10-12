//+------------------------------------------------------------------+
//| GoldMaster_Panel.mqh  v2.1 — Panel multi-activo + modo Replay    |
//| FIXES v2.1 (2026-10):                                            |
//|  · Bug#1 — SetReplayMode: EAs deben pasar MQL_VISUAL_MODE,      |
//|             NO MQL_TESTER (que es true en backtest normal).       |
//|             Panel acepta el valor que el EA le pasa.              |
//|  · Bug#2 — Badge Y: se clampa a ≥ 2 px para no salirse           |
//|  · Bug#3 — ReplayBar: muestra hora de barra actual + símbolo     |
//|  · Bug#4 — RegisterTrade: documentado y método helper añadido    |
//|  · Bug#5 — m_rows stale: se usa local_rows en Layout()           |
//|  · Bug#6 — StatsBar Y usa cálculo seguro con local_rows          |
//+------------------------------------------------------------------+
#ifndef GM_PANEL_MQH
#define GM_PANEL_MQH

#include <GoldMaster/GoldMaster_Assets.mqh>

//════════════════════════════════════════════════════════
//  ESTADÍSTICAS DE SESIÓN (se resetean al iniciar)
//════════════════════════════════════════════════════════
struct GM_SessionStats {
   int    trades_total;
   int    trades_win;
   int    trades_loss;
   double pnl_total;
   double best_trade;
   double worst_trade;
   void Reset() {
      trades_total=0; trades_win=0; trades_loss=0;
      pnl_total=0.0; best_trade=0.0; worst_trade=0.0;
   }
   void AddTrade(double profit) {
      trades_total++;
      pnl_total += profit;
      if(profit >= 0) trades_win++;
      else trades_loss++;
      best_trade  = MathMax(best_trade,  profit);
      worst_trade = MathMin(worst_trade, profit);
   }
   double WinPct() { return trades_total>0?(double)trades_win/trades_total*100.0:0.0; }
};

//════════════════════════════════════════════════════════
//  CLASE PANEL PRINCIPAL
//════════════════════════════════════════════════════════
class CGMPanel
{
private:
   string  m_pfx, m_bg, m_gvx, m_gvy, m_gvc;
   int     m_x, m_y, m_w, m_lh, m_fs, m_rows;
   color   m_bgc, m_fc, m_title_c;
   bool    m_collapsed;
   string  m_lines[];
   string  m_title_line;   // primera línea (cabecera)
   // Replay
   bool    m_replay_mode;
   string  m_replay_symbol;
   // Asset badge
   string  m_asset_icon;
   string  m_asset_name;
   color   m_asset_color;
   // Stats
   GM_SessionStats m_stats;

   void SaveXY()  { GlobalVariableSet(m_gvx,m_x); GlobalVariableSet(m_gvy,m_y); }
   void SaveCol() { GlobalVariableSet(m_gvc,m_collapsed?1:0); }

   string PnLStr(double v) {
      return (v>=0?"+":"")+DoubleToString(v,2)+"$";
   }

   // FIX#2: Badge Y clamped a >= 2
   void DrawBadge() {
      string n=m_pfx+"BADGE";
      if(ObjectFind(0,n)<0) {
         ObjectCreate(0,n,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
         ObjectSetString(0,n,OBJPROP_FONT,"Arial Bold");
         ObjectSetInteger(0,n,OBJPROP_FONTSIZE,10);
      }
      string badge_txt = m_asset_icon+" "+m_asset_name;
      if(m_replay_mode) badge_txt += " | REPLAY "+m_replay_symbol;
      ObjectSetString(0,n,OBJPROP_TEXT,badge_txt);
      ObjectSetInteger(0,n,OBJPROP_COLOR,m_replay_mode?clrOrange:clrGold);
      ObjectSetInteger(0,n,OBJPROP_XDISTANCE,m_x+8);
      ObjectSetInteger(0,n,OBJPROP_YDISTANCE,MathMax(m_y-16, 2));  // FIX#2
   }

   // FIX#3+#5: ReplayBar con hora viva + usa local_rows para Y
   void DrawReplayBar(int local_rows) {
      string n=m_pfx+"REPLAY_BAR";
      if(!m_replay_mode) { ObjectDelete(0,n); ObjectDelete(0,m_pfx+"REPLAY_TXT"); return; }
      if(ObjectFind(0,n)<0) {
         ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
      }
      int bar_y = m_y + local_rows*m_lh + 10;   // FIX#5: usa local_rows
      ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'80,30,0');
      ObjectSetInteger(0,n,OBJPROP_XDISTANCE,m_x);
      ObjectSetInteger(0,n,OBJPROP_YDISTANCE,bar_y);
      ObjectSetInteger(0,n,OBJPROP_XSIZE,m_w);
      ObjectSetInteger(0,n,OBJPROP_YSIZE,m_lh+4);

      // Texto con hora de barra actual (FIX#3)
      string nt=m_pfx+"REPLAY_TXT";
      if(ObjectFind(0,nt)<0) {
         ObjectCreate(0,nt,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,nt,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,nt,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,nt,OBJPROP_HIDDEN,true);
         ObjectSetString(0,nt,OBJPROP_FONT,"Arial Bold");
         ObjectSetInteger(0,nt,OBJPROP_FONTSIZE,9);
         ObjectSetInteger(0,nt,OBJPROP_COLOR,clrOrange);
      }
      // FIX#3: hora real de la barra actual en el tester
      datetime bar_time = iTime(m_replay_symbol, PERIOD_CURRENT, 0);
      string bar_str = (bar_time > 0) ? TimeToString(bar_time, TIME_DATE|TIME_MINUTES) : "---";
      string replay_txt = "⏸ REPLAY "+m_replay_symbol+" | "+bar_str+" | (datos históricos)";
      ObjectSetString(0,nt,OBJPROP_TEXT,replay_txt);
      ObjectSetInteger(0,nt,OBJPROP_XDISTANCE,m_x+6);
      ObjectSetInteger(0,nt,OBJPROP_YDISTANCE,bar_y+2);
   }

   // FIX#5+#6: StatsBar usa local_rows y apila correctamente bajo ReplayBar
   void DrawStatsBar(int local_rows) {
      string nb=m_pfx+"STATS_BG";
      if(ObjectFind(0,nb)<0) {
         ObjectCreate(0,nb,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(0,nb,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,nb,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(0,nb,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,nb,OBJPROP_HIDDEN,true);
      }
      // FIX#6: apila correctamente bajo ReplayBar
      int base_y = m_y + local_rows*m_lh + 10;                  // base del área extra
      int yoff   = m_replay_mode ? (m_lh + 6) : 0;              // espacio para replay bar
      int stats_y = base_y + yoff;

      ObjectSetInteger(0,nb,OBJPROP_BGCOLOR,C'12,12,18');
      ObjectSetInteger(0,nb,OBJPROP_XDISTANCE,m_x);
      ObjectSetInteger(0,nb,OBJPROP_YDISTANCE,stats_y);
      ObjectSetInteger(0,nb,OBJPROP_XSIZE,m_w);
      ObjectSetInteger(0,nb,OBJPROP_YSIZE,m_lh+4);

      string ns=m_pfx+"STATS_TXT";
      if(ObjectFind(0,ns)<0) {
         ObjectCreate(0,ns,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,ns,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,ns,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,ns,OBJPROP_HIDDEN,true);
         ObjectSetString(0,ns,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(0,ns,OBJPROP_FONTSIZE,8);
      }
      string stxt;
      if(m_stats.trades_total==0)
         stxt="Sesión: sin trades";
      else
         stxt=StringFormat("Sesión: %d trades | W:%.0f%% | P&L:%s | Mejor:%s | Peor:%s",
            m_stats.trades_total, m_stats.WinPct(),
            PnLStr(m_stats.pnl_total),
            PnLStr(m_stats.best_trade),
            PnLStr(m_stats.worst_trade));
      color stc = m_stats.pnl_total>0?C'80,200,100':(m_stats.pnl_total<0?C'200,80,80':clrGray);
      ObjectSetString(0,ns,OBJPROP_TEXT,stxt);
      ObjectSetInteger(0,ns,OBJPROP_COLOR,stc);
      ObjectSetInteger(0,ns,OBJPROP_XDISTANCE,m_x+6);
      ObjectSetInteger(0,ns,OBJPROP_YDISTANCE,stats_y+2);
   }

   void Layout()
   {
      // FIX#5: calcular rows local ANTES de usarlo en DrawReplayBar/DrawStatsBar
      int local_rows = m_collapsed ? 1 : ArraySize(m_lines);

      int maxlen=18;
      for(int i=0;i<local_rows;i++) maxlen=MathMax(maxlen,StringLen(m_lines[i]));
      m_w=(int)(maxlen*m_fs*0.72)+20;
      int h=local_rows*m_lh+10;

      // Fondo principal
      if(ObjectFind(0,m_bg)<0) {
         ObjectCreate(0,m_bg,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(0,m_bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,m_bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(0,m_bg,OBJPROP_COLOR,clrGoldenrod);
         ObjectSetInteger(0,m_bg,OBJPROP_SELECTABLE,true);
         ObjectSetInteger(0,m_bg,OBJPROP_HIDDEN,true);
         ObjectSetString(0,m_bg,OBJPROP_TOOLTIP,"Clic: colapsar/expandir | Arrastra para mover");
      }
      ObjectSetInteger(0,m_bg,OBJPROP_BGCOLOR,m_bgc);
      ObjectSetInteger(0,m_bg,OBJPROP_XDISTANCE,m_x);
      ObjectSetInteger(0,m_bg,OBJPROP_YDISTANCE,m_y);
      ObjectSetInteger(0,m_bg,OBJPROP_XSIZE,m_w);
      ObjectSetInteger(0,m_bg,OBJPROP_YSIZE,h);

      // Líneas de texto
      int total_lines = ArraySize(m_lines);
      for(int i=0;i<MathMax(total_lines,m_rows);i++) {
         string nm=m_pfx+"R"+IntegerToString(i);
         if(i>=local_rows){ ObjectDelete(0,nm); continue; }
         if(ObjectFind(0,nm)<0) {
            ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
            ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
            ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
            ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
            ObjectSetString(0,nm,OBJPROP_FONT,"Consolas");
            ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,m_fs);
         }
         color lc = m_fc;
         if(i==0) lc = clrGold;
         else {
            string ln=m_lines[i];
            if(StringFind(ln,"ALCISTA")>=0 || StringFind(ln,"BUY")>=0)      lc=C'80,200,100';
            else if(StringFind(ln,"BAJISTA")>=0 || StringFind(ln,"SELL")>=0) lc=C'200,80,80';
            else if(StringFind(ln,"BLOQUEO")>=0 || StringFind(ln,"SIN")>=0)  lc=clrOrange;
            else if(StringFind(ln,"intel:")>=0 || StringFind(ln,"INTEL")>=0) lc=C'140,200,255';
            else if(StringFind(ln,"Sesion:")>=0 || StringFind(ln,"sesion:")>=0) lc=C'160,160,200';
         }
         ObjectSetInteger(0,nm,OBJPROP_COLOR,lc);
         ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,m_x+8);
         ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,m_y+5+i*m_lh);
         string disp=(m_collapsed && i>0)?"":( (m_lines[i]==""?" ":m_lines[i]) );
         ObjectSetString(0,nm,OBJPROP_TEXT,disp);
      }
      // FIX#5: actualizar m_rows AL FINAL, después de usarlo en loop anterior
      m_rows = total_lines;

      DrawBadge();
      DrawReplayBar(local_rows);   // FIX#5: pasa local_rows
      DrawStatsBar(local_rows);    // FIX#6: pasa local_rows
      ChartRedraw();
   }

public:
   CGMPanel(){
      m_pfx=""; m_replay_mode=false; m_replay_symbol="";
      m_asset_icon="[GM]"; m_asset_name=""; m_asset_color=clrGold;
      m_collapsed=false; m_stats.Reset(); m_rows=0;
   }

   void Init(string id,int x=10,int y=46,int fontsize=9,color bg=C'18,18,28',color fc=clrWhiteSmoke)
   {
      m_pfx="GMP_"+id+"_"; m_bg=m_pfx+"BG";
      m_gvx="GMP_"+id+"_"+_Symbol+"_X";
      m_gvy="GMP_"+id+"_"+_Symbol+"_Y";
      m_gvc="GMP_"+id+"_"+_Symbol+"_C";
      m_x=GlobalVariableCheck(m_gvx)?(int)GlobalVariableGet(m_gvx):x;
      m_y=GlobalVariableCheck(m_gvy)?(int)GlobalVariableGet(m_gvy):y;
      m_collapsed = GlobalVariableCheck(m_gvc) && GlobalVariableGet(m_gvc)>0;
      m_fs=fontsize; m_lh=fontsize+7; m_bgc=bg; m_fc=fc; m_rows=0;
      ChartSetInteger(0,CHART_EVENT_OBJECT_DELETE,true);
      m_stats.Reset();
   }

   // Inicializa con perfil de activo (color y badge automáticos)
   void InitWithAsset(string id,GM_AssetProfile &ap,int x=10,int y=46)
   {
      Init(id,x,y,9,ap.panel_color==0?C'18,18,28':ap.panel_color);
      m_asset_icon  = ap.icon;
      m_asset_name  = ap.name;
      m_asset_color = ap.panel_color;
   }

   //------------------------------------------------------------------
   // FIX#1 — SetReplayMode
   // IMPORTANTE: el EA debe pasar (bool)MQLInfoInteger(MQL_VISUAL_MODE)
   // NO MQL_TESTER (que es true también en backtest normal sin visual).
   // Ejemplo correcto en OnInit del EA:
   //   g_panel.SetReplayMode((bool)MQLInfoInteger(MQL_VISUAL_MODE), _Symbol);
   //------------------------------------------------------------------
   void SetReplayMode(bool on, string sym="") {
      m_replay_mode   = on;
      m_replay_symbol = on ? (sym==""?_Symbol:sym) : "";
   }

   // FIX#4 — RegisterTrade: llámalo desde OnTradeTransaction cuando
   // una posición se cierra (DEAL_TYPE_SELL+DEAL_ENTRY_OUT o similar).
   // Ejemplo en EA:
   //   void OnTradeTransaction(const MqlTradeTransaction &trans, ...) {
   //     if(trans.type==TRADE_TRANSACTION_DEAL_ADD) {
   //       ulong deal=trans.deal;
   //       if(HistoryDealSelect(deal)) {
   //         if(HistoryDealGetInteger(deal,DEAL_ENTRY)==DEAL_ENTRY_OUT)
   //           g_panel.RegisterTrade(HistoryDealGetDouble(deal,DEAL_PROFIT));
   //       }
   //     }
   //   }
   void RegisterTrade(double profit) { m_stats.AddTrade(profit); }
   void ResetStats()                 { m_stats.Reset(); }

   void Show(string text)
   {
      StringSplit(text,'\n',m_lines);
      if(m_collapsed && ArraySize(m_lines)>0)
         m_lines[0] = m_lines[0]+" [+]";
      Layout();
   }

   void OnEvent(const int id,const long &l,const double &d,const string &s)
   {
      if(id==CHARTEVENT_OBJECT_DRAG && s==m_bg) {
         m_x=(int)ObjectGetInteger(0,m_bg,OBJPROP_XDISTANCE);
         m_y=(int)ObjectGetInteger(0,m_bg,OBJPROP_YDISTANCE);
         SaveXY(); Layout();
         ObjectSetInteger(0,m_bg,OBJPROP_SELECTED,false);
      }
      if(id==CHARTEVENT_OBJECT_CLICK && s==m_bg) {
         m_collapsed=!m_collapsed;
         SaveCol(); Layout();
      }
   }

   void Destroy() {
      if(m_pfx=="") return;
      ObjectsDeleteAll(0,m_pfx);
      ChartRedraw();
   }
};

//════════════════════════════════════════════════════════
//  FUNCIONES HELPER GLOBALES
//════════════════════════════════════════════════════════

bool GM_IsDuplicateInstance()
{
   string me=MQLInfoString(MQL_PROGRAM_NAME); long self=ChartID();
   for(long c=ChartFirst();c>=0;c=ChartNext(c))
      if(c!=self && c<self && ChartSymbol(c)==_Symbol && ChartGetString(c,CHART_EXPERT_NAME)==me) return true;
   return false;
}

void GM_Button(string name,int x,int y,int w,string text,color bg)
{
   if(ObjectFind(0,name)<0) {
      ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_LOWER);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,name,OBJPROP_FONT,"Arial Bold");
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,24);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ChartRedraw();
}

void GM_TFBadge(string tag,string valid)
{
   string tf=StringSubstr(EnumToString((ENUM_TIMEFRAMES)_Period),7);
   bool ok=StringFind(","+valid+",",","+tf+",")>=0;
   string n="GM_TF_"+tag;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,40);
   ObjectSetString(0,n,OBJPROP_TEXT,ok?tag+" · "+tf+" OK (valido: "+valid+")":"AVISO "+tag+": usar en "+valid+" — estas en "+tf);
   ObjectSetInteger(0,n,OBJPROP_COLOR,ok?C'38,166,91':clrOrange);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,ok?8:11);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   if(!ok) Print("[GM] ",tag," en ",tf," — TF recomendado: ",valid);
}

void GM_TFBadgeAsset(string tag,string valid,string asset_name,string asset_icon)
{
   string tf=StringSubstr(EnumToString((ENUM_TIMEFRAMES)_Period),7);
   bool ok=StringFind(","+valid+",",","+tf+",")>=0;
   string n="GM_TF_"+tag;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,40);
   string lbl = asset_icon+" "+asset_name+" | "+tag+" "+tf;
   lbl += ok?" (OK)":"  USE: "+valid;
   ObjectSetString(0,n,OBJPROP_TEXT,lbl);
   ObjectSetInteger(0,n,OBJPROP_COLOR,ok?C'38,166,91':clrOrange);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,ok?9:11);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   if(!ok) Print("[GM] ",tag," en ",tf," — TF recomendado para ",asset_name,": ",valid);
}

#endif
