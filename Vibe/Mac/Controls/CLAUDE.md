# Custom-drawn controls

- The transport and close buttons (`SymbolButton`) and the playing-row indicator (`EqualizerIndicatorView`) draw CALayer content instead of asset-catalog images. That keeps them resolution independent and composites their state changes on the render server.
- `SymbolButton` draws an SF Symbol — `symbolName`, say "play.fill" — rasterized at the backing scale into a CALayer *mask* over a flat color layer. CALayer cannot tint its contents, and the mask keeps the hover, press and disabled transitions as animatable color-property fades. Each button sets its own `symbolPointSize` and the icon sits centered in the frame, so the 50pt transport hit targets carry icons of about 31pt.
