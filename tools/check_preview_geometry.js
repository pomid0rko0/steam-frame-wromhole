// Evaluate the preview page's geometry code in Node and print eye states.
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const a = html.indexOf('// ---------------------------------------------------------------- geometry');
const b = html.indexOf('// ---------------------------------------------------------------- GL');
const fn = new Function(html.slice(a, b) + '\nreturn eyeState;');
const eyeState = fn();
for (const [d, o] of JSON.parse(process.argv[3])) {
  const s = eyeState(d, o);
  console.log(JSON.stringify({ d, o, foot_l: +s.foot.l.toFixed(6), foot_n: s.foot.n.map(v => +v.toFixed(6)), head_l: +s.l.toFixed(6), head_n: s.n.map(v => +v.toFixed(6)), back: s.frame[2].map(v => +v.toFixed(6)) }));
}
