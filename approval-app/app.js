// FinAgent OS approval page (FAO-GOV-004 human decision, FAO-GOV-002 identity).
//
// The approver signs in with their own Supabase Auth session and calls
// fao_hitl_get and fao_hitl_decide through PostgREST with that session. The
// database takes identity only from the session, refuses self-approval and
// journals refusals; this page adds no authority of its own.
//
// Display rules: every DOM update uses textContent; the only messages shown
// are the fixed texts below, chosen by result code (never server error text);
// a journal reference id from `ref` is shown when present.
//
// The pure functions parseHitlId, statusMessage and buildViewModel are
// exported for the offline Node tests. The browser bootstrap runs only when
// window.document exists.

// Fixed messages per result code (shared contract, section 2.6).
export const CODE_MESSAGES = Object.freeze(
  Object.assign(Object.create(null), {
    OK: 'OK',
    NO_SESSION: 'Sign in to continue.',
    INVALID_INPUT: 'The request is not valid.',
    NOT_AN_OWNER: 'Your account is not an active process owner.',
    NOT_AUTHORISED: 'You are not authorised for this action.',
    SOD_SELF_APPROVAL: 'You cannot decide a run you started.',
    SELF_CHANGE: 'You cannot change your own access.',
    NOT_FOUND: 'Not found.',
    UNKNOWN_AGENT: 'The agent does not exist.',
    AGENT_NOT_ACTIVE: 'The agent is not active.',
    BUSY: 'Someone else is deciding this request. Try again.',
    NO_RUN_RECORD: 'This request has no run record.',
    ALREADY_CLAIMED: 'This run has already started.',
    ALREADY_DECIDED: 'This request has already been decided.',
    EXPIRED: 'This request has expired.',
    TOKEN_EXPIRED: 'The run token has expired.',
    INVALID_TOKEN: 'The run token is not valid.',
    RATE_LIMITED: 'Too many runs in the last hour.',
    AUDIT_CHAIN_MISMATCH:
      "Recorded, but the run's ledger chain is incomplete, so it was not committed.",
    UNKNOWN_EXECUTION: 'No run matches this execution.',
    ALREADY_TERMINAL: 'The run has already finished.',
    NOT_PENDING: 'Nothing to send.',
    ALREADY_SENT: 'Already sent.',
  }),
);

// Fallbacks when a response is not in the result envelope (section 2.6).
export const FALLBACK_MESSAGES = Object.freeze({
  401: 'Sign in to continue.',
  403: 'You are not authorised for this action.',
  404: 'Not found.',
  server: 'Something went wrong. Try again later.',
  other: 'The request could not be completed.',
});

// Page-own texts (not server text).
export const PAGE_TEXT = Object.freeze({
  loading: 'Loading.',
  review: 'Review this request, then approve or reject it.',
  viewOnly: 'You can view this request but not decide it.',
  signInFailed: 'Sign-in failed. Check your email and password.',
  decided: 'Decision recorded.',
  committedYes: 'Yes',
  committedNo: 'No',
  signedInAs: 'Signed in as ',
  referencePrefix: 'Reference id: ',
  deciding: 'Sending your decision.',
});

const HITL_ID_RE = /^\d{1,12}$/;

// Notes limit, counted like the database (length() in characters, that is
// Unicode code points), not in UTF-16 units (B3).
export const NOTES_MAX = 2000;

export function noteLength(text) {
  if (typeof text !== 'string') return 0;
  let n = 0;
  for (const _ of text) n += 1; // string iteration walks code points
  return n;
}

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

// Returns the hitl id as a canonical decimal string, or null when the query
// string does not carry exactly one hitl_id of 1 to 12 digits with a value of
// at least 1. Callers make no network call on null.
export function parseHitlId(search) {
  if (typeof search !== 'string') return null;
  let values;
  try {
    values = new URLSearchParams(search).getAll('hitl_id');
  } catch {
    return null;
  }
  if (values.length !== 1) return null;
  const raw = values[0];
  if (!HITL_ID_RE.test(raw)) return null;
  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n < 1) return null;
  return String(n);
}

// Fixed text for a result: the code's message when the code is known, else
// the fallback for the HTTP status.
export function statusMessage(status, code) {
  if (typeof code === 'string' && hasOwn(CODE_MESSAGES, code)) return CODE_MESSAGES[code];
  const s = typeof status === 'number' && Number.isInteger(status) ? status : 0;
  if (s === 401) return FALLBACK_MESSAGES[401];
  if (s === 403) return FALLBACK_MESSAGES[403];
  if (s === 404) return FALLBACK_MESSAGES[404];
  if (s === 0 || s >= 500) return FALLBACK_MESSAGES.server;
  return FALLBACK_MESSAGES.other;
}

