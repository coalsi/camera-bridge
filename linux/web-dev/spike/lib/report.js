import { stats } from './pure.js'

/** What one case reports: checks decide pass or fail; metrics and notes are evidence. */
export class Report {
  constructor(id, title) {
    this.id = id
    this.title = title
    this.checks = []
    this.metrics = {}
    this.notes = []
    this.skipReason = null
    this.error = null
    this.startedAt = performance.now()
  }

  check(name, ok, detail = '') {
    this.checks.push({ name, ok: Boolean(ok), detail: String(detail) })
    return Boolean(ok)
  }

  metric(key, value) { this.metrics[key] = value }
  note(text) { this.notes.push(String(text)) }
  skip(reason) { this.skipReason = reason }
  stats(key, values) { this.metrics[key] = stats(values) }

  toJSON() {
    let verdict
    if (this.skipReason) verdict = 'skip'
    else if (this.error) verdict = 'fail'
    else if (this.checks.length === 0) verdict = 'info'
    else verdict = this.checks.every((c) => c.ok) ? 'pass' : 'fail'
    return {
      id: this.id, title: this.title, verdict, ms: Math.round(performance.now() - this.startedAt),
      checks: this.checks, metrics: this.metrics, notes: this.notes,
      ...(this.skipReason ? { skipReason: this.skipReason } : {}), ...(this.error ? { error: this.error } : {}),
    }
  }
}
