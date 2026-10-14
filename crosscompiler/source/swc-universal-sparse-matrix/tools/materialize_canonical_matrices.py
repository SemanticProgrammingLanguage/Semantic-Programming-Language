import csv, json, pathlib
root=pathlib.Path(__file__).resolve().parents[1]
cov=json.loads((root/'reports'/'uast-coverage-report.json').read_text(encoding='utf-8-sig'))
def emit(name, fields, rows):
 with (root/'matrices'/name).open('w',encoding='utf-8',newline='') as f:
  w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); w.writerows(rows)
emit('uast_kinds.csv',['canonical_id','kind','status','reason'],[{'canonical_id':i,'kind':r['structural_kind'],'status':r['status'],'reason':r.get('reason','')} for i,r in enumerate(cov['kinds'])])
emit('uast_relations.csv',['relation','status'],[{'relation':x,'status':'INVENTORIED'} for x in cov['relations']])
emit('uast_required_contracts.csv',['kind','required_relations','dependencies','contract_status'],[{'kind':r['structural_kind'],'required_relations':'|'.join(r.get('required_relations',[])),'dependencies':'|'.join(r.get('dependencies',[])),'contract_status':r['status']} for r in cov['kinds']])
emit('native_support.csv',['kind','status','native_execution_proven','evidence'],[{'kind':r['structural_kind'],'status':r['status'],'native_execution_proven':'1' if r['status']=='NATIVE_PROVEN' else '0','evidence':r.get('reason','')} for r in cov['kinds']])
