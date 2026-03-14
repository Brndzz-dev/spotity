/*
    Seven Music - NUI JavaScript
    Handles UI navigation, rendering, NUI callbacks and local state/history fallback.
*/

const app = document.getElementById('app');
const views = document.querySelectorAll('.view');
const navButtons = document.querySelectorAll('.nav-btn');
const searchInput = document.getElementById('searchInput');
const searchResults = document.getElementById('searchResults');
const recentSongs = document.getElementById('recentSongs');
const likedSongs = document.getElementById('likedSongs');
const librarySongs = document.getElementById('librarySongs');
const nowPlaying = document.getElementById('nowPlaying');
const toast = document.getElementById('toast');

let state = {
  isPlaying: false,
  search: [],
  recent: JSON.parse(localStorage.getItem('sevenmusic_recent') || '[]'),
  liked: JSON.parse(localStorage.getItem('sevenmusic_liked') || '[]'),
  track: null
};

function nui(name, payload = {}) {
  return fetch(`https://${GetParentResourceName()}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  }).catch(() => null);
}

function formatDuration(ms = 0) {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = String(totalSeconds % 60).padStart(2, '0');
  return `${minutes}:${seconds}`;
}

function persistLocal() {
  localStorage.setItem('sevenmusic_recent', JSON.stringify(state.recent.slice(0, 30)));
  localStorage.setItem('sevenmusic_liked', JSON.stringify(state.liked.slice(0, 100)));
}

function showToast(message, level = 'info') {
  toast.textContent = message;
  toast.className = `toast show ${level === 'error' ? 'error' : ''}`;
  setTimeout(() => (toast.className = 'toast'), 2000);
}

function createSongItem(track, options = {}) {
  const item = document.createElement('div');
  item.className = 'song-item';

  const liked = state.liked.some((s) => s.id === track.id);

  item.innerHTML = `
    <img src="${track.cover || 'https://via.placeholder.com/64?text=%E2%99%AA'}" alt="cover"/>
    <div class="meta">
      <div class="title">${track.title || 'Sem título'}</div>
      <div class="artist">${track.artist || 'Desconhecido'}</div>
      <div class="duration">${formatDuration(track.duration || 0)}</div>
    </div>
    <div class="song-actions">
      <button class="play-btn">Play</button>
      <button class="like-btn">${liked ? '♥' : '+'}</button>
    </div>
  `;

  item.querySelector('.play-btn').addEventListener('click', () => {
    state.track = track;
    nowPlaying.textContent = `Tocando: ${track.title} - ${track.artist}`;

    state.recent = [track, ...state.recent.filter((s) => s.id !== track.id)].slice(0, 30);
    persistLocal();
    renderLists();

    nui('playTrack', { track });
  });

  item.querySelector('.like-btn').addEventListener('click', () => {
    const exists = state.liked.some((s) => s.id === track.id);
    if (exists) {
      state.liked = state.liked.filter((s) => s.id !== track.id);
      nui('unlikeTrack', { trackId: track.id });
    } else {
      state.liked = [track, ...state.liked].slice(0, 100);
      nui('likeTrack', { track });
    }
    persistLocal();
    renderLists();
  });

  return item;
}

function renderSongList(target, songs) {
  target.innerHTML = '';
  if (!songs.length) {
    target.innerHTML = '<div class="artist">Nenhuma música.</div>';
    return;
  }
  songs.forEach((song) => target.appendChild(createSongItem(song)));
}

function renderLists() {
  renderSongList(searchResults, state.search);
  renderSongList(recentSongs, state.recent);
  renderSongList(likedSongs, state.liked);
  renderSongList(librarySongs, [...state.recent]);
}

navButtons.forEach((btn) => {
  btn.addEventListener('click', () => {
    navButtons.forEach((b) => b.classList.remove('active'));
    views.forEach((v) => v.classList.remove('active'));

    btn.classList.add('active');
    document.getElementById(btn.dataset.view).classList.add('active');
  });
});

let searchDebounce = null;
searchInput.addEventListener('input', () => {
  clearTimeout(searchDebounce);
  const query = searchInput.value.trim();
  searchDebounce = setTimeout(() => nui('search', { query }), 280);
});

document.getElementById('closeBtn').addEventListener('click', () => nui('close'));
document.getElementById('stopBtn').addEventListener('click', () => {
  nui('stopTrack');
  nowPlaying.textContent = 'Nenhuma música tocando.';
});
document.getElementById('refreshBtn').addEventListener('click', () => nui('refreshLibrary'));

window.addEventListener('message', (event) => {
  const data = event.data;

  if (data.action === 'toggle') {
    app.classList.toggle('hidden', !data.show);
  }

  if (data.action === 'searchResult') {
    if (!data.ok) {
      showToast(data.error || 'Erro na busca', 'error');
      return;
    }
    state.search = data.items || [];
    renderLists();
  }

  if (data.action === 'libraryData') {
    const recent = data.data?.recent || [];
    const liked = data.data?.liked || [];
    if (recent.length) state.recent = recent;
    if (liked.length) state.liked = liked;
    persistLocal();
    renderLists();
  }

  if (data.action === 'playingState') {
    state.isPlaying = !!data.isPlaying;
    if (!data.isPlaying) {
      nowPlaying.textContent = 'Nenhuma música tocando.';
    } else if (data.track) {
      nowPlaying.textContent = `Tocando: ${data.track.title} - ${data.track.artist}`;
    }
  }

  if (data.action === 'notify') {
    showToast(data.message || 'Mensagem', data.level === 'error' ? 'error' : 'info');
  }
});

renderLists();
