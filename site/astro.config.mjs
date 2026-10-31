// @ts-check
import { defineConfig, fontProviders } from 'astro/config';

import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://venkataphanindravutla.github.io',
  base: '/NetPulse',
  integrations: [sitemap()],
  // Downloaded at build time and served from this site, so visitors never contact Google Fonts.
  fonts: [
    { provider: fontProviders.google(), name: 'Geist', cssVariable: '--font-sans', weights: [400, 500, 600, 700], fallbacks: ['system-ui', 'sans-serif'] },
    { provider: fontProviders.google(), name: 'Geist Mono', cssVariable: '--font-mono', weights: [500, 600], fallbacks: ['ui-monospace', 'monospace'] },
  ],
});
