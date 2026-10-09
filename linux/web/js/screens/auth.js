// First-run setup and sign-in.
import { post } from '../api.js';
import { h, replace, spinner } from '../dom.js';

function passwordStrength(text) {
  // Length is what matters most; the meter says "keep going" rather than judging.
  const score = Math.min(1, text.length / 14);
  return { width: `${Math.round(score * 100)}%`, color: score < 0.4 ? 'var(--danger)' : score < 0.7 ? 'var(--warning)' : 'var(--live)' };
}

function errorLine(id) {
  return h('span', { class: 'error', id, role: 'alert' });
}

export function renderSetup({ session, onDone }) {
  const name = h('input', { type: 'text', id: 'setup-name', value: session.bridgeName || 'Camera Bridge', maxlength: 60, autocomplete: 'off' });
  const password = h('input', { type: 'password', id: 'setup-password', autocomplete: 'new-password', required: true, 'aria-describedby': 'setup-password-hint setup-password-error' });
  const confirm = h('input', { type: 'password', id: 'setup-confirm', autocomplete: 'new-password', required: true, 'aria-describedby': 'setup-confirm-error' });
  const code = session.setupTokenRequired ? h('input', { type: 'text', id: 'setup-code', autocomplete: 'off', required: true, spellcheck: 'false', 'aria-describedby': 'setup-code-error' }) : null;
  const meterFill = h('i');
  const passwordError = errorLine('setup-password-error');
  const confirmError = errorLine('setup-confirm-error');
  const codeError = errorLine('setup-code-error');
  const formError = h('p', { class: 'error', role: 'alert' });
  const submit = h('button', { class: 'btn primary', type: 'submit' }, 'Set up this bridge');

  password.addEventListener('input', () => {
    const s = passwordStrength(password.value);
    meterFill.style.width = s.width;
    meterFill.style.background = s.color;
  });

  const form = h('form', {
    novalidate: true,
    onsubmit: async (event) => {
      event.preventDefault();
      replace(passwordError); replace(confirmError); replace(codeError); replace(formError);
      password.removeAttribute('aria-invalid'); confirm.removeAttribute('aria-invalid');
      if (password.value.length < 8) {
        replace(passwordError, 'Use at least 8 characters.');
        password.setAttribute('aria-invalid', 'true'); password.focus();
        return;
      }
      if (password.value !== confirm.value) {
        replace(confirmError, 'The two passwords don’t match.');
        confirm.setAttribute('aria-invalid', 'true'); confirm.focus();
        return;
      }
      submit.disabled = true;
      replace(submit, spinner(), 'Setting up…');
      try {
        const info = await post('auth/setup', { password: password.value, bridgeName: name.value, setupToken: code?.value });
        onDone({ bridgeName: info.bridgeName, csrfToken: info.csrfToken, setupRequired: false });
      } catch (error) {
        submit.disabled = false;
        replace(submit, 'Set up this bridge');
        if (error.field === 'password') replace(passwordError, error.message);
        else if (error.field === 'setupToken') replace(codeError, error.message);
        else if (error.code === 'already_configured') location.reload();
        else replace(formError, error.message);
      }
    },
  },
  h('div', { class: 'field' }, h('label', { for: 'setup-name' }, 'Name this bridge'), name,
    h('span', { class: 'hint' }, 'Shown at the top of this page. Pick something you will recognise, like “Hallway”.')),
  h('div', { class: 'field' }, h('label', { for: 'setup-password' }, 'Choose a password'), password,
    h('div', { class: 'password-meter', 'aria-hidden': 'true' }, meterFill),
    h('span', { class: 'hint', id: 'setup-password-hint' }, 'At least 8 characters. Three or four words in a row make a good one.'), passwordError),
  h('div', { class: 'field' }, h('label', { for: 'setup-confirm' }, 'Type it again'), confirm, confirmError),
  code ? h('div', { class: 'field' }, h('label', { for: 'setup-code' }, 'Setup code'), code,
    h('span', { class: 'hint' }, 'This bridge was started with a setup code. You’ll find it on the bridge’s screen or in its log.'), codeError) : null,
  formError,
  h('div', { class: 'row' }, submit));

  return h('main', { class: 'center-page', id: 'main' },
    h('div', { class: 'card center-card' },
      h('img', { class: 'logo', src: '/mark.svg', alt: '' }),
      h('h1', null, 'Welcome to Camera Bridge'),
      h('p', { class: 'lede' }, 'This box turns your IP cameras into Apple Home cameras, with HomeKit Secure Video recording. Let’s set it up: name it and choose a password. You’ll use the password to sign in from any phone or computer on this network.'),
      form));
}

export function renderLogin({ bridgeName, onSignedIn }) {
  const password = h('input', { type: 'password', id: 'login-password', autocomplete: 'current-password', required: true, autofocus: true, 'aria-describedby': 'login-error' });
  const error = errorLine('login-error');
  const show = h('input', { type: 'checkbox', id: 'login-show', onchange: () => { password.type = show.checked ? 'text' : 'password'; } });
  const submit = h('button', { class: 'btn primary', type: 'submit' }, 'Sign in');
  let timer = null;

  const form = h('form', {
    onsubmit: async (event) => {
      event.preventDefault();
      replace(error);
      password.removeAttribute('aria-invalid');
      submit.disabled = true;
      replace(submit, spinner(), 'Signing in…');
      try {
        const info = await post('auth/login', { password: password.value });
        onSignedIn({ csrfToken: info.csrfToken, bridgeName: info.bridgeName || bridgeName });
      } catch (failure) {
        replace(submit, 'Sign in');
        password.setAttribute('aria-invalid', 'true');
        replace(error, failure.message);
        password.select();
        if (failure.status === 429) {
          const wait = Number(failure.message.match(/\d+/)?.[0] || 15);
          let left = wait;
          clearInterval(timer);
          timer = setInterval(() => {
            left -= 1;
            if (left <= 0) { clearInterval(timer); submit.disabled = false; replace(error); return; }
            replace(error, `Too many wrong tries. Wait ${left} second${left === 1 ? '' : 's'} and try again.`);
          }, 1000);
        } else {
          submit.disabled = false;
          password.focus();
        }
      }
    },
  },
  h('div', { class: 'field' }, h('label', { for: 'login-password' }, 'Password'), password, error),
  h('label', { class: 'check-row', for: 'login-show' }, show, h('span', { class: 'text' }, 'Show the password')),
  h('div', { class: 'row', 'aria-live': 'polite' }, submit));

  return h('main', { class: 'center-page', id: 'main' },
    h('div', { class: 'card center-card' },
      h('img', { class: 'logo', src: '/mark.svg', alt: '' }),
      h('h1', null, bridgeName),
      h('p', { class: 'lede' }, 'Sign in to see your cameras.'),
      form));
}
