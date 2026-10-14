#!/usr/bin/env python3
import argparse,json
from pathlib import Path
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--input',required=True);ap.add_argument('--output',required=True);a=ap.parse_args();d=json.loads(Path(a.input).read_text(encoding='utf-8'));ns=d['nodes']; ids=[str(n['id']) for n in ns]; S=set(ids); rel=d['relations']; dangling=[]
 for r in rel:
  if str(r.get('from')) not in S:dangling.append(r)
  t=r.get('to',{});
  if t.get('domain')=='node' and str(t.get('id')) not in S:dangling.append(r)
 result={'schema':'swc.semantic-graph-validation.v1','nodes':len(ns),'relations':len(rel),'duplicate_ids':len(ids)!=len(S),'dangling_relations':len(dangling),'status':'PASS' if len(ids)==len(S) and not dangling else 'FAIL'}
 Path(a.output).write_text(json.dumps(result,indent=2),encoding='utf-8'); print(result['status'])
if __name__=='__main__':main()
