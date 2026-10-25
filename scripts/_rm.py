import json,sys
p=f'questions/{sys.argv[1]}.json'; d=json.load(open(p)); bad=set(sys.argv[2:])
n=len(d['questions']); d['questions']=[q for q in d['questions'] if q[1] not in bad]
with open(p,'w') as fh:
    fh.write('{\n  "category": "%s",\n  "format": "%s",\n  "questions": [\n' % (d['category'], d['format']))
    fh.write(',\n'.join('    '+json.dumps(q, ensure_ascii=False) for q in d['questions']))
    fh.write('\n  ]\n}\n')
print(n-len(d['questions']),'removed from',sys.argv[1])
