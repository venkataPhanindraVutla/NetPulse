// Client-side behaviour for the NetPulse site: a live demo panel, the scroll zoom into the laptop, the network
// switcher, and scroll-triggered counters. All numbers are simulated sample data.

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

type App = { name: string; color: string; down: number; up: number; other?: boolean };

const GB = 1e9;
const MB = 1e6;

function bytes(n: number): string {
	const units = ['B', 'KB', 'MB', 'GB', 'TB'];
	let v = Math.max(0, n);
	let i = 0;
	while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
	if (i === 0) return `${Math.round(v)} B`;
	const text = v >= 99.95 ? v.toFixed(0) : v >= 9.995 ? v.toFixed(1) : v.toFixed(2);
	return `${text} ${units[i]}`;
}
const rate = (n: number) => `${bytes(n)}/s`;
const compact = (n: number) => bytes(n).replace(/ ?([KMGT])?B$/, '$1').replace(' ', '');

const baseApps: App[] = [
	{ name: 'Safari', color: '#1e90ff', down: 1.71 * GB, up: 0.13 * GB },
	{ name: 'Zoom', color: '#2d8cff', down: 0.31 * GB, up: 0.31 * GB },
	{ name: 'Software Update', color: '#8e8e93', down: 0.402 * GB, up: 0 },
	{ name: 'Slack', color: '#611f69', down: 0.141 * GB, up: 0.009 * GB },
	{ name: 'Spotify', color: '#1db954', down: 0.118 * GB, up: 0.004 * GB },
	{ name: 'Dropbox', color: '#0061ff', down: 0.022 * GB, up: 0.088 * GB },
	{ name: 'Other / system', color: '#c7c7cc', down: 0.18 * GB, up: 0.018 * GB, other: true },
];

const initials = (name: string) => name.split(/\s+/).map((w) => w[0]).join('').slice(0, 2);

function appRows(apps: App[], withBars: boolean): string {
	const ranked = [...apps.filter((a) => !a.other).sort((a, b) => b.down + b.up - (a.down + a.up)), ...apps.filter((a) => a.other)];
	const peak = Math.max(...ranked.map((a) => a.down + a.up), 1);
	return ranked.map((a) => {
		const total = a.down + a.up;
		const share = total > 0 ? (a.down / total) * 100 : 0;
		const bar = withBars ? `<div class="bars" style="width:${Math.max((total / peak) * 100, 2)}%"><i style="flex:${share}"></i><i style="flex:${100 - share}"></i></div>` : '';
		const value = withBars ? `↓${bytes(a.down)} ↑${bytes(a.up)}` : bytes(total);
		return `<div class="row${a.other ? ' other' : ''}"><span class="p-ic" style="background:${a.color}">${a.other ? '⚙︎' : initials(a.name)}</span><div class="n">${a.name}${bar}</div><span class="v">${value}</span></div>`;
	}).join('');
}