export function isEnvelope(value) {
  return (
    value !== null &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    typeof value.ok === 'boolean' &&
    typeof value.code === 'string'
  );
}

function toText(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  try {
    return JSON.stringify(value);
  } catch {
    return '';
  }
}

function assetText(item) {
  if (item === null || typeof item !== 'object' || Array.isArray(item)) return toText(item);
  let text = toText(item.asset);
  const outcome = toText(item.policy_outcome);
  const sub = toText(item.policy_sub_tier);
  const band = toText(item.band_status);
  if (outcome) text += `: ${outcome}${sub ? `/${sub}` : ''}`;
  if (band) text += ` (${band})`;
  return text;
}

function field(label, value) {
  return { label, value: toText(value) };
}

// Rows with no value are left out, so a closed or expired request shows no
// empty "Decided at" row (B4).
function filled(fields) {
  return fields.filter((f) => f.value !== '');
}

// Results after which the approver may try the same decision again with the
// form and note kept (B2): a refused note (INVALID_INPUT), someone else
// deciding (BUSY), or a network or server failure.
const RETRY_CODES = Object.freeze(['BUSY', 'INVALID_INPUT']);

function referenceText(result) {
  const ref = result && result.ref;
  if (typeof ref === 'number' && Number.isSafeInteger(ref) && ref > 0) {
    return PAGE_TEXT.referencePrefix + String(ref);
  }
  if (typeof ref === 'string' && /^\d{1,19}$/.test(ref)) return PAGE_TEXT.referencePrefix + ref;
  return '';
}

function emptyModel() {
  return {
    kind: 'message',
    ok: false,
    code: '',
    message: '',
    reference: '',
    hitlId: '',
    title: '',
    fields: [],
    assets: [],
    note: '',
    canDecide: false,
    isInvoker: false,
    needsSignIn: false,
    retry: false,
  };
}

// Turns an RPC result envelope (fao_hitl_get or fao_hitl_decide) into a view
// model of plain strings. Anything that is not an envelope becomes a message
// model with the status fallback. Server values are copied unchanged as
// strings; the page renders them with textContent only.
export function buildViewModel(result) {
  const model = emptyModel();
  if (!isEnvelope(result)) {
    const status = result && typeof result.http_status === 'number' ? result.http_status : 0;
    model.message = statusMessage(status, null);
    model.needsSignIn = status === 401;
    model.retry = status === 0 || status >= 500;
    return model;
  }
  const code = result.code;
  model.ok = result.ok;
  model.code = hasOwn(CODE_MESSAGES, code) ? code : '';
  model.reference = referenceText(result);
  model.message = statusMessage(result.http_status, model.code || null);
  const request =
    result.request && typeof result.request === 'object' && !Array.isArray(result.request)
      ? result.request
      : null;

  if (result.ok && request) {
    model.kind = 'request';
    model.hitlId = toText(request.hitl_id);
    model.title = `Request ${model.hitlId}`;
    model.canDecide = request.viewer_can_decide === true;
    model.isInvoker = request.viewer_is_invoker === true;
    model.fields = filled([
      field('Request id', request.hitl_id),
      field('Agent', request.agent_name),
      field('Agent id', request.agent_id),
      field('Risk tier', request.risk_tier),
      field('Review sub-tier', request.sub_tier),
      field('Policy rationale', request.policy_rationale),
      field('Configured approvals', request.configured_approvals),
      field('Enforced approvals', request.enforced_approvals),
      field('Requested at', request.created_at),
      field('Decide by', request.timeout_at),
      field('Decision', request.decision),
      field('Decided at', request.decided_at),
      field('Started by', request.invoker_name),
    ]);
    const assets = Array.isArray(request.escalated_assets) ? request.escalated_assets : [];
    model.assets = assets.map(assetText);
    let note = '';
    if (model.isInvoker) {
      note = CODE_MESSAGES.SOD_SELF_APPROVAL;
    } else if (!model.canDecide) {
      note = PAGE_TEXT.viewOnly;
    }
    // The status line already carries this text; it is not repeated as a
    // note under the request (B4).
    model.message = model.canDecide ? PAGE_TEXT.review : note;
    return model;
  }

  if (result.ok && hasOwn(result, 'committed')) {
    model.kind = 'decided';
    model.hitlId = toText(result.hitl_id);
    model.title = `Request ${model.hitlId}`;
    model.message = code === 'OK' ? PAGE_TEXT.decided : statusMessage(result.http_status, model.code || null);
    model.fields = filled([
      field('Request id', result.hitl_id),
      field('Decision', result.decision),
      field('Decided at', result.decided_at),
      field('Committed', result.committed === true ? PAGE_TEXT.committedYes : PAGE_TEXT.committedNo),
      field('Committed ledger id', result.committed_ledger_id),
    ]);
    return model;
  }

  if (!result.ok && request && (code === 'ALREADY_DECIDED' || code === 'EXPIRED')) {
    model.kind = 'closed';
    model.hitlId = toText(request.hitl_id);
    model.title = `Request ${model.hitlId}`;
    model.fields = filled([
      field('Request id', request.hitl_id),
      field('Decision', request.decision),
      field('Decided at', request.decided_at),
    ]);
    return model;
  }

  model.needsSignIn = code === 'NO_SESSION';
  model.retry = RETRY_CODES.includes(model.code);
  return model;
}

