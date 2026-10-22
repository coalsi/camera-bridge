// The notification log on the dev server, as the bridge keeps it (BridgeWeb/NotificationLog.swift; routes: WebApp+Notifications.swift): an entry
// when a notice first appears or changes, an event (the Internet guard's) once ever, a once-only claim for the page's toast, a read marker.
// Kept in memory; /__dev/reset starts it empty.

const EVENT_KINDS = new Set(['internetGuard']);
const CATEGORIES = { internetGuard: 'security', nvrStorage: 'recording', liveViewNotReceived: 'cameras' };

/** Where the notification page files a notice: security, recording, cameras or system. */
export const categoryOf = (kind) => CATEGORIES[kind] ?? 'system';

/** What a notice says, as the key one happening is told from another by (other figures in the text are not another happening). */
export const keyOf = (notice) => `${notice.id}|${notice.title}|${notice.cameraID ?? ''}`;

export class NotificationLog {
  constructor({ maximumEntries = 500, maximumAgeMs = 90 * 86_400_000 } = {}) {
    this.maximumEntries = maximumEntries;
    this.maximumAgeMs = maximumAgeMs;
    this.list = [];      // newest first
    this.active = new Map();
    this.events = new Set();
    this.serial = 0;
  }

  record(notices, nowMs) {
    for (const notice of notices) {
      const key = keyOf(notice);
      const event = EVENT_KINDS.has(notice.kind);
      if (event ? this.events.has(key) : this.active.get(notice.id) === key) continue;
      if (event) this.events.add(key); else this.active.set(notice.id, key);
      this.list.unshift({
        id: `n-${++this.serial}`, key, noticeID: notice.id, kind: notice.kind, category: categoryOf(notice.kind), severity: notice.severity, title: notice.title,
        detail: notice.detail, cameraID: notice.cameraID ?? null, cameraName: notice.cameraName ?? null, action: notice.action ?? null,
        date: new Date(Math.floor(nowMs / 1000) * 1000).toISOString().replace('.000Z', 'Z'), read: false, toasted: false,
      });
    }
    const current = new Set(notices.map((notice) => notice.id));
    for (const id of [...this.active.keys()]) if (!current.has(id)) this.active.delete(id);
    this.list = this.list.filter((entry) => nowMs - Date.parse(entry.date) <= this.maximumAgeMs).slice(0, this.maximumEntries);
  }

  get unread() { return this.list.filter((entry) => !entry.read).length; }

  /** The entries of `notices` not shown as a toast yet, marked shown. */
  claim(notices) {
    const keys = new Set(notices.map(keyOf));
    const claimed = this.list.filter((entry) => !entry.toasted && keys.has(entry.key));
    for (const entry of claimed) entry.toasted = true;
    return claimed;
  }

  markRead(ids) {
    const wanted = Array.isArray(ids) ? new Set(ids) : null;
    for (const entry of this.list) if (!wanted || wanted.has(entry.id)) entry.read = true;
  }
}
