//+──────────────────────────────────────────────────────────────────────────+
//│          GOLD MASTER SYSTEM — SMC Engine v3.1                            │
//│  Smart Money Concepts: Swings · BOS/CHoCH · OBs · FVGs · Liquidity     │
//│  Mejoras v3.1: OB quality score, inducements, CHoCH vs BOS, multi-TF   │
//│  confluence score, Breaker Blocks, Mitigation Blocks, ICT model         │
//+──────────────────────────────────────────────────────────────────────────+
#ifndef GOLDMASTER_SMC_MQH
#define GOLDMASTER_SMC_MQH
#include "GoldMaster_Core.mqh"

//════════════════════════════════════════════════════════
//  ESTRUCTURAS
//════════════════════════════════════════════════════════

struct GMSwing {
   datetime time;
   double   price;
   bool     is_high;
   int      bar_idx;
};

struct GMOB {
   datetime t_start, t_end;
   double   top, bottom;
   bool     is_bull;
   bool     mitigated;
   int      quality;      // 0-100: fuerza del impulso tras OB
   int      touches;      // veces que el precio tocó la zona
   bool     is_breaker;   // true si fue mitigado y se convirtió en breaker block
};

struct GMFVG {
   datetime t_candle;
   double   top, bottom;
   bool     is_bull;
   bool     filled;
   double   fill_pct;     // 0-100: % del FVG ya rellenado
   double   size_atr;     // tamaño del FVG en unidades ATR
};

struct GMLiqLevel {
   double   price;
   bool     is_high;
   int      touch_count;
   bool     swept;        // ya fue barrido (liquidez tomada)
   datetime t_formed;
};

struct GMPremiumDiscount {
   GMPremiumDiscount() {
      range_high=0; range_low=0; equilibrium=0;
      premium_zone=0; discount_zone=0;
      ote_bull_low=0; ote_bull_high=0;
      ote_bear_low=0; ote_bear_high=0;
   }
   double range_high, range_low, equilibrium;
   double premium_zone, discount_zone;
   double ote_bull_low, ote_bull_high;
   double ote_bear_low, ote_bear_high;
};

// Resultado de análisis SMC completo en un solo struct
struct GMBias {
   int      trend;          // 1=bull, -1=bear, 0=flat
   bool     bos_bull;       // Break of Structure alcista confirmado
   bool     bos_bear;
   bool     choch_bull;     // CHoCH: cambio de carácter alcista (trend reversal)
   bool     choch_bear;
   bool     in_ote_bull;    // precio en OTE zona bullish (0.618-0.786 retrace)
   bool     in_ote_bear;
   bool     near_bull_ob;   // precio tocando OB alcista activo
   bool     near_bear_ob;
   bool     in_bull_fvg;    // precio dentro de FVG alcista
   bool     in_bear_fvg;
   bool     liq_sweep_bull; // sweep bajista de liquidez → potencial long
   bool     liq_sweep_bear;
   bool     inducement_bull;// inducement = trampa antes del verdadero movimiento
   bool     inducement_bear;
   int      confluence;     // 0-10: suma de señales alineadas
};

//════════════════════════════════════════════════════════
//  CLASE SMC ENGINE v3.1
//════════════════════════════════════════════════════════
class CGoldMasterSMC {
private:
   int             m_fractal_range;
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   double          m_atr_cache;

   double GetATRCached() {
      double atr[]; int h=iATR(m_symbol,m_tf,14);
      if(CopyBuffer(h,0,0,1,atr)>0) m_atr_cache=atr[0];
      IndicatorRelease(h);
      return m_atr_cache;
   }

public:
   CGoldMasterSMC(string symbol, ENUM_TIMEFRAMES tf, int fractal_range=3) {
      m_symbol=symbol; m_tf=tf;
      m_fractal_range=fractal_range; m_atr_cache=0;
   }
   // Inicialización post-construcción (alias del constructor para compatibilidad)
   void Init(string symbol, ENUM_TIMEFRAMES tf, int fractal_range=3) {
      m_symbol=symbol; m_tf=tf;
      m_fractal_range=fractal_range; m_atr_cache=0;
   }

