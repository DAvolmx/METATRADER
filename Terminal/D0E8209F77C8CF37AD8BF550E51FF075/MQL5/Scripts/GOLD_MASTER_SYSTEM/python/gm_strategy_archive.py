"""Evaluate ten frozen families; archive evidence, reject failures, never promote live."""
import argparse, hashlib, json, sys
from pathlib import Path
import numpy as np
import pandas as pd
from gm_strategy_catalog import CATALOG, signals
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE/'optimizer'))
from gm_validation import simulate_orders, split_trades, bootstrap_metrics, stationary_sample


def metrics(trades):
    r=np.array([t.r_multiple for t in trades]);wins=r[r>0].sum();loss=-r[r<0].sum()
    return dict(n=len(r),expectancy_R=float(r.mean()) if len(r) else None,
        total_R=float(r.sum()),profit_factor=float(wins/loss) if loss>0 else None,
        win_rate=float((r>0).mean()) if len(r) else None)

def windows(f,sig,point,bounds,commission_price=0,spread_multiplier=1):
    data=dict(o=f['open'],h=f['high'],l=f['low'],c=f['close'],spread=f['spread']*spread_multiplier)
    out=[]
    for lo,hi in zip(bounds[:-1],bounds[1:]):
        trades=simulate_orders(data,sig,point,48,commission_price=commission_price,
                               slippage_points=2,start_bar=lo,end_bar=hi)
        out.append([t for t in trades if t.reason!='window_end'])
    return out

