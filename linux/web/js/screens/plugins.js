// Plugins (#/plugins): the vendor integrations this bridge has (compiled into the system, updated with it), each switched on or off, with its
// own page. The Wyze plugin (#/plugins/wyze): sign in to the Wyze account (two-step verification included), the account's cameras with how
// each one can connect, and Add for the ones that can. Sky Watcher is the third plugin: no account, so only its switch, and its page is #/sky.
import { get, patch, post } from '../api.js';
import { confirmDialog, h, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { setPlugins } from '../store.js';
import { field, inlineError, switchRow } from './common.js';
import { timeAgo } from '../format.js';

/** Where a plugin's own page is, when it is not #/plugins/<id>. */
const PLUGIN_PAGES = { sky: '#/sky' };

export function renderPlugins({ navigate }) {
  const root = h('div', { class: 'card-columns' }, h('div', { class: 'checking' }, spinner()));
  let destroyed = false;

  async function load() {
    try {
      const { plugins } = await get('plugins');
      setPlugins(plugins);   // the menu and the camera page follow the switches
      if (destroyed) return;
      replace(root, plugins.map((plugin) => h('div', { class: 'card plugin-card' },
        h('div', { class: 'plugin-head' }, h('h2', null, plugin.name),
          plugin.needsInternet ? internetBadge() : null,
          plugin.account ? h('span', { class: 'pill live' }, plugin.account) : h('span', { class: 'pill idle' }, plugin.enabled ? 'On' : 'Off')),
        h('p', { class: 'desc' }, plugin.summary),
        plugin.internetNote ? h('p', { class: 'small plugin-internet' }, plugin.internetNote) : null,
        h('p', { class: 'small muted' }, plugin.needs),
        plugin.lastError ? h('p', { class: 'problems' }, plugin.lastError) : null,
        switchRow({ title: 'Use this plugin', checked: plugin.enabled, onchange: async (on) => {
          try { await patch(`plugins/${plugin.id}`, { enabled: on }); toast(on ? `${plugin.name} is on.` : `${plugin.name} is off.`, 'ok'); load(); } catch (error) { toast(error.message, 'error'); load(); }
        } }),
        h('div', { class: 'row' }, h('a', { class: 'btn', href: Object.hasOwn(PLUGIN_PAGES, plugin.id) ? PLUGIN_PAGES[plugin.id] : `#/plugins/${plugin.id}` }, 'Open', icon('chevron'))))));
    } catch (error) {
      if (!destroyed) replace(root, inlineError(error.message));
    }
  }

  load();
  return {
    el: h('div', null, h('div', { class: 'page-head' }, h('h1', null, 'Plugins')),
      h('p', { class: 'lede' }, 'Plugins add what Camera Bridge doesn’t do on its own: connecting cameras that don’t speak ONVIF or RTSP, and watching the sky. They come with Camera Bridge OS and update with it.'),
      root),
    destroy() { destroyed = true; },
  };
}

/** The plugin needs the vendor's cloud: Camera Bridge itself works without the internet, so it is said plainly. */
function internetBadge() {
  return h('span', { class: 'pill internet', title: 'This plugin uses the camera maker’s cloud' }, icon('network'), 'Needs internet');
}

/** The badge and its sentence at the top of a plugin's own page. */
function internetNotice(id) {
  const note = h('p', { class: 'small plugin-internet' });
  const el = h('div', { class: 'plugin-internet-head', hidden: true }, internetBadge(), note);
  get('plugins').then(({ plugins }) => {
    const plugin = plugins.find((p) => p.id === id);
    if (!plugin?.needsInternet) return;
    note.textContent = plugin.internetNote || '';
    el.hidden = false;
  }).catch(() => {});
  return el;
}

const KIND_WORDS = { authenticatorApp: 'Authenticator app', textMessage: 'Text message', email: 'Email' };

export function renderWyzePlugin({ navigate }) {
  const root = h('div', null, h('div', { class: 'checking' }, spinner()));
  let destroyed = false;
  let state = null;
  let busy = '';
  let problem = null;
  const form = { email: '', password: '', keyID: '', apiKey: '' };
  let verification = null;   // { id, kinds, kind, code, sent }

  async function load(refresh = false) {
    busy = refresh ? 'refresh' : busy;
    if (state) draw();
    try {
      state = await get(`plugins/wyze${refresh ? '?refresh=1' : ''}`);
      problem = null;
    } catch (error) { problem = error.message; }
    busy = '';
    if (!destroyed) draw();
  }

  async function run(name, work) {
    busy = name; problem = null; draw();
    try { await work(); } catch (error) { problem = error.message; }
    busy = '';
    if (!destroyed) draw();
  }

  function signInCard() {
    // The Sign in button follows the four fields as they are typed (the form is not drawn again on every key).
    let submit = null;
    const complete = () => !!(form.email.trim() && form.password && form.keyID.trim() && form.apiKey.trim());
    const input = (key, label, type, hint) => field(label, h('input', { type, value: form[key], autocomplete: 'off', spellcheck: 'false',
      oninput: (e) => { form[key] = e.target.value; if (submit) submit.disabled = !!busy || !complete(); } }), { hint });
    if (verification) {
      const v = verification;
      return h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); verify(); } },
        h('h2', null, 'Two-step verification'),
        h('p', { class: 'desc' }, 'Your Wyze account asks for a code.'),
        v.kinds.length > 1 ? h('div', { class: 'stack', role: 'radiogroup', 'aria-label': 'Where the code comes from' }, v.kinds.map((kind) => h('label', { class: 'choice' },
          h('input', { type: 'radio', name: 'wyze-kind', checked: v.kind === kind, onchange: () => { v.kind = kind; v.sent = false; draw(); } }),
          h('span', { class: 'text' }, h('span', { class: 'title' }, KIND_WORDS[kind] || kind))))) : null,
        v.kind !== 'authenticatorApp' ? h('div', { class: 'row' }, h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: () => run('send', async () => {
          await post('plugins/wyze/send-code', { verification: v.id, kind: v.kind });
          v.sent = true;
          toast('Wyze sent the code.', 'ok');
        }) }, busy === 'send' ? spinner() : null, v.sent ? 'Send the code again' : 'Send me the code')) : null,
        field('Code', h('input', { type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', value: v.code, oninput: (e) => {
          v.code = e.target.value;
          const button = e.target.form?.querySelector('button[type="submit"]');
          if (button) button.disabled = !!busy || !v.code.trim();
        } }),
          { hint: v.kind === 'authenticatorApp' ? 'The six digits your authenticator app shows for Wyze.' : 'The code Wyze sent you.' }),
        h('div', { class: 'row' },
          h('button', { class: 'btn primary', type: 'submit', disabled: !!busy || !v.code.trim() }, busy === 'verify' ? spinner() : null, 'Sign in'),
          h('button', { class: 'btn ghost', type: 'button', onclick: () => { verification = null; draw(); } }, 'Start again')));
    }
    return h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); signIn(); } },
      h('h2', null, 'Sign in to Wyze'),
      h('p', { class: 'desc' }, 'Camera Bridge uses your Wyze account to list your cameras and find them on your network. Your password is used to sign in and is not kept.'),
      input('email', 'Email', 'text'),
      input('password', 'Password', 'password'),
      input('keyID', 'Key ID', 'text', 'From Wyze’s developer console (developer-api-console.wyze.com): create an API key there.'),
      input('apiKey', 'API Key', 'password', 'Shown once when you create the key in Wyze’s developer console.'),
      h('div', { class: 'row' }, submit = h('button', { class: 'btn primary', type: 'submit', disabled: !!busy || !complete() },
        busy === 'signin' ? spinner() : icon('lock'), 'Sign in')));
  }

  function signIn() {
    run('signin', async () => {
      const answer = await post('plugins/wyze/sign-in', { ...form });
      if (answer.signedIn) {
        form.password = ''; form.apiKey = '';
        toast('Signed in to Wyze.', 'ok');
        await load(false);
        return;
      }
      verification = { id: answer.verification, kinds: answer.kinds, kind: answer.kinds[0], code: '', sent: false };
    });
  }

  function verify() {
    const v = verification;
    run('verify', async () => {
      await post('plugins/wyze/verify', { verification: v.id, kind: v.kind, code: v.code });
      verification = null;
      form.password = ''; form.apiKey = '';
      toast('Signed in to Wyze.', 'ok');
      await load(false);
    });
  }

  function accountCard() {
    return h('div', { class: 'card' },
      h('div', { class: 'plugin-head' }, h('h2', null, 'Wyze account'), h('span', { class: 'pill live' }, state.account || 'Signed in')),
      h('p', { class: 'desc' }, state.lastSync ? `Cameras updated ${timeAgo(state.lastSync)}. Camera Bridge checks your account every six hours and follows a camera to its new address.` : 'Signed in.'),
      h('div', { class: 'row' },
        h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: () => load(true) }, busy === 'refresh' ? spinner() : icon('refresh'), 'Refresh'),
        h('button', { class: 'btn ghost', type: 'button', disabled: !!busy, onclick: async () => {
          if (!(await confirmDialog({ title: 'Sign out of Wyze?', body: 'Wyze cameras you added keep working: RTSP cameras need no account, and local ones keep their connection details. Camera Bridge stops following their addresses.', confirm: 'Sign out' }))) return;
          run('signout', async () => { await post('plugins/wyze/sign-out'); await load(false); });
        } }, 'Sign out')));
  }

  const RTSP_WORDS = { on: 'RTSP on', off: 'RTSP off', unsupported: 'No RTSP' };

  function camerasCard() {
    const cameras = state.cameras || [];
    return h('div', { class: 'card wyze-cameras' },
      h('h2', null, 'Your Wyze cameras'),
      cameras.length ? h('ul', { class: 'wyze-list' }, cameras.map((c) => h('li', { class: 'wyze-cam' },
        h('div', { class: 'wyze-cam-main' },
          h('strong', null, c.name),
          h('span', { class: 'small muted' }, [c.modelName, `firmware ${c.firmware}`, c.address ? c.address : null].filter(Boolean).join(' · ')),
          h('div', { class: 'row wyze-tags' },
            h('span', { class: `pill ${c.online ? 'live' : 'offline'}` }, c.online ? 'Online' : 'Offline'),
            h('span', { class: `pill ${c.rtsp === 'on' ? 'live' : 'idle'}` }, RTSP_WORDS[c.rtsp] || c.rtsp)),
          c.note ? h('p', { class: 'small' }, c.note) : null),
        c.cameraID
          ? h('a', { class: 'btn small', href: `#/camera/${c.cameraID}` }, 'In Camera Bridge', icon('chevron'))
          : h('button', { class: 'btn small primary', type: 'button', disabled: !c.ways.length, onclick: () => {
            try { sessionStorage.setItem('cb.add.wyze', c.mac); } catch { /* the page asks again */ }
            navigate('/add');
          } }, icon('plus'), 'Add'))))
        : h('p', { class: 'muted' }, 'Your Wyze account has no cameras.'),
      h('p', { class: 'small muted' }, 'RTSP is Wyze’s own feature and the best way in. To turn it on: Wyze app, the camera’s settings, Advanced, RTSP (Cam v4, v3 and Pan v3 on current firmware). The local Wyze connection is unofficial.'));
  }

  function draw() {
    if (!state) { replace(root, problem ? inlineError(problem) : h('div', { class: 'checking' }, spinner())); return; }
    replace(root,
      problem ? inlineError(problem) : null,
      state.lastError && !problem ? inlineError(state.lastError) : null,
      h('div', { class: 'card-columns' }, state.signedIn ? [accountCard(), camerasCard()] : signInCard()));
  }

  load(false);
  return {
    el: h('div', null,
      h('a', { class: 'breadcrumb', href: '#/plugins' }, icon('back'), 'Plugins'),
      h('div', { class: 'page-head' }, h('h1', null, 'Wyze')),
      internetNotice('wyze'),
      root),
    destroy() { destroyed = true; },
  };
}

