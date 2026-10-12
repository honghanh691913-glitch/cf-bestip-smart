// 187: textured orthographic shading + true visible SketchUp edges.
(function () {
  'use strict';
  let work = null, rendering = null, canvas = null, gl = null, program = null, enlargedKey = '';
  const MAX_TRIANGLES=240000, MAX_LINES=60000;
  function notify(key,token,url,error){if(window.sketchup&&typeof sketchup.soft_batch_ingest_preview_ready==='function')sketchup.soft_batch_ingest_preview_ready(key,token,url||'',error||'');}
  function cardFor(key){return Array.from(document.querySelectorAll('#rows .card')).find(c=>c.dataset.key===key);}
  window.setIngestPreviewStatus=function(key,text){
    const card=cardFor(key),row=rows.find(r=>r.key===key);if(row)row.preview_status=String(text||'');
    if(card){let label=card.querySelector('.preview-status');if(!label){label=document.createElement('div');label.className='preview-status';card.querySelector('.thumb-column').appendChild(label);}label.textContent=text||'';label.title=text||'';}
  };
  window.beginIngestPreview=function(key,token,margin){
    if(!rows.some(r=>r.key===key))return;
    if(work)work.cancelled=true;if(rendering)rendering.cancelled=true;
    work={key,token,margin:Math.max(1.06,Math.min(1.5,Number(margin)||1.2)),p:[],c:[],l:[],uv:[],ids:[],styles:new Map(),promises:[],cancelled:false};
  };
  window.addIngestPreviewStyle=function(token,style){
    if(!work||work.token!==token)return;
    const data=work;
    if(!style||!Number.isInteger(style.id)||style.id<0||style.id>1024||!Array.isArray(style.color)||style.color.length!==3)return;
    if(data.styles.has(style.id))return;
    const row={...style,alpha:Number.isFinite(style.alpha)?Math.max(0,Math.min(1,style.alpha)):1};data.styles.set(style.id,row);
    if(style.image){
      if(typeof style.image!=='string'||!style.image.startsWith('data:image/png;base64,')||style.image.length>1800000){row.failed=true;return;}
      data.promises.push(new Promise(resolve=>{
        const image=new Image();let done=false;
        const finish=(ok)=>{if(done)return;done=true;clearTimeout(timer);image.onload=image.onerror=null;row.failed=!ok;if(ok)row.bitmap=image;resolve();};
        const timer=setTimeout(()=>finish(false),10000);
        image.onload=()=>finish(image.width>0&&image.height>0&&image.width<=512&&image.height<=512);
        image.onerror=()=>finish(false);image.src=style.image;
      }));
    }
  };
  window.appendIngestPreview=function(token,positions,colors,lines,uvqs,styleIds){
    if(!work||work.token!==token)return;
    if(!Array.isArray(positions)||positions.length%9||positions.length>MAX_TRIANGLES*9){const old=work;work=null;notify(old.key,token,'','预览数据无效或超限');return;}
    const count=positions.length/9;
    if(uvqs===undefined){uvqs=Array.from({length:count*18},(_,i)=>i%3===2?1:0);styleIds=Array(count*2).fill(-1);}
    const valid=Array.isArray(positions)&&positions.length%9===0&&Array.isArray(colors)&&colors.length===count*3&&Array.isArray(lines)&&lines.length%6===0&&Array.isArray(uvqs)&&uvqs.length===count*18&&Array.isArray(styleIds)&&styleIds.length===count*2&&styleIds.every(x=>Number.isInteger(x)&&x>=-1)&&work.p.length+positions.length<=MAX_TRIANGLES*9&&work.l.length+lines.length<=MAX_LINES*6;
    if(!valid||[positions,colors,lines,uvqs].some(a=>a.some(v=>!Number.isFinite(v)))){const old=work;work=null;notify(old.key,token,'','预览数据无效或超限');return;}
    for(const [target,input] of [[work.p,positions],[work.c,colors],[work.l,lines],[work.uv,uvqs],[work.ids,styleIds]])for(let i=0;i<input.length;i++)target.push(input[i]);
  };
  window.cancelIngestPreview=function(token){if(work&&work.token===token){work.cancelled=true;work=null;}if(rendering&&rendering.token===token){rendering.cancelled=true;rendering=null;}};
  function initGL(){
    if(gl&&!gl.isContextLost())return;
    canvas=document.createElement('canvas');canvas.width=canvas.height=512;
    gl=canvas.getContext('webgl',{alpha:false,antialias:true,preserveDrawingBuffer:true});if(!gl)throw new Error('当前系统不支持WebGL预览');
    function shader(type,source){const s=gl.createShader(type);gl.shaderSource(s,source);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS)){gl.deleteShader(s);throw new Error('纹理着色器不可用');}return s;}
    const vs=shader(gl.VERTEX_SHADER,'attribute vec3 aPosition;attribute vec3 aColor;attribute vec3 aUVQ;varying vec3 color;varying vec3 uvq;void main(){gl_Position=vec4(aPosition,1.0);color=aColor;uvq=aUVQ;}');
    const fs=shader(gl.FRAGMENT_SHADER,'#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\nvarying vec3 color;varying vec3 uvq;uniform sampler2D uTexture;uniform bool uTextured;uniform float uAlpha;void main(){vec4 base=vec4(1.0);if(uTextured){if(abs(uvq.z)<0.0000001)discard;base=texture2D(uTexture,fract(uvq.xy/uvq.z));}float alpha=base.a*uAlpha;if(alpha<0.08)discard;gl_FragColor=vec4(base.rgb*color,alpha);}');
    program=gl.createProgram();gl.attachShader(program,vs);gl.attachShader(program,fs);gl.linkProgram(program);gl.deleteShader(vs);gl.deleteShader(fs);if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw new Error('纹理程序不可用');
  }
  function frameFor(data, includeLines) {
    const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
    const inv2 = 1 / Math.sqrt(2), inv6 = 1 / Math.sqrt(6), inv3 = 1 / Math.sqrt(3);
    const project = (x,y,z) => [(x+y)*inv2,(-x+y+2*z)*inv6,(x-y+z)*inv3];
    const arrays = data.p.length ? (includeLines ? [data.p, data.l] : [data.p]) : [data.l];
    for (const a of arrays) for (let i=0;i<a.length;i+=3) {
      const v=project(a[i],a[i+1],a[i+2]);
      for(let k=0;k<3;k++){min[k]=Math.min(min[k],v[k]);max[k]=Math.max(max[k],v[k]);}
    }
    if (!min.every(Number.isFinite) || !max.every(Number.isFinite)) throw new Error('没有可显示的几何');
    const center = min.map((v,k)=>v+(max[k]-v)/2);
    const extent = Math.max(max[0]-min[0],max[1]-min[1]);
    if (!(extent > 1e-10)) throw new Error('模型尺寸过小');
    const half = extent * data.margin / 2, depth = Math.max(max[2]-min[2],extent)*0.6;
    return {project, center, half, depth};
  }
  function draw(data,includeLines){
    initGL();const frame=frameFor(data,true),textures=new Map(),buffers=[];
    const posLoc=gl.getAttribLocation(program,'aPosition'),colorLoc=gl.getAttribLocation(program,'aColor'),uvLoc=gl.getAttribLocation(program,'aUVQ');
    const texLoc=gl.getUniformLocation(program,'uTextured'),alphaLoc=gl.getUniformLocation(program,'uAlpha');
    function coordinates(out,o,x,y,z){const p=frame.project(x,y,z);out[o]=(p[0]-frame.center[0])/frame.half;out[o+1]=(p[1]-frame.center[1])/frame.half;out[o+2]=-(p[2]-frame.center[2])/frame.depth;}
    function bind(a){const buffer=gl.createBuffer();buffers.push(buffer);gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,a,gl.STATIC_DRAW);for(const [loc,off] of [[posLoc,0],[colorLoc,12],[uvLoc,24]]){gl.enableVertexAttribArray(loc);gl.vertexAttribPointer(loc,3,gl.FLOAT,false,36,off);}}
    try{
      gl.viewport(0,0,512,512);gl.clearColor(1,1,1,1);gl.clearDepth(1);gl.depthMask(true);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.useProgram(program);
      gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LEQUAL);gl.disable(gl.CULL_FACE);gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);gl.activeTexture(gl.TEXTURE0);gl.uniform1i(gl.getUniformLocation(program,'uTexture'),0);
      // Bind a complete white texture even for non-textured groups.
      const white=gl.createTexture();textures.set(-1,white);gl.bindTexture(gl.TEXTURE_2D,white);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,1,1,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array([255,255,255,255]));gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
      for(const [id,style] of data.styles){
        if(style.failed)throw new Error('纹理解码失败，未以缺图冒充完成');
        if(!style.bitmap)continue;
        const texture=gl.createTexture();textures.set(id,texture);gl.bindTexture(gl.TEXTURE_2D,texture);
        const source=style.bitmap,resized=document.createElement('canvas');
        resized.width=2**Math.ceil(Math.log2(source.width));resized.height=2**Math.ceil(Math.log2(source.height));
        resized.getContext('2d').drawImage(source,0,0,resized.width,resized.height);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,false);
        gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,resized);
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.REPEAT);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.REPEAT);
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR_MIPMAP_LINEAR);gl.generateMipmap(gl.TEXTURE_2D);
      }
      const p=data.p,meta=[];
      for(let i=0;i<p.length;i+=9){
        const ax=p[i+3]-p[i],ay=p[i+4]-p[i+1],az=p[i+5]-p[i+2],bx=p[i+6]-p[i],by=p[i+7]-p[i+1],bz=p[i+8]-p[i+2];
        const nx=ay*bz-az*by,ny=az*bx-ax*bz,nz=ax*by-ay*bx,len=Math.hypot(nx,ny,nz)||1;
        const side=nx-ny+nz>=0?0:1,id=data.ids[i/9*2+side],style=data.styles.get(id);
        if(id>=0&&!style)throw new Error('预览材质信息不完整');
        const alpha=style?style.alpha:1;if(alpha<0.08)continue;
        const depth=((p[i]+p[i+3]+p[i+6])-(p[i+1]+p[i+4]+p[i+7])+(p[i+2]+p[i+5]+p[i+8]))/3;
        meta.push({i,side,id,style,depth,shade:0.70+0.30*Math.abs((nx*0.36-ny*0.48+nz*0.8)/len),transparent:!!(style&&(style.transparent||alpha<0.999))});
      }
      // Opaque batches first. Transparent triangles use far-to-near ordering;
      // depth testing remains enabled, including during the edge pass.
      meta.sort((a,b)=>a.transparent!==b.transparent?(a.transparent?1:-1):a.transparent?a.depth-b.depth:a.id-b.id);
      const vertices=new Float32Array(meta.length*27),runs=[];
      for(let n=0;n<meta.length;n++){
        const m=meta[n],textured=m.id>=0&&textures.has(m.id),rgb=m.style?m.style.color:data.c.slice(m.i/3,m.i/3+3);
        if(!runs.length||runs[runs.length-1].id!==m.id)runs.push({id:m.id,start:n*3,count:0,alpha:m.style?m.style.alpha:1});runs[runs.length-1].count+=3;
        for(let j=0;j<3;j++){
          const off=(n*3+j)*9;coordinates(vertices,off,p[m.i+j*3],p[m.i+j*3+1],p[m.i+j*3+2]);
          for(let k=0;k<3;k++)vertices[off+3+k]=(textured?1:Math.max(0,Math.min(1,rgb[k]/255)))*m.shade;
          const uv=m.i/9*18+m.side*9+j*3;for(let k=0;k<3;k++)vertices[off+6+k]=data.uv[uv+k];
        }
      }
      if(vertices.length){
        bind(vertices);gl.enable(gl.POLYGON_OFFSET_FILL);gl.polygonOffset(1,1);
        for(const run of runs){gl.bindTexture(gl.TEXTURE_2D,textures.get(run.id)||white);gl.uniform1i(texLoc,textures.has(run.id)&&run.id>=0?1:0);gl.uniform1f(alphaLoc,run.alpha);gl.drawArrays(gl.TRIANGLES,run.start,run.count);}
        gl.disable(gl.POLYGON_OFFSET_FILL);
      }
      // Only genuine, non-hidden/non-soft SketchUp edges are provided by Ruby.
      // No triangle wireframe, no back-edge/x-ray mode, no thick profile pass.
      if(data.l.length){
        const lines=new Float32Array(data.l.length*3);
        for(let i=0;i<data.l.length;i+=3){const off=i*3;coordinates(lines,off,data.l[i],data.l[i+1],data.l[i+2]);lines[off+3]=lines[off+4]=lines[off+5]=0.10;lines[off+8]=1;}
        bind(lines);gl.bindTexture(gl.TEXTURE_2D,white);gl.uniform1i(texLoc,0);gl.uniform1f(alphaLoc,1);gl.lineWidth(1);gl.drawArrays(gl.LINES,0,lines.length/9);
      }
      gl.finish();if(gl.isContextLost()||gl.getError()!==gl.NO_ERROR)throw new Error('纹理预览显卡资源不足');return canvas.toDataURL('image/png');
    }finally{for(const buffer of buffers)gl.deleteBuffer(buffer);for(const texture of textures.values())gl.deleteTexture(texture);gl.disable(gl.POLYGON_OFFSET_FILL);gl.depthMask(true);}
  }
  window.endIngestPreview=async function(token,includeLines){
    if(!work||work.token!==token)return;
    const data=work;work=null;rendering=data;
    try{
      await Promise.all(data.promises);
      if(data.cancelled||rendering!==data)return;
      if(!rows.some(r=>r.key===data.key)){notify(data.key,token,'','卡片已移除');return;}
      const url=draw(data,includeLines);notify(data.key,token,url,'');
    }catch(e){if(!data.cancelled)notify(data.key,token,'',String(e.message||e));}
    finally{if(rendering===data)rendering=null;data.styles.clear();}
  };
  window.openIngestPreview=function(key){
    const row=rows.find(r=>r.key===key);if(!row)return;
    enlargedKey=key;const overlay=document.getElementById('previewOverlay');
    document.getElementById('previewLargeImage').src=row.thumbnail_url||'';
    document.getElementById('previewCaption').textContent=row.source_label||row.name||'家具预览';
    overlay.hidden=false;document.getElementById('previewClose').disabled=false;document.getElementById('previewClose').focus();
  };
  function closePreview(){document.getElementById('previewOverlay').hidden=true;const card=cardFor(enlargedKey);enlargedKey='';if(card)card.querySelector('.thumb-frame').focus();}
  document.getElementById('previewClose').addEventListener('click',closePreview);
  document.getElementById('previewOverlay').addEventListener('click',e=>{if(e.target.id==='previewOverlay')closePreview();});
  document.addEventListener('keydown',e=>{if(!document.getElementById('previewOverlay').hidden){if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();closePreview();}else if(e.key==='Tab'){e.preventDefault();document.getElementById('previewClose').focus();}}},true);
  const update=window.updateThumb;
  window.updateThumb=function(key,url){update(key,url);if(enlargedKey===key)document.getElementById('previewLargeImage').src=url;};
})();
