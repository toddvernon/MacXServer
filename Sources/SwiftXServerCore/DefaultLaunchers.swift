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
        #
        # Passwords are stored in the macOS Keychain, not in this file.
        # On first use of a launcher you will be prompted for the password.
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
