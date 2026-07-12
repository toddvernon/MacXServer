import Foundation

// The curated guest dotfiles, embedded app-side so add-user can populate a
// new home on ANY machine -- our images and real hardware alike -- without
// depending on the guest carrying a /home/template stamp (real boxes don't;
// see HELIOS_USER_MANAGEMENT.md, decision #6, 2026-07-11).
//
// CANONICAL COPIES live in the SPARCplug repo at guest-config/dot.{cshrc,
// login,profile}; deploy-dotfiles.py pushes them to the images. If those
// files change, regenerate these blobs (base64 of the raw bytes) so the two
// stay in step -- the unit test pins the byte counts as a tripwire.
//
// Base64 on purpose, not string literals: dot.cshrc carries a literal ESC
// and BEL byte in its prompt block (the file itself warns "keep your editor
// honest"), and a byte payload encoded as a byte payload can't be mangled by
// editors, formatters, or well-meaning refactors.
public enum CanonicalDotfiles {

    /// The files a new home receives, in write order: name (as it lands in
    /// the home directory) and content.
    public static var files: [(name: String, data: Data)] {
        [(".cshrc", cshrc), (".login", login), (".profile", profile)]
    }

    /// guest-config/dot.cshrc, 3713 bytes (2026-07-11 sync).
    public static let cshrc: Data = decode(""
        + "IyAuY3NocmMgLS0gT05FIGNhbm9uaWNhbCBpbnRlcmFjdGl2ZSB0Y3NoIGNvbmZpZyBmb3Ig"
        + "ZXZlcnkgbG9naW4gb24gZXZlcnkKIyBTUEFSQ3BsdWcgZ3Vlc3QgKFNvbGFyaXMgMi42IC8g"
        + "U3VuT1MgNC4xLjQgLyBOZXRCU0QgOS4yKSwgcm9vdCBhbmQgdXNlcnMKIyBhbGlrZS4gTm90"
        + "aGluZyBoZXJlIGlzIHBlci1tYWNoaW5lOiBpdCBkZWNpZGVzIGF0IHJ1bnRpbWUgZnJvbSB0"
        + "Y3NoIGJ1aWx0LWlucwojICAgJE9TVFlQRSAgLT4gc2VhcmNoIHBhdGggKyB3aGljaCBkZXZp"
        + "Y2UgaXMgdGhlIHNlcmlhbCBjb25zb2xlCiMgICAkdWlkICAgICAtPiByb290IHZzLiBvcmRp"
        + "bmFyeS11c2VyIHByb21wdCBhbmQgaGlzdG9yeSBkZXB0aAojIENhbm9uaWNhbCBjb3B5IGxp"
        + "dmVzIGluIHRoZSBTUEFSQ3BsdWcgcmVwbyBhdCBndWVzdC1jb25maWcvZG90LmNzaHJjOwoj"
        + "IGRlcGxveSB3aXRoIGd1ZXN0LWNvbmZpZy9kZXBsb3ktZG90ZmlsZXMucHkuIERvbid0IGhh"
        + "bmQtZWRpdCBvbiBhIGd1ZXN0LgojIE5PVEU6IHRoZSBwcm9tcHQgYmxvY2sgYXQgdGhlIGJv"
        + "dHRvbSBjb250YWlucyBhIGxpdGVyYWwgRVNDIChcMDMzKSBhbmQKIyBCRUwgKFwwMDcpIGJ5"
        + "dGUgZm9yIHRoZSB4dGVybSB0aXRsZSBzZXF1ZW5jZSAtLSBrZWVwIHlvdXIgZWRpdG9yIGhv"
        + "bmVzdC4KdW1hc2sgMDIyCgojIC0tLS0gc2VhcmNoIHBhdGggKHBlci1PUykgLS0tLQpzd2l0"
        + "Y2ggKCAiJE9TVFlQRSIgKQpjYXNlIHNvbGFyaXM6CiAgICBzZXQgcGF0aCA9ICggL3Vzci9s"
        + "b2NhbC9iaW4gL3Vzci9jY3MvYmluIC9iaW4gL3Vzci9iaW4gL3Vzci9zYmluIC91c3IvdWNi"
        + "IC9ldGMgL3Vzci9ldGMgL3Vzci9vcGVud2luL2JpbiAvdXNyL1gxMVI2L2JpbiAuICkKICAg"
        + "IGJyZWFrc3cKY2FzZSBzdW5vczQ6CiAgICBzZXQgcGF0aCA9ICggL3Vzci9sb2NhbC9iaW4g"
        + "L2JpbiAvdXNyL2JpbiAvdXNyL3VjYiAvZXRjIC91c3IvZXRjIC91c3IvZXRjL2luc3RhbGwg"
        + "L3Vzci9vcGVud2luL2JpbiAvdXNyL1gxMVI2L2JpbiAvdXNyL2Jpbi9YMTEgL21udC9zeW5v"
        + "bG9neS9kaXN0IC4gKQogICAgYnJlYWtzdwpjYXNlIE5ldEJTRDoKICAgIHNldCBwYXRoID0g"
        + "KCAvdXNyL2xvY2FsL2JpbiAvYmluIC91c3IvYmluIC9zYmluIC91c3Ivc2JpbiAvdXNyL3Br"
        + "Zy9iaW4gL3Vzci9YMTFSNy9iaW4gLiApCiAgICBicmVha3N3CmVuZHN3CgojIC0tLS0gaWRl"
        + "bnRpdHkgcmVzeW5jIChpbnRlcmFjdGl2ZSBvbmx5KSAtLS0tCiMgU3VuT1MgNC4xLjQgYHN1"
        + "IC1gIGxlYXZlcyAkVVNFUiBwb2ludGluZyBhdCB0aGUgaW52b2tpbmcgdXNlciwgc28gdGNz"
        + "aCdzCiMgJW4gLyAkdXNlciBtaXNyZXBvcnQgaWRlbnRpdHkgYWZ0ZXIgc3UgKHRoZSBwcm9t"
        + "cHQncyBgI2AgaXMgcmlnaHQsIHRoZSBuYW1lCiMgaXNuJ3QpLiB3aG9hbWkgcmVhZHMgdGhl"
        + "IHJlYWwgZXVpZDsgZm9yY2UgJHVzZXIgYW5kICRVU0VSIHRvIGFncmVlIHdpdGggaXQuCiMg"
        + "UHJvbXB0LW9ubHkgKCQ/cHJvbXB0KTogdGhlIGZpeCBpcyBjb3NtZXRpYywgc28gdGhlcmUn"
        + "cyBubyByZWFzb24gdG8gZm9yawojIHdob2FtaSAtLSBvciBjbG9iYmVyIGEgZGVsaWJlcmF0"
        + "ZWx5LXNldCBVU0VSIC0tIGluIHNjcmlwdHMsIGNyb24sIG9yIGBzc2gKIyBob3N0IGNtZGAs"
        + "IGFsbCBvZiB3aGljaCBhbHNvIHNvdXJjZSB0aGlzIGZpbGUuIFBsYWNlZCBhZnRlciB0aGUg"
        + "cGF0aCBibG9jawojIHNvIHdob2FtaSAoL3Vzci91Y2Igb24gU3VuT1MpIGlzIHJlc29sdmFi"
        + "bGUuCmlmICggJD9wcm9tcHQgKSB0aGVuCiAgICBzZXQgdXNlciA9IGB3aG9hbWlgCiAgICBz"
        + "ZXRlbnYgVVNFUiAiJHVzZXIiCmVuZGlmCgojIC0tLS0gaGlzdG9yeSArIHNoZWxsIGJlaGF2"
        + "aW9yIChyb290IHZzLiB1c2VyKSAtLS0tCmlmICggJHVpZCA9PSAwICkgdGhlbgogICAgc2V0"
        + "IGhpc3RvcnkgPSAxMDAwCiAgICBzZXQgc2F2ZWhpc3QgPSAoMTAwMCBtZXJnZSkKICAgIHNl"
        + "dCBhdXRvbGlzdAogICAgc2V0IHJtc3RhcgplbHNlCiAgICBzZXQgaGlzdG9yeSA9IDMyCmVu"
        + "ZGlmCgojIC0tLS0gYWxpYXNlcyAoYWxsIGxvZ2lucykgLS0tLQphbGlhcyBsbCAnbHMgLWwn"
        + "CmFsaWFzIGxhICdscyAtbGEnCmFsaWFzIGggIGhpc3RvcnkKYWxpYXMgZ3JlZW4gICd4dGVy"
        + "bSAtZmcgZ3JlZW4gLWJnIGJsYWNrIC1jciB3aGl0ZSAtc2ImJwphbGlhcyBjeWFuICAgJ3h0"
        + "ZXJtIC1mZyBjeWFuIC1iZyBibGFjayAtY3Igd2hpdGUgLXNiJicKYWxpYXMgeWVsbG93ICd4"
        + "dGVybSAtZmcgeWVsbG93IC1iZyBibGFjayAtY3IgZ3JlZW4gLXNiJicKYWxpYXMgd2hpdGUg"
        + "ICd4dGVybSAtZmcgd2hpdGUgLWJnIGJsYWNrIC1jciBncmVlbiAtc2ImJwoKIyAtLS0tIHRl"
        + "cm1pbmFsIChpbnRlcmFjdGl2ZSBvbmx5KSAtLS0tCiMgTm8gL2Rldi9udWxsIHJlZGlyZWN0"
        + "IG9uIHN0dHkgaGVyZTogU3VuT1MgNCBzdHR5IG9wZXJhdGVzIG9uIFNURE9VVCwgc28KIyBg"
        + "c3R0eSAuLi4gPiYgL2Rldi9udWxsYCBzaWxlbnRseSByZXRhcmdldHMgaXQgYXQgL2Rldi9u"
        + "dWxsIChhIG5vLW9wKS4gVGhlCiMgJD9wcm9tcHQgZ3VhcmQga2VlcHMgbm9uLWludGVyYWN0"
        + "aXZlIHNoZWxscyAoc3NoIGNtZCwgY3NoIC1jKSBxdWlldCBpbnN0ZWFkLgppZiAoICQ/cHJv"
        + "bXB0ICkgdGhlbgogICAgc3R0eSAtaXhvbgogICAgc3R0eSBlcmFzZSAnXkgnCmVuZGlmCnNl"
        + "dGVudiBURVJNIHh0ZXJtCgojIC0tLS0gbWFjWHNlcnZlcjogRElTUExBWSArIHNlcmlhbC1j"
        + "b25zb2xlIGhhbmRsaW5nIC0tLS0KIyBUaGUgY29uc29sZSB0dHkgZGlmZmVycyBieSBPUzog"
        + "TmV0QlNEIHNlcmlhbCBjb25zb2xlID0gL2Rldi90dHlhIChjb25zdHR5CiMgcmVkaXJlY3Rp"
        + "b24pLCBTb2xhcmlzL1N1bk9TID0gL2Rldi9jb25zb2xlLiBDaG9zZW4gYXQgcnVudGltZSBm"
        + "cm9tICRPU1RZUEUuCnNldGVudiBESVNQTEFZIDEwLjAuMi4yOjAKaWYgKCAiJE9TVFlQRSIg"
        + "PT0gTmV0QlNEICkgdGhlbgogICAgc2V0IF9jb24gPSAvZGV2L3R0eWEKZWxzZQogICAgc2V0"
        + "IF9jb24gPSAvZGV2L2NvbnNvbGUKZW5kaWYKaWYgKCAiYHR0eWAiID09ICIkX2NvbiIgKSB0"
        + "aGVuCiAgICBzZXRlbnYgVEVSTSB2dDEwMAogICAgIyBTZXJpYWwgdHR5cyByZXBvcnQgYSAw"
        + "eDAgd2luc2l6ZSAobm90aGluZyBzZXRzIG9uZSksIHdoaWNoIHdlZGdlcwogICAgIyBmdWxs"
        + "LXNjcmVlbiBhcHBzOiBjbSBidXN5LWxvb3BzIG9uIDAgcm93cywgdmkgZ2FyYmxlcy4gdnQx"
        + "MDAgPSAyNHg4MC4KICAgIGlmICggJD9wcm9tcHQgKSBzdHR5IHJvd3MgMjQgY29sdW1ucyA4"
        + "MAplbmRpZgp1bnNldCBfY29uCgojIC0tLS0gcHJvbXB0IChsYXN0LCBzbyBpdCBjYW4gc2Vl"
        + "IHRoZSBmaW5hbCBURVJNKSAtLS0tCiMgJW0gPSBzaG9ydCBob3N0bmFtZS4gT24gYW4geHRl"
        + "cm0gdGhlIHByb21wdCBhbHNvIHJldGl0bGVzIHRoZSB3aW5kb3cgdG8KIyB1c2VyQGhvc3Q6"
        + "Y3dkIHZpYSB0aGUgemVyby13aWR0aCAleyBFU0MgXTA7IC4uLiBCRUwgJX0gc2VxdWVuY2U7"
        + "IHRoZSBzZXJpYWwKIyBjb25zb2xlICh2dDEwMCkgZ2V0cyB0aGUgcGxhaW4gcHJvbXB0Lgpp"
        + "ZiAoICR1aWQgPT0gMCApIHRoZW4KICAgIHNldCBfcCA9ICJbJW06WyVuXTolL10jICIKZWxz"
        + "ZQogICAgc2V0IF9wID0gIlslbTpbJW5dOiUvXSAiCmVuZGlmCmlmICggIiRURVJNIiA9PSB4"
        + "dGVybSApIHRoZW4KICAgIHNldCBwcm9tcHQgPSAiJXsbXTA7JW5AJW06JX4HJX0kX3AiCmVs"
        + "c2UKICAgIHNldCBwcm9tcHQgPSAiJF9wIgplbmRpZgp1bnNldCBfcAo=")

