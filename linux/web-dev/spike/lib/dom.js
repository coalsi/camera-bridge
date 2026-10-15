// Tiny DOM helpers. Everything is built with the DOM API (no innerHTML, no style attributes: the page runs under the daemon's CSP).
export function h(tag, props = {}, ...children) {
  const element = document.createElement(tag)
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue
    if (key === 'class') element.className = value
    else if (key.startsWith('on') && typeof value === 'function') element.addEventListener(key.slice(2), value)
    else if (value === true) element.setAttribute(key, '')
    else element.setAttribute(key, String(value))
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue
    element.append(child instanceof Node ? child : document.createTextNode(String(child)))
  }
  return element
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** Resolves with the event, rejects after timeoutMs. */
export function once(target, type, timeoutMs, message = `${type} did not fire within ${timeoutMs} ms`) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { target.removeEventListener(type, onEvent); reject(new Error(message)) }, timeoutMs)
    const onEvent = (event) => { clearTimeout(timer); resolve(event) }
    target.addEventListener(type, onEvent, { once: true })
  })
}

export function withTimeout(promise, ms, label) {
  let timer
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms} ms`)), ms) })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}
