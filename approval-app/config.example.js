// Copy to config.js (never committed). Locally scripts/local-setup.mjs writes
// config.js; live it is written at deploy with the project URL and the
// publishable key. Never put a service or secret key here.
window.FAO_CONFIG = {supabaseUrl: 'https://<project-ref>.supabase.co', supabasePublicKey: '<publishable key>'};
