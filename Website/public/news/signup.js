(() => {
  'use strict';
  const form = document.getElementById('notes-signup');
  if (!form) return;
  const button = form.querySelector('[type=submit]');
  const topics = form.querySelector('.notes-topics');
  const status = document.getElementById('notes-status');
  const count = document.getElementById('notes-count');
  const selected = () => [...form.querySelectorAll('input[name=topic]:checked')].map(input => input.value);

  function updateTopics() {
    count.textContent = selected().length + ' selected';
    status.textContent = '';
  }
  topics.addEventListener('change', updateTopics);
  window.addEventListener('pageshow', updateTopics);
  updateTopics();
  button.disabled = false;

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (button.disabled) return;
    const chosen = selected();
    if (!chosen.length) {
      topics.open = true;
      status.textContent = 'Choose at least one topic.';
      topics.querySelector('input').focus();
      return;
    }
    button.disabled = true;
    form.setAttribute('aria-busy', 'true');
    status.textContent = 'Saving your subscription…';
    try {
      const response = await fetch(form.action, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({
          email: form.elements.email.value, topics: chosen, consent: true,
          website: form.elements.website.value, source: '/newsletter'
        }),
        signal: AbortSignal.timeout(25000)
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || result.ok !== true) {
        status.textContent = typeof result.error === 'string' ? result.error : 'We couldn’t save your subscription. Please try again.';
        return;
      }
      const title = document.getElementById('notes-success-title');
      if (!result.subscribed) title.textContent = 'Signup received.';
      document.getElementById('notes-message').textContent = result.message;
      form.reset();
      form.hidden = true;
      document.getElementById('notes-invitation').hidden = true;
      document.getElementById('notes-success').hidden = false;
      title.focus();
    } catch (error) {
      status.textContent = error.name === 'TimeoutError'
        ? 'The connection took too long. Please try again.'
        : 'We couldn’t reach Oath Notes. Check your connection and try again.';
    } finally {
      form.removeAttribute('aria-busy');
      button.disabled = false;
    }
  });
})();
