(() => {
  'use strict';
  if (document.querySelector('.on-launcher') || location.hostname === 'news.oathwallet.org' ||
      location.pathname.startsWith('/news/') || location.pathname === '/newsletter-preview') return;
  const link = document.createElement('a');
  link.className = 'on-launcher';
  link.href = 'https://news.oathwallet.org/';
  link.innerHTML = '<span aria-hidden="true">✉</span> Oath Notes';
  document.body.append(link);
})();
