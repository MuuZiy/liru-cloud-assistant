/* 控制台的提示和反馈；关闭请求仅由显式关闭操作触发。 */
(function(){
  'use strict';
  function reviewText(j){
    return '另有 '+Math.max(0,Number(j.unverified_count)||0)+' 项资料，请到课程页面查看';
  }
  function showReview(j){
    let dialog=document.getElementById('manualReview');
    if(dialog)dialog.remove();
    dialog=document.createElement('dialog');dialog.id='manualReview';dialog.className='manual-review';
    dialog.setAttribute('aria-labelledby','manualReviewTitle');
    const heading=document.createElement('h2');heading.id='manualReviewTitle';heading.textContent='需要你查看的资料';
    const intro=document.createElement('p');intro.textContent='请回到课程页面，打开下面这些资料。视频任务可以照常进行。';
    const list=document.createElement('ul');list.className='manual-review-list';
    const types={url:'链接',page:'说明页',book:'书籍',resource:'资源文件',fsresource:'资源文件',folder:'资料夹'};
    (j.review_items || []).forEach(it=>{
      const li=document.createElement('li'),label=document.createElement('span'),title=document.createElement('b'),chapter=document.createElement('small');
      label.className='manual-review-type';label.textContent=types[it.type] || '课程内容';
      title.textContent=it.name || '未命名内容';chapter.textContent=it.chapter || '未分章';
      li.append(label,title,chapter);list.appendChild(li);
    });
    if(!list.children.length){const li=document.createElement('li');li.textContent='请在课程页面查看未加入自动播放的链接或说明内容。';list.appendChild(li);}
    const note=document.createElement('p');note.className='manual-review-note';note.textContent='查看后，请以课程页面显示的完成状态为准。';
    const close=document.createElement('button');close.type='button';close.textContent='知道了';
    close.onclick=()=>dialog.close();
    const previous=document.activeElement;
    dialog.addEventListener('close',()=>{if(previous && previous.isConnected)previous.focus();});
    dialog.append(heading,intro,list,note,close);document.body.appendChild(dialog);dialog.showModal();
  }
  function mountReview(j,host){
    if(!host)return;
    const count=Math.max(0,Number(j.unverified_count)||0);
    host.hidden=!count;
    if(!count)return;
    let text=host.querySelector('span'),button=host.querySelector('button');
    if(!text){text=document.createElement('span');button=document.createElement('button');button.type='button';button.textContent='查看内容';host.append(text,button);}
    text.textContent=reviewText(j);
    button.onclick=()=>showReview(j);
  }
  function message(value){
    const raw=String(value == null ? '' : value).trim();
    let title='',text='';
    if(/课程记录.*(?:保存失败|无法保存|未能保存)/.test(raw)){
      title='课程记录未能保存';text=(/旧记录仍保留|之前的记录仍保留/.test(raw) ? '之前的记录仍保留。' : '本次记录没有更新。')+'请先停止任务，再查看详细原因。';
    }else if(/验证码|验证频繁|频率限制|请求过于频繁|\b429\b|风控|安全验证/i.test(raw)){
      title='请先完成网页提示';text='请在 Edge 中查看验证或访问限制提示，处理后再继续。';
    }else if(/考勤|长按|按住确认/.test(raw) && (!/已完成|通过|成功/.test(raw) || /未通过|没.*通过|失败|未能/.test(raw))){
      title='课程需要考勤确认';text='请回到 Edge，按课程页面的要求完成确认。';
    }else if(/授权.*(?:失败|拒绝)|拒绝.*连接|WebSocket.*handshake|(?:授权|连接).*403|403.*(?:授权|连接)/i.test(raw)){
      title='Edge 尚未允许连接';text='请在 Edge 中确认连接授权，然后再点「接管 Edge」。';
    }else if(/\b403\b/.test(raw)){
      title='课程网站暂时拒绝访问';text='请在 Edge 中查看网页提示，处理后再继续。';
    }else if(/登录.*(?:过期|失效)|未登录/.test(raw)){
      title='请重新登录课程';text='请在 Edge 中完成登录，再打开课程视频。';
    }else if(/未找到.*(?:课堂|课程).*标签|目标.*(?:关闭|丢失)|窗口已关闭/.test(raw)){
      title='没有找到课程页面';text='请在 Edge 中打开课程，再回到控制台。';
    }else if(/保留.*(?:PID|记录).*|身份.*(?:无法|不明)|停止失败|未能停止|无法.*(?:停止|结束)/i.test(raw)){
      title='任务还没有停止';text='请稍后再点「停止」。控制台会保留现场，便于排查。';
    }else if(/AbortError|Failed to fetch|NetworkError|ERR_|连接不上控制台|连不上控制台|HTTP\s*5\d\d/i.test(raw)){
      title='暂时连接不上控制台';text='请确认控制台仍在运行，然后重试。';
    }else if(/Replace|Exception|Traceback|Error:|调用.*参数|0x[0-9a-f]{4}|\/api\/|CDP|WebSocket|WinError|run\.pid|stop\.flag|参数.*无效|路径的形式/i.test(raw)){
      title='这一步没有完成';text='请重试；如果仍然失败，可展开详细原因进行排查。';
    }
    if(title)return {title,text,detail:raw};
    const plain=raw.replace(/登录窗口|接管 Edge 窗口/g,'Edge');
    return {title:plain,text:plain,detail:''};
  }
  function userText(text){const m=message(text);return m.detail ? m.title+'。'+m.text : m.text;}
  function showDetails(raw,title){
    let old=document.getElementById('messageDetails');if(old)old.remove();
    const d=document.createElement('dialog');d.id='messageDetails';d.className='manual-review message-details';
    const h=document.createElement('h2');h.textContent=title || '详细原因';
    const p=document.createElement('p');p.textContent='以下信息用于排查问题，日常使用不需要理解这些内容。';
    const pre=document.createElement('pre');pre.textContent=String(raw || '没有更多信息。');
    const b=document.createElement('button');b.type='button';b.textContent='关闭';b.onclick=()=>d.close();
    const focus=document.activeElement;d.addEventListener('close',()=>{if(focus && focus.isConnected)focus.focus();d.remove();});
    d.append(h,p,pre,b);document.body.appendChild(d);d.showModal();
  }
  window.LiruInterface={reviewText,showReview,mountReview,message,userText,showDetails};
})();

