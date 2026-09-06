# MacBud artwork

`MacBud-Sunrise.png` is the user's supplied original image, preserved unchanged. `MacBud-Sunrise-Cutout.af` is the editable Affinity document with its background removed; `MacBud-Sunrise-Cutout.png` is the tightly cropped transparent export used by the app.

Run `swift scripts/make_icon.swift` from the repository root to generate AppIcon, MacBudMark, and MacBudStatusIcon. The app, black notch, welcome screen, and About screen use the gold and terracotta version without a background or enclosing box. The menu bar uses MacBudStatusIcon as a native monochrome template: macOS renders its alpha mask in the appropriate black or white foreground. The template's stored RGB colors do not affect its displayed color.

Earlier `MacBud-Sunrise-Transparent` files are unused intermediate exports; use `MacBud-Sunrise-Cutout` for any further editing. This source directory is excluded from the application bundle.

The older `MacBud-3D` and `MacBud-Notch` Affinity documents and exports are retained as previous designs and are no longer used by the app. An automatic background-cutout experiment was discarded because it added effects; no generated artwork is included in the current assets.
