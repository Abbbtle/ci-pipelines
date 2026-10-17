// Writes a tiny site to dist/. Accepts --base=/path/ like Vite, so the self-test can check
// that build-args reach the build script.
import { mkdirSync, writeFileSync } from 'node:fs';
import { greeting } from './src/greeting.js';

const baseArg = process.argv.find((arg) => arg.startsWith('--base='));
const base = baseArg ? baseArg.slice('--base='.length) : '/';

mkdirSync('dist/assets', { recursive: true });
writeFileSync(
  'dist/assets/app.js',
  `document.querySelector('output').textContent = ${JSON.stringify(greeting('CI'))};\n`,
);
writeFileSync(
  'dist/index.html',
  `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>ci-pipelines self-test</title>
  </head>
  <body>
    <h1>ci-pipelines self-test</h1>
    <p>This page is built by the Node.js test project and published by deploy-pages.yml.</p>
    <p>Script check: <output>the script did not load</output></p>
    <script src="${base}assets/app.js"></script>
  </body>
</html>
`,
);
console.log(`Built dist/ with base ${base}`);
