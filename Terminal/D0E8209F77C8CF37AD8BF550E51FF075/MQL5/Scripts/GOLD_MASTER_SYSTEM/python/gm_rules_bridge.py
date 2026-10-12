"""Export an eligible, flat rules snapshot to the MT5 file sandbox. No orders."""
from __future__ import annotations
import hashlib
import json
import math
from pathlib import Path
import time

HERE = Path(__file__).resolve().parent
SOURCE = HERE / 'runtime' / 'rules_db.json'
TARGET = HERE.parents[2] / 'Files' / 'GoldMaster' / 'rules_db.json'
IMPLEMENTATIONS = {'EMA_CROSS_M15_H1'}


def eligible_rules(document):
    accepted, rejected = [], []
    for rule in document.get('rules', []):
        name = rule.get('name', '')
        certificate = rule.get('validation', {})
        valid = (document.get('test_only') is not True
                 and rule.get('active') is True and rule.get('validated') is True
                 and rule.get('test_only') is not True
                 and rule.get('implementation') in IMPLEMENTATIONS
                 and isinstance(rule.get('asset'), str) and bool(rule['asset'])
                 and rule.get('tf') == 'M15'
                 and certificate.get('costs_calibrated') is True
                 and certificate.get('pristine_holdout') is True
                 and bool(certificate.get('report_sha256')))
        try:
            score = float(rule.get('score', 0))
            count = int(rule.get('evidence_trades', 0))
            validated_at = float(certificate.get('validated_at', 0))
            valid = valid and math.isfinite(score) and 0 <= score <= 1 and count >= 30
            valid = valid and math.isfinite(validated_at) and 0 < validated_at <= time.time()
            metrics = [float(rule.get(k, 0)) for k in ('win_rate', 'profit_factor', 'expectancy_r')]
            valid = valid and all(math.isfinite(x) for x in metrics) and metrics[2] > 0
        except (TypeError, ValueError, OverflowError):
            valid = False
        if not valid:
            rejected.append(name)
            continue
        # Flat schema with name first, used by the MQL5 reader.
        accepted.append(dict(name=name, active=True, validated=True, test_only=False,
            asset=rule['asset'], tf=rule['tf'], implementation=rule['implementation'],
            score=score, evidence_trades=count, validated_at=validated_at,
            win_rate=metrics[0], profit_factor=metrics[1], expectancy_r=metrics[2]))
    return accepted, rejected


def export_snapshot(source=SOURCE, target=TARGET):
    document = json.loads(source.read_text(encoding='utf-8')) if source.exists() else {'rules': []}
    accepted, rejected = eligible_rules(document)
    payload = dict(version=2, generated_at=time.time(), execution='disabled',
                   rules=accepted, rejected_rules=rejected)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(payload, indent=2, allow_nan=False), encoding='utf-8')
    temporary.replace(target)
    return dict(target=str(target), exported=len(accepted), rejected=rejected,
                sha256=hashlib.sha256(target.read_bytes()).hexdigest())


if __name__ == '__main__':
    print(json.dumps(export_snapshot()))
