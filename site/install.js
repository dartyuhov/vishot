'use strict';

(() => {
  const controls = document.querySelector('[data-install-controls]');
  const command = document.querySelector('[data-brew-command]');
  const copy = document.querySelector('[data-copy-command]');
  const status = document.querySelector('[data-copy-status]');
  const download = document.querySelector('[data-download]');
  const chooser = document.getElementById('download-chooser');
  let reset;

  if (controls && !controls.hidden) {
    copy.hidden = false;
    copy.addEventListener('click', async () => {
      clearTimeout(reset);
      copy.disabled = true;
      try {
        await navigator.clipboard.writeText(command.textContent);
        copy.textContent = 'Copied!';
        status.textContent = 'Command copied.';
        reset = setTimeout(() => { copy.textContent = 'Copy'; status.textContent = ''; }, 2500);
      } catch {
        copy.textContent = 'Copy';
        status.textContent = 'Could not copy. Select the command and copy it manually.';
      } finally {
        copy.disabled = false;
      }
    });
    if (typeof chooser?.showModal === 'function') {
      download.setAttribute('aria-haspopup', 'dialog');
      download.setAttribute('aria-controls', chooser.id);
      download.addEventListener('click', event => {
        if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        chooser.showModal();
      });
      chooser.querySelector('[data-close-download]').addEventListener('click', () => chooser.close());
      chooser.addEventListener('keydown', event => {
        if (event.key !== 'Tab') return;
        const items = [...chooser.querySelectorAll('button, a[href]')];
        const first = items[0];
        const last = items[items.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault(); last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault(); first.focus();
        }
      });
      chooser.addEventListener('close', () => download.focus({ preventScroll: true }));
    }
  }

  // Optional decoration runs independently of the server-rendered installation path.
  fetch('/api/github').then(response => {
    if (!response.ok) throw new Error('Metadata unavailable');
    return response.json();
  }).then(value => {
    if (!Number.isSafeInteger(value.stars) || value.stars < 0) return;
    const stars = document.querySelector('[data-stars]');
    stars.textContent = `★ ${new Intl.NumberFormat('en').format(value.stars)}`;
    stars.setAttribute('aria-label', `${value.stars} GitHub stars`);
    stars.hidden = false;
  }).catch(() => {});

})();
