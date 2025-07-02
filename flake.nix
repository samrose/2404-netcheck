{
  description = "Ubuntu 24.04 Network Health Check - Comprehensive networking diagnostics";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        network-healthcheck = pkgs.stdenv.mkDerivation {
          name = "network-healthcheck";
          version = "1.0.0";
          
          src = ./.;
          
          buildInputs = with pkgs; [
            bash
            coreutils
            util-linux
            iproute2
            iputils
            systemd
            bind.dnsutils
            nettools
            procps
            gawk
            gnugrep
            gnused
            findutils
          ];
          
          installPhase = ''
            mkdir -p $out/bin
            cp network_healthcheck.sh $out/bin/network-healthcheck
            chmod +x $out/bin/network-healthcheck
            
            # Patch the script to use Nix store paths for dependencies
            substituteInPlace $out/bin/network-healthcheck \
              --replace '/usr/bin/env bash' '${pkgs.bash}/bin/bash'
            
            # Add PATH to ensure all tools are available
            sed -i '2i export PATH="${pkgs.lib.makeBinPath [
              pkgs.coreutils
              pkgs.util-linux  
              pkgs.iproute2
              pkgs.iputils
              pkgs.systemd
              pkgs.bind.dnsutils
              pkgs.nettools
              pkgs.procps
              pkgs.gawk
              pkgs.gnugrep
              pkgs.gnused
              pkgs.findutils
            ]}:$PATH"' $out/bin/network-healthcheck
          '';
          
          meta = with pkgs.lib; {
            description = "Comprehensive network health check script for Ubuntu 24.04";
            longDescription = ''
              A comprehensive networking health check tool that validates:
              - systemd-networkd status and NDisc route issues
              - DHCP configuration and lease status
              - IPv6 and neighbor discovery functionality
              - Network connectivity and DNS resolution
              - Network interface states and configuration
            '';
            license = licenses.mit;
            platforms = platforms.linux;
            maintainers = [ ];
          };
        };
        
      in {
        packages = {
          default = network-healthcheck;
          network-healthcheck = network-healthcheck;
        };
        
        apps = {
          default = {
            type = "app";
            program = "${network-healthcheck}/bin/network-healthcheck";
          };
          network-healthcheck = {
            type = "app";
            program = "${network-healthcheck}/bin/network-healthcheck";
          };
        };
        
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            bash
            coreutils
            util-linux
            iproute2
            iputils
            systemd
            bind.dnsutils
            nettools
            procps
            gawk
            gnugrep
            gnused
            findutils
          ];
          
          shellHook = ''
            echo "Network Health Check Development Environment"
            echo "Run './network_healthcheck.sh' to test the script"
            echo "All required dependencies are available in PATH"
          '';
        };
      }
    );
}
