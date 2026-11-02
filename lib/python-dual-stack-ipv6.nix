# The one interposer that makes `IPV6_V6ONLY=True` setsockopt calls no-ops, so an
# `AF_INET6` `[::]` bind serves both families. asyncio and waitress set that flag by
# default on AF_INET6 sockets, which makes a `[::]` listener v6-only and breaks
# dual-stack clients (including anything probing 127.0.0.1).
#
# The definition-and-delete shape keeps `orig`, `ipv6`, and `v6only` as closure cells
# on the replacement rather than module globals: a consumer's module may be re-imported
# fresh by tests or tooling, and the replacement must not resolve names the module
# stopped defining.
let
  interpose = ''
    def _flake_lib_install_dual_stack_ipv6():
        import socket

        orig = socket.socket.setsockopt
        ipv6, v6only = socket.IPPROTO_IPV6, socket.IPV6_V6ONLY

        def setsockopt(self, level, optname, value, *a, **kw):
            if level == ipv6 and optname == v6only and value:
                return
            return orig(self, level, optname, value, *a, **kw)

        socket.socket.setsockopt = setsockopt

    _flake_lib_install_dual_stack_ipv6()
    del _flake_lib_install_dual_stack_ipv6
  '';
in
{
  # A directory holding a sitecustomize.py, for a PYTHONPATH the consumer controls
  # (a launcher's pythonPath, an environment's PYTHONPATH).
  site = pkgs: pkgs.writeTextDir "sitecustomize.py" interpose;

  # Appends the interposer to `initFile` — an __init__.py the entrypoint
  # transitively imports before any server socket is created — for a package whose
  # interpreter environment the consumer does not control. Appending rather than
  # prepending avoids conflicts with `from __future__` imports at the top of the
  # file, and the block still runs before any bind because __init__.py executes
  # fully during package import.
  withPackage =
    { initFile, package }:
    package.overrideAttrs (old: {
      postPatch =
        (old.postPatch or "")
        + ''
          mkdir -p "$(dirname ${initFile})"
          cat <<'FLAKE_LIB_DUAL_STACK_IPV6_EOF' >> ${initFile}
        ''
        + "\n"
        + interpose
        + ''
          FLAKE_LIB_DUAL_STACK_IPV6_EOF
        '';
    });
}