def evaluate(folder,reuse_mt5=False):
    manifest=json.loads((folder/'manifest.json').read_text(encoding='utf-8'))
    output=folder/'strategy_archive';output.mkdir(exist_ok=True)
    previous=json.loads((output/'report.json').read_text(encoding='utf-8')) if reuse_mt5 and (output/'report.json').exists() else {}
    report={'promotion_allowed':False,'selection':'ten fixed H1 families; no parameter grid',
        'strategy_code_sha256':hashlib.sha256((HERE/'gm_strategy_catalog.py').read_bytes()).hexdigest(),
        'execution_code_sha256':hashlib.sha256((HERE/'optimizer'/'gm_validation.py').read_bytes()).hexdigest(),
        'limitations':manifest['limitations']+['Python research models are not native EA tests.',
        'Chronological historical screening is not a pristine future holdout.',
        'OHLC cannot reconstruct true tick ordering, historical margin or broker stop-out.',
        'Monte Carlo conditions on the same observed trades; it does not prove future profitability.'],
        'datasets':{}}
    markdown=['# Archivo multiactivo de estrategias','',
        'Diez familias fijas evaluadas por conjunto de datos. Solo los resultados que cumplen todos los filtros aparecen en el ranking. Ninguna regla se promociona a operación real.',
        '', 'Ejecución: señal al cierre, entrada en la siguiente apertura, SL primero si SL y TP coinciden en una vela; 48 barras máximo. Separación cronológica 60/20/20; se purgan operaciones truncadas al final de cada tramo.', '',
        'Costos: spread H1 reportado por Deriv o bid/ask de Dukascopy; Binance usa un escenario de 0,20 % ida/vuelta. Deslizamiento de 2 puntos por ejecución. Stress: doble spread y comisión adicional hipotética de USD 14 por lote ida/vuelta para CFDs; no representa una tarifa confirmada de la cuenta.', '',
        'Filtro de ranking: validación y prueba con al menos 30 trades; PF >= 1,20 y expectativa positiva en ambos; expectativa de stress positiva; límite bootstrap inferior de expectativa positivo (99,5 % por familia, corrección de 10 familias por dataset); percentil 5 Monte Carlo por encima del capital inicial.', '']
    for name,meta in manifest['datasets'].items():
        if meta['asset']=='dxy': continue
        if meta.get('data_quality_passed') is False or meta.get('tf') != 'H1':
            markdown += [f'## {name}', '', 'Datos preservados pero excluidos del ranking por cobertura incompleta o resolución diferente de H1.', '']
            continue
        df=pd.read_csv(folder/meta['file']);df['time']=pd.to_datetime(df.time,utc=True)
        cached=previous.get('datasets',{}).get(name,{})
        use_cached=meta['source']=='Deriv MT5' and cached.get('source',{}).get('sha256')==meta['sha256']
        f,all_signals=({}, {}) if use_cached else signals(df)
        n=len(df);bounds=[300,int(n*.6),int(n*.8),n]
        rows=list(cached['strategies']) if use_cached else []
        asset_folder=output/name;asset_folder.mkdir(exist_ok=True)
        for key,sig in all_signals.items():
            train,validation,test=windows(f,sig,meta['point'],bounds)
            contract=meta.get('spec',{}).get('trade_contract_size',0)
            commission=14/contract if contract and meta['broker_tradable'] else 0
            stressed=windows(f,sig,meta['point'],bounds,commission,2)[-1]
            val=metrics(validation);oos=metrics(test);stress=metrics(stressed)
            seed=int.from_bytes(hashlib.sha256((name+key).encode()).digest()[:8],'big')
            rng=np.random.default_rng(seed);r=np.array([t.r_multiple for t in test])
            lower=None;mc=None
            if len(r)>=30:
                means=[stationary_sample(r,rng,max(1,int(np.sqrt(len(r))))).mean() for _ in range(1000)]
                lower=float(np.percentile(means,.5))
                mc=bootstrap_metrics(r*.25,100,50,rng,runs=1000)
            reasons=[]
            for label,m in [('validation',val),('test',oos)]:
                if m['n']<30: reasons.append(label+'_insufficient_trades')
                if not m['expectancy_R'] or m['expectancy_R']<=0: reasons.append(label+'_nonpositive_expectancy')
                if m['profit_factor'] is None or m['profit_factor']<1.2: reasons.append(label+'_PF_below_1.2_or_no_losses')
            if not stress['expectancy_R'] or stress['expectancy_R']<=0: reasons.append('cost_stress_failed')
            if lower is None or lower<=0: reasons.append('bootstrap_expectancy_not_positive')
            if mc is None or mc['final_p5']<=100: reasons.append('montecarlo_lower_tail_failed')
            row=dict(strategy=key,description=CATALOG[key][0],rr=CATALOG[key][1],
                train=metrics(train),validation=val,test=oos,stress=stress,
                expectancy_lower_99_5=lower,montecarlo=mc,seed=seed,
                historical_net_positive=oos['n']>0 and oos['total_R']>0,
                screen_passed=not reasons,rejection_reasons=reasons,validated=False)
            rows.append(row)
            pd.DataFrame([t._asdict() for t in test]).to_csv(asset_folder/(key+'_test_trades.csv'),index=False)
            (asset_folder/(key+'.json')).write_text(json.dumps(row,indent=2,allow_nan=False),encoding='utf-8')
        ranked=sorted([r for r in rows if r['screen_passed']],key=lambda r:r['validation']['expectancy_R'],reverse=True)[:10]
        report['datasets'][name]={'source':meta,'strategies':rows,'ranking':[r['strategy'] for r in ranked],
            'positive_test_count':sum(r['historical_net_positive'] for r in rows),
            'screen_passed_count':len(ranked)}
        markdown += [f'## {name} — {meta["symbol"]}', '',f'{meta["bars"]} barras H1: {meta["start"]} a {meta["end"]}. Fuente: {meta["source"]}.', '']
        if ranked:
            markdown += ['| Estrategia | Trades prueba | PF | Expectativa R | Stress R/trade |','|---|---:|---:|---:|---:|']
            markdown += [f'| {r["description"]} | {r["test"]["n"]} | {r["test"]["profit_factor"]:.2f} | {r["test"]["expectancy_R"]:.3f} | {r["stress"]["expectancy_R"]:.3f} |' for r in ranked]
        else: markdown += ['Ninguna de las diez familias superó todos los filtros. No se completan puestos con estrategias que fallaron.']
        markdown += ['',f'Familias con suma R positiva en prueba histórica: {sum(r["historical_net_positive"] for r in rows)}/10. Esto por sí solo no basta para el ranking. Detalles de cada familia y causas de rechazo en esta carpeta.', '']
        print(name,'qualified',len(ranked),'positive',sum(r['historical_net_positive'] for r in rows),flush=True)
    markdown += ['## Datos no disponibles','',json.dumps(manifest['errors'],ensure_ascii=False,indent=2)]
    (output/'report.json').write_text(json.dumps(report,indent=2,allow_nan=False),encoding='utf-8')
    (output/'ARCHIVERO_ESTRATEGIAS.md').write_text('\n'.join(markdown),encoding='utf-8')
    (HERE/'runtime'/'research_archive_latest.json').write_text(json.dumps({'folder':folder.name}),encoding='utf-8')
    print(output/'ARCHIVERO_ESTRATEGIAS.md',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('folder',type=Path);p.add_argument('--reuse-mt5',action='store_true');a=p.parse_args();evaluate(a.folder,a.reuse_mt5)
