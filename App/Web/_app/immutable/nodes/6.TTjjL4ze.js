import{$ as e,B as t,G as n,K as r,M as i,O as a,P as o,Q as s,S as c,Y as l,Z as u,at as d,j as f,k as p,lt as m,mt as h,nt as g,o as _,q as v,tt as y,ut as b}from"../chunks/Cg2ytOsU.js";import{t as ee}from"../chunks/Dz7udl-p.js";import"../chunks/xihTtKlq.js";import{t as x}from"../chunks/_bUw9wE6.js";import{a as S,o as C}from"../chunks/D0TUFhgi.js";import{c as te,l as w,o as ne}from"../chunks/_WNey27R.js";import{i as T,o as E}from"../chunks/CtQb3hFo.js";import{r as re,t as D}from"../chunks/C0AHk9ET.js";var O={program:!0,typescript:!0,json:!0,proto:!0,relation:!0,type:!0,template:!0,agent:!0,skill:!0},k={channel:[1,.63,.18],note:[.42,.62,.95],task:[.36,.78,.72],query:[.8,.52,.95],set:[.8,.52,.95],collection:[.95,.75,.35],person:[.9,.45,.55],peer:[.9,.45,.55],agent:[.55,.85,.4]};function A(e){let t=k[e];if(t)return t;let n=2166136261;for(let t of e)n=(n^t.charCodeAt(0))*16777619>>>0;return[.35+n%97/200,.35+Math.floor(n/97)%97/200,.45+Math.floor(n/9409)%97/250]}var j=[.55,.65,.85,.5],M=[.95,.75,.35,.4],N=[.8,.52,.95,.3];function P(e){return(e?.valuesValue?.items??[]).map(e=>e.stringValue).filter(e=>typeof e==`string`)}async function F(e,t){let n=(await E({limit:2e3})).records.filter(n=>{if(O[n.typeKey]||n.typeKey===`channel`)return!1;let r=n.fields.channel?.stringValue??``;return r===e||r===``&&t}),r=[],i=new Map;for(let e of n)i.set(e.id,r.length),r.push({id:e.id,name:[e.fields.iconEmoji?.stringValue,e.fields.name?.stringValue||e.id.slice(0,8)].filter(Boolean).join(` `),kind:e.typeKey,radius:10,hasAgent:!1,color:A(e.typeKey),cluster:-1,x:(Math.random()-.5)*600,y:(Math.random()-.5)*600,vx:0,vy:0});let a=[],o=Array(r.length).fill(0),s=(e,t,n)=>{e!==t&&(a.push({a:e,b:t,color:n}),o[e]+=1,o[t]+=1)},c=[];for(let e of n){let t=i.get(e.id);for(let[n,r]of Object.entries(e.fields))if(n!==`channel`){if(n===`collectionIds`){for(let e of P(r)){let n=i.get(e);n!==void 0&&s(n,t,M)}continue}if(r.linkValue){let e=i.get(r.linkValue.targetId);e!==void 0&&s(e,t,j)}else if(r.valuesValue){for(let e of r.valuesValue.items)if(e.linkValue){let n=i.get(e.linkValue.targetId);n!==void 0&&s(n,t,j)}}}(e.typeKey===`query`||e.typeKey===`set`)&&c.push(e)}for(let e of c){let t=i.get(e.id);try{let n=await E({setId:e.id,limit:50});for(let e of n.records){let n=i.get(e.id);n!==void 0&&n!==t&&s(t,n,N)}}catch{}}for(let[e,t]of r.entries())t.radius=t.kind===`channel`?14:5+1.6*Math.sqrt(o[e]);try{let e=await E({type:`agent`,limit:500});for(let t of e.records){let e=t.fields.bound_object?.stringValue;if(!e)continue;let n=i.get(e);n!==void 0&&(r[n].hasAgent=!0)}}catch{}let l=new Map;for(let[e,t]of r.entries()){let n=l.get(t.kind);n?n.push(e):l.set(t.kind,[e])}let u=new Map;try{let e=await E({type:`type`,limit:300});for(let t of e.records){let e=t.fields.key?.stringValue;if(!e)continue;let n=[t.fields.iconEmoji?.stringValue,t.fields.name?.stringValue||e].filter(Boolean).join(` `);u.set(e,n)}}catch{}let d=[...l.entries()].sort((e,t)=>t[1].length-e[1].length),f=[];for(let e=0,t=d.length-1;e<=t;e++,t--)f.push(d[e]),e!==t&&f.push(d[t]);let p=f.map(([,e])=>24+11*Math.sqrt(e.length)),m=p.reduce((e,t)=>e+t,0),h=Math.max(340,m/Math.PI*.75,46*Math.sqrt(r.length)),g=[],_=0;for(let[e,[t,n]]of f.entries()){let i=(_+p[e]/2)/m*Math.PI*2-Math.PI/2;_+=p[e];let a=Math.cos(i)*h,o=Math.sin(i)*h;g.push({kind:t,label:u.get(t)??t,x:a,y:o,count:n.length});let s=40+11*Math.sqrt(n.length);for(let[t,i]of n.entries()){let c=t*2.399963,l=s*Math.sqrt(t/Math.max(1,n.length));r[i].cluster=e,r[i].x=a+Math.cos(c)*l,r[i].y=o+Math.sin(c)*l}}return{nodes:r,edges:a,anchors:g}}function I(e,t,n=-1){let r=.0015,i=.14,a=e.nodes.length;for(let n=0;n<a;n++)for(let r=n+1;r<a;r++){let i=e.nodes[n],a=e.nodes[r],o=a.x-i.x,s=a.y-i.y,c=Math.max(o*o+s*s,25),l=Math.sqrt(c),u=-600*t/c;i.vx+=o/l*u,i.vy+=s/l*u,a.vx-=o/l*u,a.vy-=s/l*u}for(let n of e.edges){let r=e.nodes[n.a],i=e.nodes[n.b],a=i.x-r.x,o=i.y-r.y,s=Math.max(Math.hypot(a,o),1),c=(s-110)/s*t*.05;r.vx+=a*c*.5,r.vy+=o*c*.5,i.vx-=a*c*.5,i.vy-=o*c*.5}for(let[a,o]of e.nodes.entries()){if(o.vx-=o.x*r*t,o.vy-=o.y*r*t,o.cluster>=0&&e.anchors[o.cluster]&&(o.vx+=(e.anchors[o.cluster].x-o.x)*i*t,o.vy+=(e.anchors[o.cluster].y-o.y)*i*t),o.vx*=.6,o.vy*=.6,a===n){o.vx=0,o.vy=0;continue}o.x+=o.vx,o.y+=o.vy}for(let t=0;t<2;t++)for(let t=0;t<a;t++)for(let r=t+1;r<a;r++){let i=e.nodes[t],a=e.nodes[r],o=a.x-i.x,s=a.y-i.y,c=i.radius+a.radius+14,l=Math.hypot(o,s);if(l>=c)continue;l===0&&(o=Math.cos(t*2.399963),s=Math.sin(t*2.399963),l=1);let u=(c-l)/l,d=t===n?0:r===n?1:a.radius/(i.radius+a.radius),f=1-d;i.x-=o*u*d,i.y-=s*u*d,a.x+=o*u*f,a.y+=s*u*f}}var L={wgslSrc:`struct BmUniforms {
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
`,attributes:{aQuad:`vec2`},instanceAttributes:{iStart:`vec2`,iEnd:`vec2`,iColor:`vec4`},uniforms:{uScale:`float`,uOffset:`vec2`,uViewport:`vec2`,uWidth:`float`},layout:{attributes:[{name:`aQuad`,type:`vec2`,location:0,size:2,divisor:0},{name:`iStart`,type:`vec2`,location:1,size:2,divisor:1},{name:`iEnd`,type:`vec2`,location:2,size:2,divisor:1},{name:`iColor`,type:`vec4`,location:3,size:4,divisor:1}],uniforms:[{name:`uScale`,type:`float`,kind:`1f`,size:1,offset:0},{name:`uOffset`,type:`vec2`,kind:`2fv`,size:2,offset:8},{name:`uViewport`,type:`vec2`,kind:`2fv`,size:2,offset:16},{name:`uWidth`,type:`float`,kind:`1f`,size:1,offset:24}],uniformBlockSize:32}},R=o(`<canvas class="svelte-1qnqgz"></canvas> <div class="labels svelte-1qnqgz"></div>`,1),z=o(`<p class="status svelte-1qnqgz"> </p>`),B=o(`<div class="stage svelte-1qnqgz"><!> <!></div>`);function V(o,E){b(E,!0);let O=g(void 0),k=g(void 0),A=g(`Loading graph…`),j=d(()=>C.channels[0]?.id??``),M=d(()=>w.id||t(j));d(()=>C.channels.find(e=>e.id===t(M))?.name??``);let N=d(()=>x.url.searchParams.get(`focus`)??``);v(()=>{let e=t(M),n=t(O),r=e===t(j)&&e!==``;if(!e){S();return}if(!n||!t(k))return;let i=null,a=!1;return y(A,`Loading graph…`),(async()=>{let n=await F(e,r);if(y(A,n.nodes.length===0?`Nothing in this space yet.`:``,!0),!t(O)||a||n.nodes.length===0)return;let o=window.devicePixelRatio||1;t(O).width=Math.max(1,Math.floor(t(O).clientWidth*o)),t(O).height=Math.max(1,Math.floor(t(O).clientHeight*o));let s=await re(t(O),{clearColor:[.047,.055,.066,1]});if(a){s.destroy();return}let c=D(s,L,{blend:`alpha`}),l=D(s,ie,{blend:`alpha`});c.attributes.aCorner.set(new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1])),l.attributes.aQuad.set(new Float32Array([-1,0,1,0,-1,1,-1,1,1,0,1,1]));let u=n.nodes.length,d=new Float32Array(u*2),f=new Float32Array(u),p=new Float32Array(u*3),m=new Float32Array(u);for(let[e,t]of n.nodes.entries())f[e]=t.radius,p.set(t.color,e*3);let h=n.edges.length,g=new Float32Array(h*2),_=new Float32Array(h*2),v=new Float32Array(h*4);for(let[e,t]of n.edges.entries())v.set(t.color,e*4);let b=1,x=0,S=0,w=1,E=-1,j=t(N)?n.nodes.findIndex(e=>e.id===t(N)):-1,M=-1,P=!1,R=0,z=0,B=0,V=!0,H=[];for(let e=0;e<Math.min(100,u);e++){let e=document.createElement(`div`);e.className=`graph-label`,t(k).appendChild(e),H.push(e)}let U=[];for(let e of n.anchors){let n=document.createElement(`div`);n.className=`graph-anchor-label`,n.textContent=`${e.label} · ${e.count}`,t(k).appendChild(n),U.push(n)}let W=document.createElement(`div`);W.className=`graph-card`,W.style.display=`none`,t(k).appendChild(W);let G=new Map,K=-1,q,J=e=>e.replace(/[&<>"]/g,e=>({"&":`&amp;`,"<":`&lt;`,">":`&gt;`,'"':`&quot;`})[e]),ae=async e=>{let t=G.get(e);if(t)return t;let n=await T(e),r=J(n.fields.name?.stringValue||`Untitled`),i=J(n.fields.iconEmoji?.stringValue??``),a=te(C.relations,n.fields.channel?.stringValue||C.channels[0]?.id||``),o=[];for(let[e,t]of Object.entries(n.fields)){if([`name`,`iconEmoji`,`channel`,`collectionIds`,`viewFilters`,`viewSorts`,`viewRelations`,`pinnedIds`,`setOf`,`featuredRelations`].includes(e))continue;let n=``,r=``;if(t.stringValue===void 0?t.boolValue===void 0?t.intValue===void 0?t.valuesValue&&(n=t.valuesValue.items.map(e=>e.stringValue??``).filter(Boolean).join(`, `)):n=new Date(t.intValue).getFullYear()>1990?new Date(t.intValue).toLocaleDateString():String(t.intValue):r=`<span class="gc-chk${t.boolValue?` on`:``}"></span>`:n=t.stringValue,!n&&!r)continue;let i=a.find(t=>t.key===e),s=i?`${i.iconEmoji||ne(i.format)} ${i.name||e}`:e;if(o.push(`<div class="gc-row"><span class="gc-k">${J(s)}</span><span class="gc-v">${r||J(n.slice(0,60))}</span></div>`),o.length>=4)break}let s=new Map(n.blocks.map(e=>[e.id,e])),c=new Set([`__discussion__`]),l=[],u=e=>{if(c.has(e)||l.length>=8)return;let t=s.get(e);if(!t)return;let n=t.content.text;if(n?.text?.trim()){let e=n.style??0,t=e>=1&&e<=3?`gc-h`:e===8?`gc-check`:e===6||e===7?`gc-li`:`gc-p`,r=e===8?`<span class="gc-chk${n.checked?` on`:``}"></span> `:e===6?`• `:``;l.push(`<div class="${t}">${r}${J(n.text.slice(0,90))}</div>`)}for(let e of t.childrenIds??[])u(e)},d=n.blocks.filter(e=>!n.blocks.some(t=>(t.childrenIds??[]).includes(e.id)));for(let e of d)u(e.id);let f=`<div class="gc-title">${i?i+` `:``}${r}</div>${o.join(``)}${l.length?`<div class="gc-body">${l.join(``)}</div>`:``}`;return G.set(e,f),f},Y=e=>{if(clearTimeout(q),e<0){K=-1,W.style.display=`none`;return}e!==K&&(q=setTimeout(()=>{K=e;let t=n.nodes[e];ae(t.id).then(t=>{K===e&&(W.innerHTML=t,W.style.display=`block`)})},260))},X=()=>({w:t(O).clientWidth,h:t(O).clientHeight}),Z=(e,t)=>{let{w:n,h:r}=X();return{x:(e-n/2)/b+x,y:(t-r/2)/b+S}},Q=(e,t)=>{let r=Z(e,t),i=-1,a=1/0;for(let[e,t]of n.nodes.entries()){let n=Math.hypot(t.x-r.x,t.y-r.y);n<=Math.max(t.radius,3/b)+4/b&&n<a&&(a=n,i=e)}return i},oe=()=>{let{w:e,h:t}=X();if(j>=0){b=1.2,x=n.nodes[j].x,S=n.nodes[j].y;return}let r=1;for(let e of n.nodes)r=Math.max(r,Math.hypot(e.x,e.y)+e.radius+40);b=Math.min(1.6,Math.min(e,t)/(2*r)),x=0,S=0},$=t(O);$.addEventListener(`pointerdown`,e=>{$.setPointerCapture(e.pointerId),R=0,z=e.offsetX,B=e.offsetY;let t=Q(e.offsetX,e.offsetY);t>=0?(M=t,w=Math.max(w,.3)):P=!0,V=!1}),$.addEventListener(`pointermove`,e=>{let t=e.offsetX-z,r=e.offsetY-B;if(M>=0){R+=Math.abs(t)+Math.abs(r);let i=Z(e.offsetX,e.offsetY);n.nodes[M].x=i.x,n.nodes[M].y=i.y,w=Math.max(w,.3),z=e.offsetX,B=e.offsetY}else P?(R+=Math.abs(t)+Math.abs(r),x-=t/b,S-=r/b,z=e.offsetX,B=e.offsetY):(E=Q(e.offsetX,e.offsetY),$.style.cursor=E>=0?`pointer`:`grab`,Y(E))}),$.addEventListener(`pointerup`,e=>{M>=0&&R<4&&ee(`/app/object/${n.nodes[M].id}`),M=-1,P=!1}),$.addEventListener(`wheel`,e=>{e.preventDefault(),V=!1;let{w:t,h:n}=X(),r=Z(e.offsetX,e.offsetY);b=Math.min(8,Math.max(.05,b*Math.exp(-e.deltaY*.0015))),x=r.x-(e.offsetX-t/2)/b,S=r.y-(e.offsetY-n/2)/b},{passive:!1});let se=s.loop(()=>{w>.003&&(I(n,w,M),I(n,w,M),w*=.98,V&&oe());let{w:e,h:t}=X();for(let[e,t]of n.nodes.entries())d[e*2]=t.x,d[e*2+1]=t.y,m[e]=e===E||e===j?1:t.hasAgent?.5:0;for(let[e,t]of n.edges.entries())g[e*2]=n.nodes[t.a].x,g[e*2+1]=n.nodes[t.a].y,_[e*2]=n.nodes[t.b].x,_[e*2+1]=n.nodes[t.b].y;h>0&&(l.instanceAttributes.iStart.set(g),l.instanceAttributes.iEnd.set(_),l.instanceAttributes.iColor.set(v),l.uniforms.uScale.set(b),l.uniforms.uOffset.set([x,S]),l.uniforms.uViewport.set([e,t]),l.uniforms.uWidth.set(1.5),l.draw()),c.instanceAttributes.iCenter.set(d),c.instanceAttributes.iRadius.set(f),c.instanceAttributes.iTint.set(p),c.instanceAttributes.iFlags.set(m),c.uniforms.uScale.set(b),c.uniforms.uOffset.set([x,S]),c.uniforms.uViewport.set([e,t]),c.draw();let r=n.nodes.map((n,r)=>{let i=(n.x-x)*b+e/2,a=(n.y-S)*b+t/2;return{i:r,r:(i>=-40&&i<=e+40&&a>=-20&&a<=t+20?1e3:0)+n.radius+(r===E?100:0)+(r===j?200:0)}}).sort((e,t)=>t.r-e.r);for(let[i,a]of H.entries()){let o=r[i];if(!o){a.style.display=`none`;continue}let s=n.nodes[o.i],c=(s.x-x)*b+e/2,l=(s.y-S)*b+t/2+s.radius*b+4;if(c<-80||c>e+80||l<-20||l>t+20||b<.35){a.style.display=`none`;continue}a.style.display=`block`,a.style.transform=`translate(${c}px, ${l}px) translateX(-50%)`,a.textContent=s.name,a.classList.toggle(`hot`,o.i===E)}for(let[r,i]of U.entries()){let a=n.anchors[r],o=40+11*Math.sqrt(a.count),s=(a.x-x)*b+e/2,c=(a.y-o-S)*b+t/2-22;if(s<-140||s>e+140||c<-30||c>t+30){i.style.display=`none`;continue}i.style.display=`block`,i.style.transform=`translate(${s}px, ${c}px) translateX(-50%)`}if(K>=0&&K===E){let r=n.nodes[K],i=(r.x-x)*b+e/2,a=(r.y-S)*b+t/2,o=Math.min(Math.max(8,i+16),e-268),s=Math.min(Math.max(8,a-20),t-180);W.style.transform=`translate(${o}px, ${s}px)`}else K>=0&&Y(-1)});i=()=>{se(),c.dispose(),l.dispose(),s.destroy()}})().catch(e=>y(A,`Graph failed: ${e}`)),()=>{a=!0,i?.()}});var P=B();c(`1qnqgz`,e=>{n(()=>{l.title=`Graph — glon`})});var V=u(P);a(V,()=>t(M),n=>{var r=R(),a=s(r);_(a,e=>y(O,e),()=>t(O));var o=e(a,2);_(o,e=>y(k,e),()=>t(k)),i(n,r)});var H=e(V,2),U=e=>{var n=z(),a=u(n,!0);h(n),r(()=>f(a,t(A))),i(e,n)};p(H,e=>{t(A)&&e(U)}),h(P),i(o,P),m()}export{V as component};