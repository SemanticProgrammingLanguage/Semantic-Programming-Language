import json,re
from pathlib import Path
root=Path('tmp/incoming-go-se-status');out=[]
for p in root.glob('*.se'):
    t=p.read_text(encoding='utf-8',errors='ignore')
    names=sorted(set(re.findall(r'"function_binding":"([^"]+)"',t)))
    kinds=sorted(set(re.findall(r'"structural_kind":"([^"]+)"',t)))
    out.append({'file':p.name,'bytes':p.stat().st_size,'closures':len(names),'sample_closures':names[:30],'uast_kinds':len(kinds)})
Path('integration/swc-universal-sparse-matrix/reports/go-se-source-inventory.json').write_text(json.dumps({'schema':'swc.go-se-source-inventory.v1','status':'EVIDENCE_ONLY','files':out},indent=2),encoding='utf-8')
print(json.dumps(out,indent=2))
