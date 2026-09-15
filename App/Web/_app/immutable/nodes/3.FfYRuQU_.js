import{$ as e,H as t,J as n,K as r,L as i,Q as a,a as o,dt as s,j as c,k as l,n as u,ot as d,st as f,ut as p,y as m}from"../chunks/C9LrvWAa.js";import"../chunks/xihTtKlq.js";import{n as h,r as g,t as _}from"../chunks/DYV8C2HT.js";function v(e){return e===void 0?new Float32Array(16):(e.fill(0),e)}function y(e){let t=v(e);return t[0]=1,t[5]=1,t[10]=1,t[15]=1,t}function b(e,t,n){let r=n??new Float32Array(16),i=e[0],a=e[1],o=e[2],s=e[3],c=e[4],l=e[5],u=e[6],d=e[7],f=e[8],p=e[9],m=e[10],h=e[11],g=e[12],_=e[13],v=e[14],y=e[15];for(let e=0;e<4;e++){let n=t[e*4],b=t[e*4+1],x=t[e*4+2],S=t[e*4+3];r[e*4]=i*n+c*b+f*x+g*S,r[e*4+1]=a*n+l*b+p*x+_*S,r[e*4+2]=o*n+u*b+m*x+v*S,r[e*4+3]=s*n+d*b+h*x+y*S}return r}function x(e,t,n,r){let i=y(r);return i[12]=e,i[13]=t,i[14]=n,i}function S(e,t){let n=Math.cos(e),r=Math.sin(e),i=y(t);return i[5]=n,i[6]=r,i[9]=-r,i[10]=n,i}function C(e,t){let n=Math.cos(e),r=Math.sin(e),i=y(t);return i[0]=n,i[2]=-r,i[8]=r,i[10]=n,i}function w(e,t){let n=Math.cos(e),r=Math.sin(e),i=y(t);return i[0]=n,i[1]=r,i[4]=-r,i[5]=n,i}function T(e,t,n,r,i){let a=1/Math.tan(e/2),o=v(i);return o[0]=a/t,o[5]=a,o[10]=(r+n)/(n-r),o[11]=-1,o[14]=2*r*n/(n-r),o}function E(e,t,n=[0,1,0],r){let i=t[0]-e[0],a=t[1]-e[1],o=t[2]-e[2],s=Math.hypot(i,a,o)||1;i/=s,a/=s,o/=s;let c=a*n[2]-o*n[1],l=o*n[0]-i*n[2],u=i*n[1]-a*n[0],d=Math.hypot(c,l,u)||1;c/=d,l/=d,u/=d;let f=l*o-u*a,p=u*i-c*o,m=c*a-l*i,h=r??new Float32Array(16);return h[0]=c,h[1]=f,h[2]=-i,h[3]=0,h[4]=l,h[5]=p,h[6]=-a,h[7]=0,h[8]=u,h[9]=m,h[10]=-o,h[11]=0,h[12]=-(c*e[0]+l*e[1]+u*e[2]),h[13]=-(f*e[0]+p*e[1]+m*e[2]),h[14]=i*e[0]+a*e[1]+o*e[2],h[15]=1,h}function D(){return new Float32Array(16)}var O={identity:y,multiply:b,translation:x,rotationX:S,rotationY:C,rotationZ:w,perspective:T,lookAt:E,scratch:D};function k(e,t){return h(e,t)}var A={wgslSrc:`struct BmUniforms {
  uViewProj : mat4x4f,
  uTime : f32,
  uMouse : vec2f,
  uNow : f32,
}
@group(0) @binding(0) var<uniform> bm_u : BmUniforms;
@group(0) @binding(1) var<storage, read> uNodes : array<vec4f>;
struct BmVSIn {
  @location(0) aCorner : vec2f,
  @location(1) iIdx : f32,
  @location(2) iKind : f32,
  @location(3) iSeed : f32,
}
struct BmVSOut {
  @builtin(position) bm_position : vec4f,
  @location(0) vUv : vec2f,
  @location(1) vColor : vec3f,
  @location(2) vAlpha : f32,
}
@vertex
fn vs_main(bm_in : BmVSIn) -> BmVSOut {
  var bm_out : BmVSOut;
  bm_out.vUv = bm_in.aCorner;
  let node = uNodes[u32(bm_in.iIdx)];
  let grown = smoothstep(node.w, node.w + 2.8, bm_u.uNow);
  var color = vec3f(0.92, 0.42, 0.55);
  var sizeMul = 1.0;
  if (bm_in.iKind > 0.5 && bm_in.iKind < 1.5) {
    color = vec3f(0.35, 0.85, 0.6);
  } else {
    if (bm_in.iKind > 1.5 && bm_in.iKind < 2.5) {
      color = vec3f(0.95, 0.75, 0.8);
    } else {
      if (bm_in.iKind > 2.5 && bm_in.iKind < 3.5) {
        color = vec3f(0.95, 0.72, 0.35);
        sizeMul = 1.35;
      } else {
        if (bm_in.iKind > 3.5 && bm_in.iKind < 4.5) {
          color = vec3f(0.65, 0.5, 0.95);
          sizeMul = 0.95;
        } else {
          if (bm_in.iKind > 4.5 && bm_in.iKind < 5.5) {
            color = vec3f(0.45, 0.7, 1.0);
            sizeMul = 0.9;
          } else {
            if (bm_in.iKind > 5.5 && bm_in.iKind < 6.5) {
              color = vec3f(0.8, 0.42, 0.75);
              sizeMul = 0.9;
            } else {
              if (bm_in.iKind > 6.5 && bm_in.iKind < 7.5) {
                color = vec3f(0.95, 0.85, 0.4);
                sizeMul = 1.15;
              } else {
                if (bm_in.iKind > 7.5 && bm_in.iKind < 8.5) {
                  color = vec3f(0.95, 0.6, 0.35);
                  sizeMul = 1.1;
                } else {
                  if (bm_in.iKind > 8.5 && bm_in.iKind < 9.5) {
                    color = vec3f(0.75, 0.8, 0.95);
                    sizeMul = 1.2;
                  } else {
                    if (bm_in.iKind > 9.5) {
                      color = vec3f(0.42, 0.44, 0.52);
                      sizeMul = 0.55;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  color = color * 0.82;
  var size = (0.034 + fract(bm_in.iSeed * 7.3) * 0.012) * sizeMul * (0.25 + 0.75 * grown);
  var glow = (0.9 + fract(bm_in.iSeed * 4.7) * 0.1) * grown;
  if (bm_in.iKind > 9.5) {
    color = vec3f(0.45, 0.41, 0.34);
    glow = 0.55 * grown;
  }
  let bobY = sin(bm_u.uTime * 1.5 + node.w * 13.7) * 0.022 * grown;
  let bobX = cos(bm_u.uTime * 1.1 + node.w * 27.3) * 0.012 * grown;
  var p = vec3f(node.x + bobX, node.y + bobY, node.z);
  let yaw = bm_u.uTime * 0.22 + bm_u.uMouse.x * 0.5;
  let cy = cos(yaw);
  let sy = sin(yaw);
  let px = p.x * cy + p.z * sy;
  let pz0 = p.z * cy - p.x * sy;
  let tilt = 0.42 + bm_u.uMouse.y * 0.18;
  let ct = cos(tilt);
  let st = sin(tilt);
  let py = p.y * ct - pz0 * st;
  let pz1 = p.y * st + pz0 * ct;
  p = vec3f(px, py, pz1);
  let depthFade = clamp((p.z + 3.4) / 4.6, 0.25, 1.0);
  let world = p + vec3f(bm_in.aCorner.x * size, bm_in.aCorner.y * size, 0.0);
  bm_out.vColor = color;
  bm_out.vAlpha = depthFade * glow;
  bm_out.bm_position = bm_u.uViewProj * vec4f(world, 1.0);
  bm_out.bm_position.z = (bm_out.bm_position.z + bm_out.bm_position.w) * 0.5;
  return bm_out;
}
@fragment
fn fs_main(bm_in : BmVSOut) -> @location(0) vec4f {
  let d = length(bm_in.vUv);
  let disc = 1.0 - smoothstep(0.72, 1.0, d);
  return vec4f(bm_in.vColor, disc * bm_in.vAlpha);
}
`,attributes:{aCorner:`vec2`},instanceAttributes:{iIdx:`float`,iKind:`float`,iSeed:`float`},uniforms:{uViewProj:`mat4`,uTime:`float`,uMouse:`vec2`,uNow:`float`,uNodes:`storage`},layout:{attributes:[{name:`aCorner`,type:`vec2`,location:0,size:2,divisor:0},{name:`iIdx`,type:`float`,location:1,size:1,divisor:1},{name:`iKind`,type:`float`,location:2,size:1,divisor:1},{name:`iSeed`,type:`float`,location:3,size:1,divisor:1}],uniforms:[{name:`uViewProj`,type:`mat4`,kind:`m4fv`,size:16,offset:0},{name:`uTime`,type:`float`,kind:`1f`,size:1,offset:64},{name:`uMouse`,type:`vec2`,kind:`2fv`,size:2,offset:72},{name:`uNow`,type:`float`,kind:`1f`,size:1,offset:80},{name:`uNodes`,type:`storage`,kind:`1i`,size:1,unit:0,textureBinding:1}],uniformBlockSize:96}},j={wgslSrc:`struct BmUniforms {
  uViewProj : mat4x4f,
  uTime : f32,
  uMouse : vec2f,
  uWidth : f32,
  uNow : f32,
}
@group(0) @binding(0) var<uniform> bm_u : BmUniforms;
@group(0) @binding(1) var<storage, read> uNodes : array<vec4f>;
struct BmVSIn {
  @location(0) aQuad : vec2f,
  @location(1) iA : f32,
  @location(2) iB : f32,
  @location(3) iTint : vec3f,
  @location(4) iBirth : f32,
  @location(5) iDeath : f32,
}
struct BmVSOut {
  @builtin(position) bm_position : vec4f,
  @location(0) vTint : vec3f,
  @location(1) vAlong : f32,
  @location(2) vBirth : f32,
  @location(3) vAcross : f32,
  @location(4) vDeath : f32,
}
@vertex
fn vs_main(bm_in : BmVSIn) -> BmVSOut {
  var bm_out : BmVSOut;
  bm_out.vTint = bm_in.iTint;
  bm_out.vAlong = bm_in.aQuad.y;
  bm_out.vBirth = bm_in.iBirth;
  bm_out.vAcross = bm_in.aQuad.x;
  bm_out.vDeath = bm_in.iDeath;
  let na = uNodes[u32(bm_in.iA)];
  let nb = uNodes[u32(bm_in.iB)];
  let gA = smoothstep(na.w, na.w + 2.8, bm_u.uNow);
  let gB = smoothstep(nb.w, nb.w + 2.8, bm_u.uNow);
  let start = vec3f(na.x + cos(bm_u.uTime * 1.1 + na.w * 27.3) * 0.012 * gA, na.y + sin(bm_u.uTime * 1.5 + na.w * 13.7) * 0.022 * gA, na.z);
  let end = vec3f(nb.x + cos(bm_u.uTime * 1.1 + nb.w * 27.3) * 0.012 * gB, nb.y + sin(bm_u.uTime * 1.5 + nb.w * 13.7) * 0.022 * gB, nb.z);
  let yaw = bm_u.uTime * 0.22 + bm_u.uMouse.x * 0.5;
  let tilt = 0.42 + bm_u.uMouse.y * 0.18;
  let cy = cos(yaw);
  let sy = sin(yaw);
  let ct = cos(tilt);
  let st = sin(tilt);
  let ax = start.x * cy + start.z * sy;
  let az0 = start.z * cy - start.x * sy;
  let ay = start.y * ct - az0 * st;
  let az1 = start.y * st + az0 * ct;
  let a2 = vec3f(ax, ay, az1);
  let bx = end.x * cy + end.z * sy;
  let bz0 = end.z * cy - end.x * sy;
  let by = end.y * ct - bz0 * st;
  let bz1 = end.y * st + bz0 * ct;
  let b2 = vec3f(bx, by, bz1);
  let dir = b2 - a2;
  let len = length(dir);
  let n = dir * (1.0 / max(len, 0.0001));
  let perp = vec3f(-n.y, n.x, 0.0);
  let p = a2 + n * (bm_in.aQuad.y * len) + perp * (bm_in.aQuad.x * bm_u.uWidth * 0.5);
  bm_out.bm_position = bm_u.uViewProj * vec4f(p, 1.0);
  bm_out.bm_position.z = (bm_out.bm_position.z + bm_out.bm_position.w) * 0.5;
  return bm_out;
}
@fragment
fn fs_main(bm_in : BmVSOut) -> @location(0) vec4f {
  let taper = smoothstep(0.0, 0.08, bm_in.vAlong) * (1.0 - smoothstep(0.92, 1.0, bm_in.vAlong));
  let reach = smoothstep(bm_in.vBirth + 0.3, bm_in.vBirth + 1.9, bm_u.uNow) * 1.15;
  let behindTip = 1.0 - smoothstep(reach - 0.14, reach, bm_in.vAlong);
  let grown = smoothstep(bm_in.vBirth, bm_in.vBirth + 0.5, bm_u.uNow);
  let rim = 1.0 - smoothstep(0.68, 1.0, abs(bm_in.vAcross));
  let round = 0.72 + 0.28 * sqrt(max(0.0, 1.0 - bm_in.vAcross * bm_in.vAcross));
  let dying = smoothstep(bm_in.vDeath, bm_in.vDeath + 0.9, bm_u.uNow);
  let gap = dying * 0.56;
  let intact = smoothstep(gap - 0.06, gap + 0.02, abs(bm_in.vAlong - 0.5) + 0.001);
  return vec4f(bm_in.vTint * round, taper * rim * 0.92 * behindTip * grown * intact);
}
`,attributes:{aQuad:`vec2`},instanceAttributes:{iA:`float`,iB:`float`,iTint:`vec3`,iBirth:`float`,iDeath:`float`},uniforms:{uViewProj:`mat4`,uTime:`float`,uMouse:`vec2`,uWidth:`float`,uNow:`float`,uNodes:`storage`},layout:{attributes:[{name:`aQuad`,type:`vec2`,location:0,size:2,divisor:0},{name:`iA`,type:`float`,location:1,size:1,divisor:1},{name:`iB`,type:`float`,location:2,size:1,divisor:1},{name:`iTint`,type:`vec3`,location:3,size:3,divisor:1},{name:`iBirth`,type:`float`,location:4,size:1,divisor:1},{name:`iDeath`,type:`float`,location:5,size:1,divisor:1}],uniforms:[{name:`uViewProj`,type:`mat4`,kind:`m4fv`,size:16,offset:0},{name:`uTime`,type:`float`,kind:`1f`,size:1,offset:64},{name:`uMouse`,type:`vec2`,kind:`2fv`,size:2,offset:72},{name:`uWidth`,type:`float`,kind:`1f`,size:1,offset:80},{name:`uNow`,type:`float`,kind:`1f`,size:1,offset:84},{name:`uNodes`,type:`storage`,kind:`1i`,size:1,unit:0,textureBinding:1}],uniformBlockSize:96}},M=c(`<canvas aria-hidden="true" class="svelte-7heuq3"></canvas>`);function N(t,n){f(n,!0);let r=e(void 0),s=(()=>{let e=20260915;return()=>(e=e*1664525+1013904223>>>0,e/4294967296)})(),c=.85;function p(){let e=new Float32Array(262144),t=[],n=[],r=[],i=0,a=[],o=[],l=[],u=[],d=[],f=[],p=[],m=[],h=[],g=[],_=[],v=[.45,.41,.34],y=[{tint:[.92,.42,.55],weight:.42},{tint:[.35,.85,.6],weight:.13},{tint:[.95,.75,.8],weight:.11},{tint:[.95,.72,.35],weight:.06},{tint:[.65,.5,.95],weight:.06},{tint:[.45,.7,1],weight:.06},{tint:[.8,.42,.75],weight:.05},{tint:[.95,.85,.4],weight:.05},{tint:[.95,.6,.35],weight:.04},{tint:[.75,.8,.95],weight:.02}],b=()=>{let e=s();for(let t=0;t<y.length;t++)if(e-=y[t].weight,e<=0)return t;return 0},x=e=>c-(11-e)*.24,S=(c,u,d,f,p)=>{let m=i++;return e[m*4]=c,e[m*4+1]=u,e[m*4+2]=d,e[m*4+3]=f,t[m]=u,n[m]=u,r[m]=0,a.push(m),o.push(p),l.push(s()),m},C=(e,t,n,r)=>{u.push(e),d.push(t),f.push(...n),p.push(r),m.push(1e30)},w=[];for(let e=0;e<52;e++){let t=s()*Math.PI*2,n=.14+s()*.5,r=Math.cos(t)*n,i=Math.sin(t)*n,a=Math.floor(s()*(12*.7));w.push({kind:b(),birth:a,x:r,z:i,dx:(s()-.5)*.06,dz:(s()-.5)*.06,links:[],bornSlice:a,bornX:r,bornZ:i});for(let t=0;t<(e>0&&s()<.42?2:1)&&e>0;t++){let t=Math.floor(s()*e);w[e].links.includes(t)||w[e].links.push(t)}}let T=(e,t)=>{let n=t-e.birth;return[e.x+e.dx*n,e.z+e.dz*n]};for(let e of w)if(s()<.22&&e.birth+2<12){let t=e.birth+2+Math.floor(s()*(12-e.birth-2)),[n,r]=T(e,t);e.retouch={slice:t,x:n,z:r},e.x=n,e.z=r,e.dx=0,e.dz=0,e.birth=t}let E=[];for(let e of w){let t=S(e.bornX,x(Math.min(e.bornSlice,10)),e.bornZ,-2,10);E.push(t),_.push(t)}for(let e of w)if(e.retouch){let t=S(e.retouch.x,x(e.retouch.slice),e.retouch.z,-2,10);e.retouch.node=t,_.push(t)}for(let e of w){let[t,n]=T(e,11),r=S(t,c,n,-2,e.kind);g.push({kind:e.kind,node:r,degree:e.links.length})}for(let[e,t]of w.entries()){C(g[e].node,E[e],v,-2);for(let n of t.links)if(C(E[e],g[n].node,v,-2),n<e){let r=y[t.kind].tint;C(g[e].node,g[n].node,[r[0]*.45,r[1]*.45,r[2]*.45],-2)}t.retouch&&C(t.retouch.node,g[e].node,v,-2)}let D=e=>{if(g.length===0)return-1;if(s()<.65){let t=Math.max(0,g.length-10),n=t+Math.floor(s()*(g.length-t));return n===e?-1:n}let t=-1,n=-1;for(let r=0;r<3;r++){let r=Math.floor(s()*g.length);r!==e&&g[r].degree>n&&(t=r,n=g[r].degree)}return t};return{nodeData:e,sinkTail:e=>{for(let t of _)n[t]-=.05*e},get nNodes(){return i},iIdx:a,iKind:o,iSeed:l,eA:u,eB:d,eTint:f,eBirth:p,fireEvent:e=>{if(i>=65534)return!1;let t=b(),r=s()*Math.PI*2,a=.14+s()*Math.min(.62,.5+g.length*.0015),o=Math.cos(r)*a,l=Math.sin(r)*a,d=S(o,1.4,l,e,t);n[d]=c;let f={kind:t,node:d,degree:0};g.push(f);let p=S(o,c,l,e,10);_.push(p),C(d,p,v,e);let m=1+ +(s()<.45)+ +(s()<.18);for(let n=0;n<m;n++){let n=D(g.length-1);if(n===-1)continue;let r=g[n],i=y[t].tint;C(d,r.node,[i[0]*.45,i[1]*.45,i[2]*.45],e),h.push({edge:u.length-1,a:g.length-1,b:n}),C(p,r.node,v,e),f.degree++,r.degree++}return!0},breakEdge:e=>{if(h.length<8)return!1;let t=Math.floor(s()*h.length),n=h.splice(t,1)[0];return m[n.edge]=e,g[n.a].degree=Math.max(0,g[n.a].degree-1),g[n.b].degree=Math.max(0,g[n.b].degree-1),!0},eDeath:m,ease:()=>{let a=!1;for(let o=0;o<i;o++){let i=n[o]-t[o];Math.abs(i)<4e-4&&Math.abs(r[o])<4e-4||(r[o]=(r[o]+i*.006)*.92,t[o]+=r[o],e[o*4+1]=t[o],a=!0)}return a}}}u(()=>{if(!i(r))return;let e=!1,t=null,n=0,a=0,o=0,c=0,l=e=>{o=e.clientX/window.innerWidth*2-1,c=e.clientY/window.innerHeight*2-1};return window.addEventListener(`pointermove`,l),(async()=>{let l;try{l=await g(i(r),{clearColor:[.949,.796,.439,1]})}catch{return}if(e){l.destroy();return}let u=p(),d=k(l,u.nodeData),f=new Float32Array([-1,-1,1,-1,1,1,-1,-1,1,1,-1,1]),m=new Float32Array([0,0,1,0,0,1,0,1,1,0,1,1]),h=_(l,A,{blend:`alpha`});h.attributes.aCorner.set(f),h.instanceAttributes.iIdx.set(new Float32Array(u.iIdx)),h.instanceAttributes.iKind.set(new Float32Array(u.iKind)),h.instanceAttributes.iSeed.set(new Float32Array(u.iSeed)),h.uniforms.uNodes.set(d);let v=_(l,j,{blend:`alpha`});v.attributes.aQuad.set(m),v.instanceAttributes.iA.set(new Float32Array(u.eA)),v.instanceAttributes.iB.set(new Float32Array(u.eB)),v.instanceAttributes.iTint.set(new Float32Array(u.eTint)),v.instanceAttributes.iBirth.set(new Float32Array(u.eBirth)),v.instanceAttributes.iDeath.set(new Float32Array(u.eDeath)),v.uniforms.uNodes.set(d),v.uniforms.uWidth.set(.022);let y=.8+s()*1.2,b=!1,x=0;t=l.loop(e=>{let t=Math.min(e-x,.1);for(x=e;e>=y;)(s()<.12?u.breakEdge(y):u.fireEvent(y))&&(b=!0),y+=.9+s()*1.8;u.sinkTail(t),u.ease()&&d.write(u.nodeData.subarray(0,u.nNodes*4)),b&&(b=!1,h.instanceAttributes.iIdx.set(new Float32Array(u.iIdx)),h.instanceAttributes.iKind.set(new Float32Array(u.iKind)),h.instanceAttributes.iSeed.set(new Float32Array(u.iSeed)),v.instanceAttributes.iA.set(new Float32Array(u.eA)),v.instanceAttributes.iB.set(new Float32Array(u.eB)),v.instanceAttributes.iTint.set(new Float32Array(u.eTint)),v.instanceAttributes.iBirth.set(new Float32Array(u.eBirth)),v.instanceAttributes.iDeath.set(new Float32Array(u.eDeath))),n+=(o-n)*.045,a+=(c-a)*.045;let r=O.perspective(Math.PI/4.4,l.aspect,.1,100),i=O.lookAt([0,.4,4.4],[0,0,0],[0,1,0]),f=O.multiply(r,i);v.uniforms.uViewProj.set(f),v.uniforms.uTime.set(e),v.uniforms.uMouse.set([n,a]),v.uniforms.uNow.set(e),v.draw(),h.uniforms.uViewProj.set(f),h.uniforms.uTime.set(e),h.uniforms.uMouse.set([n,a]),h.uniforms.uNow.set(e),h.draw()})})(),()=>{e=!0,t?.(),window.removeEventListener(`pointermove`,l)}});var m=M();o(m,e=>a(r,e),()=>i(r)),l(t,m),d()}var P=c(`<link rel="icon" type="image/png" href="/favicon.png"/> <meta property="og:image" content="/logo.png"/> <meta name="description" content="Roostr is an open, decentralized, minimally opinionated workspace where humans get things done with an army of agents coordinating together. No account, no platform. Your key is your identity."/>`,1),F=c(`<main class="veil-page svelte-1uha8ag"><a class="veil-link svelte-1uha8ag" href="/app" aria-label="Enter Roostr"><!></a> <div class="veil-copy svelte-1uha8ag"><span class="eyebrow svelte-1uha8ag">R O O S T R</span> <h1 class="svelte-1uha8ag">A central workplace.<br/><span class="dim svelte-1uha8ag">For every kind of mind.</span></h1> <p class="sub svelte-1uha8ag">An open, decentralized, minimally opinionated workspace where humans get things done — with an
			army of agents coordinating together beside them. No account, no platform. Your key is your identity.</p> <div class="cta svelte-1uha8ag"><a class="btn primary svelte-1uha8ag" href="/app">Enter</a></div></div> <header class="chrome svelte-1uha8ag"><a class="mark svelte-1uha8ag" href="/" aria-label="Roostr home"><img src="/logo.png" alt="Roostr" class="svelte-1uha8ag"/><span>Roostr</span></a> <nav class="chrome-links svelte-1uha8ag"><a class="login svelte-1uha8ag" href="/app">Log in</a> <a class="gh svelte-1uha8ag" href="https://github.com/Geep5/Roostr" aria-label="GitHub" title="GitHub"><svg viewBox="0 0 16 16" width="24" height="24" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"></path></svg></a></nav></header> <div class="sr-only svelte-1uha8ag"><h1>Roostr — a central workplace for every kind of mind</h1> <p>An open, decentralized, minimally opinionated workspace where humans get things done — with an
			army of agents coordinating together beside them. No account, no platform. Your key is your identity.</p> <nav><a href="/app">Open the app</a> <a href="/privacy">Privacy</a> <a href="https://github.com/Geep5/Roostr">GitHub</a></nav></div></main>`);function I(e){var i=F();m(`1uha8ag`,e=>{var n=P();p(4),t(()=>{r.title=`Roostr — a central workplace for every kind of mind`}),l(e,n)});var a=n(i);N(n(a),{}),s(a),p(6),s(i),l(e,i)}export{I as component};