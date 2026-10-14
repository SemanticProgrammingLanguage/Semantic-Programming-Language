#!/usr/bin/env python3
"""Validate/transport a canonical graph without changing its node semantics."""
import argparse,json
from pathlib import Path
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--input',required=True);ap.add_argument('--output',required=True);a=ap.parse_args()
 d=json.loads(Path(a.input).read_text(encoding='utf-8')); nodes=d.get('nodes',[]); ids={str(n['id']) for n in nodes}; bad=[]
 for r in d.get('relations',[]):
  if str(r.get('from')) not in ids: bad.append(('from',r.get('from')))
  t=r.get('to',{});
  if t.get('domain')=='node' and str(t.get('id')) not in ids: bad.append(('to',t.get('id')))
 if bad: raise SystemExit('dangling relations: '+str(bad[:5]))
 out={'schema':'swc.canonical-semantic-graph.v1','nodes':len(nodes),'relations':len(d.get('relations',[])),'closures':sum(n.get('structural_kind')=='ClosureExpr' for n in nodes),'source':str(Path(a.input).resolve()),'status':'VALID'}
 Path(a.output).write_text(json.dumps(out,indent=2),encoding='utf-8'); print('VALID nodes=%d relations=%d'%(len(nodes),len(d.get('relations',[]))))
if __name__=='__main__':main()