/* Based on Motion Prompt #022 Light sweep · MIT License (c) 2026 Shohei Ohtaki · https://showheyohtaki.github.io/motion-prompt/#022
   A single restrained specular sweep for the controls. */
(function(){
  const media=matchMedia('(prefers-reduced-motion:reduce)'), active=new Set(), presses=new Set();
  const sampled='linear('+Array.from({length:31},(_,i)=>(1-Math.pow(1-i/30,3)).toFixed(5)).join(',')+')';
  const out=window.CSS && CSS.supports('animation-timing-function',sampled) ? sampled : 'cubic-bezier(.215,.61,.355,1)';
  function clear(el,keepWave){
    if(!el)return;
    if(el._receiptTimer)clearTimeout(el._receiptTimer);
    el.querySelectorAll(':scope > .press-surface').forEach(n=>{
      if(keepWave && n.classList.contains('sheen-surface'))return;
      n.getAnimations({subtree:true}).forEach(a=>a.cancel());n.remove();active.delete(n);
    });
    delete el.dataset.receipt;
  }
  function surface(el,cls){
    el.classList.add('press-host');
    const n=document.createElement('span');n.className='press-surface '+cls;n.setAttribute('aria-hidden','true');
    el.appendChild(n);active.add(n);return n;
  }
  function press(el,event){
    if(!el || el.disabled || el.getAttribute('aria-disabled')==='true' || media.matches || !el.animate)return;
    el.querySelectorAll(':scope > .press-surface.sheen-surface').forEach(n=>{
      n.getAnimations({subtree:true}).forEach(a=>a.cancel());n.remove();active.delete(n);
    });
    const box=el.getBoundingClientRect(), keyboard=!event || event.detail===0;
    const x=keyboard ? box.width/2 : Math.max(0,Math.min(box.width,event.clientX-box.left));
    const n=surface(el,'sheen-surface glass-surface');
    n.style.setProperty('--press-x',(box.width ? x/box.width*100 : 50)+'%');
    const light=document.createElement('i');light.className='press-sheen';n.appendChild(light);
    light.animate([{transform:'translateX(-120%) skewX(-20deg)'},{transform:'translateX(120%) skewX(-20deg)'}],
      {duration:560,easing:out,fill:'both'});
    if(el._glassPress){el._glassPress.cancel();presses.delete(el._glassPress);}
    if(keyboard){
      const a=el.animate([{scale:1},{scale:.985,offset:.2},{scale:1.003,offset:.65},{scale:1}],
        {duration:400,easing:'cubic-bezier(.22,.68,0,1)'});
      el._glassPress=a;presses.add(a);
      a.finished.catch(()=>{}).finally(()=>{presses.delete(a);if(el._glassPress===a)el._glassPress=null;});
    }
    const fade=n.animate([{opacity:0,offset:0},{opacity:1,offset:.18},{opacity:.7,offset:.7},{opacity:0,offset:1}],{duration:600,fill:'both'});
    fade.onfinish=()=>{n.remove();active.delete(n);};
  }
  function receipt(el,tone){
    if(!el)return;
    clear(el,true);el.dataset.receipt=tone || 'ok';
    const n=surface(el,'receipt-surface');
    if(!media.matches && n.animate){
      n.animate([{opacity:0},{opacity:1,offset:.15},{opacity:1,offset:.75},{opacity:0}],{duration:1400});
    }
    el._receiptTimer=setTimeout(()=>clear(el),1400);
  }
  document.addEventListener('click',e=>{
    const el=e.target.closest && e.target.closest('button');
    if(el && !el.closest('.menu') && !el.matches('.phfold,.fold,.iconbtn,.dlgx'))press(el,e);
  },true);
  let hoverFrame=0,hoverButton=null,hoverX=50;
  document.addEventListener('pointermove',e=>{
    if(media.matches)return;
    const el=e.target.closest && e.target.closest('.pearl,.ghostpill,.chipbtn,.mini,.iconbtn');
    if(!el || el.disabled)return;
    if(hoverButton!==el){hoverButton=el;el._glassRect=el.getBoundingClientRect();el.classList.add('glass-control');}
    hoverX=Math.max(0,Math.min(100,(e.clientX-el._glassRect.left)/el._glassRect.width*100));
    if(!hoverFrame)hoverFrame=requestAnimationFrame(()=>{hoverFrame=0;if(hoverButton)hoverButton.style.setProperty('--glass-x',hoverX+'%');});
  },{passive:true});
  addEventListener('scroll',()=>{hoverButton=null;},{passive:true});
  addEventListener('resize',()=>{hoverButton=null;},{passive:true});
  function stopFeedback(){
    active.forEach(n=>{n.getAnimations({subtree:true}).forEach(a=>a.cancel());n.remove();active.delete(n);});
    presses.forEach(a=>a.cancel());presses.clear();
    if(hoverFrame)cancelAnimationFrame(hoverFrame);hoverFrame=0;hoverButton=null;
  }
  media.addEventListener('change',e=>{if(e.matches)stopFeedback();});
  addEventListener('pagehide',stopFeedback);
  window.LiruFeedback={press,receipt,clear};
})();

