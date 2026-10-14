#!/usr/bin/env python3
"""Compute the deterministic capability closure from the checked-in matrices."""
import csv, json, argparse
from pathlib import Path

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--matrix-root',required=True); ap.add_argument('--output',required=True); a=ap.parse_args()
    root=Path(a.matrix_root); deps={}
    with (root/'primitive_dependencies.csv').open(encoding='utf-8-sig',newline='') as f:
        for row in csv.DictReader(f): deps[row['Capability']]=set(filter(None,row['Dependencies'].split('|')))
    native=set()
    p=root/'native_support.csv'
    if p.exists():
        with p.open(encoding='utf-8-sig',newline='') as f:
            for row in csv.DictReader(f):
                if str(row.get('status','')).upper() in {'NATIVE','NATIVE_PROVEN','DIRECT','SUPPORTED'}:
                    value=row.get('capability') or row.get('primitive') or row.get('name','')
                    if value: native.add(value)
    primitive={'CONST','EVAL','ADDR','LOAD','STORE','ALU','CMP','BRANCH','JUMP','CALL','RETURN'} | native
    rounds=[]
    while True:
        before=set(primitive)
        for cap,need in deps.items():
            if need <= primitive: primitive.add(cap)
        rounds.append({'round':len(rounds)+1,'activated':sorted(primitive-before)})
        if primitive==before: break
    report={'schema':'swc.matrix-fixedpoint.v1','rounds':rounds,'primitive_count':len(primitive),'activated_primitives':sorted(primitive),'blocked':{k:sorted(v-primitive) for k,v in deps.items() if not v<=primitive}}
    Path(a.output).write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('ROUNDS=%d PRIMITIVES=%d BLOCKED=%d'%(len(rounds),len(primitive),len(report['blocked'])))
if __name__=='__main__': main()
