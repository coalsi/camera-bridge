import c01 from './c01.js'
import c02 from './c02.js'
import c03 from './c03.js'
import c04 from './c04.js'
import c05 from './c05.js'
import c06 from './c06.js'
import c07 from './c07.js'
import c08 from './c08.js'
import c09 from './c09.js'
import c10 from './c10.js'
import c11 from './c11.js'
import c12 from './c12.js'
import x0 from './x0.js'

// The twelve L12 cases in order, then x0, which runs only on /?csp=old.
// Each case: { id, title, needs: [fixture ids], run(ctx, report) }.
export const CASES = new URLSearchParams(location.search).get('csp') === 'old'
  ? [x0]
  : [c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11, c12]
