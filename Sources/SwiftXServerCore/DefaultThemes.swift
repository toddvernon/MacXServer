// First-run seed for `~/.macxserver-resources`. The bundled content of
// the file the user gets the very first time they launch macXserver.
// After that the file is theirs and we never touch it (per THEMES.md
// decision 3: seed is one-time).
//
// Phase 1 ships exactly one theme (`quickplot`) populated from the
// existing `DefaultMotifResources.text` content. Other themes
// (cde-classic, dark, mwm-default) get added later by extracting from
// the perfected quickplot block.
//
// Layout:
//
//   [macxserver-config]
//   theme: quickplot
//
//   [global]
//   (empty placeholder; Todd will populate as universal rules emerge)
//
//   [theme:quickplot]
//   (all current DefaultMotifResources.text content)

public enum DefaultThemes {

    /// The complete seed content to write to `~/.macxserver-resources`
    /// on first run. Plain UTF-8 text, LF line endings, no trailing
    /// NUL — that's a wire-protocol convention added by the publish
    /// path, not a file-on-disk one.
    public static var seedContent: String {
        return """
        ! macXserver user resources. Edit this file to customize the look of
        ! Motif/CDE apps hosted by macXserver. The active theme is whichever
        ! `[theme:NAME]` block matches the `theme:` value in [macxserver-config].
        ! On save (or via the Preferences > Reload Resources menu), the
        ! server re-reads this file and republishes RESOURCE_MANAGER for
        ! newly-launched clients.
        !
        ! Restart Motif apps to see changes — toolkits cache resources at
        ! connect time and don't re-read on the fly.
        !
        ! See THEMES.md in the project tree for the format spec.

        [macxserver-config]
        theme: quickplot

        [global]
        ! Reserved for resources that should apply regardless of which
        ! theme is active. Empty for now; move rules from
        ! [theme:quickplot] here if you want them to survive a theme
        ! switch (e.g., cursor color, menu accent if you want it
        ! consistent across light/dark themes).

        [theme:quickplot]
        \(DefaultMotifResources.text)

        [motif-frame]
        ! Motif window-manager frame appearance. These control the optional
        ! Mac-side frame drawn around X windows (Preferences > Display).
        ! Colors are #RRGGBB hex. Restart the server to see changes.
        !
        Mwm*background:         #B8BAC0
        Mwm*topShadowColor:     #ECECEE
        Mwm*bottomShadowColor:  #46474C
        Mwm*title*foreground:   #101010
        Mwm*frameBorderWidth:   2
        Mwm*resizeBorderWidth:  2
        Mwm*titleBarHeight:     32
        Mwm*buttonStyle:        motif
        """
    }

    public static let motifFrameSection = """
        [motif-frame]
        ! Motif window-manager frame appearance. These control the optional
        ! Mac-side frame drawn around X windows (Preferences > Display).
        ! Colors are #RRGGBB hex. Restart the server to see changes.
        !
        Mwm*background:         #B8BAC0
        Mwm*topShadowColor:     #ECECEE
        Mwm*bottomShadowColor:  #46474C
        Mwm*title*foreground:   #101010
        Mwm*frameBorderWidth:   2
        Mwm*resizeBorderWidth:  2
        Mwm*titleBarHeight:     32
        Mwm*buttonStyle:        motif
        """
}