/** One live panel: tabs, ticking speed with a sparkline, growing totals. */
function setupPanel(root: HTMLElement) {
	const q = <T extends Element>(sel: string) => root.querySelector<T>(sel)!;
	const bind = (name: string) => root.querySelector<HTMLElement>(`[data-bind="${name}"]`)!;
	const tabs = [...root.querySelectorAll<HTMLButtonElement>('.p-seg:not(.p-seg-small) button')];
	const thumb = q<HTMLElement>('.p-seg-thumb');
	const views = [...root.querySelectorAll<HTMLElement>('[data-view]')];

	function select(tab: string) {
		tabs.forEach((b, i) => {
			const on = b.dataset.tab === tab;
			b.setAttribute('aria-selected', String(on));
			if (on) thumb.style.transform = `translateX(${i * 100}%)`;
		});
		views.forEach((v) => (v.hidden = v.dataset.view !== tab));
		if (tab === 'history') growChart();
	}
	tabs.forEach((b) => b.addEventListener('click', () => select(b.dataset.tab!)));
	root.querySelector('[data-goto="apps"]')?.addEventListener('click', () => select('apps'));

	// History chart with hover read-out.
	const chart = bind('chart');
	const days = Array.from({ length: 31 }, (_, i) => (i === 30 ? 2.9 : 1.2 + Math.abs(Math.sin(i * 1.7)) * 2.6 + (i % 7 === 5 ? 1.4 : 0)));
	const maxDay = Math.max(...days);
	days.forEach((d, i) => {
		const bar = document.createElement('i');
		bar.style.height = `${(d / maxDay) * 100}%`;
		if (i === 30) bar.className = 'today';
		bar.addEventListener('mouseenter', () => (bind('chartTip').textContent = `Oct ${i + 1} · ${d.toFixed(2)} GB`));
		chart.appendChild(bar);
	});
	chart.addEventListener('mouseleave', () => (bind('chartTip').textContent = 'hover a day'));
	function growChart() {
		if (reduceMotion) return;
		[...chart.querySelectorAll('i')].forEach((b, i) => {
			b.animate([{ transform: 'scaleY(0)' }, { transform: 'scaleY(1)' }], { duration: 600, delay: i * 14, easing: 'cubic-bezier(.3,1.1,.4,1)', fill: 'backwards' });
		});
	}

	const apps = baseApps.map((a) => ({ ...a }));
	let todayDown = 3.41 * GB;
	let todayUp = 0.432 * GB;
	let down = 6.2 * MB;
	let up = 0.9 * MB;
	const history: [number, number][] = Array.from({ length: 48 }, () => [down, up]);

	function tick() {
		// A wandering download rate with occasional bursts; upload loosely follows.
		const burst = Math.random() < 0.08 ? 6 * MB : 0;
		down = Math.min(14 * MB, Math.max(0.4 * MB, down * (0.82 + Math.random() * 0.36) + burst * Math.random()));
		up = Math.min(3 * MB, Math.max(0.05 * MB, up * (0.8 + Math.random() * 0.4) + (Math.random() < 0.1 ? 0.8 * MB : 0)));
		history.push([down, up]);
		history.shift();
		todayDown += down;
		todayUp += up;
		apps[0].down += down * 0.6;
		apps[1].down += down * 0.15;
		apps[1].up += up * 0.5;
		apps[3].down += down * 0.08;
		apps[6].down += down * 0.17;
		apps[6].up += up * 0.5;
		render();
	}

	function spark() {
		const max = Math.max(...history.map(([d]) => d), 1);
		const step = 280 / (history.length - 1);
		const pts = (i: 0 | 1) => history.map((h, x) => `${(x * step).toFixed(1)},${(38 - (h[i] / max) * 34).toFixed(1)}`).join(' ');
		const downPts = pts(0);
		q<SVGPolylineElement>('.line-down').setAttribute('points', downPts);
		q<SVGPolylineElement>('.line-up').setAttribute('points', pts(1));
		q<SVGPathElement>('.area').setAttribute('d', `M0,40 L${downPts.replace(/ /g, ' L')} L280,40 Z`);
	}

	function render() {
		bind('down').textContent = rate(down);
		bind('up').textContent = rate(up);
		bind('todayDown').textContent = bytes(todayDown);
		bind('todayUp').textContent = bytes(todayUp);
		bind('top').innerHTML = appRows(apps.filter((a) => !a.other).sort((a, b) => b.down + b.up - (a.down + a.up)).slice(0, 3), false);
		bind('apps').innerHTML = appRows(apps, true);
		bind('appsTotal').textContent = `${bytes(apps.reduce((s, a) => s + a.down + a.up, 0))} total`;
		spark();
		labelListeners.forEach((fn) => fn(down, up));
	}

	render();
	const timer = window.setInterval(tick, 1000);
	return { select, stop: () => window.clearInterval(timer) };
}

const labelListeners: ((down: number, up: number) => void)[] = [];