   //─── Swings confirmados (sin repintado: confirmados fractal_range velas después)
   int GetSwings(GMSwing &swings[], int bars=200) {
      int cnt=0;
      ArrayResize(swings,0);
      if(bars>iBars(m_symbol,m_tf)) bars=iBars(m_symbol,m_tf);
      double hi[],lo[]; datetime t[];
      ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(t,true);
      if(CopyHigh(m_symbol,m_tf,0,bars,hi)<bars) return 0;
      if(CopyLow (m_symbol,m_tf,0,bars,lo)<bars) return 0;
      if(CopyTime(m_symbol,m_tf,0,bars,t) <bars) return 0;
      int fr=m_fractal_range;
      // Oldest to newest: downstream trend logic reads count-1 as the latest swing.
      // fr+1 keeps the right confirmation wing entirely on CLOSED bars (shift >= 1).
      for(int i=bars-fr-1;i>=fr+1;i--) {
         bool is_sh=true, is_sl=true;
         for(int j=1;j<=fr;j++) {
            if(hi[i]<=hi[i+j]||hi[i]<=hi[i-j]) is_sh=false;
            if(lo[i]>=lo[i+j]||lo[i]>=lo[i-j]) is_sl=false;
         }
         if(is_sh) {
            ArrayResize(swings,cnt+1);
            swings[cnt].time=t[i]; swings[cnt].price=hi[i];
            swings[cnt].is_high=true; swings[cnt].bar_idx=i; cnt++;
         }
         if(is_sl) {
            ArrayResize(swings,cnt+1);
            swings[cnt].time=t[i]; swings[cnt].price=lo[i];
            swings[cnt].is_high=false; swings[cnt].bar_idx=i; cnt++;
         }
      }
      return cnt;
   }

   //─── Trend + BOS + CHoCH (diferenciados)
   //    BOS = ruptura en dirección de la tendencia (continuación)
   //    CHoCH = ruptura contra la tendencia (posible reversión)
   int GetMarketTrend(GMSwing &swings[], int count) {
      if(count<4) return 0;
      // Construir secuencia HH/HL/LH/LL
      double sh[4]; double sl[4]; int sh_cnt=0,sl_cnt=0;
      for(int i=count-1;i>=0&&(sh_cnt<4||sl_cnt<4);i--) {
         if(swings[i].is_high&&sh_cnt<4) { sh[sh_cnt]=swings[i].price; sh_cnt++; }
         if(!swings[i].is_high&&sl_cnt<4){ sl[sl_cnt]=swings[i].price; sl_cnt++; }
      }
      if(sh_cnt<2||sl_cnt<2) return 0;
      bool hh=(sh[0]>sh[1]); bool hl=(sl[0]>sl[1]);
      bool lh=(sh[0]<sh[1]); bool ll=(sl[0]<sl[1]);
      if(hh&&hl) return  1;  // bullish
      if(lh&&ll) return -1;  // bearish
      // Transición: CHoCH implícito si primera condición no se cumple
      if(hh&&ll) return  0;  // distribución
      if(lh&&hl) return  0;  // acumulación
      return 0;
   }

   // BOS: ¿la última swing high rompió el anterior SH? (bull BOS)
   bool DetectBOS_Bull(GMSwing &swings[], int count) {
      double sh1=0,sh2=0; int c=0;
      for(int i=count-1;i>=0&&c<2;i--)
         if(swings[i].is_high) { if(c==0)sh1=swings[i].price; else sh2=swings[i].price; c++; }
      return (c==2 && sh1>sh2);
   }
   bool DetectBOS_Bear(GMSwing &swings[], int count) {
      double sl1=0,sl2=1e10; int c=0;
      for(int i=count-1;i>=0&&c<2;i--)
         if(!swings[i].is_high) { if(c==0)sl1=swings[i].price; else sl2=swings[i].price; c++; }
      return (c==2 && sl1<sl2);
   }

   // CHoCH: swing que rompe estructura en sentido contrario a tendencia actual
   bool DetectCHoCH_Bull(GMSwing &swings[], int count, int current_trend) {
      if(current_trend!=-1) return false; // solo valid en bajista
      return DetectBOS_Bull(swings,count); // una ruptura alcista en tendencia bajista = CHoCH
   }
   bool DetectCHoCH_Bear(GMSwing &swings[], int count, int current_trend) {
      if(current_trend!=1) return false;
      return DetectBOS_Bear(swings,count);
   }