    /// guest-config/dot.login, 425 bytes (2026-07-11 sync).
    public static let login: Data = decode(""
        + "IyAubG9naW4gLS0gY2Fub25pY2FsIGZvciBldmVyeSBsb2dpbiBvbiBldmVyeSBTUEFSQ3Bs"
        + "dWcgZ3Vlc3QuIFJ1bnMgb25jZSBhdAojIGludGVyYWN0aXZlIGxvZ2luLCBhZnRlciAuY3No"
        + "cmMuIEtlZXAgaXQgcXVpZXQ6IC5jc2hyYyBvd25zIFRFUk0gYW5kIHN0dHkKIyAodGhlIG9s"
        + "ZCBTdW5PUyBTTUkgLmxvZ2luIGNsb2JiZXJlZCBURVJNIHdpdGggYHRzZXRgIC0tIGRvbid0"
        + "IGJyaW5nIHRoYXQKIyBiYWNrKS4gQ2Fub25pY2FsIGNvcHk6IFNQQVJDcGx1ZyByZXBvIGd1"
        + "ZXN0LWNvbmZpZy9kb3QubG9naW4uCgojIEEgZm9ydHVuZSBmb3IgbW9ydGFscywgc2lsZW5j"
        + "ZSBmb3Igcm9vdC4KaWYgKCAkP3VpZCApIHRoZW4KICAgIGlmICggJHVpZCAhPSAwICYmIC14"
        + "IC91c3IvZ2FtZXMvZm9ydHVuZSApIC91c3IvZ2FtZXMvZm9ydHVuZQplbmRpZgo=")

