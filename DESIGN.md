# Design System: Velora AI Studio

## 1. Visual Theme & Atmosphere
**Cinematic Glassmorphism:** Velora is designed to feel like a high-end, futuristic hardware interface. The atmosphere is moody, deep, and immersive. It uses a "Layered Depth" philosophy where content floats over dynamic, blurred backdrops. The density is balanced—spacious enough for a "Gallery" feel, yet dense enough for a professional "Studio" tool.

## 2. Color Palette & Roles
*   **Deep Space Onyx (#000000 / #0a0a0a):** The primary background color. Provides the perfect high-contrast canvas for blurred album art and glassmorphic elements.
*   **Pure Cloud White (#FFFFFF):** Used for primary typography, icons, and high-emphasis playback controls.
*   **Translucent Frost (rgba(255, 255, 255, 0.1)):** The basis for the glassmorphic "Pills" and navigations. Creates a sense of materiality without obscuring the backdrop.
*   **Electric Cobalt (#60a5fa):** The primary accent color (Tailwind `blue-400`). Used for active states (Shuffle/Repeat toggles) and progress indicators.
*   **Vibrant Emerald (#22c55e):** Used for "Live" indicators, like the music visualizer and active track titles in the queue.

## 3. Typography Rules
*   **Brand Identifier:** "Velora." is rendered in the **Stardom** font (or a high-weight geometric serif/sans) with tight tracking, giving it a premium, editorial look.
*   **Interface Text:** Clean, high-legibility sans-serif (Inter/Roboto).
    *   **Headers:** Bold, large tracking-tight (`text-2xl` to `text-5xl`).
    *   **Sub-labels:** Medium weight, reduced opacity (`text-white/60`) to create visual hierarchy.

## 4. Component Stylings
*   **Playback Pill:** A high-gloss, ultra-rounded ("Pill-shaped") container with a light border (`border-white/10`) and deep background blur. It encapsulates the core transport controls.
*   **Album Art:** "Elevated Tiles"—generously rounded corners (`rounded-xl`) with heavy, high-contrast shadows (`shadow-2xl`). In "Mobile Landscape" mode, these are proportionally scaled to anchor the layout.
*   **Navigation Tabs:** Low-profile rounded pills. Active states transition to a solid white background with black text, providing unmistakable focus.
*   **Glass Containers:** Every secondary panel (Queue, Settings) uses a `backdrop-blur-md` or `backdrop-blur-xl` effect with a 10-20% white or black tint.

## 5. Layout Principles
*   **Device-Agnostic Fluidity:** The UI is built using **CSS Container Queries** (`@container`). Unlike standard media queries, Velora components adapt to the *available space* of their parent. This allows the built-in "Simulator" to accurately represent Mobile, Tablet, and Desktop modes within a single view.
*   **Landscape Optimization:** A dedicated "Cinematic Landscape" logic triggers for mobile devices, shifting the track info and album art into a horizontal arrangement to maximize vertical height for controls and lyrics.
*   **Whitespace Strategy:** Generous "Breathing Room" margins (`px-6`, `py-8`) on desktop, tapering down to tight, high-efficiency spacing (`py-2`, `px-6`) on mobile landscape to prevent vertical overflow.
