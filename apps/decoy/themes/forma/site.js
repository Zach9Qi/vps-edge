(function () {
  var host = location.hostname.replace(/^www\./, '');
  document.querySelectorAll('[data-mail]').forEach(function (el) {
    var address = el.getAttribute('data-mail') + '@' + host;
    el.href = 'mailto:' + address;
    if (el.hasAttribute('data-show')) el.textContent = address;
  });
  document.querySelectorAll('[data-year]').forEach(function (el) {
    el.textContent = new Date().getFullYear();
  });
})();
