public enum DefaultLaunchers {
    public static let seedContent: String = """
        # Remote app launchers for MacXServer.
        #
        # Each [section] becomes a menu item under the Launchers menu.
        # Fields:
        #   host    = hostname or IP (required)
        #   user    = login username (required)
        #   command = X app to launch (required)
        #   port    = telnet port (optional, default 23)
        #   verbose = true/false (optional, default false) -- show progress window
        #   login_prompt    = substring to match for login (default: ogin:)
        #   password_prompt = substring to match for password (default: assword:)
        #   shell_prompt    = substring to match for shell ready (default: "$ ")
        #   password = login password (optional) -- see below
        #
        # If you omit `password`, it's read from the macOS Keychain; on first
        # use of a launcher you're prompted once and it's stored there.
        # Setting `password` here skips that prompt every launch -- handy
        # during development, but it's plaintext in this file, so don't use it
        # on a shared machine.
        #
        # Example:
        #
        # [xterm on u5]
        # host = u5.example.com
        # user = todd
        # command = xterm
        #
        # [xcalc on ss2]
        # host = ss2.example.com
        # user = todd
        # command = xcalc -bg gray90
        """
}