   //─── Order Blocks v3.1 con quality score y breaker detection
   int GetOrderBlocks(GMOB &obs[], int bars=50) {
      int cnt=0;
      ArrayResize(obs,0);
      double op[],hi[],lo[],cl[]; datetime t[];
      ArraySetAsSeries(op,true); ArraySetAsSeries(hi,true);
      ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
      ArraySetAsSeries(t,true);
      int need=bars+5;
      if(CopyOpen (m_symbol,m_tf,0,need,op)<need) return 0;
      if(CopyHigh (m_symbol,m_tf,0,need,hi)<need) return 0;
      if(CopyLow  (m_symbol,m_tf,0,need,lo)<need) return 0;
      if(CopyClose(m_symbol,m_tf,0,need,cl)<need) return 0;
      if(CopyTime (m_symbol,m_tf,0,need,t) <need) return 0;
      double cur=cl[0];
      double atr=GetATRCached(); if(atr<=0) atr=1.0;

      for(int i=bars;i>=3;i--) {
         double rng=hi[i]-lo[i]; if(rng<=0) continue;
         double body=MathAbs(cl[i]-op[i]);
         double body_ratio=body/rng; // relación cuerpo/rango

         // Bullish OB: vela bajista seguida de impulso fuerte alcista
         if(cl[i]<op[i] && body_ratio>0.3) {
            // Medir impulso: cuánto subió en las 3 velas siguientes
            double imp=0; for(int k=1;k<=MathMin(3,i-1);k++) imp+=(cl[i-k]-cl[i-k+1]);
            double imp_ratio=imp/rng;
            if(imp_ratio>0.8) {  // impulso >=80% del rango del OB
               ArrayResize(obs,cnt+1);
               obs[cnt].t_start  = t[i];
               obs[cnt].t_end    = t[0];
               obs[cnt].top      = hi[i];
               obs[cnt].bottom   = lo[i];
               obs[cnt].is_bull  = true;
               // Quality: body ratio + impulso + tamaño en ATR
               double size_score  = MathMin(rng/atr*30,40);
               double body_score  = body_ratio*30;
               double imp_score   = MathMin(imp_ratio*30,30);
               obs[cnt].quality   = (int)MathMin(body_score+imp_score+size_score,100);
               // Contar toques posteriores
               int touches=0;
               for(int k=i-1;k>=0;k--)
                  if(lo[k]<=hi[i] && hi[k]>=lo[i]) touches++;
               obs[cnt].touches   = touches;
               obs[cnt].mitigated = (cur>=lo[i] && cur<=hi[i]) || (touches>=2 && cur<lo[i]);
               obs[cnt].is_breaker= obs[cnt].mitigated && (touches>=1); // breaker: mitigado pero actúa como resistencia
               cnt++;
            }
         }
         // Bearish OB
         if(cl[i]>op[i] && body_ratio>0.3) {
            double imp=0; for(int k=1;k<=MathMin(3,i-1);k++) imp+=(cl[i-k+1]-cl[i-k]);
            double imp_ratio=imp/rng;
            if(imp_ratio>0.8) {
               ArrayResize(obs,cnt+1);
               obs[cnt].t_start  = t[i];
               obs[cnt].t_end    = t[0];
               obs[cnt].top      = hi[i];
               obs[cnt].bottom   = lo[i];
               obs[cnt].is_bull  = false;
               double size_score = MathMin(rng/atr*30,40);
               double body_score = body_ratio*30;
               double imp_score  = MathMin(imp_ratio*30,30);
               obs[cnt].quality  = (int)MathMin(body_score+imp_score+size_score,100);
               int touches=0;
               for(int k=i-1;k>=0;k--)
                  if(lo[k]<=hi[i] && hi[k]>=lo[i]) touches++;
               obs[cnt].touches  = touches;
               obs[cnt].mitigated=(cur>=lo[i] && cur<=hi[i]) || (touches>=2 && cur>hi[i]);
               obs[cnt].is_breaker=obs[cnt].mitigated && (touches>=1);
               cnt++;
            }
         }
      }
      return cnt;
   }

