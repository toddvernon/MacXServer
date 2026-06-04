public enum DefaultLaunchers {
    public static let seedContent: String = """
        # Remote app launchers for MacXServer.
        #
        # The Launchers menu is a two-level menu: top-level entries are
        # remote hosts; each host's submenu lists the apps you can launch
        # there. The file format groups settings to match.
        #
        # Two section shapes:
        #
        #   [host:KEY]            -- defines a host (shared connection
        #                            settings). KEY becomes the top-level
        #                            menu label.
        #   [KEY/ITEM]            -- defines a launcher under host KEY.
        #                            ITEM becomes the submenu label.
        #
        # An item inherits everything from its host block and overrides only
        # what it needs (almost always just `command`).
        #
        # Fields:
        #   host    = hostname or IP             (required on the host block)
        #   user    = login username             (required on the host block)
        #   command = X app to launch            (required on the item)
        #   port    = telnet port                (optional, default 23)
        #   verbose = true/false                 (optional, default false)
        #   login_prompt    = substring          (default: ogin:)
        #   password_prompt = substring          (default: assword:)
        #   shell_prompt    = substring          (default: "$ ")
        #   password = login password            (optional, see below)
        #
        # If you omit `password`, it's read from the macOS Keychain; on first
        # use you're prompted once and it's stored there. Setting `password`
        # in this file skips that prompt every launch -- handy during
        # development, but it's plaintext, so don't use it on a shared
        # machine.
        #
        # `command` is a shell command line, passed verbatim to /bin/sh -c
        # on the remote host. Spaces are arg separators; double-quotes and
        # redirections work. Two gotchas worth knowing:
        #
        #   - Use $HOME, not ~, for the remote user's home directory. On
        #     vintage Suns (SunOS 4 / older Solaris) /bin/sh is the original
        #     Bourne shell, which doesn't do tilde expansion. $HOME works
        #     in every shell back to v7 sh, so it's the bulletproof form.
        #     Absolute paths work too, obviously.
        #   - Single quotes in `command` break the local wrapper, which
        #     wraps your line in 'DISPLAY=...; nohup <command> ...' to set
        #     up the X display on the remote side. Use double-quotes or
        #     the standard '\''-escape idiom if you need a literal single
        #     quote.
        #
        # Example:
        #
        # [host:u5]
        # host = u5.example.com
        # user = todd
        # shell_prompt = vernon]
        #
        # [u5/xterm cyan]
        # command = xterm -bg black -fg cyan -cr yellow
        #
        # [u5/xterm yellow]
        # command = xterm -bg black -fg yellow -cr white
        #
        # [u5/dtpad]
        # command = /usr/dt/bin/dtpad -standAlone
        #
        # [host:ss2]
        # host = ss2.example.com
        # user = todd
        #
        # [ss2/xcalc]
        # command = xcalc -bg gray90
        #
        # Legacy flat sections (no `host:` prefix, no `/` in the name) still
        # parse: they're grouped automatically under the short form of their
        # `host` field (e.g. host = u5.example.com -> "u5" submenu). Migrate
        # at your own pace.
        """
}
