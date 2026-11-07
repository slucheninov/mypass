// Options page entry. Normalises the hash and shows the pane for the route.
// The settings pane content is filled in by a later task.

(function () {
  var router = window.mypassRouter;

  function render() {
    var route = router.parseRoute(location.hash);
    var settings = document.getElementById('page-settings');
    var notFound = document.getElementById('page-not-found');
    if (settings) settings.hidden = route.name !== 'settings';
    if (notFound) notFound.hidden = route.name !== 'notFound';
  }

  var canonical = router.canonicalHash(location.hash);
  if (canonical !== location.hash) {
    history.replaceState(null, '', canonical);
  }
  window.addEventListener('hashchange', render);
  render();
})();