   //─── FVGs v3.1 con fill% y tamaño en ATR
   int GetFVGs(GMFVG &fvgs[], int bars=100) {
      int cnt=0;
      ArrayResize(fvgs,0);
      double hi[],lo[],cl[]; datetime t[];
      ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
      ArraySetAsSeries(cl,true); ArraySetAsSeries(t,true);
      if(CopyHigh (m_symbol,m_tf,0,bars,hi)<bars) return 0;
      if(CopyLow  (m_symbol,m_tf,0,bars,lo)<bars) return 0;
      if(CopyClose(m_symbol,m_tf,0,bars,cl)<bars) return 0;
      if(CopyTime (m_symbol,m_tf,0,bars,t) <bars) return 0;
      double atr=GetATRCached(); if(atr<=0) atr=1.0;
      double cur=cl[0];

      for(int i=bars-2;i>=1;i--) {
         // Bullish FVG: gap entre high[i+1] y low[i-1]
         if(lo[i-1]>hi[i+1]) {
            double fvg_top=lo[i-1], fvg_bot=hi[i+1], fvg_sz=fvg_top-fvg_bot;
            if(fvg_sz<atr*0.1) continue; // ignorar micro-FVGs
            ArrayResize(fvgs,cnt+1);
            fvgs[cnt].t_candle = t[i];
            fvgs[cnt].top      = fvg_top;
            fvgs[cnt].bottom   = fvg_bot;
            fvgs[cnt].is_bull  = true;
            fvgs[cnt].size_atr = fvg_sz/atr;
            // Fill%: cuánto del FVG ha sido rellenado
            double filled_to   = MathMin(cur, fvg_top);
            double fill_raw    = (filled_to-fvg_bot)/fvg_sz*100.0;
            fvgs[cnt].fill_pct = MathMax(0,MathMin(100,fill_raw));
            fvgs[cnt].filled   = (fvgs[cnt].fill_pct>=95.0);
            cnt++;
         }
         // Bearish FVG
         if(hi[i-1]<lo[i+1]) {
            double fvg_top=lo[i+1], fvg_bot=hi[i-1], fvg_sz=fvg_top-fvg_bot;
            if(fvg_sz<atr*0.1) continue;
            ArrayResize(fvgs,cnt+1);
            fvgs[cnt].t_candle = t[i];
            fvgs[cnt].top      = fvg_top;
            fvgs[cnt].bottom   = fvg_bot;
            fvgs[cnt].is_bull  = false;
            fvgs[cnt].size_atr = fvg_sz/atr;
            double filled_from = MathMax(cur, fvg_bot);
            double fill_raw    = (fvg_top-filled_from)/fvg_sz*100.0;
            fvgs[cnt].fill_pct = MathMax(0,MathMin(100,fill_raw));
            fvgs[cnt].filled   = (fvgs[cnt].fill_pct>=95.0);
            cnt++;
         }
      }
      return cnt;
   }

   //─── Liquidity levels v3.1 con swept detection
   int GetLiquidityLevels(GMLiqLevel &levels[], int bars=100) {
      int cnt=0;
      ArrayResize(levels,0);
      double hi[],lo[]; datetime t[];
      ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(t,true);
      if(CopyHigh(m_symbol,m_tf,0,bars,hi)<bars) return 0;
      if(CopyLow (m_symbol,m_tf,0,bars,lo)<bars) return 0;
      if(CopyTime(m_symbol,m_tf,0,bars,t) <bars) return 0;
      double avg_range=0;
      for(int i=0;i<bars;i++) avg_range+=hi[i]-lo[i];
      avg_range/=bars;
      double tol=avg_range*0.05;
      double cur_h=hi[0], cur_l=lo[0];

      for(int i=0;i<bars-5;i++) {
         for(int j=i+3;j<bars;j++) {
            if(MathAbs(hi[i]-hi[j])<tol) {
               bool exists=false;
               for(int k=0;k<cnt;k++) if(MathAbs(levels[k].price-hi[i])<tol&&levels[k].is_high){levels[k].touch_count++;exists=true;break;}
               if(!exists) {
                  ArrayResize(levels,cnt+1);
                  levels[cnt].price=hi[i]; levels[cnt].is_high=true;
                  levels[cnt].touch_count=2; levels[cnt].t_formed=t[i];
                  levels[cnt].swept=(cur_h>hi[i]+tol); // precio superó el EQH
                  cnt++;
               }
            }
            if(MathAbs(lo[i]-lo[j])<tol) {
               bool exists=false;
               for(int k=0;k<cnt;k++) if(MathAbs(levels[k].price-lo[i])<tol&&!levels[k].is_high){levels[k].touch_count++;exists=true;break;}
               if(!exists) {
                  ArrayResize(levels,cnt+1);
                  levels[cnt].price=lo[i]; levels[cnt].is_high=false;
                  levels[cnt].touch_count=2; levels[cnt].t_formed=t[i];
                  levels[cnt].swept=(cur_l<lo[i]-tol);
                  cnt++;
               }
            }
         }
      }
      return cnt;
   }