// The eufy plugin (#/plugins/eufy): sign in to a eufy account (the helper may ask for the characters in a picture and an emailed code),
// the account's cameras, and Add. The helper keeps the eufy session; the password goes to it for the sign-in only.
const EUFY_COUNTRIES = [['US', 'United States'], ['CA', 'Canada'], ['GB', 'United Kingdom'], ['AU', 'Australia'], ['DE', 'Germany'], ['FR', 'France'],
  ['IT', 'Italy'], ['ES', 'Spain'], ['NL', 'Netherlands'], ['SE', 'Sweden'], ['IE', 'Ireland'], ['NZ', 'New Zealand'], ['JP', 'Japan']];

export function renderEufyPlugin({ navigate }) {
  const root = h('div', null, h('div', { class: 'checking' }, spinner()));
  let destroyed = false;
  let state = null;
  let busy = '';
  let problem = null;
  const form = { email: '', password: '', country: 'US', captcha: '', code: '' };

  async function load() {
    try {
      state = await get('plugins/eufy');
      problem = null;
    } catch (error) { problem = error.message; }
    if (!destroyed) draw();
  }

  async function run(name, work) {
    busy = name; problem = null; draw();
    try { await work(); } catch (error) { problem = error.message; }
    busy = '';
    if (!destroyed) draw();
  }

  // Each sign-in step answers the helper's status; the page follows it.
  async function step(path, body, done) {
    const status = await post(`plugins/eufy/${path}`, body);
    if (status.state === 'signedIn') {
      form.password = ''; form.captcha = ''; form.code = '';
      toast('Signed in to eufy.', 'ok');
      await load();
      return;
    }
    if (status.state === 'error' && status.error) problem = status.error;
    state = { ...(state || {}), status };
    if (done) done(status);
  }

  function signInCard() {
    const status = state.status || {};
    if (status.state === 'needsCaptcha' && status.captcha) {
      let submit = null;
      return h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); run('captcha', () => step('captcha', { id: status.captcha.id, answer: form.captcha })); } },
        h('h2', null, 'Type the characters'),
        h('p', { class: 'desc' }, 'eufy asks for the characters in this picture.'),
        h('img', { class: 'eufy-captcha', src: status.captcha.image, alt: 'Characters to type' }),
        field('Characters', h('input', { type: 'text', value: form.captcha, autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
          oninput: (e) => { form.captcha = e.target.value; if (submit) submit.disabled = !!busy || !form.captcha.trim(); } })),
        h('div', { class: 'row' }, submit = h('button', { class: 'btn primary', type: 'submit', disabled: !!busy || !form.captcha.trim() },
          busy === 'captcha' ? spinner() : null, 'Continue')));
    }
    if (status.state === 'needsCode') {
      let submit = null;
      return h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); run('verify', () => step('verify', { code: form.code })); } },
        h('h2', null, 'Enter the code'),
        h('p', { class: 'desc' }, status.codeSentTo ? `eufy emailed a code to ${status.codeSentTo}.` : 'eufy emailed you a code.'),
        field('Code', h('input', { type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', value: form.code,
          oninput: (e) => { form.code = e.target.value; if (submit) submit.disabled = !!busy || !form.code.trim(); } })),
        h('div', { class: 'row' },
          submit = h('button', { class: 'btn primary', type: 'submit', disabled: !!busy || !form.code.trim() }, busy === 'verify' ? spinner() : null, 'Sign in'),
          h('button', { class: 'btn ghost', type: 'button', onclick: () => { state = { ...state, status: { state: 'signedOut' } }; draw(); } }, 'Start again')));
    }
    let submit = null;
    const complete = () => !!(form.email.trim() && form.password);
    const input = (key, label, type, hint) => field(label, h('input', { type, value: form[key], autocomplete: 'off', spellcheck: 'false',
      oninput: (e) => { form[key] = e.target.value; if (submit) submit.disabled = !!busy || !complete(); } }), { hint });
    return h('form', { class: 'card', onsubmit: (e) => { e.preventDefault(); run('signin', () => step('sign-in', { email: form.email, password: form.password, country: form.country })); } },
      h('h2', null, 'Sign in to eufy'),
      h('p', { class: 'desc' }, 'Best: make a second eufy account, share your cameras with it from your main account in the eufy app, and sign in with that one here. Otherwise the eufy app and Camera Bridge sign each other out.'),
      input('email', 'Email', 'text'),
      input('password', 'Password', 'password', 'Used to sign in and not kept.'),
      field('Country', h('select', { onchange: (e) => { form.country = e.target.value; } },
        EUFY_COUNTRIES.map(([code, name]) => h('option', { value: code, selected: form.country === code }, name))), { hint: 'The country your eufy account was made in.' }),
      h('div', { class: 'row' }, submit = h('button', { class: 'btn primary', type: 'submit', disabled: !!busy || !complete() },
        busy === 'signin' ? spinner() : icon('lock'), 'Sign in')));
  }

  function accountCard() {
    const status = state.status || {};
    return h('div', { class: 'card' },
      h('div', { class: 'plugin-head' }, h('h2', null, 'eufy account'), h('span', { class: 'pill live' }, status.account || 'Signed in')),
      h('p', { class: 'desc' }, 'Camera Bridge gets motion and people from eufy’s notifications, and wakes a camera only when its picture is wanted.'),
      status.pushProblem ? h('p', { class: 'problems' }, status.pushProblem) : null,
      h('div', { class: 'row' },
        h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: () => run('refresh', load) }, busy === 'refresh' ? spinner() : icon('refresh'), 'Refresh'),
        h('button', { class: 'btn ghost', type: 'button', disabled: !!busy, onclick: async () => {
          if (!(await confirmDialog({ title: 'Sign out of eufy?', body: 'eufy cameras you added stop showing video until you sign in again.', confirm: 'Sign out' }))) return;
          run('signout', async () => { await post('plugins/eufy/sign-out'); await load(); });
        } }, 'Sign out')));
  }

  function camerasCard() {
    const cameras = state.cameras || [];
    return h('div', { class: 'card wyze-cameras' },
      h('h2', null, 'Your eufy cameras'),
      cameras.length ? h('ul', { class: 'wyze-list' }, cameras.map((c) => h('li', { class: 'wyze-cam' },
        h('div', { class: 'wyze-cam-main' },
          h('strong', null, c.name),
          h('span', { class: 'small muted' }, [c.modelName, c.battery != null ? `battery ${c.battery}%${c.charging ? ', charging' : ''}` : null].filter(Boolean).join(' · ')),
          h('div', { class: 'row wyze-tags' }, h('span', { class: `pill ${c.online ? 'live' : 'offline'}` }, c.online ? 'Online' : 'Offline')),
          c.note ? h('p', { class: 'small' }, c.note) : null),
        c.cameraID
          ? h('a', { class: 'btn small', href: `#/camera/${c.cameraID}` }, 'In Camera Bridge', icon('chevron'))
          : h('button', { class: 'btn small primary', type: 'button', disabled: !c.canAdd, onclick: () => {
            try { sessionStorage.setItem('cb.add.eufy', c.serial); } catch { /* the page asks again */ }
            navigate('/add');
          } }, icon('plus'), 'Add'))))
        : h('p', { class: 'muted' }, 'Your eufy account has no cameras. If you use a second account, share the cameras with it in the eufy app.'));
  }

  function draw() {
    if (!state) { replace(root, problem ? inlineError(problem) : h('div', { class: 'checking' }, spinner())); return; }
    const signedIn = state.status?.state === 'signedIn';
    let content;
    if (!state.installed) content = h('div', { class: 'card' }, h('p', null, 'This copy of Camera Bridge OS doesn’t include the eufy helper.'));
    else if (!state.enabled && !signedIn) {
      content = h('div', { class: 'card' }, h('p', { class: 'desc' }, 'The eufy plugin is off.'),
        h('button', { class: 'btn primary', type: 'button', disabled: !!busy, onclick: () => run('enable', async () => {
          await patch('plugins/eufy', { enabled: true }); await new Promise((r) => setTimeout(r, 1500)); await load();
        }) }, busy === 'enable' ? spinner() : null, 'Turn on'));
    } else content = signedIn ? [accountCard(), camerasCard()] : signInCard();
    replace(root,
      problem ? inlineError(problem) : null,
      state.lastError && !problem ? inlineError(state.lastError) : null,
      h('div', { class: 'card-columns' }, content));
  }

  load();
  return {
    el: h('div', null,
      h('a', { class: 'breadcrumb', href: '#/plugins' }, icon('back'), 'Plugins'),
      h('div', { class: 'page-head' }, h('h1', null, 'eufy')),
      internetNotice('eufy'),
      root),
    destroy() { destroyed = true; },
  };
}