/* Based on Motion Prompt #161 shared element · MIT License (c) 2026 Shohei Ohtaki · https://showheyohtaki.github.io/motion-prompt/#161
   One bounded surface carries the close button into a receipt. Completion waits for the request. */
(function(){
  let current=null;
  const preference=matchMedia('(prefers-reduced-motion:reduce)');
  const reduced=()=>preference.matches;
  preference.addEventListener('change',e=>{if(e.matches && current)current.shell.getAnimations({subtree:true}).forEach(a=>a.cancel());});
  const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  function animate(el,frames,ms,ease){
    if(reduced() || !el.animate)return Promise.resolve();
    const a=el.animate(frames,{duration:ms,easing:ease || 'cubic-bezier(.65,0,.35,1)',fill:'both'});
    return a.finished.catch(()=>{});
  }
  function showShortcut(){if(current){current.shortcut.hidden=false;current.shell.dataset.phase='done';}}
  async function request(){
    const ctrl=new AbortController(),timer=setTimeout(()=>ctrl.abort(),25000);
    try{
      const response=await fetch('/api/close-console',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}',signal:ctrl.signal});
      const data=await response.json();
      if(!response.ok || !data || !data.ok)throw new Error(data && data.msg || 'HTTP '+response.status);
      return data;
    }finally{clearTimeout(timer);}
  }
  async function run(options){
    if(current)return {ok:false,busy:true};
    const button=options.button,box=button.getBoundingClientRect();
    const oldOpacity=button.style.opacity,oldBusy=button.getAttribute('aria-busy');
    const shell=document.createElement('dialog');shell.className='console-exit';shell.dataset.phase='opening';
    shell.setAttribute('aria-label','关闭控制台');shell.addEventListener('cancel',e=>e.preventDefault());
    shell.innerHTML='<div class="exit-veil"></div><section class="exit-plate" role="status" aria-live="polite">'+
      '<span class="exit-source" aria-hidden="true"></span><div class="exit-content"><span class="exit-glyph" aria-hidden="true">'+
      '<svg class="exit-power" viewBox="0 0 48 48" fill="none"><path d="M16 9a17 17 0 1 0 16 0M24 4v17"/></svg>'+
      '<svg class="exit-check" viewBox="0 0 48 48" fill="none"><path pathLength="1" d="M12 24l8 8 17-18"/></svg></span>'+
      '<h2></h2><p class="exit-note"></p><p class="exit-shortcut" hidden>按 <kbd>Ctrl</kbd> + <kbd>W</kbd> 关闭此页</p></div></section>';
    const plate=shell.querySelector('.exit-plate'),source=shell.querySelector('.exit-source'),content=shell.querySelector('.exit-content');
    const title=shell.querySelector('h2'),note=shell.querySelector('.exit-note'),shortcut=shell.querySelector('.exit-shortcut');
    source.textContent='关闭控制台';title.textContent='正在关闭';note.textContent=options.running ? '正在停止任务，请稍等' : '正在结束本次使用';
    document.body.appendChild(shell);shell.showModal();current={shell,shortcut,button};
    const end={left:(innerWidth-Math.min(336,innerWidth-40))/2,top:Math.max(24,innerHeight*.43-100),width:Math.min(336,innerWidth-40),height:202};
    Object.assign(plate.style,{left:end.left+'px',top:end.top+'px',width:end.width+'px',height:end.height+'px',borderRadius:'28px'});
    button.disabled=true;button.setAttribute('aria-busy','true');button.style.opacity='0';
    const initial={left:box.left+'px',top:box.top+'px',width:box.width+'px',height:box.height+'px',borderRadius:'22px'};
    const terminal={left:end.left+'px',top:end.top+'px',width:end.width+'px',height:end.height+'px',borderRadius:'28px'};
    const intro=Promise.all([
      animate(plate,[initial,terminal],600),
      animate(shell.querySelector('.exit-veil'),[{opacity:0},{opacity:1}],600),
      animate(source,[{opacity:1},{opacity:0}],180),
      animate(content,[{opacity:0,translate:'0 8px',offset:0},{opacity:0,translate:'0 8px',offset:.38},{opacity:1,translate:'0 0'}],600)
    ]).then(()=>{if(current && current.shell===shell && shell.dataset.phase==='opening')shell.dataset.phase='waiting';});
    try{
      const result=await (options.request || request)();
      if(!result || !result.ok)throw new Error(result && result.msg || '关闭请求未完成');
      await intro;
      shell.dataset.phase='complete';title.textContent=options.completeTitle || '控制台已关闭';note.textContent=options.completeNote || 'Edge 浏览器保持打开';
      await delay(reduced() ? 0 : 760);
      shell.dataset.phase='done';
      try{if(options.onClosed)options.onClosed();}catch(e){showShortcut();}
      setTimeout(showShortcut,reduced() ? 0 : 650);
      return {ok:true};
    }catch(error){
      const actual=plate.getBoundingClientRect(),veil=shell.querySelector('.exit-veil');
      const veilOpacity=getComputedStyle(veil).opacity,contentOpacity=getComputedStyle(content).opacity;
      shell.dataset.phase='returning';
      shell.getAnimations({subtree:true}).forEach(a=>a.cancel());
      const from={left:actual.left+'px',top:actual.top+'px',width:actual.width+'px',height:actual.height+'px'};
      await Promise.all([
        animate(plate,[from,initial],320,'cubic-bezier(.22,.68,0,1)'),
        animate(veil,[{opacity:veilOpacity},{opacity:0}],300),
        animate(content,[{opacity:contentOpacity},{opacity:0}],180),
      ]);
      current=null;button.style.opacity=oldOpacity;button.disabled=false;shell.close();shell.remove();
      if(oldBusy==null)button.removeAttribute('aria-busy');else button.setAttribute('aria-busy',oldBusy);
      if(options.onFailed)options.onFailed(error);
      return {ok:false,error};
    }
  }
  window.LiruExit={run,showShortcut,active:()=>!!current};
})();
