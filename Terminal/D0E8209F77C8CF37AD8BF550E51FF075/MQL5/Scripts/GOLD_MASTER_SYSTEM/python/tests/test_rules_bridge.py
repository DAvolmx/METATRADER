from copy import deepcopy
from gm_rules_bridge import eligible_rules, export_snapshot
import json


def candidate():
    return dict(name='synthetic_schema_test', active=True, validated=True,
        asset='XAUUSDmicro', tf='M15', implementation='EMA_CROSS_M15_H1',
        score=.7, evidence_trades=50, win_rate=.5, profit_factor=1.4,
        expectancy_r=.2, validation=dict(costs_calibrated=True,
        pristine_holdout=True, report_sha256='test-fixture-only', validated_at=1))


def test_bridge_rejects_demo_unverified_and_unknown_signal():
    r=candidate()
    assert eligible_rules({'test_only':True,'rules':[r]})[0] == []
    for change in ({'active':False},{'validated':False},{'test_only':True},
                   {'implementation':'BOS_H1'},{'score':float('nan')},
                   {'validation':{}},{'evidence_trades':0}):
        altered={**deepcopy(r),**change}
        assert eligible_rules({'rules':[altered]})[0] == []


def test_bridge_exports_flat_snapshot_with_no_nested_conditions(tmp_path):
    source=tmp_path/'source.json'; target=tmp_path/'files'/'rules.json'
    source.write_text(json.dumps({'rules':[candidate()]}),encoding='utf-8')
    report=export_snapshot(source,target)
    result=json.loads(target.read_text())
    assert report['exported']==1
    assert list(result['rules'][0])[0]=='name'
    assert result['rules'][0]['validated_at']==1
    assert result['execution']=='disabled'
