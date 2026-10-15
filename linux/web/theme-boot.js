// Applies the appearance chosen on this browser before the page is drawn, so it never flashes the other theme. Dark is the default (nothing
// stored); Light and Auto (follow the device) are choices. A plain script, not a module, so it runs before the first paint; js/theme.js
// changes the choice later.
(function () {
  var theme = 'dark';
  try {
    var stored = localStorage.getItem('cb-theme');
    if (stored === 'light' || stored === 'auto') theme = stored;
  } catch (error) {
    // Storage blocked (a private window, cleared site data): the default.
  }
  if (theme === 'auto') return;
  document.documentElement.setAttribute('data-theme', theme);
  var metas = document.querySelectorAll('meta[name="theme-color"]');
  for (var i = 0; i < metas.length; i++) metas[i].setAttribute('content', theme === 'light' ? '#f6f4ef' : '#151517');
})();
