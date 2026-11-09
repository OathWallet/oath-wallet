(()=>{
 const controls=document.querySelector('[data-lab-controls]');if(!controls)return;
 const wallet=document.getElementById('lab-wallet'),evidence=document.getElementById('lab-evidence');
 const rows=[...document.querySelectorAll('[data-lab-row]')],count=document.querySelector('[data-lab-count]'),empty=document.querySelector('[data-lab-empty]');
 const update=()=>{let visible=0;for(const row of rows){row.hidden=Boolean((wallet.value&&row.dataset.wallet!==wallet.value)||(evidence.value&&row.dataset.evidence!==evidence.value));if(!row.hidden)visible++;}count.textContent=`${visible} of ${rows.length} comparisons shown. All results refer to the dated edition.`;empty.hidden=visible!==0;};
 wallet.addEventListener('change',update);evidence.addEventListener('change',update);
 controls.querySelector('[data-lab-reset]').addEventListener('click',()=>{wallet.value='';evidence.value='';update();});
 controls.hidden=false;update();
})();
