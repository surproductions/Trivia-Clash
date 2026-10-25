import json,sys
# usage: _fix.py category 'old prompt' 'new prompt' ['new explanation']
p=f'questions/{sys.argv[1]}.json'; d=json.load(open(p)); hit=0
for q in d['questions']:
    if q[1]==sys.argv[2]:
        q[1]=sys.argv[3]; hit+=1
        if len(sys.argv)>4: q[6]=sys.argv[4]
assert hit==1, hit
with open(p,'w') as fh:
    fh.write('{\n  "category": "%s",\n  "format": "%s",\n  "questions": [\n' % (d['category'], d['format']))
    fh.write(',\n'.join('    '+json.dumps(q, ensure_ascii=False) for q in d['questions']))
    fh.write('\n  ]\n}\n')
print('fixed')
