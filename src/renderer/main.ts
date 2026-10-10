// Phase 2 replaces this with the adapted dashboard. For now it proves the preload bridge works.
declare global {
  interface Window {
    soundbites: { version: () => Promise<string> }
  }
}

const app = document.getElementById('app')
if (app) {
  window.soundbites
    .version()
    .then((v) => {
      app.textContent = `Soundbites ${v}`
    })
    .catch(() => {
      app.textContent = 'Soundbites could not reach its engine.'
    })
}
export {}
