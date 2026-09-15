import{$ as e,E as t,H as n,J as r,K as i,L as a,O as o,Q as s,T as c,U as l,W as u,X as d,Y as f,a as p,dt as m,j as h,k as g,nt as _,ot as v,st as y,y as b}from"../chunks/C9LrvWAa.js";import{t as x}from"../chunks/BoW1EjBt.js";import"../chunks/xihTtKlq.js";import{t as S}from"../chunks/ovT3ZlFF.js";import{a as C,l as w,o as T,u as E}from"../chunks/Bx1oxhYe.js";import{c as D,l as O,o as ee}from"../chunks/BT4j7DCw.js";import{r as te,t as k}from"../chunks/DYV8C2HT.js";var A={program:!0,typescript:!0,json:!0,proto:!0,relation:!0,type:!0,template:!0,agent:!0,skill:!0},j={channel:[1,.63,.18],note:[.42,.62,.95],task:[.36,.78,.72],query:[.8,.52,.95],set:[.8,.52,.95],collection:[.95,.75,.35],person:[.9,.45,.55],peer:[.9,.45,.55],agent:[.55,.85,.4]};function M(e){let t=j[e];if(t)return t;let n=2166136261;for(let t of e)n=(n^t.charCodeAt(0))*16777619>>>0;return[.35+n%97/200,.35+Math.floor(n/97)%97/200,.45+Math.floor(n/9409)%97/250]}var N=[.55,.65,.85,.5],P=[.95,.75,.35,.4],F=[.8,.52,.95,.3];function I(e){return(e?.valuesValue?.items??[]).map(e=>e.stringValue).filter(e=>typeof e==`string`)}async function ne(e,t){let n=(await E({limit:2e3})).records.filter(n=>{if(A[n.typeKey]||n.typeKey===`channel`)return!1;let r=n.fields.channel?.stringValue??``;return r===e||r===``&&t}),r=[],i=new Map;for(let e of n)i.set(e.id,r.length),r.push({id:e.id,name:[e.fields.iconEmoji?.stringValue,e.fields.name?.stringValue||e.id.slice(0,8)].filter(Boolean).join(` `),kind:e.typeKey,radius:10,hasAgent:!1,color:M(e.typeKey),cluster:-1,x:(Math.random()-.5)*600,y:(Math.random()-.5)*600,vx:0,vy:0});let a=[],o=Array(r.length).fill(0),s=(e,t,n)=>{e!==t&&(a.push({a:e,b:t,color:n}),o[e]+=1,o[t]+=1)},c=[];for(let e of n){let t=i.get(e.id);for(let[n,r]of Object.entries(e.fields))if(n!==`channel`){if(n===`collectionIds`){for(let e of I(r)){let n=i.get(e);n!==void 0&&s(n,t,P)}continue}if(r.linkValue){let e=i.get(r.linkValue.targetId);e!==void 0&&s(e,t,N)}else if(r.valuesValue){for(let e of r.valuesValue.items)if(e.linkValue){let n=i.get(e.linkValue.targetId);n!==void 0&&s(n,t,N)}}}(e.typeKey===`query`||e.typeKey===`set`)&&c.push(e)}for(let e of c){let t=i.get(e.id);try{let n=await E({setId:e.id,limit:50});for(let e of n.records){let n=i.get(e.id);n!==void 0&&n!==t&&s(t,n,F)}}catch{}}for(let[e,t]of r.entries())t.radius=t.kind===`channel`?14:5+1.6*Math.sqrt(o[e]);try{let e=await E({type:`agent`,limit:500});for(let t of e.records){let e=t.fields.bound_object?.stringValue;if(!e)continue;let n=i.get(e);n!==void 0&&(r[n].hasAgent=!0)}}catch{}let l=new Map;for(let[e,t]of r.entries()){let n=l.get(t.kind);n?n.push(e):l.set(t.kind,[e])}let u=new Map;try{let e=await E({type:`type`,limit:300});for(let t of e.records){let e=t.fields.key?.stringValue;if(!e)continue;let n=[t.fields.iconEmoji?.stringValue,t.fields.name?.stringValue||e].filter(Boolean).join(` `);u.set(e,n)}}catch{}let d=[...l.entries()].sort((e,t)=>t[1].length-e[1].length),f=[];for(let e=0,t=d.length-1;e<=t;e++,t--)f.push(d[e]),e!==t&&f.push(d[t]);let p=f.map(([,e])=>24+11*Math.sqrt(e.length)),m=p.reduce((e,t)=>e+t,0),h=Math.max(340,m/Math.PI*.75,46*Math.sqrt(r.length)),g=[],_=0;for(let[e,[t,n]]of f.entries()){let i=(_+p[e]/2)/m*Math.PI*2-Math.PI/2;_+=p[e];let a=Math.cos(i)*h,o=Math.sin(i)*h;g.push({kind:t,label:u.get(t)??t,x:a,y:o,count:n.length});let s=40+11*Math.sqrt(n.length);for(let[t,i]of n.entries()){let c=t*2.399963,l=s*Math.sqrt(t/Math.max(1,n.length));r[i].cluster=e,r[i].x=a+Math.cos(c)*l,r[i].y=o+Math.sin(c)*l}}return{nodes:r,edges:a,anchors:g}}function L(e,t,n=-1){let r=.0015,i=.14,a=e.nodes.length;for(let n=0;n<a;n++)for(let r=n+1;r<a;r++){let i=e.nodes[n],a=e.nodes[r],o=a.x-i.x,s=a.y-i.y,c=Math.max(o*o+s*s,25),l=Math.sqrt(c),u=-600*t/c;i.vx+=o/l*u,i.vy+=s/l*u,a.vx-=o/l*u,a.vy-=s/l*u}for(let n of e.edges){let r=e.nodes[n.a],i=e.nodes[n.b],a=i.x-r.x,o=i.y-r.y,s=Math.max(Math.hypot(a,o),1),c=(s-110)/s*t*.05;r.vx+=a*c*.5,r.vy+=o*c*.5,i.vx-=a*c*.5,i.vy-=o*c*.5}for(let[a,o]of e.nodes.entries()){if(o.vx-=o.x*r*t,o.vy-=o.y*r*t,o.cluster>=0&&e.anchors[o.cluster]&&(o.vx+=(e.anchors[o.cluster].x-o.x)*i*t,o.vy+=(e.anchors[o.cluster].y-o.y)*i*t),o.vx*=.6,o.vy*=.6,a===n){o.vx=0,o.vy=0;continue}o.x+=o.vx,o.y+=o.vy}for(let t=0;t<2;t++)for(let t=0;t<a;t++)for(let r=t+1;r<a;r++){let i=e.nodes[t],a=e.nodes[r],o=a.x-i.x,s=a.y-i.y,c=i.radius+a.radius+14,l=Math.hypot(o,s);if(l>=c)continue;l===0&&(o=Math.cos(t*2.399963),s=Math.sin(t*2.399963),l=1);let u=(c-l)/l,d=t===n?0:r===n?1:a.radius/(i.radius+a.radius),f=1-d;i.x-=o*u*d,i.y-=s*u*d,a.x+=o*u*f,a.y+=s*u*f}}var re={wgslSrc:`struct BmUniforms {
  uScale : f32,
  uOffset : vec2f,
  uViewport : vec2f,
}
@group(0) @binding(0) var<uniform> bm_u : BmUniforms;
struct BmVSIn {
  @location(0) aCorner : vec2f,
  @location(1) iCenter : vec2f,
  @location(2) iRadius : f32,
  @location(3) iTint : vec3f,
  @location(4) iFlags : f32,
}
struct BmVSOut {
  @builtin(position) bm_position : vec4f,
  @location(0) vUv : vec2f,
  @location(1) vTint : vec3f,
  @location(2) vFlags : f32,
}
@vertex
fn vs_main(bm_in : BmVSIn) -> BmVSOut {
  var bm_out : BmVSOut;
  bm_out.vUv = bm_in.aCorner;
  bm_out.vTint = bm_in.iTint;
  bm_out.vFlags = bm_in.iFlags;
  let rpx = max(bm_in.iRadius * bm_u.uScale, 3.0);
  let screenC = (bm_in.iCenter - bm_u.uOffset) * bm_u.uScale + bm_u.uViewport * 0.5;
  let screen = screenC + bm_in.aCorner * (rpx * 1.25);
  let clipX = screen.x / bm_u.uViewport.x * 2.0 - 1.0;
  let clipY = 1.0 - screen.y / bm_u.uViewport.y * 2.0;
  bm_out.bm_position = vec4f(vec2f(clipX, clipY), 0.0, 1.0);
  bm_out.bm_position.z = (bm_out.bm_position.z + bm_out.bm_position.w) * 0.5;
  return bm_out;
}
@fragment
fn fs_main(bm_in : BmVSOut) -> @location(0) vec4f {
  let s = bm_in.vUv * 1.25;
  let d = length(s);
  let fill = 1.0 - smoothstep(0.9, 1.0, d);
  let ring = smoothstep(1.04, 1.1, d) * (1.0 - smoothstep(1.16, 1.24, d));
  let color = bm_in.vTint * (1.0 + bm_in.vFlags * 0.25) + vec3f(1.0, 1.0, 1.0) * (ring * bm_in.vFlags * 0.9);
  let alpha = max(fill, ring * bm_in.vFlags);
  return vec4f(color * alpha, alpha);
}
`,attributes:{aCorner:`vec2`},instanceAttributes:{iCenter:`vec2`,iRadius:`float`,iTint:`vec3`,iFlags:`float`},uniforms:{uScale:`float`,uOffset:`vec2`,uViewport:`vec2`},layout:{attributes:[{name:`aCorner`,type:`vec2`,location:0,size:2,divisor:0},{name:`iCenter`,type:`vec2`,location:1,size:2,divisor:1},{name:`iRadius`,type:`float`,location:2,size:1,divisor:1},{name:`iTint`,type:`vec3`,location:3,size:3,divisor:1},{name:`iFlags`,type:`float`,location:4,size:1,divisor:1}],uniforms:[{name:`uScale`,type:`float`,kind:`1f`,size:1,offset:0},{name:`uOffset`,type:`vec2`,kind:`2fv`,size:2,offset:8},{name:`uViewport`,type:`vec2`,kind:`2fv`,size:2,offset:16}],uniformBlockSize:32}},ie={wgslSrc:`struct BmUniforms {
  uScale : f32,
  uOffset : vec2f,
  uViewport : vec2f,
  uWidth : f32,
}
@group(0) @binding(0) var<uniform> bm_u : BmUniforms;
struct BmVSIn {
  @location(0) aQuad : vec2f,
  @location(1) iStart : vec2f,
  @location(2) iEnd : vec2f,
  @location(3) iColor : vec4f,
}
struct BmVSOut {
  @builtin(position) bm_position : vec4f,
  @location(0) vColor : vec4f,
}
@vertex
fn vs_main(bm_in : BmVSIn) -> BmVSOut {
  var bm_out : BmVSOut;
  bm_out.vColor = bm_in.iColor;
  let a = (bm_in.iStart - bm_u.uOffset) * bm_u.uScale + bm_u.uViewport * 0.5;
  let b = (bm_in.iEnd - bm_u.uOffset) * bm_u.uScale + bm_u.uViewport * 0.5;
  let along = b - a;
  let dir = normalize(along);
  let n = vec2f(0.0 - dir.y, dir.x);
  let p = a + along * bm_in.aQuad.y + n * (bm_in.aQuad.x * bm_u.uWidth * 0.5);
  let clipX = p.x / bm_u.uViewport.x * 2.0 - 1.0;
  let clipY = 1.0 - p.y / bm_u.uViewport.y * 2.0;
  bm_out.bm_position = vec4f(vec2f(clipX, clipY), 0.0, 1.0);
  bm_out.bm_position.z = (bm_out.bm_position.z + bm_out.bm_position.w) * 0.5;
  return bm_out;
}
@fragment
fn fs_main(bm_in : BmVSOut) -> @location(0) vec4f {
  return vec4f(bm_in.vColor.xyz * bm_in.vColor.w, bm_in.vColor.w);
}
`,attributes:{aQuad:`vec2`},instanceAttributes:{iStart:`vec2`,iEnd:`vec2`,iColor:`vec4`},uniforms:{uScale:`float`,uOffset:`vec2`,uViewport:`vec2`,uWidth:`float`},layout:{attributes:[{name:`aQuad`,type:`vec2`,location:0,size:2,divisor:0},{name:`iStart`,type:`vec2`,location:1,size:2,divisor:1},{name:`iEnd`,type:`vec2`,location:2,size:2,divisor:1},{name:`iColor`,type:`vec4`,location:3,size:4,divisor:1}],uniforms:[{name:`uScale`,type:`float`,kind:`1f`,size:1,offset:0},{name:`uOffset`,type:`vec2`,kind:`2fv`,size:2,offset:8},{name:`uViewport`,type:`vec2`,kind:`2fv`,size:2,offset:16},{name:`uWidth`,type:`float`,kind:`1f`,size:1,offset:24}],uniformBlockSize:32}},R=h(`<canvas class="svelte-1qnqgz"></canvas> <div class="labels svelte-1qnqgz"></div>`,1),z=h(`<p class="status svelte-1qnqgz"> </p>`),B=h(`<div class="stage svelte-1qnqgz"><!> <!></div>`);function V(h,E){y(E,!0);let A=e(void 0),j=e(void 0),M=e(`Loading graph…`),N=_(()=>T.channels[0]?.id??``),P=_(()=>O.id||a(N));_(()=>T.channels.find(e=>e.id===a(P))?.name??``);let F=_(()=>S.url.searchParams.get(`focus`)??``);u(()=>{let e=a(P),t=a(A),n=e===a(N)&&e!==``;if(!e){C();return}if(!t||!a(j))return;let r=null,i=!1;return s(M,`Loading graph…`),(async()=>{let t=await ne(e,n);if(s(M,t.nodes.length===0?`Nothing in this space yet.`:``,!0),!a(A)||i||t.nodes.length===0)return;let o=window.devicePixelRatio||1;a(A).width=Math.max(1,Math.floor(a(A).clientWidth*o)),a(A).height=Math.max(1,Math.floor(a(A).clientHeight*o));let c=await te(a(A),{clearColor:[.047,.055,.066,1]});if(i){c.destroy();return}let l=k(c,re,{blend:`alpha`}),u=k(c,ie,{blend:`alpha`});l.attributes.aCorner.set(new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1])),u.attributes.aQuad.set(new Float32Array([-1,0,1,0,-1,1,-1,1,1,0,1,1]));let d=t.nodes.length,f=new Float32Array(d*2),p=new Float32Array(d),m=new Float32Array(d*3),h=new Float32Array(d);for(let[e,n]of t.nodes.entries())p[e]=n.radius,m.set(n.color,e*3);let g=t.edges.length,_=new Float32Array(g*2),v=new Float32Array(g*2),y=new Float32Array(g*4);for(let[e,n]of t.edges.entries())y.set(n.color,e*4);let b=1,S=0,C=0,E=1,O=-1,N=a(F)?t.nodes.findIndex(e=>e.id===a(F)):-1,P=-1,I=!1,R=0,z=0,B=0,V=!0,H=[];for(let e=0;e<Math.min(100,d);e++){let e=document.createElement(`div`);e.className=`graph-label`,a(j).appendChild(e),H.push(e)}let U=[];for(let e of t.anchors){let t=document.createElement(`div`);t.className=`graph-anchor-label`,t.textContent=`${e.label} · ${e.count}`,a(j).appendChild(t),U.push(t)}let W=document.createElement(`div`);W.className=`graph-card`,W.style.display=`none`,a(j).appendChild(W);let G=new Map,K=-1,q,J=e=>e.replace(/[&<>"]/g,e=>({"&":`&amp;`,"<":`&lt;`,">":`&gt;`,'"':`&quot;`})[e]),ae=async e=>{let t=G.get(e);if(t)return t;let n=await w(e),r=J(n.fields.name?.stringValue||`Untitled`),i=J(n.fields.iconEmoji?.stringValue??``),a=D(T.relations,n.fields.channel?.stringValue||T.channels[0]?.id||``),o=[];for(let[e,t]of Object.entries(n.fields)){if([`name`,`iconEmoji`,`channel`,`collectionIds`,`viewFilters`,`viewSorts`,`viewRelations`,`pinnedIds`,`setOf`,`featuredRelations`].includes(e))continue;let n=``,r=``;if(t.stringValue===void 0?t.boolValue===void 0?t.intValue===void 0?t.valuesValue&&(n=t.valuesValue.items.map(e=>e.stringValue??``).filter(Boolean).join(`, `)):n=new Date(t.intValue).getFullYear()>1990?new Date(t.intValue).toLocaleDateString():String(t.intValue):r=`<span class="gc-chk${t.boolValue?` on`:``}"></span>`:n=t.stringValue,!n&&!r)continue;let i=a.find(t=>t.key===e),s=i?`${i.iconEmoji||ee(i.format)} ${i.name||e}`:e;if(o.push(`<div class="gc-row"><span class="gc-k">${J(s)}</span><span class="gc-v">${r||J(n.slice(0,60))}</span></div>`),o.length>=4)break}let s=new Map(n.blocks.map(e=>[e.id,e])),c=new Set([`__discussion__`]),l=[],u=e=>{if(c.has(e)||l.length>=8)return;let t=s.get(e);if(!t)return;let n=t.content.text;if(n?.text?.trim()){let e=n.style??0,t=e>=1&&e<=3?`gc-h`:e===8?`gc-check`:e===6||e===7?`gc-li`:`gc-p`,r=e===8?`<span class="gc-chk${n.checked?` on`:``}"></span> `:e===6?`• `:``;l.push(`<div class="${t}">${r}${J(n.text.slice(0,90))}</div>`)}for(let e of t.childrenIds??[])u(e)},d=n.blocks.filter(e=>!n.blocks.some(t=>(t.childrenIds??[]).includes(e.id)));for(let e of d)u(e.id);let f=`<div class="gc-title">${i?i+` `:``}${r}</div>${o.join(``)}${l.length?`<div class="gc-body">${l.join(``)}</div>`:``}`;return G.set(e,f),f},Y=e=>{if(clearTimeout(q),e<0){K=-1,W.style.display=`none`;return}e!==K&&(q=setTimeout(()=>{K=e;let n=t.nodes[e];ae(n.id).then(t=>{K===e&&(W.innerHTML=t,W.style.display=`block`)})},260))},X=()=>({w:a(A).clientWidth,h:a(A).clientHeight}),Z=(e,t)=>{let{w:n,h:r}=X();return{x:(e-n/2)/b+S,y:(t-r/2)/b+C}},Q=(e,n)=>{let r=Z(e,n),i=-1,a=1/0;for(let[e,n]of t.nodes.entries()){let t=Math.hypot(n.x-r.x,n.y-r.y);t<=Math.max(n.radius,3/b)+4/b&&t<a&&(a=t,i=e)}return i},oe=()=>{let{w:e,h:n}=X();if(N>=0){b=1.2,S=t.nodes[N].x,C=t.nodes[N].y;return}let r=1;for(let e of t.nodes)r=Math.max(r,Math.hypot(e.x,e.y)+e.radius+40);b=Math.min(1.6,Math.min(e,n)/(2*r)),S=0,C=0},$=a(A);$.addEventListener(`pointerdown`,e=>{$.setPointerCapture(e.pointerId),R=0,z=e.offsetX,B=e.offsetY;let t=Q(e.offsetX,e.offsetY);t>=0?(P=t,E=Math.max(E,.3)):I=!0,V=!1}),$.addEventListener(`pointermove`,e=>{let n=e.offsetX-z,r=e.offsetY-B;if(P>=0){R+=Math.abs(n)+Math.abs(r);let i=Z(e.offsetX,e.offsetY);t.nodes[P].x=i.x,t.nodes[P].y=i.y,E=Math.max(E,.3),z=e.offsetX,B=e.offsetY}else I?(R+=Math.abs(n)+Math.abs(r),S-=n/b,C-=r/b,z=e.offsetX,B=e.offsetY):(O=Q(e.offsetX,e.offsetY),$.style.cursor=O>=0?`pointer`:`grab`,Y(O))}),$.addEventListener(`pointerup`,e=>{P>=0&&R<4&&x(`/app/object/${t.nodes[P].id}`),P=-1,I=!1}),$.addEventListener(`wheel`,e=>{e.preventDefault(),V=!1;let{w:t,h:n}=X(),r=Z(e.offsetX,e.offsetY);b=Math.min(8,Math.max(.05,b*Math.exp(-e.deltaY*.0015))),S=r.x-(e.offsetX-t/2)/b,C=r.y-(e.offsetY-n/2)/b},{passive:!1});let se=c.loop(()=>{E>.003&&(L(t,E,P),L(t,E,P),E*=.98,V&&oe());let{w:e,h:n}=X();for(let[e,n]of t.nodes.entries())f[e*2]=n.x,f[e*2+1]=n.y,h[e]=e===O||e===N?1:n.hasAgent?.5:0;for(let[e,n]of t.edges.entries())_[e*2]=t.nodes[n.a].x,_[e*2+1]=t.nodes[n.a].y,v[e*2]=t.nodes[n.b].x,v[e*2+1]=t.nodes[n.b].y;g>0&&(u.instanceAttributes.iStart.set(_),u.instanceAttributes.iEnd.set(v),u.instanceAttributes.iColor.set(y),u.uniforms.uScale.set(b),u.uniforms.uOffset.set([S,C]),u.uniforms.uViewport.set([e,n]),u.uniforms.uWidth.set(1.5),u.draw()),l.instanceAttributes.iCenter.set(f),l.instanceAttributes.iRadius.set(p),l.instanceAttributes.iTint.set(m),l.instanceAttributes.iFlags.set(h),l.uniforms.uScale.set(b),l.uniforms.uOffset.set([S,C]),l.uniforms.uViewport.set([e,n]),l.draw();let r=t.nodes.map((t,r)=>{let i=(t.x-S)*b+e/2,a=(t.y-C)*b+n/2;return{i:r,r:(i>=-40&&i<=e+40&&a>=-20&&a<=n+20?1e3:0)+t.radius+(r===O?100:0)+(r===N?200:0)}}).sort((e,t)=>t.r-e.r);for(let[i,a]of H.entries()){let o=r[i];if(!o){a.style.display=`none`;continue}let s=t.nodes[o.i],c=(s.x-S)*b+e/2,l=(s.y-C)*b+n/2+s.radius*b+4;if(c<-80||c>e+80||l<-20||l>n+20||b<.35){a.style.display=`none`;continue}a.style.display=`block`,a.style.transform=`translate(${c}px, ${l}px) translateX(-50%)`,a.textContent=s.name,a.classList.toggle(`hot`,o.i===O)}for(let[r,i]of U.entries()){let a=t.anchors[r],o=40+11*Math.sqrt(a.count),s=(a.x-S)*b+e/2,c=(a.y-o-C)*b+n/2-22;if(s<-140||s>e+140||c<-30||c>n+30){i.style.display=`none`;continue}i.style.display=`block`,i.style.transform=`translate(${s}px, ${c}px) translateX(-50%)`}if(K>=0&&K===O){let r=t.nodes[K],i=(r.x-S)*b+e/2,a=(r.y-C)*b+n/2,o=Math.min(Math.max(8,i+16),e-268),s=Math.min(Math.max(8,a-20),n-180);W.style.transform=`translate(${o}px, ${s}px)`}else K>=0&&Y(-1)});r=()=>{se(),l.dispose(),u.dispose(),c.destroy()}})().catch(e=>s(M,`Graph failed: ${e}`)),()=>{i=!0,r?.()}});var I=B();b(`1qnqgz`,e=>{n(()=>{i.title=`Graph — glon`})});var V=r(I);c(V,()=>a(P),e=>{var t=R(),n=f(t);p(n,e=>s(A,e),()=>a(A));var r=d(n,2);p(r,e=>s(j,e),()=>a(j)),g(e,t)});var H=d(V,2),U=e=>{var t=z(),n=r(t,!0);m(t),l(()=>o(n,a(M))),g(e,t)};t(H,e=>{a(M)&&e(U)}),m(I),g(h,I),v()}export{V as component};