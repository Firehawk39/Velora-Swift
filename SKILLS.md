# Specialized Project Skills: Velora AI Studio

This document captures the specialized technical patterns and "skills" required to maintain and extend the Velora AI Studio codebase.

## 1. The Multi-Device Simulator (App.tsx)
The core of Velora is the **Simulator Wrapper**.
- **Pattern:** The app wraps the inner `main` content in a `viewMode` and `orientation` state-driven container.
- **Maintenance:** Any new global UI added to the root (like the status bar) must be conditioned against `viewMode !== 'desktop'`.
- **Scaling:** The simulator uses `scale-[]` and `origin-top` to fit large devices (Tablet) into the desktop viewport.

## 2. Container-Query Responsive Design
Velora **DOES NOT** use standard Tailwind `md:`, `lg:` prefixes for its core components (Header, NowPlayingView).
- **Skill:** Use `@sm:`, `@md:`, `@lg:`, and `@xl:` container query classes.
- **Why:** This ensures that when the user switches to "Mobile Mode" in the simulator, the components react to the *div's width*, not the *browser's width*.
- **Implementation:** Always ensure the parent container has the `@container` class.

## 3. Cinematic "Now Playing" Logic
The `NowPlayingView` component contains a complex state machine for "Idle Mode" and "Landscape Optimization".
- **isMobileLandscape:** This prop is calculated in `App.tsx` (`viewMode === 'mobile' && orientation === 'landscape'`).
- **Patterns:** 
    - In mobile landscape, the Layout shifts to `flex-row`.
    - Album art is anchored `absolute bottom-0 left-4`.
    - Playback controls sit in the bottom right or center.
- **Requirement:** When adding new controls, they must support both the vertical Stack (Portrait) and the horizontal anchored layout (Landscape).

## 4. AI Backdrop Integration
Velora uses a dual-service approach for its "Cinematic Backdrop":
- **Discogs Search:** Fetches high-resolution imagery based on artist/album strings.
- **Gemini Backup:** If Discogs fails or has low-quality assets, Gemini generates or identifies fallback artistic backdrops.
- **State Management:** These assets are stored in the `discogsData` state in `App.tsx` and passed to a `Unified Backdrop` div using `AnimatePresence` for smooth cross-fading.

## 5. Development Workflow
- **Port:** Defaults to `3001`.
- **Live Preview:** Use the internal browser or `http://localhost:3001/`.
- **Validation:** Always test a UI change across all three simulator modes (Desktop, Tablet, Mobile) and both orientations before considering a task complete.