   //─── Premium / Discount / OTE
   GMPremiumDiscount GetPremiumDiscount(int bars=50) {
      GMPremiumDiscount pd;
      double hi[],lo[];
      ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
      if(CopyHigh(m_symbol,m_tf,0,bars,hi)<bars) return pd;
      if(CopyLow (m_symbol,m_tf,0,bars,lo)<bars) return pd;
      double rh=hi[0],rl=lo[0];
      for(int i=1;i<bars;i++) { if(hi[i]>rh)rh=hi[i]; if(lo[i]<rl)rl=lo[i]; }
      double diff=rh-rl;
      pd.range_high   =rh; pd.range_low=rl;
      pd.equilibrium  =(rh+rl)/2.0;
      pd.premium_zone =(rh+pd.equilibrium)/2.0;
      pd.discount_zone=(rl+pd.equilibrium)/2.0;
      pd.ote_bull_low =rh-diff*0.786;
      pd.ote_bull_high=rh-diff*0.618;
      pd.ote_bear_low =rl+diff*0.618;
      pd.ote_bear_high=rl+diff*0.786;
      return pd;
   }

   //─── Inducement: pequeño swing que actúa como trampa antes del verdadero movimiento
   //    En tendencia bajista, un pequeño pullback sube a EQH → baja fuerte (inducement bull → bearish move)
   bool DetectInducement_Bull(GMSwing &swings[], int count, GMLiqLevel &liqs[], int liq_cnt) {
      if(count<3) return false;
      // Buscar el swing high más reciente
      for(int i=count-1;i>=0;i--) {
         if(!swings[i].is_high) continue;
         // Verificar si ese swing high está cerca de un nivel de liquidez (EQH)
         for(int j=0;j<liq_cnt;j++) {
            if(!liqs[j].is_high || liqs[j].swept) continue;
            double dist=MathAbs(swings[i].price-liqs[j].price);
            if(dist<GetATRCached()*0.3) return true; // swing tocó EQH = inducement potencial
         }
         break;
      }
      return false;
   }
   bool DetectInducement_Bear(GMSwing &swings[], int count, GMLiqLevel &liqs[], int liq_cnt) {
      if(count<3) return false;
      for(int i=count-1;i>=0;i--) {
         if(swings[i].is_high) continue;
         for(int j=0;j<liq_cnt;j++) {
            if(liqs[j].is_high || liqs[j].swept) continue;
            double dist=MathAbs(swings[i].price-liqs[j].price);
            if(dist<GetATRCached()*0.3) return true;
         }
         break;
      }
      return false;
   }

   //─── Sweep de liquidez
   bool DetectLiquiditySweep(double swept_level, bool swept_high, int shift=1) {
      double hi[],lo[],cl[];
      ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
      if(CopyHigh (m_symbol,m_tf,shift,1,hi)<1) return false;
      if(CopyLow  (m_symbol,m_tf,shift,1,lo)<1) return false;
      if(CopyClose(m_symbol,m_tf,shift,1,cl)<1) return false;
      if(swept_high) return (hi[0]>swept_level && cl[0]<swept_level);
      else           return (lo[0]<swept_level && cl[0]>swept_level);
   }

