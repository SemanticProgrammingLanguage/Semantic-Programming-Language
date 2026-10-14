#!/usr/bin/env python3
"""Produce an auditable native-rule inventory from existing matrices; no fake rules."""
import argparse,csv,json
from pathlib import Path
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--root',required=True);ap.add_argument('--output',required=True);a=ap.parse_args();r=Path(a.root);rows=[]
 with (r/'matrices'/'uast_kinds.csv').open(encoding='utf-8-sig',newline='') as f:
  for x in csv.DictReader(f): rows.append({'kind':x.get('kind') or x.get('uast_kind'),'status':'CATALOGUED','evidence':x})
 out={'schema':'swc.native-rule-inventory.v1','rules':rows,'native_execution_requires':'existing SWC emitter and validated contract'};Path(a.output).write_text(json.dumps(out,indent=2),encoding='utf-8');print('KINDS=%d'%len(rows))
if __name__=='__main__':main()
