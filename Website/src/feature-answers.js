// Lookup vocabulary lives beside the reviewed copy. Unknown qualifiers must not
// become a positive answer for some other network or signing method.
const variants = new Map(Object.entries({approvals:'approval', allowances:'allowance', dapps:'dapp', revoking:'revoke'}));

function terms(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim().split(/\s+/)
    .filter(word => word && !/^(a|an|the|can|does|do|i|my|me|how|on|to|for|with|in|use|using|oath|support|supports|is|are)$/.test(word))
    .map(word => variants.get(word) || word)
    .sort().join(' ');
}

export function featureAnswers(catalog) {
  const guides = catalog.features.map(f => ({
    id: f.slug, name: f.name, summary: f.description,
    url: 'https://oathwallet.org' + f.path, guide: 'https://help.oathwallet.org/articles/' + f.guide,
    app_version: catalog.version, build: catalog.build, reviewed_on: catalog.reviewed,
    legacyIds: f.legacyIds, lookupTerms: f.lookupTerms, scope: f.scope.map(({label, detail, lookupTerms}) => ({label, detail, lookupTerms})),
    limitations: f.scopeIntro, steps: f.steps.map(s => s.text), questions: f.questions
  }));
  return [...guides, ...catalog.otherFeatures];
}

export function findFeature(features, query) {
  const key = terms(query);
  if (!key) return null;
  for (const f of features) {
    if (query.toLowerCase().trim() === f.id) return f;
    const legacy = f.legacyIds?.find(id => id === query.toLowerCase().trim());
    if (legacy) return {...f, id: legacy, canonical_id: f.id};
    const question = f.questions?.find(q => terms(q.q) === key);
    if (question) return {...f, answer: question.a};
    const names = [f.id, f.name, ...(f.lookupTerms || []), ...(f.legacyIds || [])];
    for (const scope of f.scope || []) {
      for (const qualifier of scope.lookupTerms) {
        if (names.some(name => terms(name + ' ' + qualifier) === key)) {
          return {...f, answer: scope.detail, matched_scope: scope.label};
        }
      }
    }
    if (names.some(name => terms(name) === key)) return f;
  }
  return null;
}
