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

  // 首页对话演示：读屏软件读原始列表，动画用一份复制品
  var source = document.getElementById('demo');
  if (!source || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  var items = Array.prototype.map.call(source.children, function (li) {
    return { ai: li.classList.contains('ai'), text: li.textContent };
  });
  var chat = source.cloneNode(false);
  chat.removeAttribute('id');
  chat.setAttribute('aria-hidden', 'true');
  source.classList.add('sr-only');
  source.parentNode.insertBefore(chat, source);
  var replay = document.getElementById('replay');
  var run = 0;

  function wait(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

  async function play() {
    var id = ++run;
    chat.innerHTML = '';
    replay.hidden = true;
    for (var n = 0; n < items.length; n++) {
      var item = items[n];
      var li = document.createElement('li');
      if (item.ai) {
        li.className = 'msg ai typing';
        li.innerHTML = '<span></span><span></span><span></span>';
        chat.appendChild(li);
        await wait(1100);
        if (id !== run) return;
        li.className = 'msg ai';
        for (var i = 1; i <= item.text.length; i++) {
          li.textContent = item.text.slice(0, i);
          await wait(28);
          if (id !== run) return;
        }
      } else {
        await wait(600);
        if (id !== run) return;
        li.className = 'msg me';
        li.textContent = item.text;
        chat.appendChild(li);
      }
      await wait(800);
      if (id !== run) return;
    }
    replay.hidden = false;
  }

  replay.addEventListener('click', play);
  play();
})();