/** Scroll-driven zoom from the whole desk photo into the panel, with captions that switch the panel's tab. */
function setupZoom(section: HTMLElement, panel: ReturnType<typeof setupPanel>) {
	const scene = section.querySelector<HTMLElement>('.scene')!;
	const label = section.querySelector<HTMLElement>('.mb-label')!;
	const captions = [...section.querySelectorAll<HTMLElement>('.cap')];
	const hint = section.querySelector<HTMLElement>('.scroll-hint');
	const W = 3200, H = 1906;
	const panelEl = scene.querySelector<HTMLElement>('.panel')!;
	labelListeners.push((d, u) => (label.innerHTML = `<span>↑ ${compact(u)}</span><span>↓ ${compact(d)}</span>`));

	const ease = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
	let lastTab = '';
	let tallest = 0;

	function frame() {
		const vw = window.innerWidth;
		const vh = section.querySelector<HTMLElement>('.sticky')!.clientHeight;
		const mobile = vw < 820;
		const rect = section.getBoundingClientRect();
		const total = section.offsetHeight - vh;
		const p = reduceMotion ? 0 : Math.min(1, Math.max(0, -rect.top / Math.max(total, 1)));
		const z = ease(Math.min(1, p / 0.45));

		const s0 = Math.max(vw / W, vh / H);
		const panelW = panelEl.offsetWidth * 0.96;
		// Centre on the tallest tab seen so far, so switching tabs doesn't make the scene jump.
		tallest = Math.max(tallest, panelEl.offsetHeight);
		const panelH = tallest * 0.96;
		if (!vw || !vh || !panelW || !panelH) { requestAnimationFrame(frame); return; }
		const cx = 1715 + panelW / 2;
		const cy = 446 + panelH / 2;
		const s1 = mobile ? Math.min((vh * 0.62) / panelH, (vw * 0.84) / panelW) : Math.min((vh * 0.8) / panelH, (vw * 0.42) / panelW);
		const s = s0 * Math.pow(s1 / s0, z);
		const start = { x: (vw - W * s0) / 2 + cx * s0, y: (vh - H * s0) / 2 + cy * s0 };
		const end = { x: mobile ? vw / 2 : vw * 0.66, y: mobile ? vh * 0.4 : vh / 2 };
		const px = start.x + (end.x - start.x) * z;
		const py = start.y + (end.y - start.y) * z;
		scene.style.transform = `translate3d(${px - cx * s}px, ${py - cy * s}px, 0) scale(${s})`;

		if (hint) hint.style.opacity = String(1 - Math.min(1, p / 0.08));
		const stage = p < 0.5 ? -1 : p < 0.66 ? 0 : p < 0.83 ? 1 : 2;
		captions.forEach((c, i) => c.classList.toggle('on', i === stage));
		const tab = ['now', 'now', 'apps', 'history'][stage + 1];
		if (!reduceMotion && tab !== lastTab) { lastTab = tab; panel.select(tab); }
	}

	let queued = false;
	const request = () => { if (!queued) { queued = true; requestAnimationFrame(() => { queued = false; frame(); }); } };
	window.addEventListener('scroll', request, { passive: true });
	window.addEventListener('resize', request);
	window.addEventListener('load', request);
	frame();
}

