const gallery = document.querySelector('.gallery');
if (typeof gallery.showModal === 'function') {
  const views = Array.from(document.querySelectorAll('[data-view]'));
  const crop = gallery.querySelector('.gallery-crop');
  const photo = gallery.querySelector('.gallery-photo');
  const caption = gallery.querySelector('.gallery-caption');
  const zoom = gallery.querySelector('#zoom');
  let currentIndex = 0;

  function setZoom(active) {
    crop.classList.toggle('enlarged', active);
    zoom.setAttribute('aria-pressed', String(active));
    zoom.textContent = active ? '还原' : '放大';
  }

  function showView(index) {
    currentIndex = (index + views.length) % views.length;
    const view = views[currentIndex];
    const source = view.querySelector('img');
    crop.className = 'gallery-crop ' + view.dataset.view;
    photo.src = source.src;
    photo.alt = source.alt;
    caption.textContent = (currentIndex + 1) + ' / ' + views.length + '　' + view.dataset.name;
    setZoom(false);
  }

  document.querySelectorAll('[data-open-view]').forEach(button => {
    button.hidden = false;
    button.addEventListener('click', () => {
      showView(views.findIndex(view => view.dataset.view === button.dataset.openView));
      gallery.showModal();
    });
  });
  zoom.addEventListener('click', () => setZoom(!crop.classList.contains('enlarged')));
  gallery.querySelector('#previous').addEventListener('click', () => showView(currentIndex - 1));
  gallery.querySelector('#next').addEventListener('click', () => showView(currentIndex + 1));
  gallery.addEventListener('keydown', event => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    event.preventDefault();
    showView(currentIndex + (event.key === 'ArrowRight' ? 1 : -1));
  });
}
