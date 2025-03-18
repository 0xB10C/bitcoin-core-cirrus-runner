{
  pkgs,
  ...
}:

{
  nixpkgs.overlays = [
    (self: super: {
      iptables = super.iptables.overrideAttrs (oldAttrs: rec {
	version = "1.8.10";
        src = pkgs.fetchurl {
	  url = "https://www.netfilter.org/projects/iptables/files/iptables-${version}.tar.xz";
          sha256 = "sha256-XMJVwYk1bjF9BwdVzpNx62Oht4PDRJj7jDAmTzzFnJw=";
        };
      });
    })
  ];

}