// ---------------------------------------------------------------------------
// Browser bootstrap (runs only with a DOM)
// ---------------------------------------------------------------------------

function makeUi(doc) {
  const el = (id) => doc.getElementById(id);
  const show = (id, visible) => {
    const node = el(id);
    if (node) node.hidden = !visible;
  };
  const setText = (id, text) => {
    const node = el(id);
    if (node) node.textContent = text;
  };
  const fillFields = (id, fields) => {
    const list = el(id);
    if (!list) return;
    list.replaceChildren();
    for (const f of fields) {
      const dt = doc.createElement('dt');
      dt.textContent = f.label;
      const dd = doc.createElement('dd');
      dd.textContent = f.value;
      list.append(dt, dd);
    }
  };
  const fillList = (id, items) => {
    const list = el(id);
    if (!list) return;
    list.replaceChildren();
    for (const item of items) {
      const li = doc.createElement('li');
      li.textContent = item;
      list.append(li);
    }
  };
  return { el, show, setText, fillFields, fillList };
}

async function bootstrap(win) {
  const ui = makeUi(win.document);
  const sections = ['signin', 'request', 'decide', 'result'];
  const hideAll = () => sections.forEach((s) => ui.show(s, false));
  const message = (text, reference = '') => {
    ui.setText('status', text);
    ui.setText('reference', reference);
    ui.show('reference', reference !== '');
  };

  const hitlId = parseHitlId(win.location.search);
  if (hitlId === null) {
    // Invalid link: fixed message, no client and no RPC call.
    hideAll();
    message(CODE_MESSAGES.INVALID_INPUT);
    return;
  }

  const cfg = win.FAO_CONFIG;
  const lib = win.supabase;
  if (
    !cfg ||
    typeof cfg.supabaseUrl !== 'string' ||
    typeof cfg.supabasePublicKey !== 'string' ||
    !lib ||
    typeof lib.createClient !== 'function'
  ) {
    hideAll();
    message(FALLBACK_MESSAGES.server);
    return;
  }

  const client = lib.createClient(cfg.supabaseUrl, cfg.supabasePublicKey, {
    auth: {
      persistSession: true,
      storage: win.sessionStorage,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  });

  let busy = false;

  const setSignedIn = (session) => {
    const email = session && session.user && typeof session.user.email === 'string' ? session.user.email : '';
    ui.setText('signed-in', email ? PAGE_TEXT.signedInAs + email : '');
    ui.show('signed-in', email !== '');
    ui.show('signout', Boolean(session));
  };

  // Moves focus to the status line when the focused control was hidden or
  // disabled by a view change, so keyboard users keep their place (B5).
  const settleFocus = () => {
    const doc = win.document;
    const active = doc.activeElement;
    const lost =
      !active ||
      active === doc.body ||
      active.disabled === true ||
      (typeof active.closest === 'function' && active.closest('[hidden]') !== null);
    const status = ui.el('status');
    if (lost && status && typeof status.focus === 'function') status.focus();
  };

  // Clears everything the previous person typed or was shown: draft notes,
  // request fields, assets and result (B1). Runs on sign-out, whenever the
  // sign-in form is shown, and after each successful sign-in.
  const resetViews = () => {
    const notesEl = ui.el('decide-notes');
    if (notesEl) notesEl.value = '';
    ui.setText('request-title', 'Request');
    ui.fillFields('request-fields', []);
    ui.fillList('request-assets', []);
    ui.setText('request-note', '');
    ui.show('request-note', false);
    ui.fillFields('result-fields', []);
  };

  const showSignIn = (text) => {
    hideAll();
    resetViews();
    setSignedIn(null);
    message(text || CODE_MESSAGES.NO_SESSION);
    ui.show('signin', true);
    settleFocus();
  };

  const callRpc = async (name, args) => {
    let res;
    try {
      res = await client.rpc(name, args);
    } catch {
      return { http_status: 0 };
    }
    const body = res && res.data !== null && res.data !== undefined ? res.data : res && res.error;
    if (isEnvelope(body)) return body;
    return { http_status: res && typeof res.status === 'number' ? res.status : 0 };
  };

  const render = (model) => {
    hideAll();
    if (model.needsSignIn) {
      showSignIn(model.message);
      return;
    }
    message(model.message, model.reference);
    if (model.kind === 'request' || model.kind === 'closed') {
      ui.setText('request-title', model.title);
      ui.fillFields('request-fields', model.fields);
      ui.fillList('request-assets', model.assets);
      // No empty "Escalated assets" heading (B4).
      ui.show('request-assets-heading', model.assets.length > 0);
      ui.show('request-assets', model.assets.length > 0);
      ui.setText('request-note', model.note);
      ui.show('request-note', model.note !== '' && model.note !== model.message);
      ui.show('request', true);
    }
    if (model.kind === 'request' && model.canDecide) {
      ui.show('decide', true);
    } else {
      // The decision form is gone for good on this view: drop any draft.
      const notesEl = ui.el('decide-notes');
      if (notesEl) notesEl.value = '';
    }
    if (model.kind === 'decided') {
      ui.fillFields('result-fields', model.fields);
      ui.show('result', true);
    }
    settleFocus();
  };

  const loadRequest = async () => {
    message(PAGE_TEXT.loading);
    const result = await callRpc('fao_hitl_get', { p_hitl_id: hitlId });
    render(buildViewModel(result));
  };

  const setButtons = (enabled) => {
    for (const id of ['approve', 'reject']) {
      const b = ui.el(id);
      if (b) b.disabled = !enabled;
    }
  };

  const decide = async (decision) => {
    if (busy) return;
    busy = true;
    setButtons(false);
    try {
      const notesEl = ui.el('decide-notes');
      const notes = notesEl ? notesEl.value : '';
      if (noteLength(notes) > NOTES_MAX) {
        message(CODE_MESSAGES.INVALID_INPUT);
        return;
      }
      message(PAGE_TEXT.deciding);
      const result = await callRpc('fao_hitl_decide', {
        p_hitl_id: hitlId,
        p_decision: decision,
        p_notes: notes === '' ? null : notes,
      });
      const model = buildViewModel(result);
      if (model.retry) {
        // BUSY, INVALID_INPUT or a network or server failure: keep the form
        // and the typed note so the approver can fix it or try again (B2).
        message(model.message, model.reference);
        return;
      }
      render(model);
    } finally {
      busy = false;
      setButtons(true);
      settleFocus();
    }
  };

  ui.el('signin-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy) return;
    busy = true;
    const emailEl = ui.el('signin-email');
    const passwordEl = ui.el('signin-password');
    const email = emailEl.value.trim();
    const password = passwordEl.value;
    passwordEl.value = '';
    try {
      if (!email || !password) {
        message(PAGE_TEXT.signInFailed);
        return;
      }
      let outcome;
      try {
        outcome = await client.auth.signInWithPassword({ email, password });
      } catch {
        outcome = { error: true };
      }
      if (!outcome || outcome.error || !outcome.data || !outcome.data.session) {
        message(PAGE_TEXT.signInFailed);
        return;
      }
      resetViews();
      setSignedIn(outcome.data.session);
      await loadRequest();
    } finally {
      busy = false;
    }
  });

  ui.el('decide-form').addEventListener('submit', (event) => event.preventDefault());
  ui.el('approve').addEventListener('click', () => decide('APPROVED'));
  ui.el('reject').addEventListener('click', () => decide('REJECTED'));
  ui.el('signout').addEventListener('click', async () => {
    try {
      await client.auth.signOut();
    } catch {
      // The local session is cleared either way.
    }
    // The next person starts from an empty form (B1).
    const emailEl = ui.el('signin-email');
    if (emailEl) emailEl.value = '';
    showSignIn(CODE_MESSAGES.NO_SESSION);
  });

  let session = null;
  try {
    const { data } = await client.auth.getSession();
    session = data && data.session ? data.session : null;
  } catch {
    session = null;
  }
  if (!session) {
    showSignIn(CODE_MESSAGES.NO_SESSION);
    return;
  }
  setSignedIn(session);
  await loadRequest();
}

if (typeof window !== 'undefined' && window.document) {
  bootstrap(window);
}
