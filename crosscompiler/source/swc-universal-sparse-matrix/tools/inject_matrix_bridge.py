#!/usr/bin/env python3
"""Add explicit, side-effect-free matrix probes to the reachable rich bridge."""
import argparse,json
from pathlib import Path
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--input',required=True);ap.add_argument('--output',required=True);a=ap.parse_args();d=json.loads(Path(a.input).read_text(encoding='utf-8'))
 ns=d['nodes']; rs=d['relations']; by={str(n['id']):n for n in ns}; scope='22629'
 if scope not in by: raise SystemExit('compile_uast_rich_support body not found')
 mx=max(int(n['id']) for n in ns)+1; existing=[r for r in rs if r.get('from')==int(scope) and r.get('kind')=='syntax.child']; ordinal=max([int(r.get('attributes',{}).get('ordinal',-1)) for r in existing]+[-1])+1
 for name,args in [('legacy_primitive_route',['matrix_probe','native']),('matrixUASTKind',['LiteralExpr']),('matrixOperationSemantics',['literal','const'])]:
  sym=mx; call=sym+1; assign=call+1; ids=[sym,call,assign]; mx+=3
  call_fields={'kind':'call','value':{'reference':{'domain':'node','id':str(sym)}},'arguments':[{'reference':{'domain':'node','id':str(sym+2+i)}} for i in range(len(args))],'scope_id':1}
  ns.extend([{'id':sym,'structural_kind':'SymbolRef','fields':{'kind':'identifier','name':name,'scope_id':1}}, {'id':call,'structural_kind':'CallExpr','fields':call_fields}, {'id':assign,'structural_kind':'AssignStmt','fields':{'kind':'assign','name':'matrix_probe_'+name,'operands':[{'reference':{'domain':'node','id':str(call)},'role':'expression'}],'scope_id':1}}])
  for i,v in enumerate(args):
   lid=mx;mx+=1;ns.append({'id':lid,'structural_kind':'LiteralExpr','fields':{'kind':'literal','operation':{'literal_kind':'string','text':v},'scope_id':1}}); call_fields['arguments'][i]['reference']['id']=str(lid);rs.append({'kind':'syntax.child','from':call,'to':{'domain':'node','id':str(lid)},'attributes':{'role':'argument','ordinal':i}})
  rs += [{'kind':'syntax.child','from':int(scope),'to':{'domain':'node','id':str(assign)},'attributes':{'role':'statement','ordinal':ordinal}}, {'kind':'syntax.child','from':assign,'to':{'domain':'node','id':str(call)},'attributes':{'role':'expression','ordinal':0}}, {'kind':'syntax.child','from':call,'to':{'domain':'node','id':str(sym)},'attributes':{'role':'callee','ordinal':0}}, {'kind':'call.calls','from':call,'to':{'domain':'node','id':str(sym)}}]; ordinal+=1
 by[scope]['fields'].setdefault('members',[]).extend({'domain':'node','id':str(x)} for x in [assign])
 Path(a.output).write_text(json.dumps(d,separators=(',',':')),encoding='utf-8')
 print('INJECTED=3')
if __name__=='__main__':main()
