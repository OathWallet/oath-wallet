/* Runs before first paint. Light is the default, regardless of OS appearance. */
(() => {
 const key='oath-theme';
 const valid=value=>value==='light'||value==='dark';
 const saved=()=>{
  try {const cookie=document.cookie.split(/;\s*/).find(part=>part.startsWith(key+'='))?.slice(key.length+1);
  if(valid(cookie))return cookie;}catch{}
  try {const value=localStorage.getItem(key);if(valid(value))return value;}catch{}
  return 'light';
 };
 function apply(theme) {
  document.documentElement.setAttribute('data-oath-theme',theme);
  document.documentElement.style.colorScheme=theme;
  let meta=document.querySelector('meta[data-oath-theme-color]');
  if(!meta){meta=document.createElement('meta');meta.name='theme-color';meta.dataset.oathThemeColor='';document.head.append(meta);}
  meta.content=theme==='dark'?'#0a0a0b':'#ffffff';
  document.querySelectorAll('[data-oath-theme-choice]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.oathThemeChoice===theme)));
 }
 apply(saved());
 function persist(theme){
  try{localStorage.setItem(key,theme);}catch{}
  const domain=location.hostname==='oathwallet.org'||location.hostname.endsWith('.oathwallet.org')?'; Domain=oathwallet.org':'';
  try{document.cookie=`${key}=${theme}; Path=/; Max-Age=31536000; SameSite=Lax${domain}${location.protocol==='https:'?'; Secure':''}`;}catch{}
 }
 document.addEventListener('click',event=>{
  const button=event.target.closest?.('[data-oath-theme-choice]');
  const theme=button?.dataset.oathThemeChoice;if(!valid(theme))return;
  apply(theme);
  persist(theme);
 });
 document.addEventListener('DOMContentLoaded',()=>apply(saved()));
 window.addEventListener('pageshow',()=>apply(saved()));
 window.addEventListener('storage',event=>{if(event.key===key&&valid(event.newValue)){apply(event.newValue);persist(event.newValue);}});
 // The home-page component replaces its server fallback after loading.
 new MutationObserver(()=>{
  const theme=document.documentElement.getAttribute('data-oath-theme');
  document.querySelectorAll('[data-oath-theme-choice]').forEach(button=>{
   const value=String(button.dataset.oathThemeChoice===theme);
   if(button.getAttribute('aria-pressed')!==value)button.setAttribute('aria-pressed',value);
  });
 }).observe(document.documentElement,{childList:true,subtree:true});
})();
