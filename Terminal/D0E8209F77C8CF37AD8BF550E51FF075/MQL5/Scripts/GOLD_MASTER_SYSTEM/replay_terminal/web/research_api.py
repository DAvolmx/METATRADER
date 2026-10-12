"""Read-only strategy archive endpoints; files remain within project runtime."""
import json
from pathlib import Path
from fastapi import HTTPException
from fastapi.responses import FileResponse

RUNTIME=Path(__file__).parents[2]/'python'/'runtime'

def archive_folder():
    pointer=json.loads((RUNTIME/'research_archive_latest.json').read_text(encoding='utf-8'))
    folder=(RUNTIME/pointer['folder']/'strategy_archive').resolve()
    if not folder.is_relative_to(RUNTIME.resolve()): raise ValueError('invalid archive path')
    return folder

def archive_summary():
    try:
        folder=archive_folder();report=json.loads((folder/'report.json').read_text(encoding='utf-8'))
        accepted=[]
        for dataset,row in report['datasets'].items():
            for strategy in row['strategies']:
                if strategy['screen_passed']:
                    accepted.append(dict(dataset=dataset,strategy=strategy['description'],
                        rr=strategy['rr'],test=strategy['test'],validated=False))
        return dict(available=True,datasets=len(report['datasets']),families=10,
                    accepted=accepted,promotion_allowed=False,report_url='/api/research/archive/report')
    except (OSError,ValueError,KeyError):
        return dict(available=False,accepted=[],promotion_allowed=False)

def register_research(app):
    @app.get('/api/research/archive')
    async def summary(): return archive_summary()

    @app.get('/api/research/archive/report')
    async def report():
        try: path=archive_folder()/'ARCHIVERO_ESTRATEGIAS.md'
        except (OSError,ValueError,KeyError): raise HTTPException(404,'Archivo no disponible')
        if not path.exists(): raise HTTPException(404,'Archivo no disponible')
        return FileResponse(path,media_type='text/plain; charset=utf-8')