   //─── ANÁLISIS COMPLETO: devuelve GMBias con todo calculado
   GMBias GetFullBias(int bars=100) {
      GMBias bias;
      ZeroMemory(bias);

      GMSwing   swings[]; int sw_cnt =GetSwings(swings,bars);
      GMOB      obs[];    int ob_cnt =GetOrderBlocks(obs,MathMin(bars,50));
      GMFVG     fvgs[];   int fvg_cnt=GetFVGs(fvgs,bars);
      GMLiqLevel liqs[];  int liq_cnt=GetLiquidityLevels(liqs,bars);
      GMPremiumDiscount pd=GetPremiumDiscount(bars);

      double cur=SymbolInfoDouble(m_symbol,SYMBOL_BID);
      double atr=GetATRCached(); if(atr<=0) return bias;

      bias.trend      =GetMarketTrend(swings,sw_cnt);
      bias.bos_bull   =DetectBOS_Bull(swings,sw_cnt);
      bias.bos_bear   =DetectBOS_Bear(swings,sw_cnt);
      bias.choch_bull =DetectCHoCH_Bull(swings,sw_cnt,bias.trend);
      bias.choch_bear =DetectCHoCH_Bear(swings,sw_cnt,bias.trend);

      // OTE zones
      bias.in_ote_bull=(cur>=pd.ote_bull_low && cur<=pd.ote_bull_high && cur<pd.equilibrium);
      bias.in_ote_bear=(cur>=pd.ote_bear_low && cur<=pd.ote_bear_high && cur>pd.equilibrium);

      // OB proximity (precio dentro o a 0.3 ATR del OB de calidad ≥60)
      for(int i=0;i<ob_cnt;i++) {
         if(obs[i].mitigated || obs[i].quality<50) continue;
         if(obs[i].is_bull && cur>=obs[i].bottom-atr*0.3 && cur<=obs[i].top+atr*0.3)
            bias.near_bull_ob=true;
         if(!obs[i].is_bull && cur>=obs[i].bottom-atr*0.3 && cur<=obs[i].top+atr*0.3)
            bias.near_bear_ob=true;
      }

      // FVG
      for(int i=0;i<fvg_cnt;i++) {
         if(fvgs[i].filled || fvgs[i].fill_pct>80) continue;
         if(fvgs[i].is_bull  && cur>=fvgs[i].bottom && cur<=fvgs[i].top) bias.in_bull_fvg=true;
         if(!fvgs[i].is_bull && cur>=fvgs[i].bottom && cur<=fvgs[i].top) bias.in_bear_fvg=true;
      }

      // Liquidity sweeps (últimas 3 velas)
      for(int sh=1;sh<=3;sh++) {
         for(int j=0;j<liq_cnt;j++) {
            if(liqs[j].is_high  && DetectLiquiditySweep(liqs[j].price,true, sh))  bias.liq_sweep_bear=true;
            if(!liqs[j].is_high && DetectLiquiditySweep(liqs[j].price,false,sh)) bias.liq_sweep_bull=true;
         }
      }

      // Inducements
      bias.inducement_bull=DetectInducement_Bull(swings,sw_cnt,liqs,liq_cnt);
      bias.inducement_bear=DetectInducement_Bear(swings,sw_cnt,liqs,liq_cnt);

      // Confluence score BULL
      int bull_score=0;
      if(bias.trend==1)          bull_score+=2;
      if(bias.bos_bull)          bull_score++;
      if(bias.choch_bull)        bull_score+=2;
      if(bias.in_ote_bull)       bull_score+=2;
      if(bias.near_bull_ob)      bull_score+=2;
      if(bias.in_bull_fvg)       bull_score++;
      if(bias.liq_sweep_bull)    bull_score+=2;
      if(bias.inducement_bear)   bull_score++; // inducement bajista → reversión alcista

      // Confluence score BEAR
      int bear_score=0;
      if(bias.trend==-1)         bear_score+=2;
      if(bias.bos_bear)          bear_score++;
      if(bias.choch_bear)        bear_score+=2;
      if(bias.in_ote_bear)       bear_score+=2;
      if(bias.near_bear_ob)      bear_score+=2;
      if(bias.in_bear_fvg)       bear_score++;
      if(bias.liq_sweep_bear)    bear_score+=2;
      if(bias.inducement_bull)   bear_score++;

      bias.confluence=MathMax(bull_score,bear_score);
      return bias;
   }

   // Multi-TF bias: compara TF actual con TF superior
   int GetHTFBias(ENUM_TIMEFRAMES htf, int bars=100) {
      CGoldMasterSMC htf_smc(m_symbol, htf, m_fractal_range);
      GMSwing htf_sw[]; int c=htf_smc.GetSwings(htf_sw,bars);
      return htf_smc.GetMarketTrend(htf_sw,c);
   }

   // Helpers
   bool InBullishOB(double price, GMOB &obs[], int count) {
      for(int i=0;i<count;i++)
         if(obs[i].is_bull&&!obs[i].mitigated&&price>=obs[i].bottom&&price<=obs[i].top) return true;
      return false;
   }
   bool InBearishOB(double price, GMOB &obs[], int count) {
      for(int i=0;i<count;i++)
         if(!obs[i].is_bull&&!obs[i].mitigated&&price>=obs[i].bottom&&price<=obs[i].top) return true;
      return false;
   }
};

#endif // GOLDMASTER_SMC_MQH
