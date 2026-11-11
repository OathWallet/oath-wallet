(() => {
  const greetings = {
    en: 'Hello', ar: 'مرحبًا', fr: 'Bonjour', ja: 'こんにちは', es: 'Hola',
    am: 'ሰላም', bn: 'নমস্কার', cs: 'Ahoj', da: 'Hej', de: 'Hallo',
    el: 'Γεια σου', fa: 'سلام', fi: 'Hei', fil: 'Kumusta', gu: 'નમસ્તે',
    ha: 'Sannu', he: 'שלום', hi: 'नमस्ते', hr: 'Bok', hu: 'Szia',
    id: 'Halo', it: 'Ciao', ka: 'გამარჯობა', km: 'សួស្តី', kn: 'ನಮಸ್ಕಾರ',
    ko: '안녕하세요', ml: 'നമസ്കാരം', mr: 'नमस्कार', ms: 'Helo', my: 'မင်္ဂလာပါ',
    nb: 'Hei', ne: 'नमस्ते', nl: 'Hallo', or: 'ନମସ୍କାର', pa: 'ਸਤ ਸ੍ਰੀ ਅਕਾਲ',
    pl: 'Cześć', 'pt-BR': 'Olá', 'pt-PT': 'Olá', ro: 'Salut', ru: 'Привет',
    sd: 'سلام', si: 'ආයුබෝවන්', sk: 'Ahoj', sl: 'Živjo', sv: 'Hej',
    sw: 'Habari', ta: 'வணக்கம்', te: 'నమస్కారం', th: 'สวัสดี', tr: 'Merhaba',
    uk: 'Привіт', ur: 'سلام', uz: 'Salom', vi: 'Xin chào', yo: 'Ẹ n lẹ',
    'zh-Hans': '你好', 'zh-Hant': '你好',
  };

  function mount(section) {
    const heading = section.querySelector('h2');
    const letters = [...heading.querySelectorAll('span > span, em > span')];
    const track = section.querySelector('.why-track');
    const stack = section.querySelector('.why-stack');
    const cards = [...section.querySelectorAll('.why-card')];
    const greeting = section.querySelector('.why-greetings span');
    const motion = matchMedia('(prefers-reduced-motion: reduce)');
    const words = typeof Intl.Segmenter === 'function' ? Object.entries(greetings).map(([lang, word]) => {
      const segments = new Intl.Segmenter(lang, { granularity: 'grapheme' }).segment(word);
      return { lang, letters: Array.from(segments, part => part.segment) };
    }) : [];
    let wordIndex = 0, length = 0, deleting = false, timer = 0, frame = 0;

    function type() {
      const word = words[wordIndex];
      length += deleting ? -1 : 1;
      greeting.lang = word.lang;
      greeting.textContent = word.letters.slice(0, length).join('');
      let delay = deleting ? 70 : 125;
      if (length === word.letters.length) {
        deleting = true;
        delay = 1100;
      } else if (length === 0) {
        deleting = false;
        wordIndex = (wordIndex + 1) % words.length;
        delay = 220;
      }
      timer = setTimeout(type, delay);
    }

    const pinTop = 92;
    let step = 0;

    function revealFocusedCard(event) {
      const index = cards.indexOf(event.target.closest('.why-card'));
      if (index >= 0 && !cards[index].hasAttribute('data-current')) {
        window.scrollBy({ top: track.getBoundingClientRect().top - pinTop + index * step + 1, behavior: 'instant' });
        update();
      }
    }

    function update() {
      frame = 0;
      const animated = !motion.matches;
      section.setAttribute('data-deck', '');
      const height = window.innerHeight;
      const top = heading.getBoundingClientRect().top;
      const count = Math.floor((height * .92 - top) / (height * .24) * letters.length);
      letters.forEach((letter, i) => letter.toggleAttribute('data-pending', animated && i >= count));
      // Every card occupies the same grid cell. Scroll distance selects one card
      // and lets a card taller than the viewport pass completely into view.
      const overflow = Math.max(0, stack.offsetHeight + pinTop + 16 - height);
      step = Math.round(Math.max(180, Math.min(340, height * .38)) + overflow);
      track.style.setProperty('--travel', ((cards.length - 1) * step + overflow) + 'px');
      const trackTop = track.getBoundingClientRect().top;
      const distance = Math.max(0, pinTop - trackTop);
      const index = Math.min(cards.length - 1, Math.floor(distance / step));
      const withinCard = distance - index * step;
      stack.style.setProperty('--pin', (pinTop - Math.min(overflow, withinCard)) + 'px');
      const entered = !animated || (count >= letters.length && trackTop <= height * .72);
      cards.forEach((card, i) => card.toggleAttribute('data-current', entered && i === index));
      const showGreeting = entered && index === cards.length - 1 && stack.getBoundingClientRect().bottom > 0;
      if (animated && words.length && showGreeting && !document.hidden) {
        if (!timer) type();
      } else {
        clearTimeout(timer);
        timer = 0;
        if (!animated) {
          greeting.lang = 'en';
          greeting.textContent = greetings.en;
          wordIndex = length = 0;
          deleting = false;
        }
      }
    }

    function schedule() {
      if (!frame) frame = requestAnimationFrame(update);
    }
    update();
    const observer = new ResizeObserver(schedule);
    observer.observe(stack);
    stack.addEventListener('focusin', revealFocusedCard);
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    motion.addEventListener('change', schedule);
    document.addEventListener('visibilitychange', schedule);
    return () => {
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', schedule);
      motion.removeEventListener('change', schedule);
      document.removeEventListener('visibilitychange', schedule);
      stack.removeEventListener('focusin', revealFocusedCard);
      observer.disconnect();
      cancelAnimationFrame(frame);
      clearTimeout(timer);
    };
  }
  window.OathWhy = { mount };
})();