/** Network switcher: usage, cap and app ranking change with the selected network; rows slide to new positions. */
function setupNetworks(root: HTMLElement) {
	const nets = {
		home: { label: 'Home Wi-Fi', used: 64.2, cap: 100, left: 4, apps: [['Safari', '#1e90ff', 21.4], ['Zoom', '#2d8cff', 9.8], ['Spotify', '#1db954', 6.1], ['Software Update', '#8e8e93', 4.0], ['Slack', '#611f69', 2.2]] },
		hotspot: { label: 'iPhone hotspot', used: 8.3, cap: 10, left: 4, apps: [['Zoom', '#2d8cff', 3.9], ['Slack', '#611f69', 1.6], ['Safari', '#1e90ff', 1.4], ['Spotify', '#1db954', 0.6], ['Software Update', '#8e8e93', 0.1]] },
		office: { label: 'Office Ethernet', used: 41.7, cap: 0, left: 0, apps: [['Software Update', '#8e8e93', 12.8], ['Safari', '#1e90ff', 11.2], ['Slack', '#611f69', 7.3], ['Zoom', '#2d8cff', 5.9], ['Spotify', '#1db954', 1.2]] },
	} as const;
	type Key = keyof typeof nets;
	const buttons = [...root.querySelectorAll<HTMLButtonElement>('[data-net]')];
	const thumb = root.querySelector<HTMLElement>('.net-thumb')!;
	const list = root.querySelector<HTMLElement>('.net-apps')!;
	const usedEl = root.querySelector<HTMLElement>('[data-net-used]')!;
	const capEl = root.querySelector<HTMLElement>('[data-net-cap]')!;
	const barEl = root.querySelector<HTMLElement>('[data-net-bar]')!;
	const noteEl = root.querySelector<HTMLElement>('[data-net-note]')!;
	const titleEl = root.querySelector<HTMLElement>('[data-net-title]')!;
	let shown = 0;

	// Build one row per app once; switching only moves and resizes them.
	const names = ['Safari', 'Zoom', 'Spotify', 'Software Update', 'Slack'];
	const rows = new Map<string, HTMLElement>();
	for (const name of names) {
		const row = document.createElement('div');
		row.className = 'net-row';
		const color = nets.home.apps.find((a) => a[0] === name)![1];
		row.innerHTML = `<span class="p-ic" style="background:${color}">${initials(name)}</span><span class="nm">${name}</span><span class="track"><i></i></span><span class="val"></span>`;
		list.appendChild(row);
		rows.set(name, row);
	}
	const ROW = 46;

	function count(el: HTMLElement, from: number, to: number, fmt: (n: number) => string) {
		if (reduceMotion) { el.textContent = fmt(to); return; }
		const t0 = performance.now();
		const step = (t: number) => {
			const k = Math.min(1, (t - t0) / 700);
			const e = 1 - Math.pow(1 - k, 3);
			el.textContent = fmt(from + (to - from) * e);
			if (k < 1) requestAnimationFrame(step);
		};
		requestAnimationFrame(step);
	}

	function select(key: Key, i: number) {
		const n = nets[key];
		buttons.forEach((b) => b.setAttribute('aria-selected', String(b.dataset.net === key)));
		thumb.style.transform = `translateX(${i * 100}%)`;
		titleEl.textContent = n.label;
		count(usedEl, shown, n.used, (v) => `${v.toFixed(1)} GB`);
		shown = n.used;
		const pct = n.cap ? Math.min(100, (n.used / n.cap) * 100) : 0;
		barEl.style.width = n.cap ? `${pct}%` : '0%';
		barEl.style.background = pct >= 100 ? '#ff453a' : pct >= 80 ? '#ff9f0a' : '#0a84ff';
		capEl.textContent = n.cap ? `of ${n.cap} GB this month` : 'no cap set';
		noteEl.textContent = n.cap ? (pct >= 80 ? `${Math.round(pct)}% used · alert sent at 80%` : `${Math.round(pct)}% used · ${n.left} days left`) : 'Totals still tracked, no alerts';
		noteEl.dataset.level = pct >= 80 ? 'warn' : 'ok';
		root.querySelector('.toast')?.classList.toggle('show', pct >= 80);
		const peak = n.apps[0][2];
		n.apps.forEach(([name, , gb], rank) => {
			const row = rows.get(name)!;
			row.style.transform = `translateY(${rank * ROW}px)`;
			row.querySelector<HTMLElement>('.track i')!.style.width = `${(gb / peak) * 100}%`;
			row.querySelector<HTMLElement>('.val')!.textContent = `${gb.toFixed(1)} GB`;
		});
	}
	list.style.height = `${names.length * ROW}px`;
	buttons.forEach((b, i) => b.addEventListener('click', () => select(b.dataset.net as Key, i)));
	select('home', 0);
}

/** Bars grow and numbers count up when a block scrolls into view; the cap notification slides in. */
function setupReveal() {
	const els = document.querySelectorAll<HTMLElement>('[data-reveal]');
	if (reduceMotion || !('IntersectionObserver' in window)) { els.forEach((e) => e.classList.add('in')); return; }
	const io = new IntersectionObserver((entries) => {
		for (const e of entries) {
			if (!e.isIntersecting) continue;
			const el = e.target as HTMLElement;
			el.classList.add('in');
			el.querySelectorAll<HTMLElement>('[data-count]').forEach((c) => {
				const to = Number(c.dataset.count);
				const dec = Number(c.dataset.dec ?? 0);
				const unit = c.dataset.unit ?? '';
				const t0 = performance.now();
				const step = (t: number) => {
					const k = Math.min(1, (t - t0) / 1100);
					const v = to * (1 - Math.pow(1 - k, 3));
					c.textContent = c.dataset.bytes !== undefined ? bytes(v) : `${v.toFixed(dec)}${unit}`;
					if (k < 1) requestAnimationFrame(step);
				};
				requestAnimationFrame(step);
			});
			io.unobserve(el);
		}
	}, { threshold: 0.35 });
	els.forEach((e) => io.observe(e));
}

const heroPanel = document.getElementById('hero-panel');
const zoom = document.querySelector<HTMLElement>('.zoom');
if (heroPanel && zoom) setupZoom(zoom, setupPanel(heroPanel));
const net = document.querySelector<HTMLElement>('.net-demo');
if (net) setupNetworks(net);
setupReveal();
