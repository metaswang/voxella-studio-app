import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { Script } from 'node:vm';
const target='../Sources/VoxstudioPro/Resources/MCPApps';
await mkdir(target,{recursive:true});
const template=await readFile('index.html','utf8');
const styles=await readFile('shared/style.css','utf8');
for(const name of ['library','transcription','session','dubbing','workspace']) {
 const result=await build({entryPoints:[`panels/${name}.ts`],bundle:true,write:false,format:'iife',target:'es2022',minify:true,legalComments:'inline'});
 let html=template.replace('<!--STYLES-->',()=>styles);
 const marker='<!--BUNDLE-->';
 if(html.split(marker).length!==2)throw new Error('Expected exactly one bundle insertion marker');
 const script=result.outputFiles[0].text.replace(/<\/script/gi,'<\\/script');
 new Script(script,{filename:`voxstudio-${name}.js`});
 // Function replacement is essential: literal $&, $` and $' occur in SDK code.
 html=html.replace(marker,()=>`<script>${script}</script>`);
 if(name==='workspace')html=html.replace('<body>','<body><!--voxstudio-session-companion-v1-->');
 await writeFile(`${target}/${name}.html`,html);
 if(name==='library')await writeFile(`${target}/workbench.html`,html);
 console.log(`${name}: ${Buffer.byteLength(html)} bytes · script syntax checked`);
}