    /// guest-config/dot.profile, 1621 bytes (2026-07-11 sync).
    public static let profile: Data = decode(""
        + "IyAucHJvZmlsZSAtLSBPTkUgY2Fub25pY2FsIHNoLXNpZGUgcHJvZmlsZSBmb3IgZXZlcnkg"
        + "bG9naW4gb24gZXZlcnkgU1BBUkNwbHVnCiMgZ3Vlc3QgKFN1bk9TIDQuMS40IC8gU29sYXJp"
        + "cyAyLjYgLyBOZXRCU0QgOS4yKSwgcm9vdCBhbmQgdXNlcnMgYWxpa2UuCiMgQnJhbmNoZXMg"
        + "b24gYHVuYW1lIC1yYCBhdCBydW50aW1lOyBzYW1lIGJ5dGVzIG9uIGFsbCB0aHJlZSBndWVz"
        + "dHMuCiMgQ2Fub25pY2FsIGNvcHk6IFNQQVJDcGx1ZyByZXBvIGd1ZXN0LWNvbmZpZy9kb3Qu"
        + "cHJvZmlsZS4KIwojIExvZ2luIHNoZWxscyBzdGF5IC9iaW4vc2ggKHJvb3QgZXNwZWNpYWxs"
        + "eTogc2luZ2xlLXVzZXIgbWFpbnRlbmFuY2UgbXVzdAojIHdvcmsgd2hlbiAvdXNyL2xvY2Fs"
        + "IGlzIHVuYXZhaWxhYmxlKTsgaW50ZXJhY3RpdmUgc2Vzc2lvbnMgaGFuZCBvZmYgdG8gdGNz"
        + "aAojIGF0IHRoZSBib3R0b20sIHNvIGV2ZXJ5IGludGVyYWN0aXZlIGxvZ2luIGNvbnZlcmdl"
        + "cyBvbiB0aGUgc2FtZSAuY3NocmMuCgpjYXNlICJgdW5hbWUgLXJgIiBpbgo0LiopICAgICMg"
        + "U3VuT1MgNC4xLjQKICAgIFBBVEg9L3Vzci9sb2NhbC9zYmluOi91c3IvbG9jYWwvYmluOi9i"
        + "aW46L3Vzci9iaW46L3Vzci91Y2I6L2V0YzovdXNyL2V0YzovdXNyL2V0Yy9pbnN0YWxsOi91"
        + "c3Ivb3Blbndpbi9iaW46L3Vzci9YMTFSNi9iaW46L3Vzci9iaW4vWDExOi9tbnQvc3lub2xv"
        + "Z3kvZGlzdDouCiAgICBNQU5QQVRIPS91c3IvbG9jYWwvbWFuOi91c3IvbWFuCiAgICBOQ0ZU"
        + "UERJUj0vLm5jZnRwOyBleHBvcnQgTkNGVFBESVIKICAgIDs7CjUuKikgICAgIyBTb2xhcmlz"
        + "IDIuNgogICAgUEFUSD0vdXNyL2xvY2FsL2JpbjovdXNyL2xvY2FsL3NiaW46L3Vzci9jY3Mv"
        + "YmluOi91c3Ivc2JpbjovdXNyL2Jpbjovc2JpbjovZXRjOi91c3IvdWNiOi91c3Ivb3Blbndp"
        + "bi9iaW46LgogICAgTERfTElCUkFSWV9QQVRIPS91c3IvbG9jYWwvbGliOi91c3IvbG9jYWwv"
        + "c3NsL2xpYjsgZXhwb3J0IExEX0xJQlJBUllfUEFUSAogICAgTUFOUEFUSD0vdXNyL2xvY2Fs"
        + "L21hbjovdXNyL21hbjovdXNyL29wZW53aW4vbWFuCiAgICA7Owo5LiopICAgICMgTmV0QlNE"
        + "IDkuMgogICAgUEFUSD0vdXNyL2xvY2FsL3NiaW46L3Vzci9sb2NhbC9iaW46L3NiaW46L3Vz"
        + "ci9zYmluOi9iaW46L3Vzci9iaW46L3Vzci9wa2cvc2JpbjovdXNyL3BrZy9iaW46L3Vzci9Y"
        + "MTFSNy9iaW46LgogICAgTUFOUEFUSD0vdXNyL2xvY2FsL21hbjovdXNyL3BrZy9tYW46L3Vz"
        + "ci9zaGFyZS9tYW46L3Vzci9YMTFSNy9tYW4KICAgIDs7CmVzYWMKZXhwb3J0IFBBVEggTUFO"
        + "UEFUSAoKRElTUExBWT0xMC4wLjIuMjowOyBleHBvcnQgRElTUExBWQpFRElUT1I9dmk7IGV4"
        + "cG9ydCBFRElUT1IKRU5WPSRIT01FLy5rc2hyYzsgZXhwb3J0IEVOViAgICAjIG9ubHkgcmVh"
        + "ZCBpZiB3ZSBldmVyIGxhbmQgaW4ga3NoCgojIEludGVyYWN0aXZlPyBIYW5kIG9mZiB0byB0"
        + "Y3NoIHNvIGV2ZXJ5IGxvZ2luIHNoYXJlcyBvbmUgZW52aXJvbm1lbnQuCmlmIFsgLXQgMCBd"
        + "OyB0aGVuCiAgICBmb3IgX3NoIGluIC91c3IvbG9jYWwvYmluL3Rjc2ggL3Vzci9iaW4vdGNz"
        + "aDsgZG8KICAgICAgICBbIC14ICIkX3NoIiBdICYmIGV4ZWMgIiRfc2giCiAgICBkb25lCmZp"
        + "Cg==")

    private static func decode(_ b64: String) -> Data {
        guard let data = Data(base64Encoded: b64) else {
            // The blobs are compile-time constants; a decode failure is a
            // build-time authoring error, not a runtime condition.
            fatalError("CanonicalDotfiles: embedded base64 is corrupt")
        }
        return data
    }
}
